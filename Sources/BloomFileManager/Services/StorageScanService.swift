import Darwin
import Foundation
import UniformTypeIdentifiers

struct StorageScanOptions: Equatable, Sendable {
    var includeHiddenItems = false
}

enum StorageScanRootKind: Equatable, Sendable {
    case directory
}

struct StorageScanAuthorizationContext: Equatable, Sendable {
    let isProtectedLocation: Bool
    let protectedScanAuthorized: Bool
    let cleanupAuthorized: Bool
}

struct StorageScanAdmissionToken: Equatable, Sendable {
    let root: URL
    let rootIdentity: FileIdentity
    let rootKind: StorageScanRootKind
    let volumeClassification: StorageScanVolumeClassification
    let authorization: StorageScanAuthorizationContext

    func authorizingProtectedScan() -> Self {
        Self(
            root: root,
            rootIdentity: rootIdentity,
            rootKind: rootKind,
            volumeClassification: volumeClassification,
            authorization: .init(
                isProtectedLocation: authorization.isProtectedLocation,
                protectedScanAuthorized: true,
                cleanupAuthorized: false
            )
        )
    }

    func authorizingCleanup() -> Self {
        Self(
            root: root,
            rootIdentity: rootIdentity,
            rootKind: rootKind,
            volumeClassification: volumeClassification,
            authorization: .init(
                isProtectedLocation: authorization.isProtectedLocation,
                protectedScanAuthorized: authorization.protectedScanAuthorized,
                cleanupAuthorized: true
            )
        )
    }
}

struct StorageScanRequest: Sendable {
    let admission: StorageScanAdmissionToken
    let options: StorageScanOptions

    var root: URL { admission.root }
    var rootIdentity: FileIdentity { admission.rootIdentity }
}

enum StorageScanRecord: Sendable {
    case entry(StorageEntry)
    case failure(path: StorageRelativePath, message: String)
}

struct StorageScanBatch: Sendable {
    let records: [StorageScanRecord]
}

enum StorageScanError: Error, Equatable, Sendable {
    case rootIdentityMismatch
    case admissionInvalid
}

protocol StorageScanning: Sendable {
    func identity(of root: URL) async throws -> FileIdentity
    func validateAdmission(_ admission: StorageScanAdmissionToken) async throws
    func batches(for request: StorageScanRequest)
        -> AsyncThrowingStream<StorageScanBatch, Error>
}

extension StorageScanning {
    func validateAdmission(_ admission: StorageScanAdmissionToken) async throws {
        let current = try await identity(of: admission.root)
        guard current == admission.rootIdentity else {
            throw StorageScanError.admissionInvalid
        }
    }
}

protocol StorageScanBufferObserving: Sendable {
    func didEnqueue(bufferedCount: Int) async
    func didApplyBackpressure() async
}

private struct NoopStorageScanBufferObserver: StorageScanBufferObserving {
    func didEnqueue(bufferedCount _: Int) async {}
    func didApplyBackpressure() async {}
}

struct LiveStorageScanService: StorageScanning {
    private let listing: any ComparisonListingService
    private let bufferCapacity: Int
    private let bufferObserver: any StorageScanBufferObserving
    private let volumeClassification:
        @Sendable (URL) throws -> StorageScanVolumeClassification

    init(
        listing: any ComparisonListingService = LiveComparisonListingService(),
        bufferCapacity: Int = 8,
        bufferObserver: any StorageScanBufferObserving =
            NoopStorageScanBufferObserver(),
        volumeClassification:
            @escaping @Sendable (URL) throws -> StorageScanVolumeClassification =
            storageScanVolumeClassification
    ) {
        self.listing = listing
        self.bufferCapacity = max(1, bufferCapacity)
        self.bufferObserver = bufferObserver
        self.volumeClassification = volumeClassification
    }

    func identity(of root: URL) async throws -> FileIdentity {
        try await listing.identity(of: root)
    }

    func validateAdmission(_ admission: StorageScanAdmissionToken) async throws {
        let candidate = admission.root.standardizedFileURL
        guard candidate == admission.root,
              admission.rootKind == .directory,
              admission.volumeClassification == .local,
              !admission.authorization.isProtectedLocation
                || admission.authorization.protectedScanAuthorized
        else {
            throw StorageScanError.admissionInvalid
        }
        let information = try storageLstat(candidate)
        guard information.st_mode & S_IFMT == S_IFDIR,
              information.st_mode & S_IFMT != S_IFLNK,
              storageIdentity(from: information) == admission.rootIdentity,
              try volumeClassification(candidate) == admission.volumeClassification,
              isProtectedSystemLocation(candidate)
                == admission.authorization.isProtectedLocation
        else {
            throw StorageScanError.admissionInvalid
        }
        let listingIdentity = try await listing.identity(of: candidate)
        guard listingIdentity == admission.rootIdentity else {
            throw StorageScanError.admissionInvalid
        }
    }

    func batches(for request: StorageScanRequest)
        -> AsyncThrowingStream<StorageScanBatch, Error> {
        AsyncThrowingStream(
            bufferingPolicy: .bufferingOldest(bufferCapacity)
        ) { continuation in
            let task = Task {
                do {
                    try await validateAdmission(request.admission)
                    try Task.checkCancellation()

                    let listingRequest = ComparisonListingRequest(
                        root: request.root,
                        seed: nil,
                        subtree: nil,
                        options: ComparisonOptions(
                            includeSubfolders: true,
                            includeHiddenItems: request.options.includeHiddenItems
                        )
                    )
                    for try await batch in listing.batches(for: listingRequest) {
                        try Task.checkCancellation()
                        try await validateAdmission(request.admission)
                        let output = StorageScanBatch(
                            records: try batch.records.map(storageScanRecord)
                        )
                        try await yieldCritical(output, to: continuation)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func yieldCritical(
        _ batch: StorageScanBatch,
        to continuation: AsyncThrowingStream<StorageScanBatch, Error>.Continuation
    ) async throws {
        while true {
            try Task.checkCancellation()
            switch continuation.yield(batch) {
            case let .enqueued(remainingCapacity):
                await bufferObserver.didEnqueue(
                    bufferedCount: bufferCapacity - remainingCapacity
                )
                return
            case .dropped:
                await bufferObserver.didApplyBackpressure()
                try await Task.sleep(for: .milliseconds(1))
            case .terminated:
                throw CancellationError()
            @unknown default:
                throw CancellationError()
            }
        }
    }
}

protocol StorageEntryFingerprintReading: Sendable {
    func fingerprint(of url: URL) async throws -> ComparisonFingerprint
}

struct LiveStorageEntryFingerprintReader: StorageEntryFingerprintReading {
    func fingerprint(of url: URL) async throws -> ComparisonFingerprint {
        try await Task.detached {
            let information = try storageLstat(url)
            let identity = "\(UInt64(information.st_dev)):\(UInt64(information.st_ino))"
            return ComparisonFingerprint(
                identity: FileIdentity(
                    entryIdentifier: identity,
                    resolvedIdentifier: identity
                ),
                byteSize: Int64(information.st_size),
                modifiedAt: Date(
                    timeIntervalSince1970: TimeInterval(information.st_mtimespec.tv_sec)
                        + TimeInterval(information.st_mtimespec.tv_nsec) / 1_000_000_000
                ),
                rawModifiedAt: ComparisonModificationTimestamp(
                    seconds: Int64(information.st_mtimespec.tv_sec),
                    nanoseconds: Int64(information.st_mtimespec.tv_nsec)
                )
            )
        }.value
    }
}

enum StorageScanLocationDecision: Equatable {
    case allowed(StorageScanAdmissionToken)
    case protected(reason: String, admission: StorageScanAdmissionToken)
    case rejected(reason: String)

    var admission: StorageScanAdmissionToken? {
        switch self {
        case let .allowed(admission),
             let .protected(_, admission):
            admission
        case .rejected:
            nil
        }
    }

    var isProtected: Bool {
        if case .protected = self { true } else { false }
    }

    var isRejected: Bool {
        if case .rejected = self { true } else { false }
    }
}

enum StorageScanVolumeClassification: Equatable, Sendable {
    case local
    case network
    case fileProvider
    case unknown
}

@MainActor
protocol StorageScanLocationValidating {
    func decision(for url: URL) -> StorageScanLocationDecision
    func revalidate(_ admission: StorageScanAdmissionToken) -> Bool
}

extension StorageScanLocationValidating {
    func revalidate(_ admission: StorageScanAdmissionToken) -> Bool {
        guard let current = decision(for: admission.root).admission else { return false }
        return current.root == admission.root
            && current.rootIdentity == admission.rootIdentity
            && current.rootKind == admission.rootKind
            && current.volumeClassification == admission.volumeClassification
            && current.authorization.isProtectedLocation
                == admission.authorization.isProtectedLocation
    }
}

@MainActor
struct LiveStorageScanLocationPolicy: StorageScanLocationValidating {
    private let cloudLocations: CloudLocationsStore
    private let packageMetadata: (URL) throws -> Bool
    private let volumeClassification: (URL) throws -> StorageScanVolumeClassification

    init(
        cloudLocations: CloudLocationsStore,
        packageMetadata: @escaping (URL) throws -> Bool = storageScanPackageMetadata,
        volumeClassification: @escaping (URL) throws -> StorageScanVolumeClassification =
            storageScanVolumeClassification
    ) {
        self.cloudLocations = cloudLocations
        self.packageMetadata = packageMetadata
        self.volumeClassification = volumeClassification
    }

    func decision(for url: URL) -> StorageScanLocationDecision {
        guard url.isFileURL else {
            return .rejected(reason: "Choose a local folder.")
        }
        let candidate = url.standardizedFileURL
        let information: stat
        do {
            information = try storageLstat(candidate)
        } catch {
            return .rejected(reason: "Choose an existing folder.")
        }
        guard information.st_mode & S_IFMT != S_IFLNK else {
            return .rejected(reason: "Folder aliases cannot be scanned.")
        }
        guard information.st_mode & S_IFMT == S_IFDIR else {
            return .rejected(reason: "Choose an existing folder.")
        }

        let isPackage: Bool
        do {
            isPackage = try packageMetadata(candidate)
        } catch {
            return .rejected(reason: "This folder could not be inspected.")
        }
        guard !isPackage else {
            return .rejected(reason: "Application packages cannot be scanned.")
        }
        guard FileManager.default.isReadableFile(atPath: candidate.path) else {
            return .rejected(reason: "This folder cannot be read.")
        }
        guard cloudLocations.hasCompletedInitialDiscovery else {
            return .rejected(reason: "Storage locations are still being discovered.")
        }
        if cloudLocations.intersectsKnownLocation(candidate) {
            return .rejected(reason: "Cloud storage locations cannot be scanned.")
        }
        let classification: StorageScanVolumeClassification
        do {
            classification = try volumeClassification(candidate)
        } catch {
            return .rejected(reason: "This storage location could not be classified.")
        }
        switch classification {
        case .local:
            break
        case .network:
            return .rejected(reason: "Network-mounted folders cannot be scanned.")
        case .fileProvider:
            return .rejected(reason: "Cloud storage locations cannot be scanned.")
        case .unknown:
            return .rejected(reason: "Choose a local folder or directly attached volume.")
        }
        let isProtected = isProtectedSystemLocation(candidate)
        let admission = StorageScanAdmissionToken(
            root: candidate,
            rootIdentity: storageIdentity(from: information),
            rootKind: .directory,
            volumeClassification: classification,
            authorization: .init(
                isProtectedLocation: isProtected,
                protectedScanAuthorized: !isProtected,
                cleanupAuthorized: !isProtected
            )
        )
        return isProtected
            ? .protected(
                reason: "This folder contains protected system files.",
                admission: admission
            )
            : .allowed(admission)
    }
}

private func storageScanPackageMetadata(_ url: URL) throws -> Bool {
    try url.resourceValues(forKeys: [.isPackageKey]).isPackage == true
}

private func storageScanVolumeClassification(
    _ url: URL
) throws -> StorageScanVolumeClassification {
    let candidate = url.standardizedFileURL
    let cloudStorageRoot = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library", directoryHint: .isDirectory)
        .appending(path: "CloudStorage", directoryHint: .isDirectory)
        .standardizedFileURL
    if candidate.pathComponents.starts(with: cloudStorageRoot.pathComponents) {
        return .fileProvider
    }

    let values = try candidate.resourceValues(forKeys: [
        .isUbiquitousItemKey,
        .volumeIsLocalKey
    ])
    if values.isUbiquitousItem == true {
        return .fileProvider
    }
    guard let isLocal = values.volumeIsLocal else {
        return .unknown
    }
    return isLocal ? .local : .network
}

private func storageScanRecord(
    _ record: ComparisonListingRecord
) throws -> StorageScanRecord {
    switch record {
    case let .entry(entry):
        return .entry(StorageEntry(
            relativePath: try StorageRelativePath(
                components: entry.relativePath.components
            ),
            url: entry.url,
            kind: storageEntryKind(entry.kind),
            category: storageFileCategory(for: entry),
            fingerprint: entry.fingerprint,
            typeDescription: entry.typeDescription
        ))
    case let .failure(path, _):
        return .failure(
            path: try StorageRelativePath(components: path.components),
            message: "This item could not be scanned."
        )
    }
}

private func storageEntryKind(_ kind: ComparisonEntryKind) -> StorageEntryKind {
    switch kind {
    case .regularFile: .regularFile
    case .directory: .directory
    case .symbolicLink: .symbolicLink
    case .package: .package
    case .special: .special
    }
}

private func storageFileCategory(for entry: ComparisonEntry) -> StorageFileCategory {
    guard entry.kind == .regularFile || entry.kind == .package else {
        return .other
    }
    guard let type = try? entry.url.resourceValues(
        forKeys: [.contentTypeKey]
    ).contentType else {
        return .other
    }
    if type.conforms(to: .image) { return .image }
    if type.conforms(to: .movie) { return .video }
    if type.conforms(to: .audio) { return .audio }
    if type.conforms(to: .archive) { return .archive }
    if type.conforms(to: .application) { return .application }
    if type.conforms(to: .text)
        || type.conforms(to: .pdf)
        || type.conforms(to: .spreadsheet)
        || type.conforms(to: .presentation) {
        return .document
    }
    return .other
}

private func isProtectedSystemLocation(_ candidate: URL) -> Bool {
    var protectedRoots = [
        URL(filePath: "/System", directoryHint: .isDirectory),
        URL(filePath: "/Library", directoryHint: .isDirectory)
    ]
    if let userLibrary = FileManager.default.urls(
        for: .libraryDirectory,
        in: .userDomainMask
    ).first {
        protectedRoots.append(userLibrary)
    }
    let candidateComponents = candidate.standardizedFileURL.pathComponents
    return protectedRoots.contains { root in
        let rootComponents = root.standardizedFileURL.pathComponents
        return candidateComponents.starts(with: rootComponents)
            || rootComponents.starts(with: candidateComponents)
    }
}

private func storageLstat(_ url: URL) throws -> stat {
    var information = stat()
    let status: Int32 = url.withUnsafeFileSystemRepresentation { path in
        guard let path else { return Int32(-1) }
        return Darwin.lstat(path, &information)
    }
    guard status == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return information
}

private func storageIdentity(from information: stat) -> FileIdentity {
    let identifier = "\(UInt64(information.st_dev)):\(UInt64(information.st_ino))"
    return FileIdentity(entryIdentifier: identifier, resolvedIdentifier: identifier)
}
