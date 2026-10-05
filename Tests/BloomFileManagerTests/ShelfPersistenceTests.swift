import Foundation
import Testing
@testable import BloomFileManager

@Suite("Shelf private local storage")
struct ShelfPersistenceTests {
    @Test func intermediateSymlinkIsNeverFollowed() async throws {
        let fixture = try ShelfDiskFixture()
        defer { fixture.remove() }
        let target = fixture.outer.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let alias = fixture.outer.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        let persistence = ShelfPersistence(root: alias.appendingPathComponent("Shelf"))
        await #expect(throws: (any Error).self) { try await persistence.save([ShelfItem(content: .text("fixture"))]) }
        #expect(!FileManager.default.fileExists(atPath: target.appendingPathComponent("Shelf").path))
    }

    @Test func roundTripAndClearAffectOnlyTheSnapshot() async throws {
        let fixture = try ShelfDiskFixture()
        defer { fixture.remove() }
        let persistence = ShelfPersistence(root: fixture.root)
        let items = [ShelfItem(content: .text("로컬 fixture")), ShelfItem(content: .file(fixture.outer.appendingPathComponent("original")))]
        try Data("original".utf8).write(to: fixture.outer.appendingPathComponent("original"))
        try await persistence.save(items)
        #expect(try await persistence.load() == items)
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.snapshot.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let rootAttributes = try FileManager.default.attributesOfItem(atPath: fixture.root.path)
        #expect((rootAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        let unrelated = fixture.root.appendingPathComponent("unrelated.txt")
        try Data("leave".utf8).write(to: unrelated)
        try await persistence.remove()
        #expect(!FileManager.default.fileExists(atPath: fixture.snapshot.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
        #expect(FileManager.default.fileExists(atPath: fixture.outer.appendingPathComponent("original").path))
        #expect(try await persistence.load().isEmpty)
    }

    @Test func invalidAndOversizedSnapshotsAreRejectedWithoutOverwrite() async throws {
        let fixture = try ShelfDiskFixture()
        defer { fixture.remove() }
        let persistence = ShelfPersistence(root: fixture.root)
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: false)
        try Data("not a plist".utf8).write(to: fixture.snapshot)
        await #expect(throws: (any Error).self) { try await persistence.load() }
        #expect(try String(contentsOf: fixture.snapshot, encoding: .utf8) == "not a plist")
        let handle = try FileHandle(forWritingTo: fixture.snapshot)
        try handle.truncate(atOffset: 70 * 1024 * 1024)
        try handle.close()
        await #expect(throws: (any Error).self) { try await persistence.load() }
    }

    @Test func symlinkSnapshotAndDirectoryAreNeverFollowed() async throws {
        let fixture = try ShelfDiskFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: false)
        let outside = fixture.outer.appendingPathComponent("outside")
        try Data("sentinel".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: fixture.snapshot, withDestinationURL: outside)
        let persistence = ShelfPersistence(root: fixture.root)
        await #expect(throws: (any Error).self) { try await persistence.load() }
        await #expect(throws: (any Error).self) { try await persistence.save([ShelfItem(content: .text("overwrite"))]) }
        await #expect(throws: (any Error).self) { try await persistence.remove() }
        #expect(try String(contentsOf: outside, encoding: .utf8) == "sentinel")
        let linkedRoot = fixture.outer.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: fixture.root)
        let linked = ShelfPersistence(root: linkedRoot)
        await #expect(throws: (any Error).self) { try await linked.load() }
    }

    @Test func malformedRestoredPayloadIsNotAccepted() async throws {
        let fixture = try ShelfDiskFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: false)
        struct Snapshot: Codable { let version: Int; let items: [ShelfItem] }
        let badImage = ShelfItem(content: .image(Data([1, 2, 3]), .png))
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let persistence = ShelfPersistence(root: fixture.root)
        for snapshot in [Snapshot(version: 99, items: []), Snapshot(version: 1, items: [badImage]), Snapshot(version: 1, items: (0..<51).map { ShelfItem(content: .text("\($0)")) })] {
            try encoder.encode(snapshot).write(to: fixture.snapshot)
            await #expect(throws: (any Error).self) { try await persistence.load() }
        }
    }
}

private struct ShelfDiskFixture {
    let outer: URL
    var root: URL { outer.appendingPathComponent("Shelf", isDirectory: true) }
    var snapshot: URL { root.appendingPathComponent("snapshot.plist") }
    init() throws {
        outer = FileManager.default.temporaryDirectory.appendingPathComponent("pengrid-shelf-test-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: outer, withIntermediateDirectories: false)
    }
    func remove() { try? FileManager.default.removeItem(at: outer) }
}
