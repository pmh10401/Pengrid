import Foundation
import Testing
@testable import BloomFileManager

@Test func tenThousandItemsArriveProgressivelyAndCompletely() async throws {
    let root = try TemporaryDirectory()
    defer { root.removeRecordingFailure() }
    try root.createEmptyFiles(count: 10_000)

    let clock = ContinuousClock()
    let start = clock.now
    var firstBatchTime: Duration?
    var sizes: [Int] = []
    for try await batch in LiveDirectoryListingService(batchSize: 256).batches(in: root.url) {
        if firstBatchTime == nil { firstBatchTime = start.duration(to: clock.now) }
        sizes.append(batch.count)
    }
    let complete = start.duration(to: clock.now)

    #expect(sizes.count > 1)
    #expect(sizes.reduce(0, +) == 10_000)
    #expect(sizes.first == 256)
    print(
        "navigation-baseline listing-10k items=\(sizes.reduce(0, +)) batches=\(sizes.count) "
            + "firstBatch=\(firstBatchTime ?? complete) complete=\(complete)"
    )
}

@Test func listingPerformanceProbeReportsFirstBatchAndCompletion() async throws {
    let root = try TemporaryDirectory()
    defer { root.removeRecordingFailure() }
    try root.createEmptyFiles(count: 300)
    let sample = try await measureListing(
        service: LiveDirectoryListingService(batchSize: 256),
        directory: root.url
    )
    #expect(sample.itemCount == 300)
    #expect(sample.batchCount == 2)
    #expect(sample.firstBatch <= sample.complete)
    print(
        "navigation-baseline listing items=\(sample.itemCount) batches=\(sample.batchCount) "
            + "firstBatch=\(sample.firstBatch) complete=\(sample.complete)"
    )
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
