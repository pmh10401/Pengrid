import Foundation
import Testing
@testable import BloomFileManager

@Test func tenThousandItemsArriveProgressivelyAndCompletely() async throws {
    let root = try TemporaryDirectory()
    defer { root.removeRecordingFailure() }
    try root.createEmptyFiles(count: 10_000)

    var sizes: [Int] = []
    for try await batch in LiveDirectoryListingService(batchSize: 256).batches(in: root.url) {
        sizes.append(batch.count)
    }

    #expect(sizes.count > 1)
    #expect(sizes.reduce(0, +) == 10_000)
    #expect(sizes.first == 256)
}

private extension TemporaryDirectory {
    func removeRecordingFailure() {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            Issue.record("Could not remove 10,000-item test directory: \(error)")
        }
    }

    func createEmptyFiles(count: Int) throws {
        for index in 0..<count {
            let created = FileManager.default.createFile(
                atPath: url.appending(path: "item-\(index)").path,
                contents: Data()
            )
            if !created {
                throw CocoaError(.fileWriteUnknown)
            }
        }
    }
}
