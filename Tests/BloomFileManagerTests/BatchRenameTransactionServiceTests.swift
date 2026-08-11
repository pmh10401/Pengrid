import Foundation
import Testing
@testable import BloomFileManager

@Suite struct BatchRenameTransactionServiceTests {
    @Test func liveExecutionRenamesFilesWithoutChangingTheirContents() async throws {
        let fixture = try LiveBatchRenameFixture(contents: [
            "one.txt": "first",
            "two.txt": "second"
        ])
        defer { fixture.remove() }
        let plan = try await fixture.plan(["one.txt": "alpha.txt", "two.txt": "beta.txt"])

        let result = await fixture.service.execute(plan) { _ in }

        #expect(result.outcomes == [
            .succeeded(source: fixture.url("one.txt"), destination: fixture.url("alpha.txt")),
            .succeeded(source: fixture.url("two.txt"), destination: fixture.url("beta.txt"))
        ])
        #expect(try fixture.contents("alpha.txt") == "first")
        #expect(try fixture.contents("beta.txt") == "second")
        #expect(try fixture.names().allSatisfy { !$0.hasPrefix(".pengrid-rename-") })
    }

    @Test func liveExecutionSupportsTwoFileSwap() async throws {
        let fixture = try LiveBatchRenameFixture(contents: ["A.txt": "A", "B.txt": "B"])
        defer { fixture.remove() }
        let plan = try await fixture.plan(["A.txt": "B.txt", "B.txt": "A.txt"])

        let result = await fixture.service.execute(plan) { _ in }

        #expect(!result.hasFailures)
        #expect(try fixture.contents("A.txt") == "B")
        #expect(try fixture.contents("B.txt") == "A")
        #expect(try fixture.names() == ["A.txt", "B.txt"])
    }

    @Test func liveExecutionSupportsThreeFileCycle() async throws {
        let fixture = try LiveBatchRenameFixture(contents: [
            "A.txt": "A",
            "B.txt": "B",
            "C.txt": "C"
        ])
        defer { fixture.remove() }
        let plan = try await fixture.plan([
            "A.txt": "B.txt",
            "B.txt": "C.txt",
            "C.txt": "A.txt"
        ])

        let result = await fixture.service.execute(plan) { _ in }

        #expect(!result.hasFailures)
        #expect(try fixture.contents("A.txt") == "C")
        #expect(try fixture.contents("B.txt") == "A")
        #expect(try fixture.contents("C.txt") == "B")
    }

    @Test func liveCancellationAfterFirstStagingMoveRollsBackNamesAndContents() async throws {
        let fixture = try LiveBatchRenameFixture(contents: ["A.txt": "A", "B.txt": "B"])
        defer { fixture.remove() }
        let plan = try await fixture.plan(["A.txt": "C.txt", "B.txt": "D.txt"])

        let result = await Task {
            await fixture.service.execute(plan) { update in
                guard update.phase == .staging, update.completedCount == 1 else { return }
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }.value

        #expect(result.outcomes.allSatisfy {
            if case .cancelled = $0 { true } else { false }
        })
        #expect(try fixture.names() == ["A.txt", "B.txt"])
        #expect(try fixture.contents("A.txt") == "A")
        #expect(try fixture.contents("B.txt") == "B")
    }

    @Test func sourceIdentityDriftFailsBeforeTheFirstMutation() async throws {
        let fixture = try await RecordingBatchRenameFixture(names: ["A.txt", "B.txt"])
        let replacement = FileIdentity(entryIdentifier: "replacement", resolvedIdentifier: "replacement")
        await fixture.fileSystem.replaceIdentity(at: fixture.url("A.txt"), with: replacement)

        let result = await Task {
            await fixture.service.execute(fixture.plan) { _ in }
        }.value

        #expect(result.hasFailures)
        #expect(await fixture.fileSystem.existingURLs == [
            fixture.parent,
            fixture.url("A.txt"),
            fixture.url("B.txt")
        ])
        #expect(await fixture.fileSystem.events.contains(where: {
            $0.hasPrefix("moveExclusiveChecked:")
        }) == false)
    }

    @Test func destinationCreatedAfterPreviewFailsBeforeStaging() async throws {
        let fixture = try await RecordingBatchRenameFixture(
            names: ["A.txt", "B.txt"],
            proposedNames: ["C.txt", "D.txt"]
        )
        await fixture.fileSystem.replaceIdentity(
            at: fixture.url("c.TXT"),
            with: FileIdentity(entryIdentifier: "raced", resolvedIdentifier: "raced")
        )

        let result = await Task {
            await fixture.service.execute(fixture.plan) { _ in }
        }.value

        #expect(result.hasFailures)
        #expect(await fixture.fileSystem.existingURLs.contains(fixture.url("A.txt")))
        #expect(await fixture.fileSystem.existingURLs.contains(fixture.url("B.txt")))
        #expect(await fixture.fileSystem.events.contains(where: {
            $0.hasPrefix("moveExclusiveChecked:")
        }) == false)
    }

    @Test func parentReplacementFailsBeforeTheFirstMutation() async throws {
        let fixture = try await RecordingBatchRenameFixture(names: ["A.txt", "B.txt"])
        await fixture.fileSystem.replaceIdentity(
            at: fixture.parent,
            with: FileIdentity(entryIdentifier: "new-parent", resolvedIdentifier: "new-parent")
        )

        let result = await fixture.service.execute(fixture.plan) { _ in }

        #expect(result.hasFailures)
        #expect(await fixture.fileSystem.events.contains(where: {
            $0.hasPrefix("moveExclusiveChecked:")
        }) == false)
    }

    @Test func reservedTemporaryNameCollisionFailsBeforeTheFirstMutation() async throws {
        let fixture = try await RecordingBatchRenameFixture(names: ["A.txt", "B.txt"])
        await fixture.fileSystem.replaceIdentity(
            at: fixture.url(".pengrid-rename-test-0"),
            with: FileIdentity(entryIdentifier: "occupied", resolvedIdentifier: "occupied")
        )

        let result = await fixture.service.execute(fixture.plan) { _ in }

        #expect(result.hasFailures)
        #expect(await fixture.fileSystem.existingURLs.contains(fixture.url("A.txt")))
        #expect(await fixture.fileSystem.existingURLs.contains(fixture.url("B.txt")))
    }

    @Test func publishedIdentityDriftRequiresRecoveryWithoutAdoptingReplacement() async throws {
        let fixture = try await RecordingBatchRenameFixture(
            names: ["A.txt", "B.txt"],
            replaceMovedDestinationIdentityAfterCheckedExclusiveMoveAttempts: [3]
        )

        let result = await fixture.service.execute(fixture.plan) { _ in }

        #expect(result.outcomes.contains {
            if case .recoveryNeeded = $0 { true } else { false }
        })
        #expect(await fixture.fileSystem.existingURLs.contains(fixture.url("new-A.txt")))
    }

    @Test func deniedScopedAccessFailsOnceWithoutFilesystemMutation() async throws {
        let fixture = try await RecordingBatchRenameFixture(names: ["A.txt", "B.txt"])
        let driver = DenyingBatchRenameSecurityScopeDriver()
        let coordinator = CloudLocationScopedAccessCoordinator(driver: driver)
        coordinator.replaceManualRoots([fixture.parent])
        let service = BatchRenameTransactionService(
            fileSystem: fixture.fileSystem,
            accessCoordinator: coordinator,
            temporaryName: { ".pengrid-rename-denied-\($0)" }
        )
        await fixture.fileSystem.clearEvents()

        let result = await service.execute(fixture.plan) { _ in }

        #expect(result.hasFailures)
        #expect(driver.startCount == 1)
        #expect(await fixture.fileSystem.events.isEmpty)
    }

    @Test func cancellationDuringStagingRollsBackAndLeavesNoTemporaryNames() async throws {
        let fixture = try await RecordingBatchRenameFixture(
            names: ["A.txt", "B.txt"],
            cancelAfterCheckedExclusiveMoveAttempt: 1
        )

        let result = await Task {
            await fixture.service.execute(fixture.plan) { _ in }
        }.value

        #expect(result.outcomes == [
            .cancelled(source: fixture.url("A.txt")),
            .cancelled(source: fixture.url("B.txt"))
        ])
        #expect(await fixture.fileSystem.existingURLs == [
            fixture.parent,
            fixture.url("A.txt"),
            fixture.url("B.txt")
        ])
    }

    @Test func cancellationDuringPublishingRollsBackPublishedAndStagedItems() async throws {
        let fixture = try await RecordingBatchRenameFixture(
            names: ["A.txt", "B.txt"],
            cancelAfterCheckedExclusiveMoveAttempt: 3
        )

        let result = await Task {
            await fixture.service.execute(fixture.plan) { _ in }
        }.value

        #expect(result.outcomes.allSatisfy {
            if case .cancelled = $0 { true } else { false }
        })
        #expect(await fixture.fileSystem.existingURLs == [
            fixture.parent,
            fixture.url("A.txt"),
            fixture.url("B.txt")
        ])
    }

    @Test func rollbackFailureRequiresRecoveryAndPreservesTheRecoverableItem() async throws {
        let fixture = try await RecordingBatchRenameFixture(
            names: ["A.txt", "B.txt"],
            cancelAfterCheckedExclusiveMoveAttempt: 1,
            failCheckedExclusiveMoveAttempts: [2]
        )

        let result = await Task {
            await fixture.service.execute(fixture.plan) { _ in }
        }.value

        #expect(result.outcomes.contains {
            if case .recoveryNeeded = $0 { true } else { false }
        })
        #expect(await fixture.fileSystem.existingURLs.contains {
            $0.lastPathComponent.hasPrefix(".pengrid-rename-")
        })
    }

    @Test func progressReportsStagingThenPublishingInStableOrder() async throws {
        let fixture = try await RecordingBatchRenameFixture(names: ["A.txt", "B.txt"])
        let recorder = BatchRenameProgressRecorder()

        let result = await fixture.service.execute(fixture.plan) { progress in
            await recorder.append(progress)
        }

        #expect(!result.hasFailures)
        #expect(await recorder.values.map(\.phase) == [
            .staging, .staging, .publishing, .publishing
        ])
        #expect(await recorder.values.map(\.completedCount) == [1, 2, 1, 2])
        #expect(await recorder.values.allSatisfy { !$0.currentName.contains("/") })
    }
}

private actor BatchRenameProgressRecorder {
    private(set) var values: [BatchRenameTransactionProgress] = []

    func append(_ value: BatchRenameTransactionProgress) {
        values.append(value)
    }
}

private struct LiveBatchRenameFixture {
    let root: TemporaryDirectory
    let fileSystem: LiveFileSystemAccess
    let service: BatchRenameTransactionService

    init(contents: [String: String]) throws {
        root = try TemporaryDirectory()
        for (name, contents) in contents {
            try Data(contents.utf8).write(to: root.url.appending(path: name))
        }
        fileSystem = LiveFileSystemAccess()
        service = BatchRenameTransactionService(fileSystem: fileSystem)
    }

    func url(_ name: String) -> URL { root.url.appending(path: name) }
    func contents(_ name: String) throws -> String {
        try String(contentsOf: url(name), encoding: .utf8)
    }
    func names() throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: root.url.path))
    }
    func remove() { root.remove() }

    func plan(_ mapping: [String: String]) async throws -> BatchRenamePlan {
        let orderedNames = mapping.keys.sorted()
        let sources = try await orderedNames.asyncMap { name in
            BatchRenameSource(
                url: url(name),
                identity: try #require(await fileSystem.identity(of: url(name))),
                name: name,
                isDirectory: false,
                isPackage: false
            )
        }
        let request = BatchRenamePlanningRequest(
            parentURL: root.url,
            parentIdentity: try #require(await fileSystem.identity(of: root.url)),
            sources: sources
        )
        let preview = try BatchRenamePlanner.preview(
            request: request,
            proposedNames: orderedNames.map { mapping[$0]! },
            occupiedNames: Set(orderedNames),
            comparisonPolicy: try await fileSystem.filenameComparisonPolicy(in: root.url)
        )
        return try #require(preview.plan)
    }
}

private struct RecordingBatchRenameFixture {
    let parent = URL(filePath: "/workspace", directoryHint: .isDirectory)
    let fileSystem: RecordingFileSystem
    let service: BatchRenameTransactionService
    let plan: BatchRenamePlan

    init(
        names: [String],
        proposedNames: [String]? = nil,
        cancelAfterCheckedExclusiveMoveAttempt: Int? = nil,
        failCheckedExclusiveMoveAttempts: Set<Int> = [],
        replaceMovedDestinationIdentityAfterCheckedExclusiveMoveAttempts: Set<Int> = []
    ) async throws {
        let parent = self.parent
        let sourceURLs = names.map { parent.appending(path: $0) }
        let fileSystem = RecordingFileSystem(
            existingURLs: Set([parent] + sourceURLs),
            caseInsensitivePaths: true,
            cancelAfterCheckedExclusiveMoveAttempt: cancelAfterCheckedExclusiveMoveAttempt,
            failCheckedExclusiveMoveAttempts: failCheckedExclusiveMoveAttempts,
            replaceMovedDestinationIdentityAfterCheckedExclusiveMoveAttempts:
                replaceMovedDestinationIdentityAfterCheckedExclusiveMoveAttempts
        )
        self.fileSystem = fileSystem
        service = BatchRenameTransactionService(
            fileSystem: fileSystem,
            temporaryName: { ".pengrid-rename-test-\($0)" }
        )
        let sources = try await names.asyncMap { name in
            let url = parent.appending(path: name)
            return BatchRenameSource(
                url: url,
                identity: try #require(await fileSystem.identity(of: url)),
                name: name,
                isDirectory: false,
                isPackage: false
            )
        }
        let request = BatchRenamePlanningRequest(
            parentURL: parent,
            parentIdentity: try #require(await fileSystem.identity(of: parent)),
            sources: sources
        )
        let proposedNames = proposedNames ?? names.map { "new-\($0)" }
        let preview = try BatchRenamePlanner.preview(
            request: request,
            proposedNames: proposedNames,
            occupiedNames: Set(names),
            comparisonPolicy: .caseInsensitiveCanonical
        )
        plan = try #require(preview.plan)
        await fileSystem.clearEvents()
    }

    func url(_ name: String) -> URL { parent.appending(path: name) }
}

private final class DenyingBatchRenameSecurityScopeDriver:
    SecurityScopedResourceAccessing, @unchecked Sendable {
    private let lock = NSLock()
    private var starts = 0

    var startCount: Int { lock.withLock { starts } }

    func startAccessing(_ url: URL) -> Bool {
        lock.withLock { starts += 1 }
        return false
    }

    func stopAccessing(_ url: URL) {}
}

private extension Array {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var result: [T] = []
        result.reserveCapacity(count)
        for element in self {
            result.append(try await transform(element))
        }
        return result
    }
}
