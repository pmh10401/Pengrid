import Foundation
import Testing
@testable import BloomFileManager

@Suite("ArchiveSourcePreparationServiceTests")
struct ArchiveSourcePreparationServiceTests {
    @Test func sourcePreparationCopiesTopLevelItemsWithMonotonicProgress() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let first = root.url.appending(path: "First.txt")
        let second = root.url.appending(path: "Second.txt")
        let output = root.url.appending(path: "Archive.zip")
        try Data("first".utf8).write(to: first)
        try Data("second".utf8).write(to: second)

        let service = LiveArchiveSourcePreparationService(fileSystem: LiveFileSystemAccess())
        let phases = ArchiveSourcePreparationPhaseCollector()
        let prepared = try await service.prepare(
            identifiedArchiveTestSources([first, second]),
            beside: output,
            parentIdentity: archiveTestIdentity(for: root.url),
            progress: { await phases.append($0) }
        )

        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: prepared.root.path))
            == ["First.txt", "Second.txt"])
        #expect(await phases.values == [
            .preparingSources(completedCount: 0, totalCount: 2),
            .preparingSources(completedCount: 1, totalCount: 2),
            .preparingSources(completedCount: 2, totalCount: 2)
        ])
        try await service.cleanup(prepared)
        #expect(FileManager.default.fileExists(atPath: prepared.root.path) == false)
    }

    @Test func sourcePreparationRejectsSourceIdentityReplacementAndCleansStaging() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let source = root.url.appending(path: "Source.txt")
        let replacement = root.url.appending(path: "Replacement.txt")
        let output = root.url.appending(path: "Archive.zip")
        try Data(repeating: 0x01, count: 256).write(to: source)
        try Data(repeating: 0x02, count: 256).write(to: replacement)
        let originalIdentity = archiveTestIdentity(for: source)
        let hookState = ArchiveSourcePreparationHookState()
        let fileSystem = LiveFileSystemAccess(onBeforeCopySourceEntryOpen: { opened in
            guard opened.standardizedFileURL == source.standardizedFileURL,
                  hookState.takeReplacement() else { return }
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.moveItem(at: replacement, to: source)
        })
        let service = LiveArchiveSourcePreparationService(fileSystem: fileSystem)

        await #expect(throws: Error.self) {
            try await service.prepare(
                identifiedArchiveTestSources([source]),
                beside: output,
                parentIdentity: archiveTestIdentity(for: root.url),
                progress: { _ in }
            )
        }
        #expect(try await fileSystem.identity(of: source) != originalIdentity)
        try expectNoArchivePreparationStagingDirectories(in: root.url)
    }

    @Test func sourcePreparationCancellationCleansStaging() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let source = root.url.appending(path: "Large Source.bin")
        let output = root.url.appending(path: "Archive.zip")
        try Data(repeating: 0x01, count: 128 * 1024).write(to: source)
        let fileSystem = LiveFileSystemAccess(
            copyChunkSize: 4_096,
            onCopyChunk: {
                withUnsafeCurrentTask { $0?.cancel() }
            }
        )
        let service = LiveArchiveSourcePreparationService(fileSystem: fileSystem)

        await #expect(throws: Error.self) {
            try await service.prepare(
                identifiedArchiveTestSources([source]),
                beside: output,
                parentIdentity: archiveTestIdentity(for: root.url),
                progress: { _ in }
            )
        }
        try expectNoArchivePreparationStagingDirectories(in: root.url)
    }
}

private actor ArchiveSourcePreparationPhaseCollector {
    private(set) var values: [ArchiveOperationPhase] = []

    func append(_ phase: ArchiveOperationPhase) {
        values.append(phase)
    }
}

private final class ArchiveSourcePreparationHookState: @unchecked Sendable {
    private let lock = NSLock()
    private var didReplace = false

    func takeReplacement() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !didReplace else { return false }
        didReplace = true
        return true
    }
}

private func expectNoArchivePreparationStagingDirectories(in directory: URL) throws {
    let children = try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: nil
    )
    #expect(children.contains {
        $0.lastPathComponent.hasPrefix(".bloom-staging-")
    } == false)
}
