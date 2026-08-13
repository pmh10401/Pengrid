import Darwin
import Foundation

protocol GetInfoInspecting: Sendable {
    func inspect(_ items: [FileItem]) async throws -> GetInfoInspectionReport
}

struct LiveGetInfoInspectionService: GetInfoInspecting {
    private let fileSystem: any FileSystemAccess
    private let accessCoordinator: CloudLocationScopedAccessCoordinator
    private let identityLookup: (@Sendable (URL) async throws -> FileIdentity?)?

    init(
        fileSystem: any FileSystemAccess = LiveFileSystemAccess(),
        accessCoordinator: CloudLocationScopedAccessCoordinator = .init(),
        identityLookup: (@Sendable (URL) async throws -> FileIdentity?)? = nil
    ) {
        self.fileSystem = fileSystem
        self.accessCoordinator = accessCoordinator
        self.identityLookup = identityLookup
    }

    func inspect(_ items: [FileItem]) async throws -> GetInfoInspectionReport {
        var outcomes: [GetInfoInspectionOutcome] = []
        outcomes.reserveCapacity(items.count)

        for item in items {
            do {
                try Task.checkCancellation()
                outcomes.append(.success(try await inspect(item)))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                outcomes.append(.failure(.init(
                    url: item.url.standardizedFileURL,
                    reason: failureReason(for: error)
                )))
            }
        }
        return .init(outcomes: outcomes)
    }

    private func inspect(_ item: FileItem) async throws -> GetInfoItemSnapshot {
        let url = item.url.standardizedFileURL
        let accessLease = try accessCoordinator.acquireAccess(for: url)
        defer { accessLease?.finish() }

        try Task.checkCancellation()
        guard let initialIdentity = try await identity(of: url) else {
            throw GetInfoInspectionFailure.Reason.itemChanged
        }
        let metadata = try await Task.detached(priority: .utility) {
            try GetInfoNoFollowMetadata.read(at: url)
        }.value
        try Task.checkCancellation()
        guard let finalIdentity = try await identity(of: url), finalIdentity == initialIdentity else {
            throw GetInfoInspectionFailure.Reason.itemChanged
        }

        let checksumRequest: ChecksumRequest?
        if metadata.kind == .regularFile {
            checksumRequest = .init(
                url: url,
                fingerprint: .init(
                    identity: initialIdentity,
                    byteSize: metadata.logicalByteSize,
                    modifiedAt: metadata.modifiedAt,
                    rawModifiedAt: .init(
                        seconds: metadata.modificationSeconds,
                        nanoseconds: metadata.modificationNanoseconds
                    )
                )
            )
        } else {
            checksumRequest = nil
        }
        return .init(
            url: url,
            name: url.lastPathComponent,
            kind: metadata.kind,
            typeDescription: metadata.typeDescription,
            typeIdentifier: metadata.typeIdentifier,
            logicalByteSize: metadata.logicalByteSize,
            allocatedByteSize: metadata.allocatedByteSize,
            createdAt: metadata.createdAt,
            modifiedAt: metadata.modifiedAt,
            ownerID: metadata.ownerID,
            groupID: metadata.groupID,
            posixMode: metadata.posixMode,
            finderTags: metadata.finderTags,
            symbolicLinkDestination: metadata.symbolicLinkDestination,
            availability: item.availability,
            identity: initialIdentity,
            checksumRequest: checksumRequest
        )
    }

    private func identity(of url: URL) async throws -> FileIdentity? {
        if let identityLookup {
            return try await identityLookup(url)
        }
        return try await fileSystem.identity(of: url)
    }

    private func failureReason(for error: any Error) -> GetInfoInspectionFailure.Reason {
        if let reason = error as? GetInfoInspectionFailure.Reason {
            return reason
        }
        if error is CloudLocationScopedAccessError {
            return .accessDenied
        }
        if error is FileSystemAccessError {
            return .itemChanged
        }
        if let error = error as? POSIXError,
           error.code == .EACCES || error.code == .EPERM {
            return .accessDenied
        }
        return .metadataUnavailable
    }
}

private struct GetInfoNoFollowMetadata: Sendable {
    let kind: GetInfoEntryKind
    let typeDescription: String
    let typeIdentifier: String?
    let logicalByteSize: Int64?
    let allocatedByteSize: Int64?
    let createdAt: Date?
    let modifiedAt: Date?
    let ownerID: UInt32
    let groupID: UInt32
    let posixMode: UInt16
    let finderTags: [String]
    let symbolicLinkDestination: String?
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64

    static func read(at url: URL) throws -> Self {
        let information = try lstat(at: url)
        let kind = entryKind(for: information, url: url)
        let values = try? url.resourceValues(forKeys: [
            .creationDateKey,
            .contentModificationDateKey,
            .localizedTypeDescriptionKey,
            .typeIdentifierKey,
            .tagNamesKey
        ])
        let modificationSeconds = Int64(information.st_mtimespec.tv_sec)
        let modificationNanoseconds = Int64(information.st_mtimespec.tv_nsec)
        let modifiedAt = values?.contentModificationDate ?? timestamp(
            seconds: modificationSeconds,
            nanoseconds: modificationNanoseconds
        )
        let typeDescription: String
        if kind == .symbolicLink {
            typeDescription = "Symbolic Link"
        } else {
            typeDescription = values?.localizedTypeDescription ?? kind.rawValue
        }
        let logicalByteSize = kind == .regularFile ? Int64(information.st_size) : nil
        let allocatedByteSize = kind == .regularFile ? Int64(information.st_blocks) * 512 : nil

        return .init(
            kind: kind,
            typeDescription: typeDescription,
            typeIdentifier: values?.typeIdentifier,
            logicalByteSize: logicalByteSize,
            allocatedByteSize: allocatedByteSize,
            createdAt: values?.creationDate ?? timestamp(
                seconds: Int64(information.st_birthtimespec.tv_sec),
                nanoseconds: Int64(information.st_birthtimespec.tv_nsec)
            ),
            modifiedAt: modifiedAt,
            ownerID: UInt32(information.st_uid),
            groupID: UInt32(information.st_gid),
            posixMode: UInt16(information.st_mode & 0o7777),
            finderTags: values?.tagNames ?? [],
            symbolicLinkDestination: kind == .symbolicLink ? try symbolicLinkDestination(at: url) : nil,
            modificationSeconds: modificationSeconds,
            modificationNanoseconds: modificationNanoseconds
        )
    }

    private static func entryKind(for information: stat, url: URL) -> GetInfoEntryKind {
        switch information.st_mode & S_IFMT {
        case S_IFREG: return .regularFile
        case S_IFDIR:
            return (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) == true
                ? .package
                : .directory
        case S_IFLNK: return .symbolicLink
        default: return .special
        }
    }

    private static func lstat(at url: URL) throws -> stat {
        var information = stat()
        let status: Int32 = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return Darwin.lstat(path, &information)
        }
        guard status == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return information
    }

    private static func timestamp(seconds: Int64, nanoseconds: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(seconds) + TimeInterval(nanoseconds) / 1_000_000_000)
    }

    private static func symbolicLinkDestination(at url: URL) throws -> String {
        var capacity = 256
        while capacity <= 65_536 {
            var buffer = [CChar](repeating: 0, count: capacity)
            let count: Int = url.withUnsafeFileSystemRepresentation { path in
                guard let path else { return -1 }
                return buffer.withUnsafeMutableBufferPointer {
                    Darwin.readlink(path, $0.baseAddress, $0.count)
                }
            }
            guard count >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if count < capacity {
                return String(decoding: buffer.prefix(count).map(UInt8.init(bitPattern:)), as: UTF8.self)
            }
            capacity *= 2
        }
        throw POSIXError(.ENAMETOOLONG)
    }
}
