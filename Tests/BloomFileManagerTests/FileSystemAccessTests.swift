import Foundation
import Testing
@testable import BloomFileManager

@Suite("FileSystemAccessTests")
struct FileSystemAccessTests {
    @Test func exclusiveMovePreservesExistingDestination() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let stagedItem = root.url.appending(path: "staged.zip")
        let destination = root.url.appending(path: "archive.zip")
        let stagedData = Data("staged archive".utf8)
        let existingData = Data("existing archive".utf8)
        try stagedData.write(to: stagedItem)
        try existingData.write(to: destination)
        let fileSystem = LiveFileSystemAccess()
        let destinationIdentity = try #require(await fileSystem.identity(of: destination))

        await #expect(throws: POSIXError(.EEXIST)) {
            try await fileSystem.moveExclusively(stagedItem, to: destination)
        }

        #expect(try Data(contentsOf: destination) == existingData)
        #expect(try await fileSystem.identity(of: destination) == destinationIdentity)
        #expect(try Data(contentsOf: stagedItem) == stagedData)
    }

    @Test func exclusiveMovePublishesStagedItemAtAbsentDestination() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let stagedItem = root.url.appending(path: "staged.zip")
        let destination = root.url.appending(path: "archive.zip")
        let stagedData = Data("staged archive".utf8)
        try stagedData.write(to: stagedItem)
        let fileSystem = LiveFileSystemAccess()
        let stagedIdentity = try #require(await fileSystem.identity(of: stagedItem))

        try await fileSystem.moveExclusively(stagedItem, to: destination)

        #expect(try Data(contentsOf: destination) == stagedData)
        #expect(try await fileSystem.identity(of: destination) == stagedIdentity)
        #expect(FileManager.default.fileExists(atPath: stagedItem.path) == false)
    }

    @Test func identifiedTrashReturnsTheActualURLAndPreservesIdentity() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let source = root.url.appending(path: "trash-result-(UUID().uuidString).txt")
        try Data("temporary test fixture".utf8).write(to: source)
        let fileSystem = LiveFileSystemAccess()
        let identity = try #require(await fileSystem.identity(of: source))
        let resultingURL = try #require(
            try await fileSystem.trashAndReturnResultingURL(source, identifiedBy: identity)
        )
        defer { try? FileManager.default.removeItem(at: resultingURL) }

        #expect(FileManager.default.fileExists(atPath: source.path) == false)
        #expect(try await fileSystem.identity(of: resultingURL) == identity)

        try await fileSystem.move(resultingURL, identifiedBy: identity, to: source)
        #expect(try await fileSystem.identity(of: source) == identity)
    }
}
