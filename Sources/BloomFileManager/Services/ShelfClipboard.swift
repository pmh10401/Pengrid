import AppKit
import ImageIO

// Keep row thumbnail decoding serial, independently of SwiftUI's concurrent row tasks.
actor ShelfThumbnailRenderer {
    static let shared = ShelfThumbnailRenderer()
    func image(for item: ShelfItem) -> CGImage? {
        guard !Task.isCancelled else { return nil }
        return ShelfClipboard.thumbnail(for: item)
    }
}

enum ShelfClipboardError: Error, LocalizedError, Equatable, Sendable {
    case pasteboardChanged
    case sensitiveContents
    case invalidFileBatch
    case unsupportedContents
    case invalidContents
    case missingFile
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .pasteboardChanged:
            "The clipboard changed before it could be imported."
        case .sensitiveContents:
            "This clipboard content is marked as concealed or transient."
        case .invalidFileBatch:
            "The clipboard contains an invalid file selection."
        case .unsupportedContents:
            "The clipboard content is not supported by the shelf."
        case .invalidContents:
            "The clipboard content could not be read."
        case .missingFile:
            "The selected file is no longer available."
        case .writeFailed:
            "The clipboard could not be updated."
        }
    }
}

enum ShelfClipboard {
    @MainActor
    static func read(from board: NSPasteboard, expectedChangeCount: Int) async throws -> [ShelfItem] {
        try requireUnchanged(board, expectedChangeCount: expectedChangeCount)

        let items = board.pasteboardItems ?? []
        guard !items.isEmpty else {
            try requireUnchanged(board, expectedChangeCount: expectedChangeCount)
            return []
        }
        guard items.count <= ShelfItem.maximumItemCount else {
            throw ShelfItemError.tooManyItems
        }

        let boardTypes = board.types ?? []
        if boardTypes.contains(concealedType)
            || boardTypes.contains(transientType)
            || items.contains(where: containsSensitiveMarker) {
            throw ShelfClipboardError.sensitiveContents
        }

        let captured: CapturedClipboard
        if items.contains(where: hasFileURL) {
            captured = try captureFiles(from: items)
        } else if items.contains(where: hasImage) {
            captured = try captureImages(from: items)
        } else {
            captured = try captureText(from: items)
        }
        try requireUnchanged(board, expectedChangeCount: expectedChangeCount)

        let worker = Task.detached(priority: .userInitiated) {
            try Self.decodeAndValidate(captured)
        }
        let result = try await withTaskCancellationHandler(
            operation: { try await worker.value },
            onCancel: { worker.cancel() }
        )
        try Task.checkCancellation()
        try requireUnchanged(board, expectedChangeCount: expectedChangeCount)
        return result
    }

    @MainActor
    static func write(_ item: ShelfItem, to board: NSPasteboard) throws {
        let writer = try writer(for: item)

        board.clearContents()
        guard board.writeObjects([writer]) else {
            throw ShelfClipboardError.writeFailed
        }
    }

    @MainActor
    static func writer(for item: ShelfItem) throws -> any NSPasteboardWriting {
        try validateForWriting(item)

        switch item.content {
        case let .file(url):
            return url as NSURL
        case let .text(value):
            let pasteboardItem = NSPasteboardItem()
            guard pasteboardItem.setString(value, forType: .string) else {
                throw ShelfClipboardError.writeFailed
            }
            return pasteboardItem
        case let .image(data, format):
            let pasteboardItem = NSPasteboardItem()
            let type: NSPasteboard.PasteboardType = format == .png ? .png : .tiff
            guard pasteboardItem.setData(data, forType: type) else {
                throw ShelfClipboardError.writeFailed
            }
            return pasteboardItem
        }
    }

    static func thumbnail(for item: ShelfItem) -> CGImage? {
        guard case let .image(data, _) = item.content,
              (try? ShelfItem.validatedAddition([item], to: [])) != nil,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 256,
            kCGImageSourceShouldCache: false,
            kCGImageSourceShouldCacheImmediately: false
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              thumbnail.width > 0,
              thumbnail.height > 0,
              thumbnail.width <= 256,
              thumbnail.height <= 256 else {
            return nil
        }

        let bytesPerRow = thumbnail.width * 4
        guard bytesPerRow * thumbnail.height <= 256 * 1024,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: thumbnail.width,
                  height: thumbnail.height,
                  bitsPerComponent: 8,
                  bytesPerRow: bytesPerRow,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
              ) else {
            return nil
        }

        context.interpolationQuality = .medium
        context.draw(
            thumbnail,
            in: CGRect(x: 0, y: 0, width: thumbnail.width, height: thumbnail.height)
        )
        guard let image = context.makeImage(),
              image.bitsPerComponent == 8,
              image.bitsPerPixel == 32,
              image.bytesPerRow * image.height <= 256 * 1024 else {
            return nil
        }
        return image
    }

    @MainActor
    private static func requireUnchanged(_ board: NSPasteboard, expectedChangeCount: Int) throws {
        guard board.changeCount == expectedChangeCount else {
            throw ShelfClipboardError.pasteboardChanged
        }
    }

    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    private struct CapturedImage: Sendable {
        let data: Data
        let format: ShelfImageFormat
    }

    private enum CapturedClipboard: Sendable {
        case files([String])
        case images([CapturedImage])
        case text([String])
    }

    @MainActor
    private static func containsSensitiveMarker(_ item: NSPasteboardItem) -> Bool {
        item.types.contains(concealedType) || item.types.contains(transientType)
    }

    @MainActor
    private static func hasFileURL(_ item: NSPasteboardItem) -> Bool {
        item.types.contains(.fileURL)
    }

    @MainActor
    private static func hasImage(_ item: NSPasteboardItem) -> Bool {
        item.types.contains(.png) || item.types.contains(.tiff)
    }

    @MainActor
    private static func captureFiles(from items: [NSPasteboardItem]) throws -> CapturedClipboard {
        guard items.allSatisfy(hasFileURL) else {
            throw ShelfClipboardError.invalidFileBatch
        }

        let values = try items.map { item in
            guard let value = item.string(forType: .fileURL),
                  !value.isEmpty else {
                throw ShelfClipboardError.invalidFileBatch
            }
            return value
        }
        return .files(values)
    }

    @MainActor
    private static func captureImages(from items: [NSPasteboardItem]) throws -> CapturedClipboard {
        let imageItems = items.filter(hasImage)
        guard !imageItems.isEmpty else {
            throw ShelfClipboardError.invalidContents
        }

        var totalBytes = 0
        var result: [CapturedImage] = []
        result.reserveCapacity(imageItems.count)
        for item in imageItems {
            let data: Data
            let format: ShelfImageFormat
            if let pngData = item.data(forType: .png) {
                data = pngData
                format = .png
            } else if let tiffData = item.data(forType: .tiff) {
                data = tiffData
                format = .tiff
            } else {
                throw ShelfClipboardError.invalidContents
            }

            guard data.count <= ShelfItem.maximumImageBytes else {
                throw ShelfItemError.imageTooLarge
            }
            totalBytes += data.count
            guard totalBytes <= ShelfItem.maximumTotalPayloadBytes else {
                throw ShelfItemError.totalPayloadTooLarge
            }
            result.append(CapturedImage(data: data, format: format))
        }
        return .images(result)
    }

    @MainActor
    private static func captureText(from items: [NSPasteboardItem]) throws -> CapturedClipboard {
        var totalBytes = 0
        var result: [String] = []
        result.reserveCapacity(items.count)
        for item in items {
            guard let value = item.string(forType: .string) else {
                throw ShelfClipboardError.unsupportedContents
            }
            let byteCount = value.utf8.count
            guard byteCount <= ShelfItem.maximumTextBytes else {
                throw ShelfItemError.textTooLarge
            }
            totalBytes += byteCount
            guard totalBytes <= ShelfItem.maximumTotalPayloadBytes else {
                throw ShelfItemError.totalPayloadTooLarge
            }
            result.append(value)
        }
        return .text(result)
    }

    private static func decodeAndValidate(_ captured: CapturedClipboard) throws -> [ShelfItem] {
        try Task.checkCancellation()

        let imported: [ShelfItem]
        switch captured {
        case let .files(values):
            imported = try values.map { value in
                guard let url = URL(string: value) else {
                    throw ShelfClipboardError.invalidFileBatch
                }
                return ShelfItem(content: .file(url))
            }
        case let .images(values):
            imported = values.map { ShelfItem(content: .image($0.data, $0.format)) }
        case let .text(values):
            imported = values.map { ShelfItem(content: .text($0)) }
        }

        try Task.checkCancellation()
        return try ShelfItem.validatedAddition(imported, to: [])
    }

    @MainActor
    private static func validateForWriting(_ item: ShelfItem) throws {
        _ = try ShelfItem.validatedAddition([item], to: [])
        if case let .file(url) = item.content,
           !FileManager.default.fileExists(atPath: url.path) {
            throw ShelfClipboardError.missingFile
        }
    }
}
