import Foundation
import Testing
@testable import BloomFileManager

@Suite("Identity checked file operation undo")
struct FileOperationUndoServiceTests {
    @Test func renameUndoMovesOnlyTheCapturedIdentityBackToAnEmptyOriginalPath() async throws {
        let original = URL(filePath: "/workspace/Before.txt")
        let renamed = URL(filePath: "/workspace/After.txt")
        let fileSystem = RecordingFileSystem(existingURLs: [renamed])
        let service = FileOperationUndoService(fileSystem: fileSystem)
        let recipe = try #require(await service.makeRecipe(
            kind: .rename,
            result: FileOperationResult(outcomes: [
                .succeeded(source: original, destination: renamed)
            ]),
            allowsUndo: true
        ))

        let result = await service.perform(recipe)

        #expect(result == FileOperationResult(outcomes: [
            .succeeded(source: renamed, destination: original)
        ]))
        #expect(await fileSystem.existingURLs == [original])
        #expect(await fileSystem.events.contains(where: {
            $0 == "moveExclusiveChecked:/workspace/After.txt->/workspace/Before.txt"
        }))
    }

    @Test func restoreRaceNeverOverwritesANewOriginalPath() async throws {
        let original = URL(filePath: "/workspace/Before.txt")
        let renamed = URL(filePath: "/workspace/After.txt")
        let fileSystem = RecordingFileSystem(
            existingURLs: [renamed],
            raceDestinationBeforeExclusiveMove: original
        )
        let service = FileOperationUndoService(fileSystem: fileSystem)
        let recipe = try #require(await service.makeRecipe(
            kind: .rename,
            result: FileOperationResult(outcomes: [
                .succeeded(source: original, destination: renamed)
            ]),
            allowsUndo: true
        ))

        let result = await service.perform(recipe)

        #expect(result.hasFailures)
        #expect(await fileSystem.existingURLs.contains(original))
        #expect(await fileSystem.existingURLs.contains(renamed))
    }

    @Test func moveUndoPreflightRefusesAnOccupiedOriginalWithoutMovingAnything() async throws {
        let original = URL(filePath: "/source/Report.pdf")
        let moved = URL(filePath: "/destination/Report.pdf")
        let fileSystem = RecordingFileSystem(existingURLs: [original, moved])
        let service = FileOperationUndoService(fileSystem: fileSystem)
        let recipe = try #require(await service.makeRecipe(
            kind: .move,
            result: FileOperationResult(outcomes: [
                .succeeded(source: original, destination: moved)
            ]),
            allowsUndo: true
        ))

        let result = await service.perform(recipe)

        #expect(result.hasFailures)
        #expect(await fileSystem.existingURLs == [original, moved])
        #expect(await fileSystem.events.contains(where: { $0.hasPrefix("moveChecked:") }) == false)
    }

    @Test func trashUndoRestoresTheCapturedTrashIdentityToItsOriginalPath() async throws {
        let original = URL(filePath: "/workspace/Deleted.txt")
        let trashed = URL(filePath: "/.Trash/Pengrid-Deleted.txt")
        let fileSystem = RecordingFileSystem(existingURLs: [trashed])
        let service = FileOperationUndoService(fileSystem: fileSystem)
        let recipe = try #require(await service.makeRecipe(
            kind: .trash,
            result: FileOperationResult(outcomes: [
                .succeeded(source: original, destination: trashed)
            ]),
            allowsUndo: true
        ))

        let result = await service.perform(recipe)

        #expect(result == FileOperationResult(outcomes: [
            .succeeded(source: trashed, destination: original)
        ]))
        #expect(await fileSystem.existingURLs == [original])
    }

    @Test func copiedOutputUndoQuarantinesAndTrashesOnlyAnUnchangedFingerprint() async throws {
        let source = URL(filePath: "/source/Photo.jpg")
        let copied = URL(filePath: "/destination/Photo.jpg")
        let fileSystem = RecordingFileSystem(existingURLs: [copied])
        let service = FileOperationUndoService(fileSystem: fileSystem)
        let recipe = try #require(await service.makeRecipe(
            kind: .copy,
            result: FileOperationResult(outcomes: [
                .succeeded(source: source, destination: copied)
            ]),
            allowsUndo: true
        ))

        let result = await service.perform(recipe)

        #expect(result.hasFailures == false)
        #expect(await fileSystem.existingURLs.contains(copied) == false)
        let events = await fileSystem.events
        #expect(events.contains("fingerprint:/destination/Photo.jpg"))
        #expect(events.contains(where: { $0.hasPrefix("moveChecked:/destination/Photo.jpg->") }))
        #expect(events.contains(where: { $0.hasPrefix("trash:") }))
    }

    @Test func copiedOutputUndoRollsBackWhenContentsChangedAfterCompletion() async throws {
        let source = URL(filePath: "/source/Notes.md")
        let copied = URL(filePath: "/destination/Notes.md")
        let fileSystem = RecordingFileSystem(existingURLs: [copied])
        let service = FileOperationUndoService(fileSystem: fileSystem)
        let recipe = try #require(await service.makeRecipe(
            kind: .copy,
            result: FileOperationResult(outcomes: [
                .succeeded(source: source, destination: copied)
            ]),
            allowsUndo: true
        ))
        await fileSystem.mutateContents(at: copied)

        let result = await service.perform(recipe)

        #expect(result.hasFailures)
        #expect(await fileSystem.existingURLs.contains(copied))
        let events = await fileSystem.events
        #expect(events.filter { $0 == "fingerprint:/destination/Notes.md" }.count >= 2)
        #expect(events.contains(where: { $0.hasPrefix("trash:") }) == false)
    }

    @Test func failedTrashCommitRestoresEveryLaterQuarantinedOutput() async throws {
        let firstSource = URL(filePath: "/source/First.txt")
        let secondSource = URL(filePath: "/source/Second.txt")
        let firstCopy = URL(filePath: "/destination/First.txt")
        let secondCopy = URL(filePath: "/destination/Second.txt")
        let fileSystem = RecordingFileSystem(
            existingURLs: [firstCopy, secondCopy],
            forceTrashQuarantineRecovery: true
        )
        let service = FileOperationUndoService(fileSystem: fileSystem)
        let recipe = try #require(await service.makeRecipe(
            kind: .copy,
            result: FileOperationResult(outcomes: [
                .succeeded(source: firstSource, destination: firstCopy),
                .succeeded(source: secondSource, destination: secondCopy)
            ]),
            allowsUndo: true
        ))

        let result = await service.perform(recipe)

        #expect(result.outcomes == [
            .recoveryNeeded(source: firstCopy),
            .cancelled(source: secondCopy)
        ])
        #expect(await !fileSystem.existingURLs.contains(firstCopy))
        #expect(await fileSystem.existingURLs.contains(secondCopy))
    }

    @Test func cancellationBeforeNextTrashCommitRestoresThatQuarantinedOutput() async throws {
        let firstSource = URL(filePath: "/source/First.txt")
        let secondSource = URL(filePath: "/source/Second.txt")
        let firstCopy = URL(filePath: "/destination/First.txt")
        let secondCopy = URL(filePath: "/destination/Second.txt")
        let fileSystem = RecordingFileSystem(existingURLs: [firstCopy, secondCopy])
        let service = FileOperationUndoService(fileSystem: fileSystem)
        let recipe = try #require(await service.makeRecipe(
            kind: .copy,
            result: FileOperationResult(outcomes: [
                .succeeded(source: firstSource, destination: firstCopy),
                .succeeded(source: secondSource, destination: secondCopy)
            ]),
            allowsUndo: true
        ))
        let gate = UndoProgressCancellationGate()

        let operation = Task {
            await service.perform(recipe) { progress in
                guard progress.completedCount == 1 else { return }
                await gate.suspend()
            }
        }
        await gate.waitUntilSuspended()
        operation.cancel()
        await gate.release()
        let result = await operation.value

        #expect(result.outcomes.count == 2)
        guard case let .succeeded(source, destination) = result.outcomes.first else {
            Issue.record("Expected the first output to reach Trash")
            return
        }
        #expect(source == firstCopy)
        #expect(destination != nil)
        #expect(result.outcomes.last == .recoveryNeeded(source: secondCopy))
        #expect(await fileSystem.existingURLs.contains(firstCopy) == false)
        #expect(await fileSystem.existingURLs.contains(secondCopy))
    }

    @Test func partialUndoFailureRequiresRecoveryEvenWhenCurrentItemWasRestored() async throws {
        let firstSource = URL(filePath: "/source/First.txt")
        let secondSource = URL(filePath: "/source/Second.txt")
        let firstCopy = URL(filePath: "/destination/First.txt")
        let secondCopy = URL(filePath: "/destination/Second.txt")
        let fileSystem = RecordingFileSystem(
            existingURLs: [firstCopy, secondCopy],
            failTrashQuarantineCommitOnAttempt: 2
        )
        let service = FileOperationUndoService(fileSystem: fileSystem)
        let recipe = try #require(await service.makeRecipe(
            kind: .copy,
            result: FileOperationResult(outcomes: [
                .succeeded(source: firstSource, destination: firstCopy),
                .succeeded(source: secondSource, destination: secondCopy)
            ]),
            allowsUndo: true
        ))

        let result = await service.perform(recipe)

        #expect(result.outcomes.count == 2)
        guard case .succeeded = result.outcomes.first else {
            Issue.record("Expected the first output to reach Trash")
            return
        }
        #expect(result.outcomes.last == .recoveryNeeded(source: secondCopy))
        #expect(await fileSystem.existingURLs.contains(firstCopy) == false)
        #expect(await fileSystem.existingURLs.contains(secondCopy))
    }

    @Test func replacementJobsAndMissingTrashDestinationsDoNotProduceUndoRecipes() async {
        let source = URL(filePath: "/workspace/Item")
        let destination = URL(filePath: "/workspace/Item copy")
        let fileSystem = RecordingFileSystem(existingURLs: [destination])
        let service = FileOperationUndoService(fileSystem: fileSystem)
        let result = FileOperationResult(outcomes: [
            .succeeded(source: source, destination: destination)
        ])

        #expect(await service.makeRecipe(kind: .copy, result: result, allowsUndo: false) == nil)
        #expect(await service.makeRecipe(
            kind: .trash,
            result: FileOperationResult(outcomes: [
                .succeeded(source: source, destination: nil)
            ]),
            allowsUndo: true
        ) == nil)
    }

    @Test func liveCreatedDirectoryUndoVerifiesQuarantinedContentsBeforeTrash() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let created = root.url.appending(path: "Created", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: created, withIntermediateDirectories: false)
        try Data("keep the exact tree".utf8).write(to: created.appending(path: "child.txt"))
        let service = FileOperationUndoService(fileSystem: LiveFileSystemAccess())
        let recipe = try #require(await service.makeRecipe(
            kind: .createFolder,
            result: FileOperationResult(outcomes: [
                .succeeded(source: created, destination: created)
            ]),
            allowsUndo: true
        ))

        let result = await service.perform(recipe)
        let trashURL = try #require(result.outcomes.compactMap { outcome -> URL? in
            guard case let .succeeded(_, destination) = outcome else { return nil }
            return destination
        }.first)
        defer { try? FileManager.default.removeItem(at: trashURL) }

        #expect(FileManager.default.fileExists(atPath: created.path) == false)
        #expect(FileManager.default.fileExists(atPath: trashURL.appending(path: "child.txt").path))
    }
}

private actor UndoProgressCancellationGate {
    private var isSuspended = false
    private var suspensionWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func suspend() async {
        isSuspended = true
        let waiters = suspensionWaiters
        suspensionWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitUntilSuspended() async {
        if isSuspended { return }
        await withCheckedContinuation { suspensionWaiters.append($0) }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
