import Foundation
import Testing
@testable import BloomFileManager

@Test func listingPublishesMultipleBatchesWithFolderMetadata() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root.appending(path: "Folder"), withIntermediateDirectories: false)
    for index in 0..<300 {
        try Data("x".utf8).write(to: root.appending(path: "file-\(index).txt"))
    }

    var batches: [[FileItem]] = []
    for try await batch in LiveDirectoryListingService(batchSize: 128).batches(in: root) {
        batches.append(batch)
    }

    #expect(batches.count == 3)
    #expect(batches.flatMap { $0 }.count == 301)
    #expect(batches.flatMap { $0 }.first(where: { $0.name == "Folder" })?.isDirectory == true)
}
