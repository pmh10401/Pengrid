import Foundation
import Testing
@testable import BloomFileManager

struct PaneBatchBufferTests {
    @Test func bufferPublishesFirstAndCoalescesLaterBatches() {
        var buffer = PaneBatchBuffer()

        #expect(buffer.receive([item("first")]) == .publish([item("first")]))
        #expect(buffer.receive([item("second")]) == .scheduleFlush)
        #expect(buffer.receive([item("third")]) == .none)
        #expect(buffer.drain().map(\.name) == ["second", "third"])
    }

    private func item(_ name: String) -> FileItem {
        FileItem(
            url: URL(filePath: "/buffer/\(name)"),
            name: name,
            isDirectory: false,
            isPackage: false,
            modifiedAt: nil,
            byteSize: 1,
            typeDescription: "File"
        )
    }
}
