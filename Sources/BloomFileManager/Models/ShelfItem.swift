import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ShelfContentKind: String, Codable, CaseIterable, Sendable, Equatable, Hashable {
    case file
    case text
    case image
}

enum ShelfImageFormat: String, Codable, CaseIterable, Sendable, Equatable, Hashable {
    case png
    case tiff

    var displayName: String {
        rawValue.uppercased()
    }

    fileprivate var uniformType: UTType {
        switch self {
        case .png: .png
        case .tiff: .tiff
        }
    }
}

enum ShelfContent: Codable, Sendable, Equatable {
    case file(URL)
    case text(String)
    case image(Data, ShelfImageFormat)

    var kind: ShelfContentKind {
        switch self {
        case .file: .file
        case .text: .text
        case .image: .image
        }
    }

    fileprivate var encodedByteCount: Int {
        switch self {
        case .file: 0
        case let .text(value): value.utf8.count
        case let .image(data, _): data.count
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case fileURL
        case text
        case imageData
        case imageFormat
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try values.decode(ShelfContentKind.self, forKey: .kind)
        switch kind {
        case .file:
            self = .file(try values.decode(URL.self, forKey: .fileURL))
        case .text:
            self = .text(try values.decode(String.self, forKey: .text))
        case .image:
            self = .image(
                try values.decode(Data.self, forKey: .imageData),
                try values.decode(ShelfImageFormat.self, forKey: .imageFormat)
            )
        }
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(kind, forKey: .kind)
        switch self {
        case let .file(url):
            try values.encode(url, forKey: .fileURL)
        case let .text(value):
            try values.encode(value, forKey: .text)
        case let .image(data, format):
            try values.encode(data, forKey: .imageData)
            try values.encode(format, forKey: .imageFormat)
        }
    }
}

enum ShelfItemError: Error, LocalizedError, Equatable, Sendable {
    case invalidFileURL
    case fileURLTooLarge
    case textTooLarge
    case imageTooLarge
    case imagePixelLimitExceeded
    case invalidImage
    case tooManyItems
    case totalPayloadTooLarge
    case duplicateIdentifier

    var errorDescription: String? {
        switch self {
        case .invalidFileURL:
            "The shelf item is not a local file URL."
        case .fileURLTooLarge:
            "The shelf file URL exceeds the 16 KiB limit."
        case .textTooLarge:
            "The shelf text exceeds the 256 KiB limit."
        case .imageTooLarge:
            "The shelf image exceeds the 16 MiB limit."
        case .imagePixelLimitExceeded:
            "The shelf image exceeds the 40 megapixel limit."
        case .invalidImage:
            "The shelf image is not a valid PNG or TIFF image."
        case .tooManyItems:
            "The shelf cannot contain more than 50 items."
        case .totalPayloadTooLarge:
            "The shelf payload exceeds the 64 MiB limit."
        case .duplicateIdentifier:
            "The shelf contains duplicate item identifiers."
        }
    }
}

struct ShelfItem: Codable, Sendable, Equatable, Identifiable {
    static let maximumItemCount = 50
    static let maximumFileURLBytes = 16 * 1024
    static let maximumTextBytes = 256 * 1024
    static let maximumImageBytes = 16 * 1024 * 1024
    static let maximumImagePixels: Int64 = 40 * 1_000 * 1_000
    static let maximumTotalPayloadBytes = 64 * 1024 * 1024

    let id: UUID
    let content: ShelfContent
    let createdAt: Date

    init(id: UUID = UUID(), content: ShelfContent, createdAt: Date = Date()) {
        self.id = id
        self.content = content
        self.createdAt = createdAt
    }

    var kind: ShelfContentKind { content.kind }

    var displayName: String {
        switch content {
        case let .file(url):
            let name = url.lastPathComponent
            return name.isEmpty ? url.path : name
        case let .text(value):
            let firstLine = value.split(maxSplits: 1, omittingEmptySubsequences: false, whereSeparator: \.isNewline).first.map(String.init) ?? ""
            return String(firstLine.prefix(80))
        case let .image(_, format):
            return "\(format.displayName) image"
        }
    }

    var byteCount: Int { content.encodedByteCount }

    static func validatedAddition(_ incoming: [ShelfItem], to existing: [ShelfItem]) throws -> [ShelfItem] {
        // Validate every value before building a result so a later bad value
        // cannot leave a partially imported list behind.
        for item in existing {
            try validate(item)
        }
        for item in incoming {
            try validate(item)
        }

        var identifiers = Set<UUID>()
        for item in existing {
            guard identifiers.insert(item.id).inserted else {
                throw ShelfItemError.duplicateIdentifier
            }
        }
        for item in incoming {
            guard identifiers.insert(item.id).inserted else {
                throw ShelfItemError.duplicateIdentifier
            }
        }

        var result = existing
        var fileURLs = Set(existing.compactMap { item -> URL? in
            guard case let .file(url) = item.content else { return nil }
            return url
        })

        for item in incoming {
            if case let .file(url) = item.content {
                guard fileURLs.insert(url).inserted else { continue }
            }
            result.append(item)
        }

        guard result.count <= maximumItemCount else { throw ShelfItemError.tooManyItems }
        guard totalByteCount(of: result) <= maximumTotalPayloadBytes else {
            throw ShelfItemError.totalPayloadTooLarge
        }
        return result
    }

    static func search(
        _ items: [ShelfItem],
        query: String,
        kind: ShelfContentKind? = nil
    ) -> [ShelfItem] {
        guard !Task.isCancelled else { return [] }

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            var results: [ShelfItem] = []
            results.reserveCapacity(items.count)
            for item in items {
                guard !Task.isCancelled else { return [] }
                if kind == nil || item.kind == kind {
                    results.append(item)
                }
            }
            return results
        }

        let plan: SmartSearchQueryPlan
        do {
            plan = try SmartSearchTextAnalyzer.queryPlan(for: trimmedQuery) {
                try Task.checkCancellation()
            }
        } catch {
            return []
        }

        let foldedQuery = folded(trimmedQuery)
        var results: [ShelfItem] = []
        results.reserveCapacity(items.count)
        for item in items {
            guard !Task.isCancelled else { return [] }
            guard kind == nil || item.kind == kind else { continue }

            if plan.clauses.isEmpty {
                if folded(searchableText(for: item)).contains(foldedQuery) {
                    results.append(item)
                }
                continue
            }

            do {
                let fields = searchableFields(for: item)
                if try SmartSearchTextAnalyzer.match(
                    plan: plan,
                    filename: fields.filename,
                    relativePath: fields.relativePath,
                    analysisStep: { try Task.checkCancellation() }
                ) != nil {
                    results.append(item)
                }
            } catch {
                return []
            }
        }
        return results
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let id = try values.decode(UUID.self, forKey: .id)
        let content = try values.decode(ShelfContent.self, forKey: .content)
        let createdAt = try values.decode(Date.self, forKey: .createdAt)
        let item = ShelfItem(id: id, content: content, createdAt: createdAt)
        try Self.validate(item)
        self = item
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case content
        case createdAt
    }

    private static func validate(_ item: ShelfItem) throws {
        switch item.content {
        case let .file(url):
            try validate(fileURL: url)
        case let .text(value):
            guard value.utf8.count <= maximumTextBytes else { throw ShelfItemError.textTooLarge }
        case let .image(data, format):
            try validate(imageData: data, format: format)
        }
    }

    private static func validate(fileURL url: URL) throws {
        guard url.absoluteString.utf8.count <= maximumFileURLBytes else {
            throw ShelfItemError.fileURLTooLarge
        }
        guard url.isFileURL,
              let scheme = url.scheme?.lowercased(), scheme == "file",
              !url.path.isEmpty,
              url.path.hasPrefix("/"),
              !url.path.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw ShelfItemError.invalidFileURL
        }

        if let host = url.host, !host.isEmpty,
           host.caseInsensitiveCompare("localhost") != .orderedSame {
            throw ShelfItemError.invalidFileURL
        }
    }

    private static func validate(imageData data: Data, format: ShelfImageFormat) throws {
        guard data.count <= maximumImageBytes else { throw ShelfItemError.imageTooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let sourceType = CGImageSourceGetType(source),
              CGImageSourceGetCount(source) == 1,
              String(sourceType) == format.uniformType.identifier,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = (properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?.int64Value,
              let height = (properties[kCGImagePropertyPixelHeight as String] as? NSNumber)?.int64Value,
              width > 0,
              height > 0 else {
            throw ShelfItemError.invalidImage
        }

        // Divide before multiplying so hostile metadata cannot overflow.
        guard width <= maximumImagePixels / height else {
            throw ShelfItemError.imagePixelLimitExceeded
        }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1
        ]
        guard CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) != nil else {
            throw ShelfItemError.invalidImage
        }
    }

    private static func totalByteCount(of items: [ShelfItem]) -> Int {
        items.reduce(into: 0) { total, item in
            total += item.byteCount
        }
    }

    private static func searchableText(for item: ShelfItem) -> String {
        let fields = searchableFields(for: item)
        return "\(fields.filename)\n\(fields.relativePath)"
    }

    private static func searchableFields(for item: ShelfItem) -> (filename: String, relativePath: String) {
        switch item.content {
        case let .file(url):
            return (url.lastPathComponent, url.path)
        case let .text(value):
            return (value, value)
        case let .image(_, format):
            let name = "\(format.displayName) image"
            return (name, name)
        }
    }

    private static func folded(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
    }
}
