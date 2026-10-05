import AppKit
import Testing
@testable import BloomFileManager

@Suite("Shelf manual clipboard", .serialized)
@MainActor
struct ShelfClipboardTests {
    @Test func textRoundTripSurvivesValueRemoval() async throws {
        let board = NSPasteboard(name: .init("shelf-test-\(UUID())"))
        defer { board.releaseGlobally() }
        var items = [ShelfItem(content: .text("한글 clipboard"))]
        try ShelfClipboard.write(items[0], to: board)
        items.removeAll()
        let result = try await ShelfClipboard.read(from: board, expectedChangeCount: board.changeCount)
        #expect(result.map(\.content) == [.text("한글 clipboard")])
    }

    @Test func changeBetweenUserActionAndReadRejectsNewContents() async throws {
        let board = NSPasteboard(name: .init("shelf-test-\(UUID())"))
        defer { board.releaseGlobally() }
        board.setString("old", forType: .string)
        let count = board.changeCount
        board.clearContents()
        board.setString("new", forType: .string)
        await #expect(throws: (any Error).self) {
            try await ShelfClipboard.read(from: board, expectedChangeCount: count)
        }
    }

    @Test func concealedAndTransientAreNeverImported() async {
        for type in ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType"] {
            let board = NSPasteboard(name: .init("shelf-test-\(UUID())"))
            defer { board.releaseGlobally() }
            let value = NSPasteboardItem()
            value.setString("secret fixture", forType: .string)
            value.setData(Data(), forType: .init(type))
            board.writeObjects([value])
            await #expect(throws: (any Error).self) {
                try await ShelfClipboard.read(from: board, expectedChangeCount: board.changeCount)
            }
        }
    }

    @Test func fileRepresentationWinsAndInvalidMixedBatchFails() async throws {
        let board = NSPasteboard(name: .init("shelf-test-\(UUID())"))
        defer { board.releaseGlobally() }
        let value = NSPasteboardItem()
        value.setString("file:///tmp/shelf-fixture.txt", forType: .fileURL)
        value.setString("fallback", forType: .string)
        board.writeObjects([value])
        let result = try await ShelfClipboard.read(from: board, expectedChangeCount: board.changeCount)
        #expect(result.map(\.content) == [.file(URL(fileURLWithPath: "/tmp/shelf-fixture.txt"))])

        let invalid = NSPasteboardItem()
        invalid.setString("https://example.invalid/not-a-file", forType: .fileURL)
        board.clearContents()
        let fresh = NSPasteboardItem()
        fresh.setString("file:///tmp/shelf-fixture.txt", forType: .fileURL)
        board.writeObjects([fresh, invalid])
        await #expect(throws: (any Error).self) {
            try await ShelfClipboard.read(from: board, expectedChangeCount: board.changeCount)
        }
    }

    @Test func imageWinsOverAuxiliaryTextAndProducesBoundedThumbnail() async throws {
        let board = NSPasteboard(name: .init("shelf-test-\(UUID())"))
        defer { board.releaseGlobally() }
        let representation = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 512, pixelsHigh: 128,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let data = try #require(representation.representation(using: .png, properties: [:]))
        let value = NSPasteboardItem()
        value.setData(data, forType: .png)
        value.setString("image alt text", forType: .string)
        board.writeObjects([value])
        let item = try #require((await ShelfClipboard.read(from: board, expectedChangeCount: board.changeCount)).first)
        #expect(item.kind == .image)
        let thumbnail = try #require(ShelfClipboard.thumbnail(for: item))
        #expect(thumbnail.width == 256)
        #expect(thumbnail.height == 64)
        #expect(thumbnail.bytesPerRow * thumbnail.height <= 256 * 1024)
        try ShelfClipboard.write(item, to: board)
        #expect(board.data(forType: .png) == data)
    }

    @Test func invalidCopyDoesNotClearExistingClipboard() {
        let board = NSPasteboard(name: .init("shelf-test-\(UUID())"))
        defer { board.releaseGlobally() }
        board.setString("keep fixture", forType: .string)
        #expect(throws: (any Error).self) {
            try ShelfClipboard.write(ShelfItem(content: .image(Data([1, 2]), .png)), to: board)
        }
        #expect(board.string(forType: .string) == "keep fixture")
    }
}
