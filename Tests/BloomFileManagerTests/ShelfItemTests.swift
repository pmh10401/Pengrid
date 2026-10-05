import Foundation
import AppKit
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import BloomFileManager

@Suite struct ShelfItemTests {
    @Test func validatedAdditionRejectsFiftyFirstUniqueInputAtomically() {
        let existing = (0..<50).map { fileItem(path: "/tmp/shelf-existing-\($0)") }
        let candidate = fileItem(path: "/tmp/shelf-51")

        #expect(throws: (any Error).self) {
            try ShelfItem.validatedAddition([candidate], to: existing)
        }
        #expect(existing.count == 50)
        #expect(existing.map(\.id) == (0..<50).map { existing[$0].id })
    }

    @Test func validatedAdditionRejectsOversizedTextBeforeChangingTheList() {
        let existing = [fileItem(path: "/tmp/shelf-existing")]
        let oversized = ShelfItem(content: .text(String(repeating: "a", count: 256 * 1024 + 1)))

        #expect(throws: (any Error).self) {
            try ShelfItem.validatedAddition([oversized], to: existing)
        }
        #expect(existing.count == 1)
        #expect(existing.first?.content == .file(URL(filePath: "/tmp/shelf-existing")))
    }

    @Test func validatedAdditionRejectsCorruptImageBeforeChangingTheList() {
        let existing = [fileItem(path: "/tmp/shelf-existing")]
        let corrupt = ShelfItem(content: .image(Data([0x89, 0x50, 0x4E, 0x47, 0x00]), .png))

        #expect(throws: (any Error).self) {
            try ShelfItem.validatedAddition([corrupt], to: existing)
        }
        #expect(existing.count == 1)
    }

    @Test func validatedAdditionAcceptsImageIOVerifiedTIFF() throws {
        let item = ShelfItem(content: .image(try bitmapData(fileType: .tiff), .tiff))

        let result = try ShelfItem.validatedAddition([item], to: [])

        #expect(result == [item])
        #expect(item.byteCount > 0)
    }

    @Test func validatedAdditionRejectsOversizedImageBeforeImageIOReadsIt() {
        let existing = [fileItem(path: "/tmp/shelf-existing")]
        let oversized = ShelfItem(content: .image(Data(repeating: 0, count: ShelfItem.maximumImageBytes + 1), .png))

        #expect(throws: (any Error).self) {
            try ShelfItem.validatedAddition([oversized], to: existing)
        }
        #expect(existing.count == 1)
    }

    @Test func validatedAdditionRejectsMultiframeTIFFInsteadOfImportingOnlyTheFirstFrame() throws {
        let item = ShelfItem(content: .image(try multiframeTIFFData(), .tiff))

        #expect(throws: (any Error).self) {
            try ShelfItem.validatedAddition([item], to: [])
        }
    }

    @Test func validatedAdditionIgnoresExactDuplicateFileURLsAndKeepsOrder() throws {
        let original = fileItem(path: "/tmp/shelf-duplicate")
        let existing = [original]
        let duplicate = ShelfItem(content: .file(URL(filePath: "/tmp/shelf-duplicate")))
        let text = ShelfItem(content: .text("new note"))

        let result = try ShelfItem.validatedAddition([duplicate, text], to: existing)

        #expect(result.map(\.id) == [original.id, text.id])
        #expect(result.count == 2)
    }

    @Test func validatedAdditionIsAtomicWhenAValidInputPrecedesAnInvalidInput() {
        let existing = [fileItem(path: "/tmp/shelf-existing")]
        let valid = ShelfItem(content: .text("valid"))
        let invalid = ShelfItem(content: .text(String(repeating: "b", count: 256 * 1024 + 1)))

        #expect(throws: (any Error).self) {
            try ShelfItem.validatedAddition([valid, invalid], to: existing)
        }
        #expect(existing.count == 1)
    }

    @Test func codableRoundTripPreservesAllShelfItemValues() throws {
        let item = ShelfItem(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            content: .image(try pngData(), .png),
            createdAt: Date(timeIntervalSince1970: 1_735_689_600)
        )

        let data = try JSONEncoder().encode(item)
        let restored = try JSONDecoder().decode(ShelfItem.self, from: data)

        #expect(restored == item)
    }

    @Test func decodingOversizedTextUsesTheSameValidationBoundary() throws {
        let item = ShelfItem(content: .text("valid"))
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any])
        object["content"] = ["kind": "text", "text": String(repeating: "x", count: 256 * 1024 + 1)]
        let corrupted = try JSONSerialization.data(withJSONObject: object)

        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(ShelfItem.self, from: corrupted)
        }
    }

    @Test func searchUsesInitialsCaseFoldingLiteralPunctuationAndTypeFilters() throws {
        let file = ShelfItem(
            id: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
            content: .file(URL(filePath: "/tmp/한글 Report.pdf"))
        )
        let text = ShelfItem(
            id: UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!,
            content: .text("분기별 report!!!")
        )
        let image = ShelfItem(
            id: UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!,
            content: .image(try pngData(), .png)
        )
        let items = [file, text, image]

        #expect(ShelfItem.search(items, query: "", kind: nil).map(\.id) == items.map(\.id))
        #expect(ShelfItem.search(items, query: "ㅎㄱ", kind: nil).map(\.id) == [file.id])
        #expect(ShelfItem.search(items, query: "REPORT", kind: .file).map(\.id) == [file.id])
        #expect(ShelfItem.search(items, query: "REPORT", kind: .text).map(\.id) == [text.id])
        #expect(ShelfItem.search(items, query: "!!!", kind: .text).map(\.id) == [text.id])
        #expect(ShelfItem.search(items, query: "report", kind: .image).isEmpty)
    }

    @Test func searchUsesFullTextEvenWhenDisplayNameIsBounded() {
        let tail = "needle-at-the-end"
        let item = ShelfItem(content: .text(String(repeating: "prefix ", count: 20) + tail))

        #expect(item.displayName.count <= 80)
        #expect(ShelfItem.search([item], query: tail, kind: .text).map(\.id) == [item.id])
    }

    @Test func validatedAdditionRejectsDuplicateIdentifiersAtomically() {
        let id = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!
        let existing = [ShelfItem(id: id, content: .text("first"))]
        let duplicate = ShelfItem(id: id, content: .text("second"))

        #expect(throws: (any Error).self) {
            try ShelfItem.validatedAddition([duplicate], to: existing)
        }
        #expect(existing.map(\.id) == [id])
    }

    @Test func rejectsNonLocalAndMalformedFileURLs() {
        let existing = [fileItem(path: "/tmp/shelf-existing")]
        let remote = ShelfItem(content: .file(URL(string: "file://example.com/tmp/remote")!))
        let malformed = ShelfItem(content: .file(URL(string: "file://localhost")!))

        #expect(throws: (any Error).self) {
            try ShelfItem.validatedAddition([remote], to: existing)
        }
        #expect(throws: (any Error).self) {
            try ShelfItem.validatedAddition([malformed], to: existing)
        }
        #expect(existing.count == 1)
    }

    @Test func rejectsOverlongFileURLsBeforeTheyEnterTheShelf() {
        let longPath = "/" + String(repeating: "segment/", count: 3_000) + "file.txt"
        let item = ShelfItem(content: .file(URL(filePath: longPath)))

        #expect(throws: (any Error).self) {
            try ShelfItem.validatedAddition([item], to: [])
        }
    }

    private func fileItem(path: String) -> ShelfItem {
        ShelfItem(content: .file(URL(filePath: path)))
    }

    private func pngData() throws -> Data {
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        return try #require(Data(base64Encoded: png))
    }

    private func bitmapData(fileType: NSBitmapImageRep.FileType) throws -> Data {
        let representation = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 2,
            pixelsHigh: 2,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        return try #require(representation.representation(using: fileType, properties: [:]))
    }

    private func multiframeTIFFData() throws -> Data {
        let representation = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 2,
            pixelsHigh: 2,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let image = try #require(representation.cgImage)
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            output,
            UTType.tiff.identifier as CFString,
            2,
            nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }
}
