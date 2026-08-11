import Foundation
import Testing
@testable import BloomFileManager

@Suite("Identity checked file operation undo")
struct FileOperationUndoServiceTests {
    @Test func duplicateUndoRequiresTheCapturedCreatedIdentityAndFingerprint() async throws {
        let source = URL(filePath: "/workspace/Report.txt")
        let duplicate = URL(filePath: "/workspace/Report copy.txt")
        let fileSystem = RecordingFileSystem(existingURLs: [duplicate])
        let service = FileOperationUndoService(fileSystem: fileSystem)
        let result = await authoritativeUndoResult(
            outcomes: [.succeeded(source: source, destination: duplicate)],
            fileSystem: fileSystem
        )

        let recipe = try #require(await service.makeRecipe(
            kind: .duplicate,
            result: result,
            allowsUndo: true
        ))
        await fileSystem.mutateContents(at: duplicate)

        let undo = await service.perform(recipe)
        #expect(undo.hasFailures)
        #expect(await fileSystem.existingURLs.contains(duplicate))
    }

    @Test func recipeNeverAdoptsAReplacementThatAppearsAfterCompletion() async {
        let source = URL(filePath: "/source/Owned.txt")
        let destination = URL(filePath: "/destination/Owned.txt")
        let ownedIdentity = FileIdentity(
            entryIdentifier: "owned",
            resolvedIdentifier: "owned"
        )
        let replacementIdentity = FileIdentity(
            entryIdentifier: "replacement",
            resolvedIdentifier: "replacement"
        )
        let fileSystem = RecordingFileSystem(
            existingURLs: [destination],
            identities: [destination: replacementIdentity]
        )
        let service = FileOperationUndoService(fileSystem: fileSystem)
        let result = FileOperationResult(
            outcomes: [.succeeded(source: source, destination: destination)],
            undoDestinationIdentities: [destination: ownedIdentity]
        )

        #expect(await service.makeRecipe(
            kind: .copy,
            result: result,
            allowsUndo: true
        ) == nil)
        #expect(await fileSystem.events.contains("fingerprint:/destination/Owned.txt") == false)
    }

    @Test func recipeNeverAdoptsInPlaceEditsMadeAfterMutationCompletion() async throws {
        let source = URL(filePath: "/source/Owned.txt")
        let destination = URL(filePath: "/destination/Owned.txt")
        let ownedIdentity = FileIdentity(
            entryIdentifier: "owned",
            resolvedIdentifier: "owned"
        )
        let fileSystem = RecordingFileSystem(
            existingURLs: [destination],
            identities: [destination: ownedIdentity]
        )
        let mutationFingerprint = try await fileSystem.fingerprint(of: destination)
        await fileSystem.mutateContents(at: destination)
        let service = FileOperationUndoService(fileSystem: fileSystem)
        let result = FileOperationResult(
            outcomes: [.succeeded(source: source, destination: destination)],
            undoDestinationIdentities: [destination: ownedIdentity],
            undoDestinationFingerprints: [destination: mutationFingerprint]
        )

        #expect(await service.makeRecipe(
            kind: .copy,
            result: result,
            allowsUndo: true
        ) == nil)
    }

    @Test func renameUndoMovesOnlyTheCapturedIdentityBackToAnEmptyOriginalPath() async throws {
        let original = URL(filePath: "/workspace/Before.txt")
        let renamed = URL(filePath: "/workspace/After.txt")
        let fileSystem = RecordingFileSystem(existingURLs: [renamed])
        let service = FileOperationUndoService(fileSystem: fileSystem)
        let recipe = try #require(await service.makeRecipe(
            kind: .rename,
            result: await authoritativeUndoResult(outcomes: [
                .succeeded(source: original, destination: renamed)
            ], fileSystem: fileSystem),
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
            result: await authoritativeUndoResult(outcomes: [
                .succeeded(source: original, destination: renamed)
            ], fileSystem: fileSystem),
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
            result: await authoritativeUndoResult(outcomes: [
                .succeeded(source: original, destination: moved)
            ], fileSystem: fileSystem),
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
            result: await authoritativeUndoResult(outcomes: [
                .succeeded(source: original, destination: trashed)
            ], fileSystem: fileSystem),
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
            result: await authoritativeUndoResult(outcomes: [
                .succeeded(source: source, destination: copied)
            ], fileSystem: fileSystem),
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
            result: await authoritativeUndoResult(outcomes: [
                .succeeded(source: source, destination: copied)
            ], fileSystem: fileSystem),
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
            result: await authoritativeUndoResult(outcomes: [
                .succeeded(source: firstSource, destination: firstCopy),
                .succeeded(source: secondSource, destination: secondCopy)
            ], fileSystem: fileSystem),
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
            result: await authoritativeUndoResult(outcomes: [
                .succeeded(source: firstSource, destination: firstCopy),
                .succeeded(source: secondSource, destination: secondCopy)
            ], fileSystem: fileSystem),
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
            result: await authoritativeUndoResult(outcomes: [
                .succeeded(source: firstSource, destination: firstCopy),
                .succeeded(source: secondSource, destination: secondCopy)
            ], fileSystem: fileSystem),
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
            result: await authoritativeUndoResult(outcomes: [
                .succeeded(source: source, destination: nil)
            ], fileSystem: fileSystem),
            allowsUndo: true
        ) == nil)
    }

    @Test func liveCreatedDirectoryUndoVerifiesQuarantinedContentsBeforeTrash() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let created = root.url.appending(path: "Created", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: created, withIntermediateDirectories: false)
        try Data("keep the exact tree".utf8).write(to: created.appending(path: "child.txt"))
        let fileSystem = LiveFileSystemAccess()
        let service = FileOperationUndoService(fileSystem: fileSystem)
        let recipe = try #require(await service.makeRecipe(
            kind: .createFolder,
            result: await authoritativeUndoResult(outcomes: [
                .succeeded(source: created, destination: created)
            ], fileSystem: fileSystem),
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

    @Test func batchRenameUndoReversesASwapThroughTheTransactionEngine() async throws {
        let fixture = try await BatchRenameUndoFixture(
            mapping: ["A.txt": "B.txt", "B.txt": "A.txt"]
        )
        let operationResult = await fixture.transaction.execute(fixture.plan) { _ in }
        let undoService = FileOperationUndoService(
            fileSystem: fixture.fileSystem,
            batchRenameService: fixture.transaction
        )
        let recipe = try #require(await undoService.makeRecipe(
            kind: .rename,
            result: operationResult,
            allowsUndo: true
        ))

        let result = await undoService.perform(recipe)

        #expect(!result.hasFailures)
        #expect(try await fixture.identity("A.txt") == fixture.originalIdentities["A.txt"])
        #expect(try await fixture.identity("B.txt") == fixture.originalIdentities["B.txt"])
        #expect(await fixture.fileSystem.existingURLs == [
            fixture.parent,
            fixture.url("A.txt"),
            fixture.url("B.txt")
        ])
    }

    @Test func liveBatchRenameUndoAcceptsRelocationOnlyMetadataChanges() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let fileSystem = LiveFileSystemAccess()
        let transaction = BatchRenameTransactionService(fileSystem: fileSystem)
        for name in ["A", "B"] {
            let directory = root.url.appending(path: name, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false
            )
            try Data("contents-\(name)".utf8).write(
                to: directory.appending(path: "child.txt")
            )
        }
        let mapping = ["A": "C", "B": "D"]
        var sources: [BatchRenameSource] = []
        for name in mapping.keys.sorted() {
            let url = root.url.appending(path: name, directoryHint: .isDirectory)
            sources.append(BatchRenameSource(
                url: url,
                identity: try #require(await fileSystem.identity(of: url)),
                name: name,
                isDirectory: true,
                isPackage: false
            ))
        }
        let request = BatchRenamePlanningRequest(
            parentURL: root.url,
            parentIdentity: try #require(await fileSystem.identity(of: root.url)),
            sources: sources
        )
        let plan = try #require(BatchRenamePlanner.preview(
            request: request,
            proposedNames: sources.map { mapping[$0.name]! },
            occupiedNames: Set(mapping.keys),
            comparisonPolicy: try await fileSystem.filenameComparisonPolicy(in: root.url)
        ).plan)
        let operationResult = await transaction.execute(plan) { _ in }
        let undoService = FileOperationUndoService(
            fileSystem: fileSystem,
            batchRenameService: transaction
        )
        let recipe = try #require(await undoService.makeRecipe(
            kind: .rename,
            result: operationResult,
            allowsUndo: true
        ))

        let result = await undoService.perform(recipe)

        #expect(!result.hasFailures)
        #expect(try String(
            contentsOf: root.url.appending(path: "A/child.txt"),
            encoding: .utf8
        ) == "contents-A")
        #expect(try String(
            contentsOf: root.url.appending(path: "B/child.txt"),
            encoding: .utf8
        ) == "contents-B")
        #expect(FileManager.default.fileExists(atPath: root.url.appending(path: "C").path) == false)
        #expect(FileManager.default.fileExists(atPath: root.url.appending(path: "D").path) == false)
    }

    @Test func batchRenameUndoRefusesAChangedFinalFingerprint() async throws {
        let fixture = try await BatchRenameUndoFixture(
            mapping: ["A.txt": "C.txt", "B.txt": "D.txt"]
        )
        let operationResult = await fixture.transaction.execute(fixture.plan) { _ in }
        let undoService = FileOperationUndoService(
            fileSystem: fixture.fileSystem,
            batchRenameService: fixture.transaction
        )
        let recipe = try #require(await undoService.makeRecipe(
            kind: .rename,
            result: operationResult,
            allowsUndo: true
        ))
        await fixture.fileSystem.mutateContents(at: fixture.url("C.txt"))

        let result = await undoService.perform(recipe)

        #expect(result.hasFailures)
        #expect(await fixture.fileSystem.existingURLs.contains(fixture.url("C.txt")))
        #expect(await fixture.fileSystem.existingURLs.contains(fixture.url("D.txt")))
    }

    @Test func batchRenameUndoRechecksFingerprintAfterIdentitySafeStaging() async throws {
        let fixture = try await BatchRenameUndoFixture(
            mapping: ["A.txt": "C.txt", "B.txt": "D.txt"],
            mutateMovedDestinationAfterCheckedExclusiveMoveAttempts: [5]
        )
        let operationResult = await fixture.transaction.execute(fixture.plan) { _ in }
        let undoService = FileOperationUndoService(
            fileSystem: fixture.fileSystem,
            batchRenameService: fixture.transaction
        )
        let recipe = try #require(await undoService.makeRecipe(
            kind: .rename,
            result: operationResult,
            allowsUndo: true
        ))

        let result = await undoService.perform(recipe)

        #expect(result.hasFailures)
        #expect(await fixture.fileSystem.existingURLs.contains(fixture.url("C.txt")))
        #expect(await fixture.fileSystem.existingURLs.contains(fixture.url("D.txt")))
        #expect(await fixture.fileSystem.existingURLs.contains {
            $0.lastPathComponent.hasPrefix(".pengrid-rename-")
        } == false)
    }

    @Test func batchRenameUndoRejectsMutationDuringPublication() async throws {
        let fixture = try await BatchRenameUndoFixture(
            mapping: ["A.txt": "C.txt", "B.txt": "D.txt"],
            mutateMovedDestinationAfterCheckedExclusiveMoveAttempts: [7]
        )
        let operationResult = await fixture.transaction.execute(fixture.plan) { _ in }
        let undoService = FileOperationUndoService(
            fileSystem: fixture.fileSystem,
            batchRenameService: fixture.transaction
        )
        let recipe = try #require(await undoService.makeRecipe(
            kind: .rename,
            result: operationResult,
            allowsUndo: true
        ))

        let result = await undoService.perform(recipe)

        #expect(result.hasFailures)
        #expect(await fixture.fileSystem.existingURLs.contains(fixture.url("C.txt")))
        #expect(await fixture.fileSystem.existingURLs.contains(fixture.url("D.txt")))
        #expect(await fixture.fileSystem.existingURLs.contains {
            $0.lastPathComponent.hasPrefix(".pengrid-rename-")
        } == false)
    }

    @Test func batchRenameUndoRefusesAnExternallyOccupiedOriginalName() async throws {
        let fixture = try await BatchRenameUndoFixture(
            mapping: ["A.txt": "C.txt", "B.txt": "D.txt"]
        )
        let operationResult = await fixture.transaction.execute(fixture.plan) { _ in }
        let undoService = FileOperationUndoService(
            fileSystem: fixture.fileSystem,
            batchRenameService: fixture.transaction
        )
        let recipe = try #require(await undoService.makeRecipe(
            kind: .rename,
            result: operationResult,
            allowsUndo: true
        ))
        await fixture.fileSystem.replaceIdentity(
            at: fixture.url("A.txt"),
            with: FileIdentity(entryIdentifier: "external", resolvedIdentifier: "external")
        )

        let result = await undoService.perform(recipe)

        #expect(result.hasFailures)
        #expect(await fixture.fileSystem.existingURLs.contains(fixture.url("A.txt")))
        #expect(await fixture.fileSystem.existingURLs.contains(fixture.url("C.txt")))
    }

    @Test func selectionFolderUndoRecipeRequiresACompleteUnchangedTransaction() async throws {
        let fixture = try await SelectionFolderUndoFixture()
        let undoService = FileOperationUndoService(
            fileSystem: fixture.fileSystem,
            selectionFolderTransactionService: fixture.transaction
        )

        let recipe = try #require(await undoService.makeRecipe(
            kind: .encloseSelection,
            result: fixture.result,
            allowsUndo: true
        ))
        #expect(recipe == .selectionFolder(fixture.undoPlan))

        await fixture.fileSystem.mutateContents(at: fixture.folder.appending(path: "A.txt"))
        await fixture.fileSystem.clearEvents()

        #expect(await undoService.makeRecipe(
            kind: .encloseSelection,
            result: fixture.result,
            allowsUndo: true
        ) == nil)
        #expect(await fixture.fileSystem.events.contains(where: {
            $0.hasPrefix("move") || $0.hasPrefix("remove")
        }) == false)
    }

    @Test func selectionFolderUndoRecipeRejectsEveryGlobalPreflightChangeWithoutMutation() async throws {
        let extraChild = try await SelectionFolderUndoFixture()
        await extraChild.fileSystem.replaceIdentity(
            at: extraChild.folder.appending(path: "External.txt"),
            with: FileIdentity(entryIdentifier: "external", resolvedIdentifier: "external")
        )
        let extraChildUndo = FileOperationUndoService(fileSystem: extraChild.fileSystem)
        await extraChild.fileSystem.clearEvents()
        #expect(await extraChildUndo.makeRecipe(
            kind: .encloseSelection,
            result: extraChild.result,
            allowsUndo: true
        ) == nil)
        #expect(await extraChild.fileSystem.events.contains(where: { $0.hasPrefix("move") }) == false)

        let occupiedOriginal = try await SelectionFolderUndoFixture()
        await occupiedOriginal.fileSystem.replaceIdentity(
            at: occupiedOriginal.parent.appending(path: "A.txt"),
            with: FileIdentity(entryIdentifier: "external", resolvedIdentifier: "external")
        )
        let occupiedOriginalUndo = FileOperationUndoService(fileSystem: occupiedOriginal.fileSystem)
        await occupiedOriginal.fileSystem.clearEvents()
        #expect(await occupiedOriginalUndo.makeRecipe(
            kind: .encloseSelection,
            result: occupiedOriginal.result,
            allowsUndo: true
        ) == nil)
        #expect(await occupiedOriginal.fileSystem.events.contains(where: { $0.hasPrefix("move") }) == false)

        let changedFolder = try await SelectionFolderUndoFixture()
        await changedFolder.fileSystem.replaceIdentity(
            at: changedFolder.folder,
            with: FileIdentity(entryIdentifier: "external-folder", resolvedIdentifier: "external-folder")
        )
        let changedFolderUndo = FileOperationUndoService(fileSystem: changedFolder.fileSystem)
        await changedFolder.fileSystem.clearEvents()
        #expect(await changedFolderUndo.makeRecipe(
            kind: .encloseSelection,
            result: changedFolder.result,
            allowsUndo: true
        ) == nil)
        #expect(await changedFolder.fileSystem.events.contains(where: { $0.hasPrefix("move") }) == false)

        let partial = try await SelectionFolderUndoFixture()
        let partialResult = FileOperationResult(
            outcomes: [
                .succeeded(
                    source: partial.undoPlan.entries[0].originalSource.item.url,
                    destination: partial.undoPlan.entries[0].folderURL
                ),
                .failed(
                    source: partial.undoPlan.entries[1].originalSource.item.url,
                    message: "interrupted"
                )
            ],
            selectionFolderUndoPlan: partial.undoPlan
        )
        let partialUndo = FileOperationUndoService(fileSystem: partial.fileSystem)
        await partial.fileSystem.clearEvents()
        #expect(await partialUndo.makeRecipe(
            kind: .encloseSelection,
            result: partialResult,
            allowsUndo: true
        ) == nil)
        #expect(await partial.fileSystem.events.contains(where: { $0.hasPrefix("move") }) == false)
    }

    @Test func selectionFolderUndoRoutesTheAcceptedRecipeThroughTheReverseTransaction() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let parent = root.url
        let folder = parent.appending(path: "Collected", directoryHint: .isDirectory)
        let first = parent.appending(path: "A.txt")
        let second = parent.appending(path: "B.txt")
        try Data("A".utf8).write(to: first)
        try Data("B".utf8).write(to: second)
        let fileSystem = LiveFileSystemAccess()
        let transaction = SelectionFolderTransactionService(fileSystem: fileSystem)
        let parentIdentity = try #require(await fileSystem.identity(of: parent))
        var sources: [ContextActionSource] = []
        for url in [first, second] {
            sources.append(ContextActionSource(
                item: FileItem(
                    url: url,
                    name: url.lastPathComponent,
                    isDirectory: false,
                    isPackage: false,
                    modifiedAt: nil,
                    byteSize: nil,
                    typeDescription: "Document"
                ),
                identity: try #require(await fileSystem.identity(of: url))
            ))
        }
        let forward = await transaction.execute(SelectionFolderPlan(
            parentURL: parent,
            parentIdentity: parentIdentity,
            folderName: "Collected",
            folderURL: folder,
            sources: sources
        ), progress: { _ in })
        let undoService = FileOperationUndoService(
            fileSystem: fileSystem,
            selectionFolderTransactionService: transaction
        )
        let recipe = try #require(await undoService.makeRecipe(
            kind: .encloseSelection,
            result: forward,
            allowsUndo: true
        ))

        let result = await undoService.perform(recipe)

        #expect(!result.hasFailures)
        #expect(FileManager.default.fileExists(atPath: folder.path) == false)
        #expect(try String(contentsOf: first, encoding: .utf8) == "A")
        #expect(try String(contentsOf: second, encoding: .utf8) == "B")
    }
}

private struct BatchRenameUndoFixture {
    let parent = URL(filePath: "/workspace", directoryHint: .isDirectory)
    let fileSystem: RecordingFileSystem
    let transaction: BatchRenameTransactionService
    let plan: BatchRenamePlan
    let originalIdentities: [String: FileIdentity]

    init(
        mapping: [String: String],
        mutateMovedDestinationAfterCheckedExclusiveMoveAttempts: Set<Int> = []
    ) async throws {
        let parentURL = URL(filePath: "/workspace", directoryHint: .isDirectory)
        let names = mapping.keys.sorted()
        let urls = names.map { parentURL.appending(path: $0) }
        fileSystem = RecordingFileSystem(
            existingURLs: Set([parentURL] + urls),
            caseInsensitivePaths: true,
            mutateMovedDestinationAfterCheckedExclusiveMoveAttempts:
                mutateMovedDestinationAfterCheckedExclusiveMoveAttempts
        )
        transaction = BatchRenameTransactionService(
            fileSystem: fileSystem,
            temporaryName: { ".pengrid-rename-undo-\($0)" }
        )
        var identities: [String: FileIdentity] = [:]
        var sources: [BatchRenameSource] = []
        for name in names {
            let url = parentURL.appending(path: name)
            let identity = try #require(await fileSystem.identity(of: url))
            identities[name] = identity
            sources.append(BatchRenameSource(
                url: url,
                identity: identity,
                name: name,
                isDirectory: false,
                isPackage: false
            ))
        }
        originalIdentities = identities
        let request = BatchRenamePlanningRequest(
            parentURL: parentURL,
            parentIdentity: try #require(await fileSystem.identity(of: parentURL)),
            sources: sources
        )
        plan = try #require(BatchRenamePlanner.preview(
            request: request,
            proposedNames: names.map { mapping[$0]! },
            occupiedNames: Set(names),
            comparisonPolicy: .caseInsensitiveCanonical
        ).plan)
        await fileSystem.clearEvents()
    }

    func url(_ name: String) -> URL { parent.appending(path: name) }

    func identity(_ name: String) async throws -> FileIdentity? {
        try await fileSystem.identity(of: url(name))
    }
}

private struct SelectionFolderUndoFixture {
    let parent = URL(filePath: "/workspace", directoryHint: .isDirectory)
    let folder = URL(filePath: "/workspace/Collected", directoryHint: .isDirectory)
    let fileSystem: RecordingFileSystem
    let transaction: SelectionFolderTransactionService
    let result: FileOperationResult
    let undoPlan: SelectionFolderUndoPlan

    init() async throws {
        let parentURL = URL(filePath: "/workspace", directoryHint: .isDirectory)
        let folderURL = parentURL.appending(path: "Collected", directoryHint: .isDirectory)
        let sourceURLs = ["A.txt", "B.txt"].map { parentURL.appending(path: $0) }
        fileSystem = RecordingFileSystem(existingURLs: Set([parentURL] + sourceURLs))
        transaction = SelectionFolderTransactionService(fileSystem: fileSystem)
        let parentIdentity = try #require(await fileSystem.identity(of: parentURL))
        var sources: [ContextActionSource] = []
        for url in sourceURLs {
            sources.append(ContextActionSource(
                item: FileItem(
                    url: url,
                    name: url.lastPathComponent,
                    isDirectory: false,
                    isPackage: false,
                    modifiedAt: nil,
                    byteSize: nil,
                    typeDescription: "Document"
                ),
                identity: try #require(await fileSystem.identity(of: url))
            ))
        }
        let plan = SelectionFolderPlan(
            parentURL: parentURL,
            parentIdentity: parentIdentity,
            folderName: "Collected",
            folderURL: folderURL,
            sources: sources
        )
        result = await transaction.execute(plan, progress: { _ in })
        undoPlan = try #require(result.selectionFolderUndoMetadata())
        await fileSystem.clearEvents()
    }
}

private func authoritativeUndoResult(
    outcomes: [FileOperationItemOutcome],
    fileSystem: any FileSystemAccess
) async -> FileOperationResult {
    var identities: [URL: FileIdentity] = [:]
    var fingerprints: [URL: SourceFingerprint] = [:]
    for outcome in outcomes {
        guard case let .succeeded(_, destination?) = outcome,
              let identity = try? await fileSystem.identity(of: destination)
        else { continue }
        identities[destination] = identity
        fingerprints[destination] = try? await fileSystem.fingerprint(of: destination)
    }
    return FileOperationResult(
        outcomes: outcomes,
        undoDestinationIdentities: identities,
        undoDestinationFingerprints: fingerprints
    )
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
