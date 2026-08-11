import Foundation
import Testing
@testable import BloomFileManager

@Suite("SelectionFolderTransactionServiceTests", .serialized)
struct SelectionFolderTransactionServiceTests {
    @Test func executeCreatesTheExactFolderMovesSourcesInOrderAndCapturesUndoMetadata() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let first = root.url.appending(path: "A.txt")
        let second = root.url.appending(path: "B.txt")
        try Data("A".utf8).write(to: first)
        try Data("B".utf8).write(to: second)
        let fileSystem = LiveFileSystemAccess()
        let parentIdentity = try #require(await fileSystem.identity(of: root.url))
        let firstIdentity = try #require(await fileSystem.identity(of: first))
        let secondIdentity = try #require(await fileSystem.identity(of: second))
        let plan = SelectionFolderPlan(
            parentURL: root.url,
            parentIdentity: parentIdentity,
            folderName: "Collected",
            folderURL: root.url.appending(path: "Collected", directoryHint: .isDirectory),
            sources: [
                source(first, identity: firstIdentity),
                source(second, identity: secondIdentity)
            ]
        )
        let progress = SelectionFolderProgressRecorder()

        let result = await SelectionFolderTransactionService(fileSystem: fileSystem).execute(
            plan,
            progress: { await progress.append($0) }
        )

        let folder = root.url.appending(path: "Collected", directoryHint: .isDirectory)
        #expect(result.outcomes == [
            .succeeded(source: first, destination: folder.appending(path: "A.txt")),
            .succeeded(source: second, destination: folder.appending(path: "B.txt"))
        ])
        #expect(try Data(contentsOf: folder.appending(path: "A.txt")) == Data("A".utf8))
        #expect(try Data(contentsOf: folder.appending(path: "B.txt")) == Data("B".utf8))
        let undo = try #require(result.selectionFolderUndoMetadata())
        #expect(undo.entries.map(\.originalSource.item.name) == ["A.txt", "B.txt"])
        #expect(await progress.values.map(\.currentName) == ["Collected", "A.txt", "B.txt"])
    }

    @Test func reverseRestoresEveryOriginalPathThenRemovesOnlyTheOwnedEmptyFolder() async throws {
        let fixture = try await makeFixture()
        defer { fixture.root.remove() }
        let service = SelectionFolderTransactionService(fileSystem: fixture.fileSystem)
        let forward = await service.execute(fixture.plan, progress: { _ in })
        let undo = try #require(forward.selectionFolderUndoMetadata())

        let result = await service.reverse(undo, progress: { _ in })

        #expect(result.outcomes == [
            .succeeded(source: fixture.folder.appending(path: "A.txt"), destination: fixture.first),
            .succeeded(source: fixture.folder.appending(path: "B.txt"), destination: fixture.second)
        ])
        #expect(try Data(contentsOf: fixture.first) == Data("A".utf8))
        #expect(try Data(contentsOf: fixture.second) == Data("B".utf8))
        #expect(FileManager.default.fileExists(atPath: fixture.folder.path) == false)
    }

    @Test func reversePreflightDoesNotMutateWhenAnExternalFolderChildAppears() async throws {
        let fixture = try await makeFixture()
        defer { fixture.root.remove() }
        let service = SelectionFolderTransactionService(fileSystem: fixture.fileSystem)
        let forward = await service.execute(fixture.plan, progress: { _ in })
        let undo = try #require(forward.selectionFolderUndoMetadata())
        let external = fixture.folder.appending(path: "external")
        try Data("external".utf8).write(to: external)

        let result = await service.reverse(undo, progress: { _ in })

        #expect(result.outcomes.allSatisfy {
            if case .failed = $0 { return true }
            return false
        })
        #expect(FileManager.default.fileExists(atPath: fixture.folder.appending(path: "A.txt").path))
        #expect(FileManager.default.fileExists(atPath: fixture.folder.appending(path: "B.txt").path))
        #expect(try Data(contentsOf: external) == Data("external".utf8))
        #expect(FileManager.default.fileExists(atPath: fixture.first.path) == false)
        #expect(FileManager.default.fileExists(atPath: fixture.second.path) == false)
    }

    @Test func executePreflightPreservesEverySourceWhenTheFinalFolderNameIsOccupied() async throws {
        let fixture = try await makeFixture()
        defer { fixture.root.remove() }
        try FileManager.default.createDirectory(at: fixture.folder, withIntermediateDirectories: false)

        let result = await SelectionFolderTransactionService(fileSystem: fixture.fileSystem).execute(
            fixture.plan, progress: { _ in }
        )

        #expect(result.outcomes.allSatisfy {
            if case .failed = $0 { return true }
            return false
        })
        #expect(try Data(contentsOf: fixture.first) == Data("A".utf8))
        #expect(try Data(contentsOf: fixture.second) == Data("B".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.folder.path).isEmpty)
    }

    @Test(arguments: [TransactionFault.cancelBeforeCreate, .cancelAfterCreate, .cancelAfterMove(1), .cancelAfterMove(2)])
    func executeCancellationAtEveryMutatedBoundaryRestoresSourcesAndOwnedFolder(
        fault: TransactionFault
    ) async throws {
        let fixture = TransactionFixture(fault: fault)
        let operation = Task {
            await fixture.service.execute(fixture.plan, progress: { _ in })
        }
        let result = await operation.value

        #expect(result.outcomes.allSatisfy {
            if case .cancelled = $0 { return true }
            return false
        })
        #expect(await fixture.fileSystem.exists(fixture.first))
        #expect(await fixture.fileSystem.exists(fixture.second))
        #expect(!(await fixture.fileSystem.exists(fixture.folder)))
    }

    @Test func executeFailureBeforeCreateDoesNotMutateAndBalancesScopedAccess() async throws {
        let access = TransactionScopeRecorder()
        let fixture = TransactionFixture(fault: .failCreate, access: access)
        let result = await fixture.service.execute(fixture.plan, progress: { _ in })

        #expect(result.outcomes.allSatisfy { if case .failed = $0 { return true }; return false })
        #expect(await fixture.fileSystem.events == [])
        #expect(access.starts == access.stops)
        #expect(access.starts == [fixture.parent])
    }

    @Test func executeFailureAfterEachMoveRollsBackInReverseOrder() async throws {
        let fixture = TransactionFixture(fault: .failMove(2))
        let result = await fixture.service.execute(fixture.plan, progress: { _ in })

        #expect(result.outcomes.allSatisfy { if case .failed = $0 { return true }; return false })
        #expect(await fixture.fileSystem.events == [
            "create:Collected", "move:A.txt->A.txt", "move:A.txt->A.txt", "remove:Collected"
        ])
        #expect(await fixture.fileSystem.exists(fixture.first))
        #expect(await fixture.fileSystem.exists(fixture.second))
    }

    @Test func executeFailureAfterCreateRemovesTheOwnedEmptyFolder() async throws {
        let fixture = TransactionFixture(fault: .failMove(1))
        let result = await fixture.service.execute(fixture.plan, progress: { _ in })

        #expect(result.outcomes.allSatisfy { if case .failed = $0 { return true }; return false })
        #expect(await fixture.fileSystem.events == ["create:Collected", "remove:Collected"])
        #expect(await fixture.fileSystem.exists(fixture.first))
        #expect(await fixture.fileSystem.exists(fixture.second))
    }

    @Test func incompleteForwardRollbackIsRecoveryNeededAndLeavesRecoverableItems() async throws {
        let fixture = TransactionFixture(fault: .failMoveAndRollback(2))
        let result = await fixture.service.execute(fixture.plan, progress: { _ in })

        #expect(result.outcomes.contains(.recoveryNeeded(source: fixture.first)))
        #expect(await fixture.fileSystem.exists(fixture.folder.appending(path: "A.txt")))
        #expect(await fixture.fileSystem.exists(fixture.folder))
    }

    @Test func executeCancellationDuringPostMoveIdentityVerificationRestoresThePublishedEntry() async throws {
        let fixture = TransactionFixture(fault: .cancelDuringForwardVerificationAfterMove(1))

        let operation = Task {
            await fixture.service.execute(fixture.plan, progress: { _ in })
        }
        let result = await operation.value

        #expect(result.outcomes.allSatisfy { if case .cancelled = $0 { return true }; return false })
        #expect(await fixture.fileSystem.exists(fixture.first))
        #expect(await fixture.fileSystem.exists(fixture.second))
        #expect(await fixture.fileSystem.exists(fixture.folder) == false)
    }

    @Test(arguments: [TransactionReverseMutation.parent, .folder, .extraChild, .childIdentity, .fingerprint, .occupiedOriginal])
    func reverseGlobalPreflightFailureDoesNotMutate(
        mutation: TransactionReverseMutation
    ) async throws {
        let fixture = TransactionFixture()
        let forward = await fixture.service.execute(fixture.plan, progress: { _ in })
        let undo = try #require(forward.selectionFolderUndoMetadata())
        await fixture.fileSystem.apply(mutation, fixture: fixture)
        let before = await fixture.fileSystem.events.count

        let result = await fixture.service.reverse(undo, progress: { _ in })

        #expect(result.outcomes.allSatisfy { if case .failed = $0 { return true }; return false })
        #expect(await fixture.fileSystem.events.count == before)
    }

    @Test func reverseFailureMovesCompletedEntriesBackIntoTheFolder() async throws {
        let fixture = TransactionFixture(fault: .failReverseMove(2))
        let forward = await fixture.service.execute(fixture.plan, progress: { _ in })
        let undo = try #require(forward.selectionFolderUndoMetadata())
        let result = await fixture.service.reverse(undo, progress: { _ in })

        #expect(result.outcomes.allSatisfy { if case .failed = $0 { return true }; return false })
        #expect(await fixture.fileSystem.exists(fixture.folder.appending(path: "A.txt")))
        #expect(await fixture.fileSystem.exists(fixture.folder.appending(path: "B.txt")))
        #expect(!(await fixture.fileSystem.exists(fixture.first)))
        #expect(!(await fixture.fileSystem.exists(fixture.second)))
    }

    @Test func reverseRechecksEachFingerprintAfterPreflightAndRollsBackEarlierMoves() async throws {
        let fixture = TransactionFixture(fault: .mutateSiblingAfterReversePreflight)
        let forward = await fixture.service.execute(fixture.plan, progress: { _ in })
        let undo = try #require(forward.selectionFolderUndoMetadata())

        let result = await fixture.service.reverse(undo, progress: { _ in })

        #expect(result.outcomes.allSatisfy { if case .failed = $0 { return true }; return false })
        #expect(await fixture.fileSystem.exists(fixture.folder.appending(path: "A.txt")))
        #expect(await fixture.fileSystem.exists(fixture.folder.appending(path: "B.txt")))
        #expect(await fixture.fileSystem.exists(fixture.first) == false)
        #expect(await fixture.fileSystem.exists(fixture.second) == false)
    }

    @Test func incompleteReverseRollbackIsRecoveryNeeded() async throws {
        let fixture = TransactionFixture(fault: .failReverseMoveAndRollback(2))
        let forward = await fixture.service.execute(fixture.plan, progress: { _ in })
        let undo = try #require(forward.selectionFolderUndoMetadata())
        let result = await fixture.service.reverse(undo, progress: { _ in })

        #expect(result.outcomes.contains(.recoveryNeeded(source: fixture.second)))
    }

    @Test(arguments: [1, 2])
    func reverseCancellationRestoresTheFolderAndReportsCancellation(
        afterReverseMove moveIndex: Int
    ) async throws {
        let fixture = TransactionFixture(fault: .cancelReverseMove(moveIndex))
        let forward = await fixture.service.execute(fixture.plan, progress: { _ in })
        let undo = try #require(forward.selectionFolderUndoMetadata())
        let task = Task { await fixture.service.reverse(undo, progress: { _ in }) }
        let result = await task.value

        #expect(result.outcomes.allSatisfy { if case .cancelled = $0 { return true }; return false })
        #expect(await fixture.fileSystem.exists(fixture.folder.appending(path: "A.txt")))
        #expect(await fixture.fileSystem.exists(fixture.folder.appending(path: "B.txt")))
    }

    @Test func malformedReversePlanDoesNotMutate() async throws {
        let fixture = TransactionFixture()
        let forward = await fixture.service.execute(fixture.plan, progress: { _ in })
        let undo = try #require(forward.selectionFolderUndoMetadata())
        let malformed = SelectionFolderUndoPlan(parentURL: undo.parentURL, parentIdentity: undo.parentIdentity,
            folderURL: undo.folderURL, folderIdentity: undo.folderIdentity,
            entries: [undo.entries[0]])
        let before = await fixture.fileSystem.events.count

        let result = await fixture.service.reverse(malformed, progress: { _ in })

        #expect(result.outcomes.allSatisfy { if case .failed = $0 { return true }; return false })
        #expect(await fixture.fileSystem.events.count == before)
    }

    private func source(_ url: URL, identity: FileIdentity) -> ContextActionSource {
        ContextActionSource(
            item: FileItem(
                url: url,
                name: url.lastPathComponent,
                isDirectory: false,
                isPackage: false,
                modifiedAt: nil,
                byteSize: nil,
                typeDescription: "Document"
            ),
            identity: identity
        )
    }

    private func makeFixture() async throws -> SelectionFolderTransactionFixture {
        let root = try TemporaryDirectory()
        let first = root.url.appending(path: "A.txt")
        let second = root.url.appending(path: "B.txt")
        let folder = root.url.appending(path: "Collected", directoryHint: .isDirectory)
        try Data("A".utf8).write(to: first)
        try Data("B".utf8).write(to: second)
        let fileSystem = LiveFileSystemAccess()
        let parentIdentity = try #require(await fileSystem.identity(of: root.url))
        let firstIdentity = try #require(await fileSystem.identity(of: first))
        let secondIdentity = try #require(await fileSystem.identity(of: second))
        return .init(
            root: root,
            first: first,
            second: second,
            folder: folder,
            fileSystem: fileSystem,
            plan: .init(
                parentURL: root.url, parentIdentity: parentIdentity,
                folderName: "Collected", folderURL: folder,
                sources: [source(first, identity: firstIdentity), source(second, identity: secondIdentity)]
            )
        )
    }
}

private struct SelectionFolderTransactionFixture {
    let root: TemporaryDirectory
    let first: URL
    let second: URL
    let folder: URL
    let fileSystem: LiveFileSystemAccess
    let plan: SelectionFolderPlan
}

private actor SelectionFolderProgressRecorder {
    private(set) var values: [SelectionFolderTransactionProgress] = []

    func append(_ value: SelectionFolderTransactionProgress) {
        values.append(value)
    }
}

enum TransactionFault: Sendable, Equatable {
    case none
    case cancelBeforeCreate
    case failCreate
    case cancelAfterCreate
    case cancelAfterMove(Int)
    case cancelDuringForwardVerificationAfterMove(Int)
    case failMove(Int)
    case failMoveAndRollback(Int)
    case failReverseMove(Int)
    case failReverseMoveAndRollback(Int)
    case cancelReverseMove(Int)
    case mutateSiblingAfterReversePreflight
}

enum TransactionReverseMutation: Sendable, Equatable {
    case parent, folder, extraChild, childIdentity, fingerprint, occupiedOriginal
}

private final class TransactionScopeRecorder: SecurityScopedResourceAccessing, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var starts: [URL] = []
    private(set) var stops: [URL] = []
    func startAccessing(_ url: URL) -> Bool { lock.withLock { starts.append(url); return true } }
    func stopAccessing(_ url: URL) { lock.withLock { stops.append(url) } }
}

private final class TransactionFixture: @unchecked Sendable {
    let parent = URL(filePath: "/transaction-parent", directoryHint: .isDirectory)
    let first = URL(filePath: "/transaction-parent/A.txt")
    let second = URL(filePath: "/transaction-parent/B.txt")
    let folder = URL(filePath: "/transaction-parent/Collected", directoryHint: .isDirectory)
    let parentIdentity = FileIdentity(entryIdentifier: "parent", resolvedIdentifier: "parent")
    let firstIdentity = FileIdentity(entryIdentifier: "a", resolvedIdentifier: "a")
    let secondIdentity = FileIdentity(entryIdentifier: "b", resolvedIdentifier: "b")
    let fileSystem: TransactionFileSystem
    let service: SelectionFolderTransactionService
    lazy var plan = SelectionFolderPlan(parentURL: parent, parentIdentity: parentIdentity,
        folderName: "Collected", folderURL: folder, sources: [item(first, firstIdentity), item(second, secondIdentity)])

    init(fault: TransactionFault = .none, access: TransactionScopeRecorder? = nil) {
        fileSystem = TransactionFileSystem(parent: parent, parentIdentity: parentIdentity,
            entries: [first: firstIdentity, second: secondIdentity], fault: fault)
        let coordinator = CloudLocationScopedAccessCoordinator(driver: access ?? TransactionScopeRecorder())
        coordinator.replaceManualRoots([parent])
        service = SelectionFolderTransactionService(fileSystem: fileSystem, accessCoordinator: coordinator)
    }

    private func item(_ url: URL, _ identity: FileIdentity) -> ContextActionSource {
        .init(item: .init(url: url, name: url.lastPathComponent, isDirectory: false,
            isPackage: false, modifiedAt: nil, byteSize: nil, typeDescription: "Document"), identity: identity)
    }
}

private actor TransactionFileSystem: FileSystemAccess {
    private var entries: [URL: FileIdentity]
    private let parent: URL
    private let parentIdentity: FileIdentity
    private let fault: TransactionFault
    private var moveAttempt = 0
    private var reverseMoveAttempt = 0
    private var fingerprints: [URL: Int] = [:]
    private var fingerprintCallCount = 0
    private var didCancelForwardVerification = false
    private(set) var events: [String] = []

    init(parent: URL, parentIdentity: FileIdentity, entries: [URL: FileIdentity], fault: TransactionFault) {
        self.parent = parent; self.parentIdentity = parentIdentity; self.entries = entries; self.fault = fault
        self.entries[parent] = parentIdentity
    }

    func exists(_ url: URL) async -> Bool {
        if fault == .cancelBeforeCreate, url.lastPathComponent == "Collected" {
            withUnsafeCurrentTask { $0?.cancel() }
        }
        return entries[url] != nil
    }
    func createDirectory(_ url: URL) async throws { entries[url] = identity("dir:\(url.lastPathComponent)") }
    func createEmptyItemAndCaptureIdentity(_ url: URL, kind: EmptyFileSystemItemKind, parentIdentifiedBy identity: FileIdentity) async throws -> OpenedEmptyFileSystemItem {
        guard entries[parent] == identity else { throw FileSystemAccessError.identityMismatch(parent) }
        if fault == .failCreate { throw POSIXError(.EIO) }
        let created = self.identity("folder")
        entries[url] = created; events.append("create:\(url.lastPathComponent)")
        if fault == .cancelAfterCreate { withUnsafeCurrentTask { $0?.cancel() } }
        return .init(identity: created, descriptor: -1)
    }
    func copyAndCaptureIdentity(_ source: URL, to destination: URL) async throws -> FileIdentity { throw FileSystemAccessError.unsupportedOperation(source) }
    func move(_ source: URL, to destination: URL) async throws { try await moveExclusively(source, to: destination) }
    func moveExclusively(_ source: URL, to destination: URL) async throws {
        guard let value = entries.removeValue(forKey: source), entries[destination] == nil else { throw POSIXError(.EEXIST) }
        entries[destination] = value
    }
    func remove(_ url: URL) async throws { entries.removeValue(forKey: url) }
    func replace(_ destination: URL, with stagedItem: URL) async throws { try await moveExclusively(stagedItem, to: destination) }
    func identity(of url: URL) async throws -> FileIdentity? {
        if case let .cancelDuringForwardVerificationAfterMove(index) = fault,
           moveAttempt == index,
           !didCancelForwardVerification {
            didCancelForwardVerification = true
            withUnsafeCurrentTask { $0?.cancel() }
            throw CancellationError()
        }
        return entries[url]
    }
    func move(_ source: URL, identifiedBy identity: FileIdentity, to destination: URL) async throws { try await moveExclusively(source, identifiedBy: identity, to: destination) }
    func moveExclusively(_ source: URL, identifiedBy identity: FileIdentity, to destination: URL) async throws { try await checkedMove(source, identity, destination, parent: destination.deletingLastPathComponent()) }
    func moveExclusively(_ source: URL, identifiedBy identity: FileIdentity, to destination: URL, destinationParentIdentifiedBy parentIdentity: FileIdentity) async throws { try await checkedMove(source, identity, destination, parent: destination.deletingLastPathComponent(), expectedParent: parentIdentity) }
    private func checkedMove(_ source: URL, _ identity: FileIdentity, _ destination: URL, parent destinationParent: URL, expectedParent: FileIdentity? = nil) async throws {
        try Task.checkCancellation()
        guard entries[source] == identity, entries[destination] == nil, expectedParent == nil || entries[destinationParent] == expectedParent else { throw POSIXError(.EEXIST) }
        let isReverse = source.deletingLastPathComponent().lastPathComponent == "Collected"
        if isReverse { reverseMoveAttempt += 1 } else { moveAttempt += 1 }
        let attempt = isReverse ? reverseMoveAttempt : moveAttempt
        switch fault {
        case let .failMove(index) where !isReverse && attempt == index: throw POSIXError(.EIO)
        case let .failMoveAndRollback(index) where !isReverse && attempt >= index: throw POSIXError(.EIO)
        case .failMoveAndRollback where isReverse: throw POSIXError(.EIO)
        case let .failReverseMove(index) where isReverse && attempt == index: throw POSIXError(.EIO)
        case let .failReverseMoveAndRollback(index) where isReverse && attempt == index: throw POSIXError(.EIO)
        case .failReverseMoveAndRollback where !isReverse && reverseMoveAttempt > 0: throw POSIXError(.EIO)
        default: break
        }
        entries.removeValue(forKey: source); entries[destination] = identity
        events.append("move:\(source.lastPathComponent)->\(destination.lastPathComponent)")
        if case let .cancelAfterMove(index) = fault, !isReverse, attempt == index { withUnsafeCurrentTask { $0?.cancel() } }
        if case let .cancelReverseMove(index) = fault, isReverse, attempt == index { withUnsafeCurrentTask { $0?.cancel() } }
    }
    func remove(_ url: URL, identifiedBy identity: FileIdentity) async throws { guard entries[url] == identity else { throw FileSystemAccessError.identityMismatch(url) }; entries.removeValue(forKey: url) }
    func replace(_ destination: URL, identifiedBy destinationIdentity: FileIdentity, with stagedItem: URL, identifiedBy stagedIdentity: FileIdentity) async throws { try await moveExclusively(stagedItem, identifiedBy: stagedIdentity, to: destination) }
    func reserveStagingDirectory(beside destination: URL) async throws -> StagingReservation { throw FileSystemAccessError.unsupportedOperation(destination) }
    func removeStagingDirectory(_ reservation: StagingReservation) async throws { }
    func fingerprint(of url: URL) async throws -> SourceFingerprint {
        fingerprintCallCount += 1
        if fault == .mutateSiblingAfterReversePreflight, fingerprintCallCount == 7 {
            if let sibling = entries.keys.first(where: {
                $0.lastPathComponent == "A.txt" && $0.deletingLastPathComponent() != parent
            }) {
                fingerprints[sibling] = 1
            }
        }
        return .init(entries: [.init(relativePath: ".", device: 1, inode: 1, mode: 0, size: Int64(fingerprints[url, default: 0]), modificationSeconds: 0, modificationNanoseconds: 0, changeSeconds: 0, changeNanoseconds: 0)])
    }
    func trash(_ url: URL) async throws { entries.removeValue(forKey: url) }
    func trash(_ url: URL, identifiedBy identity: FileIdentity) async throws { try await remove(url, identifiedBy: identity) }
    func trashAndReturnResultingURL(_ url: URL, identifiedBy identity: FileIdentity) async throws -> URL? { try await remove(url, identifiedBy: identity); return nil }
    func quarantineForTrash(_ url: URL, identifiedBy identity: FileIdentity) async throws -> StorageTrashQuarantine { throw FileSystemAccessError.unsupportedOperation(url) }
    func rollbackTrashQuarantine(_ quarantine: StorageTrashQuarantine) async throws { }
    func moveTrashQuarantineAtomically(_ quarantine: StorageTrashQuarantine) async throws -> URL { throw FileSystemAccessError.unsupportedOperation(quarantine.quarantinedURL) }
    func names(in directory: URL) async throws -> Set<String> { Set(entries.keys.filter { $0.deletingLastPathComponent() == directory }.map(\.lastPathComponent)) }
    func volumeIdentifier(for url: URL) async throws -> String { "volume" }
    func byteSize(of url: URL) async throws -> Int64? { nil }
    func availableCapacity(at url: URL) async throws -> Int64? { nil }
    func prepareDirectoryHierarchy(root: URL, identifiedBy rootIdentity: FileIdentity, relativeComponents: [String]) async throws -> PreparedDirectoryHierarchy { throw FileSystemAccessError.unsupportedOperation(root) }
    func removeEmptyOwnedDirectories(root: URL, identifiedBy rootIdentity: FileIdentity, directories: [PreparedDirectoryHierarchy.OwnedDirectory]) async throws { }
    func removeEmptyDirectory(_ url: URL, identifiedBy identity: FileIdentity) async throws {
        guard entries[url] == identity,
              !(entries.keys.contains { $0.deletingLastPathComponent() == url }) else { throw POSIXError(.ENOTEMPTY) }
        entries.removeValue(forKey: url); events.append("remove:\(url.lastPathComponent)")
    }
    func apply(_ mutation: TransactionReverseMutation, fixture: TransactionFixture) {
        switch mutation {
        case .parent: entries[fixture.parent] = identity("changed-parent")
        case .folder: entries[fixture.folder] = identity("changed-folder")
        case .extraChild: entries[fixture.folder.appending(path: "external")] = identity("external")
        case .childIdentity: entries[fixture.folder.appending(path: "A.txt")] = identity("changed-child")
        case .fingerprint: fingerprints[fixture.folder.appending(path: "A.txt")] = 1
        case .occupiedOriginal: entries[fixture.first] = identity("occupied")
        }
    }
    private func identity(_ value: String) -> FileIdentity { .init(entryIdentifier: value, resolvedIdentifier: value) }
}
