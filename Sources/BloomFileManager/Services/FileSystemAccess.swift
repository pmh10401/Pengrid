import Darwin
import Foundation

struct FileIdentity: Hashable, Sendable {
    let entryIdentifier: String
    let resolvedIdentifier: String

    func refersToSameItem(as other: FileIdentity) -> Bool {
        resolvedIdentifier == other.resolvedIdentifier
    }
}

struct StagingReservation: Sendable {
    let directory: URL
    let directoryIdentity: FileIdentity
    let item: URL
}

struct StorageTrashQuarantine: Sendable {
    let id: UUID
    let originalURL: URL
    let quarantinedURL: URL
    let identity: FileIdentity
    let reservation: StagingReservation

    init(
        id: UUID = UUID(),
        originalURL: URL,
        quarantinedURL: URL,
        identity: FileIdentity,
        reservation: StagingReservation
    ) {
        self.id = id
        self.originalURL = originalURL
        self.quarantinedURL = quarantinedURL
        self.identity = identity
        self.reservation = reservation
    }
}

struct PreparedDirectoryHierarchy: Sendable {
    struct OwnedDirectory: Sendable {
        let relativeComponents: [String]
        let identity: FileIdentity
    }

    let destinationDirectory: URL
    let createdDirectories: [OwnedDirectory]
}

struct SourceFingerprint: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        let relativePath: String
        let device: UInt64
        let inode: UInt64
        let mode: UInt32
        let size: Int64
        let modificationSeconds: Int64
        let modificationNanoseconds: Int64
        let changeSeconds: Int64
        let changeNanoseconds: Int64
    }

    let entries: [Entry]
}

protocol FileSystemAccess: Sendable {
    func exists(_ url: URL) async -> Bool
    func createDirectory(_ url: URL) async throws
    func copyAndCaptureIdentity(_ source: URL, to destination: URL) async throws -> FileIdentity
    func move(_ source: URL, to destination: URL) async throws
    func moveExclusively(_ source: URL, to destination: URL) async throws
    func remove(_ url: URL) async throws
    func replace(_ destination: URL, with stagedItem: URL) async throws
    func identity(of url: URL) async throws -> FileIdentity?
    func move(_ source: URL, identifiedBy identity: FileIdentity, to destination: URL) async throws
    func remove(_ url: URL, identifiedBy identity: FileIdentity) async throws
    func replace(
        _ destination: URL,
        identifiedBy destinationIdentity: FileIdentity,
        with stagedItem: URL,
        identifiedBy stagedIdentity: FileIdentity
    ) async throws
    func reserveStagingDirectory(beside destination: URL) async throws -> StagingReservation
    func removeStagingDirectory(_ reservation: StagingReservation) async throws
    func fingerprint(of source: URL) async throws -> SourceFingerprint
    func trash(_ url: URL) async throws
    func trash(_ url: URL, identifiedBy identity: FileIdentity) async throws
    func quarantineForTrash(
        _ url: URL,
        identifiedBy identity: FileIdentity
    ) async throws -> StorageTrashQuarantine
    func rollbackTrashQuarantine(_ quarantine: StorageTrashQuarantine) async throws
    func moveTrashQuarantineAtomically(
        _ quarantine: StorageTrashQuarantine
    ) async throws -> URL
    func names(in directory: URL) async throws -> Set<String>
    func volumeIdentifier(for url: URL) async throws -> String
    func byteSize(of url: URL) async throws -> Int64?
    func availableCapacity(at url: URL) async throws -> Int64?
    func prepareDirectoryHierarchy(
        root: URL,
        identifiedBy rootIdentity: FileIdentity,
        relativeComponents: [String]
    ) async throws -> PreparedDirectoryHierarchy
    func removeEmptyOwnedDirectories(
        root: URL,
        identifiedBy rootIdentity: FileIdentity,
        directories: [PreparedDirectoryHierarchy.OwnedDirectory]
    ) async throws
}

extension FileSystemAccess {
    func quarantineForTrash(
        _ url: URL,
        identifiedBy identity: FileIdentity
    ) async throws -> StorageTrashQuarantine {
        let reservation = try await reserveStagingDirectory(beside: url)
        do {
            try await move(url, identifiedBy: identity, to: reservation.item)
            guard try await self.identity(of: reservation.item) == identity else {
                if await !exists(url) {
                    try? await move(reservation.item, identifiedBy: identity, to: url)
                }
                throw FileSystemAccessError.identityMismatch(url)
            }
            return StorageTrashQuarantine(
                originalURL: url,
                quarantinedURL: reservation.item,
                identity: identity,
                reservation: reservation
            )
        } catch {
            try? await removeStagingDirectory(reservation)
            throw error
        }
    }

    func rollbackTrashQuarantine(_ quarantine: StorageTrashQuarantine) async throws {
        guard await !exists(quarantine.originalURL) else {
            throw FileSystemAccessError.identityMismatch(quarantine.originalURL)
        }
        try await move(
            quarantine.quarantinedURL,
            identifiedBy: quarantine.identity,
            to: quarantine.originalURL
        )
        try await removeStagingDirectory(quarantine.reservation)
    }

    func moveTrashQuarantineAtomically(
        _ quarantine: StorageTrashQuarantine
    ) async throws -> URL {
        do {
            try await trash(
                quarantine.quarantinedURL,
                identifiedBy: quarantine.identity
            )
            try? await removeStagingDirectory(quarantine.reservation)
            return quarantine.quarantinedURL
        } catch {
            do {
                try await rollbackTrashQuarantine(quarantine)
            } catch {
                throw StorageTrashAccessError.recoveryRequired
            }
            throw StorageTrashAccessError.failedButRestored
        }
    }
}

enum FileSystemAccessError: Error, Equatable {
    case missingVolumeIdentifier(URL)
    case identityMismatch(URL)
}

enum StorageTrashAccessError: LocalizedError, Equatable {
    case failedButRestored
    case recoveryRequired

    var errorDescription: String? {
        switch self {
        case .failedButRestored:
            "The item was restored after cleanup could not finish."
        case .recoveryRequired:
            "Cleanup could not finish safely. A recoverable item remains and should be reviewed manually."
        }
    }
}

enum VolumeIdentifierNormalizationError: Error, Equatable {
    case unsupportedType(String)
}

enum VolumeIdentifierNormalizer {
    static func normalize(_ identifier: Any) throws -> String {
        if let value = identifier as? String {
            return "string:\(value)"
        }
        if let value = identifier as? UUID {
            return "uuid:\(value.uuidString.lowercased())"
        }
        if let value = identifier as? NSNumber {
            return "number:\(value.stringValue)"
        }
        if let value = identifier as? Data {
            let hex = value.map { String(format: "%02x", $0) }.joined()
            return "data:\(hex)"
        }
        throw VolumeIdentifierNormalizationError.unsupportedType(
            String(reflecting: type(of: identifier))
        )
    }
}

actor LiveFileSystemAccess: FileSystemAccess {
    private struct StorageQuarantineContext {
        let quarantine: StorageTrashQuarantine
        let trashDirectory: URL
        let sourceParentDescriptor: Int32
        let sourceName: String
        let stagingDescriptor: Int32
    }

    private let fileManager: FileManager
    private let copyChunkSize: Int
    private let onCopyChunk: @Sendable () -> Void
    private let onBeforeCopyEntryCreate: @Sendable (URL) -> Void
    private let onCopyEntryCreatedBeforeOpen: @Sendable (URL) -> Void
    private let onBeforeCopySourceEntryOpen: @Sendable (URL) -> Void
    private let onCopyEntryCreated: @Sendable (URL) -> Void
    private let onCopyMetadataApplied: @Sendable () throws -> Void
    private let storageTrashDirectory: (URL) throws -> URL
    private let storageTrashName: @Sendable () -> String
    private let onAfterStorageQuarantineRename: @Sendable () throws -> Void
    private let onBeforeStorageTrashMove:
        @Sendable (StorageTrashQuarantine) throws -> Void
    private let onAfterStorageTrashRename:
        @Sendable (StorageTrashQuarantine) throws -> Void
    private let onBeforeStorageRollbackMove: @Sendable (URL) throws -> Void
    private var pendingCopies: [String: PendingOwnedCopy] = [:]
    private var storageQuarantines: [UUID: StorageQuarantineContext] = [:]

    init(
        fileManager: FileManager = .default,
        copyChunkSize: Int = 1_048_576,
        onCopyChunk: @escaping @Sendable () -> Void = {},
        onBeforeCopyEntryCreate: @escaping @Sendable (URL) -> Void = { _ in },
        onCopyEntryCreatedBeforeOpen: @escaping @Sendable (URL) -> Void = { _ in },
        onBeforeCopySourceEntryOpen: @escaping @Sendable (URL) -> Void = { _ in },
        onCopyEntryCreated: @escaping @Sendable (URL) -> Void = { _ in },
        onCopyMetadataApplied: @escaping @Sendable () throws -> Void = {},
        storageTrashDirectory:
            ((URL) throws -> URL)? = nil,
        storageTrashName:
            @escaping @Sendable () -> String =
            { ".pengrid-trash-\(UUID().uuidString)" },
        onAfterStorageQuarantineRename:
            @escaping @Sendable () throws -> Void = {},
        onBeforeStorageTrashMove:
            @escaping @Sendable (StorageTrashQuarantine) throws -> Void = { _ in },
        onAfterStorageTrashRename:
            @escaping @Sendable (StorageTrashQuarantine) throws -> Void = { _ in },
        onBeforeStorageRollbackMove:
            @escaping @Sendable (URL) throws -> Void = { _ in }
    ) {
        self.fileManager = fileManager
        self.copyChunkSize = max(copyChunkSize, 4_096)
        self.onCopyChunk = onCopyChunk
        self.onBeforeCopyEntryCreate = onBeforeCopyEntryCreate
        self.onCopyEntryCreatedBeforeOpen = onCopyEntryCreatedBeforeOpen
        self.onBeforeCopySourceEntryOpen = onBeforeCopySourceEntryOpen
        self.onCopyEntryCreated = onCopyEntryCreated
        self.onCopyMetadataApplied = onCopyMetadataApplied
        self.storageTrashDirectory = storageTrashDirectory ?? { source in
            try fileManager.url(
                for: .trashDirectory,
                in: .userDomainMask,
                appropriateFor: source,
                create: true
            )
        }
        self.storageTrashName = storageTrashName
        self.onAfterStorageQuarantineRename = onAfterStorageQuarantineRename
        self.onBeforeStorageTrashMove = onBeforeStorageTrashMove
        self.onAfterStorageTrashRename = onAfterStorageTrashRename
        self.onBeforeStorageRollbackMove = onBeforeStorageRollbackMove
    }

    func exists(_ url: URL) -> Bool {
        fileManager.fileExists(atPath: url.path)
    }

    func createDirectory(_ url: URL) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
    }

    func copyAndCaptureIdentity(_ source: URL, to destination: URL) throws -> FileIdentity {
        var ownedEntries: [OwnedCopyEntry] = []
        var rootDescriptor: Int32?
        let (sourceParentDescriptor, sourceName) = try openParentDirectory(of: source)
        defer { Darwin.close(sourceParentDescriptor) }
        let (destinationParentDescriptor, destinationName) = try openParentDirectory(of: destination)
        defer { Darwin.close(destinationParentDescriptor) }
        do {
            let identity = try copyOwnedNode(
                source,
                sourceName: sourceName,
                sourceParentDescriptor: sourceParentDescriptor,
                to: destination,
                destinationName: destinationName,
                destinationParentDescriptor: destinationParentDescriptor,
                relativePath: [],
                rootDescriptor: &rootDescriptor,
                ownedEntries: &ownedEntries
            )
            guard let rootDescriptor else {
                throw FileTransferAccessError.missingCopiedRootDescriptor
            }
            let rootParentDescriptor = Darwin.dup(destinationParentDescriptor)
            guard rootParentDescriptor >= 0 else { throw currentPOSIXError() }
            pendingCopies[identity.entryIdentifier] = PendingOwnedCopy(
                entries: ownedEntries,
                rootParentDescriptor: rootParentDescriptor,
                rootDescriptor: rootDescriptor,
                rootName: destinationName
            )
            return identity
        } catch {
            let cleanupError = cleanupOwnedCopyEntries(
                ownedEntries,
                rootDescriptor: rootDescriptor,
                rootParentDescriptor: destinationParentDescriptor,
                rootName: destinationName
            )
            if let rootDescriptor { Darwin.close(rootDescriptor) }
            throw FileTransferAccessFailure(primary: error, cleanup: cleanupError)
        }
    }

    func move(_ source: URL, to destination: URL) throws {
        try renameItem(source, to: destination)
    }

    func moveExclusively(_ source: URL, to destination: URL) throws {
        let (sourceParentDescriptor, sourceName) = try openParentDirectory(of: source)
        defer { Darwin.close(sourceParentDescriptor) }
        let (destinationParentDescriptor, destinationName) = try openParentDirectory(
            of: destination
        )
        defer { Darwin.close(destinationParentDescriptor) }
        try renameExclusive(
            from: sourceParentDescriptor,
            name: sourceName,
            to: destinationParentDescriptor,
            name: destinationName
        )
    }

    func remove(_ url: URL) throws {
        try fileManager.removeItem(at: url)
    }

    func replace(_ destination: URL, with stagedItem: URL) throws {
        _ = try fileManager.replaceItemAt(destination, withItemAt: stagedItem)
    }

    func identity(of url: URL) throws -> FileIdentity? {
        guard let entryIdentifier = try nodeIdentifier(for: url, followsSymlink: false) else {
            return nil
        }
        let resolvedIdentifier = try nodeIdentifier(for: url, followsSymlink: true) ?? entryIdentifier
        return FileIdentity(
            entryIdentifier: entryIdentifier,
            resolvedIdentifier: resolvedIdentifier
        )
    }

    func move(_ source: URL, identifiedBy identity: FileIdentity, to destination: URL) throws {
        try requireIdentity(identity, at: source)
        var information = stat()
        let status: Int32 = source.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return Darwin.lstat(path, &information)
        }
        guard status == 0 else { throw currentPOSIXError() }

        let isDirectory = information.st_mode & S_IFMT == S_IFDIR
        let originalMode = mode_t(information.st_mode & 0o7777)
        let needsTemporaryOwnerWrite = isDirectory && originalMode & S_IWUSR == 0
        if needsTemporaryOwnerWrite {
            try changeMode(of: source, to: originalMode | S_IWUSR)
        }
        do {
            try renameItem(source, to: destination)
        } catch {
            if needsTemporaryOwnerWrite { try? changeMode(of: source, to: originalMode) }
            throw error
        }
        if needsTemporaryOwnerWrite {
            try changeMode(of: destination, to: originalMode)
        }
        try applyAndClosePendingCopy(for: identity)
    }

    func remove(_ url: URL, identifiedBy identity: FileIdentity) throws {
        if let pending = pendingCopies.removeValue(forKey: identity.entryIdentifier) {
            defer { closePendingCopy(pending) }
            if let cleanupError = cleanupOwnedCopyEntries(
                pending.entries,
                rootDescriptor: pending.rootDescriptor,
                rootParentDescriptor: pending.rootParentDescriptor,
                rootName: pending.rootName
            ) {
                throw cleanupError
            }
            return
        }
        try requireIdentity(identity, at: url)
        try fileManager.removeItem(at: url)
    }

    func replace(
        _ destination: URL,
        identifiedBy destinationIdentity: FileIdentity,
        with stagedItem: URL,
        identifiedBy stagedIdentity: FileIdentity
    ) throws {
        try requireIdentity(destinationIdentity, at: destination)
        try requireIdentity(stagedIdentity, at: stagedItem)
        _ = try fileManager.replaceItemAt(destination, withItemAt: stagedItem)
        try applyAndClosePendingCopy(for: stagedIdentity)
    }

    func reserveStagingDirectory(beside destination: URL) throws -> StagingReservation {
        while true {
            try Task.checkCancellation()
            let directory = destination
                .deletingLastPathComponent()
                .appending(path: ".bloom-staging-\(UUID().uuidString)", directoryHint: .isDirectory)
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
            } catch where isFileExists(error) {
                continue
            }

            do {
                guard let directoryIdentity = try identity(of: directory) else {
                    throw FileTransferAccessError.missingStagingIdentity
                }
                return StagingReservation(
                    directory: directory,
                    directoryIdentity: directoryIdentity,
                    item: directory.appending(path: "payload")
                )
            } catch {
                let cleanupError = removeEmptyDirectory(directory)
                throw FileTransferAccessFailure(primary: error, cleanup: cleanupError)
            }
        }
    }

    func fingerprint(of source: URL) throws -> SourceFingerprint {
        var entries: [SourceFingerprint.Entry] = []
        try appendFingerprintEntries(at: source, relativePath: ".", to: &entries)
        return SourceFingerprint(entries: entries)
    }

    func removeStagingDirectory(_ reservation: StagingReservation) throws {
        // The identity check and rmdir are synchronous within this actor, minimizing the
        // public-API TOCTOU window. rmdir never recursively removes raced-in contents.
        try requireIdentity(reservation.directoryIdentity, at: reservation.directory)
        if let error = removeEmptyDirectory(reservation.directory) {
            throw error
        }
    }

    func trash(_ url: URL) throws {
        var resultingURL: NSURL?
        try fileManager.trashItem(at: url, resultingItemURL: &resultingURL)
    }

    func trash(_ url: URL, identifiedBy identity: FileIdentity) throws {
        try requireIdentity(identity, at: url)
        var resultingURL: NSURL?
        try fileManager.trashItem(at: url, resultingItemURL: &resultingURL)
    }

    func quarantineForTrash(
        _ url: URL,
        identifiedBy expectedIdentity: FileIdentity
    ) async throws -> StorageTrashQuarantine {
        let trashDirectory = try storageTrashDirectory(url)
        let reservation = try reserveStagingDirectory(beside: url)
        let (sourceParent, sourceName) = try openParentDirectory(of: url)
        let staging: Int32
        do {
            staging = try openDescriptor(
                reservation.directory,
                flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW
            )
        } catch {
            Darwin.close(sourceParent)
            try? removeStagingDirectory(reservation)
            throw error
        }
        var movedIntoStaging = false
        do {
            _ = try requireOpenedEntry(
                staging,
                expectedIdentity: reservation.directoryIdentity,
                expectedType: S_IFDIR,
                at: reservation.directory
            )
            guard try identity(
                named: sourceName,
                in: sourceParent,
                noFollow: true
            ) == expectedIdentity else {
                throw FileSystemAccessError.identityMismatch(url)
            }
            try renameExclusive(
                from: sourceParent,
                name: sourceName,
                to: staging,
                name: "payload"
            )
            movedIntoStaging = true
            try onAfterStorageQuarantineRename()
            guard try identity(
                named: "payload",
                in: staging,
                noFollow: true
            ) == expectedIdentity else {
                throw FileSystemAccessError.identityMismatch(url)
            }
            guard Darwin.fchmod(staging, 0) == 0 else {
                throw currentPOSIXError()
            }
            let quarantine = StorageTrashQuarantine(
                originalURL: url,
                quarantinedURL: reservation.item,
                identity: expectedIdentity,
                reservation: reservation
            )
            storageQuarantines[quarantine.id] = StorageQuarantineContext(
                quarantine: quarantine,
                trashDirectory: trashDirectory,
                sourceParentDescriptor: sourceParent,
                sourceName: sourceName,
                stagingDescriptor: staging
            )
            return quarantine
        } catch let primaryError {
            if movedIntoStaging {
                let recovered: Bool
                do {
                    try onBeforeStorageRollbackMove(url)
                    try renameExclusive(
                        from: staging,
                        name: "payload",
                        to: sourceParent,
                        name: sourceName
                    )
                    recovered = true
                } catch {
                    recovered = false
                }
                _ = Darwin.fchmod(staging, 0o700)
                Darwin.close(staging)
                Darwin.close(sourceParent)
                if recovered {
                    try? removeStagingDirectory(reservation)
                    throw StorageTrashAccessError.failedButRestored
                }
                throw StorageTrashAccessError.recoveryRequired
            }
            Darwin.close(staging)
            Darwin.close(sourceParent)
            try? removeStagingDirectory(reservation)
            throw primaryError
        }
    }

    func rollbackTrashQuarantine(_ quarantine: StorageTrashQuarantine) async throws {
        guard let context = storageQuarantines[quarantine.id],
              context.quarantine.identity == quarantine.identity else {
            throw StorageTrashAccessError.recoveryRequired
        }
        do {
            guard Darwin.fchmod(context.stagingDescriptor, 0o700) == 0 else {
                throw currentPOSIXError()
            }
            try onBeforeStorageRollbackMove(quarantine.originalURL)
            guard try identity(
                named: "payload",
                in: context.stagingDescriptor,
                noFollow: true
            ) == quarantine.identity else {
                throw FileSystemAccessError.identityMismatch(
                    quarantine.quarantinedURL
                )
            }
            try renameExclusive(
                from: context.stagingDescriptor,
                name: "payload",
                to: context.sourceParentDescriptor,
                name: context.sourceName
            )
        } catch {
            abandonRecoverableQuarantine(context)
            throw StorageTrashAccessError.recoveryRequired
        }
        finishEmptyQuarantine(context)
    }

    func moveTrashQuarantineAtomically(
        _ quarantine: StorageTrashQuarantine
    ) async throws -> URL {
        guard let context = storageQuarantines[quarantine.id],
              context.quarantine.identity == quarantine.identity else {
            throw StorageTrashAccessError.recoveryRequired
        }
        let trashDirectory = context.trashDirectory
        var trashDescriptor: Int32?
        defer {
            if let trashDescriptor {
                Darwin.close(trashDescriptor)
            }
        }
        let destinationName = storageTrashName()
        let destination = trashDirectory.appending(path: destinationName)
        var movedToTrash = false
        do {
            try FilenameValidator.validate(destinationName)
            let openedTrashDescriptor = try openAnchoredAbsoluteDirectory(
                trashDirectory
            )
            trashDescriptor = openedTrashDescriptor
            try onBeforeStorageTrashMove(quarantine)
            guard Darwin.fchmod(context.stagingDescriptor, 0o700) == 0 else {
                throw currentPOSIXError()
            }
            guard try identity(
                named: "payload",
                in: context.stagingDescriptor,
                noFollow: true
            ) == quarantine.identity else {
                throw FileSystemAccessError.identityMismatch(
                    quarantine.quarantinedURL
                )
            }
            try renameExclusive(
                from: context.stagingDescriptor,
                name: "payload",
                to: openedTrashDescriptor,
                name: destinationName
            )
            movedToTrash = true
            try onAfterStorageTrashRename(quarantine)
            guard try identity(
                named: destinationName,
                in: openedTrashDescriptor,
                noFollow: true
            ) == quarantine.identity else {
                throw FileSystemAccessError.identityMismatch(
                    destination
                )
            }
            finishEmptyQuarantine(context)
            return destination
        } catch {
            if movedToTrash {
                guard let trashDescriptor else {
                    abandonRecoverableQuarantine(context)
                    throw StorageTrashAccessError.recoveryRequired
                }
                do {
                    try renameExclusive(
                        from: trashDescriptor,
                        name: destinationName,
                        to: context.stagingDescriptor,
                        name: "payload"
                    )
                } catch {
                    if (try? identity(
                        named: destinationName,
                        in: trashDescriptor,
                        noFollow: true
                    )) == quarantine.identity {
                        try? renameExclusive(
                            from: trashDescriptor,
                            name: destinationName,
                            to: context.stagingDescriptor,
                            name: ".recovery-\(UUID().uuidString)"
                        )
                    }
                    abandonRecoverableQuarantine(context)
                    throw StorageTrashAccessError.recoveryRequired
                }
            }
            do {
                try await rollbackTrashQuarantine(quarantine)
            } catch {
                throw StorageTrashAccessError.recoveryRequired
            }
            throw StorageTrashAccessError.failedButRestored
        }
    }

    func names(in directory: URL) throws -> Set<String> {
        let children = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        return Set(children.map(\.lastPathComponent))
    }

    func volumeIdentifier(for url: URL) throws -> String {
        let values = try url.resourceValues(forKeys: [.volumeIdentifierKey])
        guard let identifier = values.volumeIdentifier else {
            throw FileSystemAccessError.missingVolumeIdentifier(url)
        }
        return try VolumeIdentifierNormalizer.normalize(identifier)
    }

    func byteSize(of url: URL) throws -> Int64? {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize else {
            return nil
        }
        return Int64(size)
    }

    func availableCapacity(at url: URL) throws -> Int64? {
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values.volumeAvailableCapacityForImportantUsage
    }

    func prepareDirectoryHierarchy(
        root: URL,
        identifiedBy rootIdentity: FileIdentity,
        relativeComponents: [String]
    ) throws -> PreparedDirectoryHierarchy {
        try relativeComponents.forEach(FilenameValidator.validate)
        let rootDescriptor = try openDescriptor(
            root,
            flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK
        )
        defer { Darwin.close(rootDescriptor) }
        _ = try requireOpenedEntry(
            rootDescriptor,
            expectedIdentity: rootIdentity,
            expectedType: S_IFDIR,
            at: root
        )

        var currentDescriptor = Darwin.dup(rootDescriptor)
        guard currentDescriptor >= 0 else { throw currentPOSIXError() }
        defer { Darwin.close(currentDescriptor) }
        var currentURL = root
        var created: [PreparedDirectoryHierarchy.OwnedDirectory] = []

        do {
            for (index, component) in relativeComponents.enumerated() {
                try Task.checkCancellation()
                let nextURL = currentURL.appending(path: component, directoryHint: .isDirectory)
                var nextDescriptor = component.withCString {
                    Darwin.openat(
                        currentDescriptor,
                        $0,
                        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK
                    )
                }
                if nextDescriptor < 0, errno == ENOENT {
                    let createStatus = component.withCString {
                        Darwin.mkdirat(currentDescriptor, $0, 0o700)
                    }
                    guard createStatus == 0 else { throw currentPOSIXError() }

                    var information = stat()
                    let identityStatus = component.withCString {
                        Darwin.fstatat(
                            currentDescriptor,
                            $0,
                            &information,
                            AT_SYMLINK_NOFOLLOW
                        )
                    }
                    guard identityStatus == 0 else { throw currentPOSIXError() }
                    guard information.st_mode & S_IFMT == S_IFDIR else {
                        throw FileTransferAccessError.unexpectedOpenedEntryType(nextURL)
                    }
                    let capturedIdentity = identity(from: information)
                    created.append(.init(
                        relativeComponents: Array(relativeComponents.prefix(index + 1)),
                        identity: capturedIdentity
                    ))

                    nextDescriptor = component.withCString {
                        Darwin.openat(
                            currentDescriptor,
                            $0,
                            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK
                        )
                    }
                    guard nextDescriptor >= 0 else { throw currentPOSIXError() }
                    do {
                        _ = try requireOpenedEntry(
                            nextDescriptor,
                            expectedIdentity: capturedIdentity,
                            expectedType: S_IFDIR,
                            at: nextURL
                        )
                    } catch {
                        Darwin.close(nextDescriptor)
                        throw error
                    }
                } else {
                    guard nextDescriptor >= 0 else { throw currentPOSIXError() }
                    var information = stat()
                    guard Darwin.fstat(nextDescriptor, &information) == 0 else {
                        let error = currentPOSIXError()
                        Darwin.close(nextDescriptor)
                        throw error
                    }
                    guard information.st_mode & S_IFMT == S_IFDIR else {
                        Darwin.close(nextDescriptor)
                        throw FileTransferAccessError.unexpectedOpenedEntryType(nextURL)
                    }
                }
                Darwin.close(currentDescriptor)
                currentDescriptor = nextDescriptor
                currentURL = nextURL
            }
            return PreparedDirectoryHierarchy(
                destinationDirectory: currentURL,
                createdDirectories: created
            )
        } catch {
            let cleanupError = removeEmptyOwnedDirectories(
                rootDescriptor: rootDescriptor,
                root: root,
                directories: created
            )
            throw FileTransferAccessFailure(primary: error, cleanup: cleanupError)
        }
    }

    func removeEmptyOwnedDirectories(
        root: URL,
        identifiedBy rootIdentity: FileIdentity,
        directories: [PreparedDirectoryHierarchy.OwnedDirectory]
    ) throws {
        guard !directories.isEmpty else { return }
        let rootDescriptor = try openDescriptor(
            root,
            flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK
        )
        defer { Darwin.close(rootDescriptor) }
        _ = try requireOpenedEntry(
            rootDescriptor,
            expectedIdentity: rootIdentity,
            expectedType: S_IFDIR,
            at: root
        )
        if let error = removeEmptyOwnedDirectories(
            rootDescriptor: rootDescriptor,
            root: root,
            directories: directories
        ) {
            throw error
        }
    }

    private func removeEmptyOwnedDirectories(
        rootDescriptor: Int32,
        root: URL,
        directories: [PreparedDirectoryHierarchy.OwnedDirectory]
    ) -> (any Error)? {
        var firstError: (any Error)?
        for directory in directories.sorted(by: {
            $0.relativeComponents.count > $1.relativeComponents.count
        }) {
            guard let name = directory.relativeComponents.last else { continue }
            do {
                let parentDescriptor = try openRelativeDirectory(
                    Array(directory.relativeComponents.dropLast()),
                    from: rootDescriptor
                )
                defer { Darwin.close(parentDescriptor) }
                let current = try identity(named: name, in: parentDescriptor, noFollow: true)
                let directoryURL = directory.relativeComponents.reduce(root) {
                    $0.appending(path: $1, directoryHint: .isDirectory)
                }
                guard current.entryIdentifier == directory.identity.entryIdentifier else {
                    throw FileSystemAccessError.identityMismatch(directoryURL)
                }
                let result = name.withCString {
                    Darwin.unlinkat(parentDescriptor, $0, AT_REMOVEDIR)
                }
                if result != 0, errno != ENOTEMPTY {
                    throw currentPOSIXError()
                }
            } catch {
                firstError = firstError ?? error
            }
        }
        return firstError
    }

    private func requireIdentity(_ expected: FileIdentity, at url: URL) throws {
        // Public macOS file APIs offer no compare-and-mutate primitive for these
        // operations. Keeping this check and its mutation synchronous on the actor
        // narrows, but cannot eliminate, the final external-process TOCTOU window.
        guard try identity(of: url)?.entryIdentifier == expected.entryIdentifier else {
            throw FileSystemAccessError.identityMismatch(url)
        }
    }

    private func copyOwnedNode(
        _ source: URL,
        sourceName: String,
        sourceParentDescriptor: Int32,
        to destination: URL,
        destinationName: String,
        destinationParentDescriptor: Int32,
        relativePath: [String],
        rootDescriptor: inout Int32?,
        ownedEntries: inout [OwnedCopyEntry]
    ) throws -> FileIdentity {
        try Task.checkCancellation()
        var information = stat()
        let sourceStatus = sourceName.withCString {
            Darwin.fstatat(sourceParentDescriptor, $0, &information, AT_SYMLINK_NOFOLLOW)
        }
        guard sourceStatus == 0 else { throw currentPOSIXError() }

        switch information.st_mode & S_IFMT {
        case S_IFREG:
            return try copyOwnedRegularFile(
                source,
                sourceName: sourceName,
                sourceParentDescriptor: sourceParentDescriptor,
                to: destination,
                destinationName: destinationName,
                destinationParentDescriptor: destinationParentDescriptor,
                sourceIdentity: identity(from: information),
                finalFlags: information.st_flags,
                relativePath: relativePath,
                rootDescriptor: &rootDescriptor,
                ownedEntries: &ownedEntries
            )
        case S_IFDIR:
            let sourceIdentity = identity(from: information)
            onBeforeCopyEntryCreate(destination)
            let createStatus = destinationName.withCString {
                Darwin.mkdirat(destinationParentDescriptor, $0, 0o700)
            }
            guard createStatus == 0 else { throw currentPOSIXError() }
            let createdIdentity = try identity(
                named: destinationName,
                in: destinationParentDescriptor,
                noFollow: true
            )
            onCopyEntryCreatedBeforeOpen(destination)
            let destinationDescriptor = destinationName.withCString {
                Darwin.openat(
                    destinationParentDescriptor,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK
                )
            }
            guard destinationDescriptor >= 0 else {
                let primaryError = currentPOSIXError()
                let cleanupError = removeCreatedEntry(
                    named: destinationName,
                    in: destinationParentDescriptor,
                    identifiedBy: createdIdentity,
                    isDirectory: true
                )
                throw FileTransferAccessFailure(primary: primaryError, cleanup: cleanupError)
            }
            var closesDestinationDescriptor = true
            defer {
                if closesDestinationDescriptor { Darwin.close(destinationDescriptor) }
            }
            let copiedIdentity: FileIdentity
            do {
                copiedIdentity = try requireOpenedEntry(
                    destinationDescriptor,
                    expectedIdentity: createdIdentity,
                    expectedType: S_IFDIR,
                    at: destination
                )
            } catch {
                let cleanupError = removeCreatedEntry(
                    named: destinationName,
                    in: destinationParentDescriptor,
                    identifiedBy: createdIdentity,
                    isDirectory: true
                )
                throw FileTransferAccessFailure(primary: error, cleanup: cleanupError)
            }
            appendOwnedEntry(
                url: destination,
                relativePath: relativePath,
                identity: copiedIdentity,
                kind: .directory,
                finalFlags: information.st_flags,
                to: &ownedEntries
            )
            if relativePath.isEmpty {
                rootDescriptor = destinationDescriptor
                closesDestinationDescriptor = false
            }
            onCopyEntryCreated(destination)
            try verifyEntry(copiedIdentity, named: destinationName, in: destinationParentDescriptor)

            onBeforeCopySourceEntryOpen(source)
            let sourceDescriptor = sourceName.withCString {
                Darwin.openat(
                    sourceParentDescriptor,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK
                )
            }
            guard sourceDescriptor >= 0 else { throw currentPOSIXError() }
            defer { Darwin.close(sourceDescriptor) }
            _ = try requireOpenedEntry(
                sourceDescriptor,
                expectedIdentity: sourceIdentity,
                expectedType: S_IFDIR,
                at: source
            )
            for childName in try directoryEntryNames(in: sourceDescriptor) {
                try Task.checkCancellation()
                _ = try copyOwnedNode(
                    source.appending(path: childName),
                    sourceName: childName,
                    sourceParentDescriptor: sourceDescriptor,
                    to: destination.appending(path: childName),
                    destinationName: childName,
                    destinationParentDescriptor: destinationDescriptor,
                    relativePath: relativePath + [childName],
                    rootDescriptor: &rootDescriptor,
                    ownedEntries: &ownedEntries
                )
            }
            try copyMetadata(
                from: sourceDescriptor,
                to: destinationDescriptor,
                finalFlags: information.st_flags
            )
            try verifyEntry(copiedIdentity, named: destinationName, in: destinationParentDescriptor)
            return copiedIdentity
        case S_IFLNK:
            let sourceIdentity = identity(from: information)
            onBeforeCopySourceEntryOpen(source)
            let sourceDescriptor = sourceName.withCString {
                Darwin.openat(sourceParentDescriptor, $0, O_RDONLY | O_SYMLINK | O_NONBLOCK)
            }
            guard sourceDescriptor >= 0 else { throw currentPOSIXError() }
            defer { Darwin.close(sourceDescriptor) }
            _ = try requireOpenedEntry(
                sourceDescriptor,
                expectedIdentity: sourceIdentity,
                expectedType: S_IFLNK,
                at: source
            )
            var target = try symbolicLinkTarget(
                named: sourceName,
                in: sourceParentDescriptor,
                expectedSize: Int(information.st_size)
            )
            try verifyEntry(sourceIdentity, named: sourceName, in: sourceParentDescriptor)
            onBeforeCopyEntryCreate(destination)
            let createStatus = target.withUnsafeMutableBufferPointer { buffer in
                destinationName.withCString {
                    Darwin.symlinkat(buffer.baseAddress, destinationParentDescriptor, $0)
                }
            }
            guard createStatus == 0 else { throw currentPOSIXError() }
            let createdIdentity = try identity(
                named: destinationName,
                in: destinationParentDescriptor,
                noFollow: true
            )
            onCopyEntryCreatedBeforeOpen(destination)
            let destinationDescriptor = destinationName.withCString {
                Darwin.openat(
                    destinationParentDescriptor,
                    $0,
                    O_RDONLY | O_SYMLINK | O_NONBLOCK
                )
            }
            guard destinationDescriptor >= 0 else {
                let primaryError = currentPOSIXError()
                let cleanupError = removeCreatedEntry(
                    named: destinationName,
                    in: destinationParentDescriptor,
                    identifiedBy: createdIdentity,
                    isDirectory: false
                )
                throw FileTransferAccessFailure(primary: primaryError, cleanup: cleanupError)
            }
            var closesDestinationDescriptor = true
            defer {
                if closesDestinationDescriptor { Darwin.close(destinationDescriptor) }
            }
            let copiedIdentity: FileIdentity
            do {
                copiedIdentity = try requireOpenedEntry(
                    destinationDescriptor,
                    expectedIdentity: createdIdentity,
                    expectedType: S_IFLNK,
                    at: destination
                )
            } catch {
                let cleanupError = removeCreatedEntry(
                    named: destinationName,
                    in: destinationParentDescriptor,
                    identifiedBy: createdIdentity,
                    isDirectory: false
                )
                throw FileTransferAccessFailure(primary: error, cleanup: cleanupError)
            }
            appendOwnedEntry(
                url: destination,
                relativePath: relativePath,
                identity: copiedIdentity,
                kind: .symbolicLink,
                finalFlags: information.st_flags,
                to: &ownedEntries
            )
            if relativePath.isEmpty {
                rootDescriptor = destinationDescriptor
                closesDestinationDescriptor = false
            }
            onCopyEntryCreated(destination)
            try verifyEntry(copiedIdentity, named: destinationName, in: destinationParentDescriptor)
            try copyMetadata(
                from: sourceDescriptor,
                to: destinationDescriptor,
                finalFlags: information.st_flags
            )
            return copiedIdentity
        default:
            throw FileTransferAccessError.unsupportedSpecialFile
        }
    }

    private func copyOwnedRegularFile(
        _ source: URL,
        sourceName: String,
        sourceParentDescriptor: Int32,
        to destination: URL,
        destinationName: String,
        destinationParentDescriptor: Int32,
        sourceIdentity: FileIdentity,
        finalFlags: UInt32,
        relativePath: [String],
        rootDescriptor: inout Int32?,
        ownedEntries: inout [OwnedCopyEntry]
    ) throws -> FileIdentity {
        onBeforeCopySourceEntryOpen(source)
        let sourceDescriptor = sourceName.withCString {
            Darwin.openat(sourceParentDescriptor, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        }
        guard sourceDescriptor >= 0 else { throw currentPOSIXError() }
        defer { Darwin.close(sourceDescriptor) }
        _ = try requireOpenedEntry(
            sourceDescriptor,
            expectedIdentity: sourceIdentity,
            expectedType: S_IFREG,
            at: source
        )

        onBeforeCopyEntryCreate(destination)
        let destinationDescriptor = destinationName.withCString {
            Darwin.openat(
                destinationParentDescriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
                0o600
            )
        }
        guard destinationDescriptor >= 0 else { throw currentPOSIXError() }
        var closesDestinationDescriptor = true
        defer {
            if closesDestinationDescriptor { Darwin.close(destinationDescriptor) }
        }

        let copiedIdentity = try identity(ofDescriptor: destinationDescriptor)
        appendOwnedEntry(
            url: destination,
            relativePath: relativePath,
            identity: copiedIdentity,
            kind: .regularFile,
            finalFlags: finalFlags,
            to: &ownedEntries
        )
        if relativePath.isEmpty {
            rootDescriptor = destinationDescriptor
            closesDestinationDescriptor = false
        }
        onCopyEntryCreated(destination)
        try verifyEntry(copiedIdentity, named: destinationName, in: destinationParentDescriptor)

        var buffer = [UInt8](repeating: 0, count: copyChunkSize)
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(sourceDescriptor, $0.baseAddress, $0.count)
            }
            guard count >= 0 else { throw currentPOSIXError() }
            guard count > 0 else { break }
            var written = 0
            while written < count {
                try Task.checkCancellation()
                let result = buffer.withUnsafeBytes {
                    Darwin.write(
                        destinationDescriptor,
                        $0.baseAddress!.advanced(by: written),
                        count - written
                    )
                }
                guard result > 0 else { throw currentPOSIXError() }
                written += result
            }
            onCopyChunk()
        }
        try copyMetadata(from: sourceDescriptor, to: destinationDescriptor, finalFlags: finalFlags)
        try verifyEntry(copiedIdentity, named: destinationName, in: destinationParentDescriptor)
        return copiedIdentity
    }

    private func copyMetadata(
        from sourceDescriptor: Int32,
        to destinationDescriptor: Int32,
        finalFlags: UInt32
    ) throws {
        try Task.checkCancellation()
        let copyStatus = fcopyfile(
            sourceDescriptor,
            destinationDescriptor,
            nil,
            UInt32(COPYFILE_METADATA)
        )
        let copyError = errno
        var primaryError: (any Error)?
        if copyStatus != 0 {
            primaryError = posixError(copyError)
        } else {
            do {
                try onCopyMetadataApplied()
            } catch {
                primaryError = error
            }
        }
        let stagingFlags = finalFlags & ~Self.mutationBlockingFlags
        let flagsStatus = Darwin.fchflags(destinationDescriptor, stagingFlags)
        let flagsError = errno
        if let primaryError { throw primaryError }
        guard flagsStatus == 0 else { throw posixError(flagsError) }
        try preserveCreationTime(from: sourceDescriptor, to: destinationDescriptor)
        try Task.checkCancellation()
    }

    private static let mutationBlockingFlags = UInt32(
        UF_IMMUTABLE | UF_APPEND | SF_IMMUTABLE | SF_APPEND
    )

    private func appendOwnedEntry(
        url: URL,
        relativePath: [String],
        identity: FileIdentity,
        kind: OwnedCopyEntry.Kind,
        finalFlags: UInt32,
        to entries: inout [OwnedCopyEntry]
    ) {
        entries.append(OwnedCopyEntry(
            url: url,
            relativePath: relativePath,
            identity: identity,
            kind: kind,
            finalFlags: finalFlags
        ))
    }

    private func removeCreatedEntry(
        named name: String,
        in parentDescriptor: Int32,
        identifiedBy expectedIdentity: FileIdentity,
        isDirectory: Bool
    ) -> (any Error)? {
        do {
            let currentIdentity = try identity(named: name, in: parentDescriptor, noFollow: true)
            guard currentIdentity.entryIdentifier == expectedIdentity.entryIdentifier else {
                return FileSystemAccessError.identityMismatch(URL(filePath: name))
            }
            let flags = isDirectory ? AT_REMOVEDIR : 0
            let status = name.withCString { Darwin.unlinkat(parentDescriptor, $0, flags) }
            return status == 0 ? nil : currentPOSIXError()
        } catch {
            return error
        }
    }

    private func directoryEntryNames(in descriptor: Int32) throws -> [String] {
        let duplicate = Darwin.dup(descriptor)
        guard duplicate >= 0 else { throw currentPOSIXError() }
        guard let directory = Darwin.fdopendir(duplicate) else {
            Darwin.close(duplicate)
            throw currentPOSIXError()
        }
        defer { Darwin.closedir(directory) }
        var names: [String] = []
        errno = 0
        while let entry = Darwin.readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if name != ".", name != ".." { names.append(name) }
            errno = 0
        }
        guard errno == 0 else { throw currentPOSIXError() }
        return names.sorted()
    }

    private func symbolicLinkTarget(
        named name: String,
        in parentDescriptor: Int32,
        expectedSize: Int
    ) throws -> [CChar] {
        var buffer = [CChar](repeating: 0, count: max(expectedSize + 2, Int(PATH_MAX) + 1))
        let count = name.withCString {
            Darwin.readlinkat(parentDescriptor, $0, &buffer, buffer.count - 1)
        }
        guard count >= 0 else { throw currentPOSIXError() }
        buffer[Int(count)] = 0
        return Array(buffer.prefix(Int(count) + 1))
    }

    private func preserveCreationTime(
        from sourceDescriptor: Int32,
        to destinationDescriptor: Int32
    ) throws {
        var sourceInformation = stat()
        guard Darwin.fstat(sourceDescriptor, &sourceInformation) == 0 else {
            throw currentPOSIXError()
        }
        var attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = UInt32(ATTR_CMN_CRTIME)
        var creationTime = sourceInformation.st_birthtimespec
        guard fsetattrlist(
            destinationDescriptor,
            &attributes,
            &creationTime,
            MemoryLayout<timespec>.size,
            0
        ) == 0 else {
            throw currentPOSIXError()
        }
    }

    private func openDescriptor(_ url: URL, flags: Int32) throws -> Int32 {
        let descriptor: Int32 = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return Darwin.open(path, flags)
        }
        guard descriptor >= 0 else { throw currentPOSIXError() }
        return descriptor
    }

    private func openParentDirectory(of url: URL) throws -> (Int32, String) {
        let parent = url.deletingLastPathComponent()
        let descriptor = try openDescriptor(parent, flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        return (descriptor, url.lastPathComponent)
    }

    private func identity(ofDescriptor descriptor: Int32) throws -> FileIdentity {
        var information = stat()
        guard Darwin.fstat(descriptor, &information) == 0 else { throw currentPOSIXError() }
        return identity(from: information)
    }

    private func requireOpenedEntry(
        _ descriptor: Int32,
        expectedIdentity: FileIdentity,
        expectedType: mode_t,
        at url: URL
    ) throws -> FileIdentity {
        var information = stat()
        guard Darwin.fstat(descriptor, &information) == 0 else { throw currentPOSIXError() }
        guard information.st_mode & S_IFMT == expectedType else {
            throw FileTransferAccessError.unexpectedOpenedEntryType(url)
        }
        let openedIdentity = identity(from: information)
        guard openedIdentity.entryIdentifier == expectedIdentity.entryIdentifier else {
            throw FileSystemAccessError.identityMismatch(url)
        }
        return openedIdentity
    }

    private func identity(
        named name: String,
        in parentDescriptor: Int32,
        noFollow: Bool
    ) throws -> FileIdentity {
        var information = stat()
        let flags = noFollow ? AT_SYMLINK_NOFOLLOW : 0
        let status = name.withCString { Darwin.fstatat(parentDescriptor, $0, &information, flags) }
        guard status == 0 else { throw currentPOSIXError() }
        return identity(from: information)
    }

    private func entryExists(named name: String, in parentDescriptor: Int32) -> Bool {
        var information = stat()
        let status = name.withCString {
            Darwin.fstatat(parentDescriptor, $0, &information, AT_SYMLINK_NOFOLLOW)
        }
        return status == 0
    }

    private func openAnchoredAbsoluteDirectory(_ directory: URL) throws -> Int32 {
        guard directory.isFileURL, directory.path.hasPrefix("/") else {
            throw FileSystemAccessError.identityMismatch(directory)
        }
        let components = directory.path.split(
            separator: "/",
            omittingEmptySubsequences: true
        ).map(String.init)
        guard components.allSatisfy({
            !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/")
        }) else {
            throw FileSystemAccessError.identityMismatch(directory)
        }

        var descriptor = try openDescriptor(
            URL(filePath: "/", directoryHint: .isDirectory),
            flags: O_SEARCH | O_NOFOLLOW | O_CLOEXEC
        )
        do {
            for component in components {
                let next = component.withCString {
                    Darwin.openat(
                        descriptor,
                        $0,
                        O_SEARCH | O_NOFOLLOW | O_CLOEXEC
                    )
                }
                guard next >= 0 else { throw currentPOSIXError() }
                Darwin.close(descriptor)
                descriptor = next
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private func renameExclusive(
        from sourceDescriptor: Int32,
        name sourceName: String,
        to destinationDescriptor: Int32,
        name destinationName: String
    ) throws {
        let status = sourceName.withCString { sourcePath in
            destinationName.withCString { destinationPath in
                Darwin.renameatx_np(
                    sourceDescriptor,
                    sourcePath,
                    destinationDescriptor,
                    destinationPath,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard status == 0 else { throw currentPOSIXError() }
    }

    private func finishEmptyQuarantine(_ context: StorageQuarantineContext) {
        storageQuarantines.removeValue(forKey: context.quarantine.id)
        _ = Darwin.fchmod(context.stagingDescriptor, 0o700)
        Darwin.close(context.stagingDescriptor)
        Darwin.close(context.sourceParentDescriptor)
        try? removeStagingDirectory(context.quarantine.reservation)
    }

    private func abandonRecoverableQuarantine(
        _ context: StorageQuarantineContext
    ) {
        storageQuarantines.removeValue(forKey: context.quarantine.id)
        _ = Darwin.fchmod(context.stagingDescriptor, 0o700)
        Darwin.close(context.stagingDescriptor)
        Darwin.close(context.sourceParentDescriptor)
    }

    private func identity(from information: stat) -> FileIdentity {
        let token = "\(UInt64(information.st_dev)):\(UInt64(information.st_ino))"
        return FileIdentity(entryIdentifier: token, resolvedIdentifier: token)
    }

    private func verifyEntry(
        _ expected: FileIdentity,
        named name: String,
        in parentDescriptor: Int32
    ) throws {
        guard try identity(named: name, in: parentDescriptor, noFollow: true).entryIdentifier
            == expected.entryIdentifier
        else {
            throw FileSystemAccessError.identityMismatch(URL(filePath: name))
        }
    }

    private func currentPOSIXError() -> POSIXError {
        posixError(errno)
    }

    private func posixError(_ code: Int32) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }

    private func renameItem(_ source: URL, to destination: URL) throws {
        let status: Int32 = source.withUnsafeFileSystemRepresentation { sourcePath in
            destination.withUnsafeFileSystemRepresentation { destinationPath in
                guard let sourcePath, let destinationPath else { return -1 }
                return Darwin.rename(sourcePath, destinationPath)
            }
        }
        guard status == 0 else { throw currentPOSIXError() }
    }

    private func changeMode(of url: URL, to mode: mode_t) throws {
        let status: Int32 = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return Darwin.chmod(path, mode)
        }
        guard status == 0 else { throw currentPOSIXError() }
    }

    private func cleanupOwnedCopyEntries(
        _ entries: [OwnedCopyEntry],
        rootDescriptor: Int32?,
        rootParentDescriptor: Int32,
        rootName: String
    ) -> (any Error)? {
        guard let rootDescriptor else {
            return entries.isEmpty ? nil : FileTransferAccessError.missingCopiedRootDescriptor
        }
        var firstError: (any Error)?
        for entry in entries {
            do {
                let descriptor = try openOwnedEntry(entry, from: rootDescriptor)
                defer {
                    if !entry.relativePath.isEmpty { Darwin.close(descriptor) }
                }
                try requireIdentity(entry.identity, ofDescriptor: descriptor, at: entry.url)
                if Darwin.fchflags(
                    descriptor,
                    entry.finalFlags & ~Self.mutationBlockingFlags
                ) != 0 {
                    firstError = firstError ?? currentPOSIXError()
                }
                guard entry.kind == .directory else { continue }
                var information = stat()
                if Darwin.fstat(descriptor, &information) != 0 {
                    firstError = firstError ?? currentPOSIXError()
                    continue
                }
                let cleanupMode = mode_t(information.st_mode & 0o7777) | S_IWUSR | S_IXUSR
                if Darwin.fchmod(descriptor, cleanupMode) != 0 {
                    firstError = firstError ?? currentPOSIXError()
                }
            } catch {
                firstError = firstError ?? error
            }
        }
        for entry in entries.reversed() {
            do {
                if entry.relativePath.isEmpty {
                    try requireIdentity(entry.identity, ofDescriptor: rootDescriptor, at: entry.url)
                    let current = try identity(named: rootName, in: rootParentDescriptor, noFollow: true)
                    guard current.entryIdentifier == entry.identity.entryIdentifier else {
                        throw FileSystemAccessError.identityMismatch(entry.url)
                    }
                    let flags = entry.kind == .directory ? AT_REMOVEDIR : 0
                    let result = rootName.withCString {
                        Darwin.unlinkat(rootParentDescriptor, $0, flags)
                    }
                    if result != 0 { throw currentPOSIXError() }
                    continue
                }
                let parentDescriptor = try openRelativeDirectory(
                    Array(entry.relativePath.dropLast()),
                    from: rootDescriptor
                )
                defer { Darwin.close(parentDescriptor) }
                let name = entry.relativePath.last!
                let current = try identity(named: name, in: parentDescriptor, noFollow: true)
                guard current.entryIdentifier == entry.identity.entryIdentifier else {
                    throw FileSystemAccessError.identityMismatch(entry.url)
                }
                let flags = entry.kind == .directory ? AT_REMOVEDIR : 0
                let result = name.withCString {
                    Darwin.unlinkat(parentDescriptor, $0, flags)
                }
                if result != 0 { throw currentPOSIXError() }
            } catch {
                firstError = firstError ?? error
            }
        }
        return firstError
    }

    private func closePendingCopy(_ pending: PendingOwnedCopy) {
        Darwin.close(pending.rootParentDescriptor)
        Darwin.close(pending.rootDescriptor)
    }

    private func applyAndClosePendingCopy(for identity: FileIdentity) throws {
        guard let pending = pendingCopies.removeValue(forKey: identity.entryIdentifier) else { return }
        defer { closePendingCopy(pending) }
        var firstError: (any Error)?
        for entry in pending.entries.reversed()
            where entry.finalFlags & Self.mutationBlockingFlags != 0 {
            do {
                let descriptor = try openOwnedEntry(entry, from: pending.rootDescriptor)
                defer {
                    if !entry.relativePath.isEmpty { Darwin.close(descriptor) }
                }
                try requireIdentity(entry.identity, ofDescriptor: descriptor, at: entry.url)
                if Darwin.fchflags(descriptor, entry.finalFlags) != 0 {
                    firstError = firstError ?? currentPOSIXError()
                }
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError { throw firstError }
    }

    private func openOwnedEntry(
        _ entry: OwnedCopyEntry,
        from rootDescriptor: Int32
    ) throws -> Int32 {
        guard !entry.relativePath.isEmpty else { return rootDescriptor }
        let parentDescriptor = try openRelativeDirectory(
            Array(entry.relativePath.dropLast()),
            from: rootDescriptor
        )
        defer { Darwin.close(parentDescriptor) }
        let (flags, expectedType): (Int32, mode_t) = switch entry.kind {
        case .regularFile:
            (O_RDONLY | O_NOFOLLOW | O_NONBLOCK, S_IFREG)
        case .directory:
            (O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK, S_IFDIR)
        case .symbolicLink:
            (O_RDONLY | O_SYMLINK | O_NONBLOCK, S_IFLNK)
        }
        let descriptor = entry.relativePath.last!.withCString {
            Darwin.openat(parentDescriptor, $0, flags)
        }
        guard descriptor >= 0 else { throw currentPOSIXError() }
        do {
            _ = try requireOpenedEntry(
                descriptor,
                expectedIdentity: entry.identity,
                expectedType: expectedType,
                at: entry.url
            )
        } catch {
            Darwin.close(descriptor)
            throw error
        }
        return descriptor
    }

    private func openRelativeDirectory(
        _ components: [String],
        from rootDescriptor: Int32
    ) throws -> Int32 {
        var descriptor = Darwin.dup(rootDescriptor)
        guard descriptor >= 0 else { throw currentPOSIXError() }
        do {
            for component in components {
                let next = component.withCString {
                    Darwin.openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                }
                guard next >= 0 else { throw currentPOSIXError() }
                Darwin.close(descriptor)
                descriptor = next
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private func requireIdentity(
        _ expected: FileIdentity,
        ofDescriptor descriptor: Int32,
        at url: URL
    ) throws {
        guard try identity(ofDescriptor: descriptor).entryIdentifier == expected.entryIdentifier else {
            throw FileSystemAccessError.identityMismatch(url)
        }
    }

    private func nodeIdentifier(for url: URL, followsSymlink: Bool) throws -> String? {
        var information = stat()
        let inspectedURL = followsSymlink ? url.resolvingSymlinksInPath() : url
        let result: Int32 = inspectedURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.lstat(path, &information)
        }
        guard result == 0 else {
            if errno == ENOENT {
                return nil
            }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return "\(UInt64(information.st_dev)):\(UInt64(information.st_ino))"
    }

    private func appendFingerprintEntries(
        at url: URL,
        relativePath: String,
        to entries: inout [SourceFingerprint.Entry]
    ) throws {
        try Task.checkCancellation()
        var information = stat()
        let result: Int32 = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.lstat(path, &information)
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        entries.append(
            SourceFingerprint.Entry(
                relativePath: relativePath,
                device: UInt64(information.st_dev),
                inode: UInt64(information.st_ino),
                mode: UInt32(information.st_mode),
                size: Int64(information.st_size),
                modificationSeconds: Int64(information.st_mtimespec.tv_sec),
                modificationNanoseconds: Int64(information.st_mtimespec.tv_nsec),
                changeSeconds: Int64(information.st_ctimespec.tv_sec),
                changeNanoseconds: Int64(information.st_ctimespec.tv_nsec)
            )
        )

        guard information.st_mode & S_IFMT == S_IFDIR else {
            return
        }
        for name in try fileManager.contentsOfDirectory(atPath: url.path).sorted() {
            let childRelativePath = relativePath == "." ? name : "\(relativePath)/\(name)"
            try appendFingerprintEntries(
                at: url.appending(path: name),
                relativePath: childRelativePath,
                to: &entries
            )
        }
    }

    private func removeEmptyDirectory(_ directory: URL) -> (any Error)? {
        let result: Int32 = directory.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.rmdir(path)
        }
        guard result != 0 else { return nil }
        return POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    private func isFileExists(_ error: any Error) -> Bool {
        let cocoaError = error as NSError
        return cocoaError.domain == NSCocoaErrorDomain
            && cocoaError.code == CocoaError.Code.fileWriteFileExists.rawValue
    }
}

private struct FileTransferAccessFailure: LocalizedError {
    let primary: any Error
    let cleanup: (any Error)?

    var errorDescription: String? {
        guard let cleanup else { return primary.localizedDescription }
        return "\(primary.localizedDescription) (cleanup failed: \(cleanup.localizedDescription))"
    }
}

private enum FileTransferAccessError: Error {
    case missingStagingIdentity
    case missingCopiedItemIdentity
    case missingCopiedRootDescriptor
    case unexpectedOpenedEntryType(URL)
    case unsupportedSpecialFile
}

private struct OwnedCopyEntry {
    enum Kind {
        case regularFile
        case directory
        case symbolicLink
    }

    let url: URL
    let relativePath: [String]
    let identity: FileIdentity
    let kind: Kind
    let finalFlags: UInt32
}

private struct PendingOwnedCopy {
    let entries: [OwnedCopyEntry]
    let rootParentDescriptor: Int32
    let rootDescriptor: Int32
    let rootName: String
}
