import Foundation
@testable import BloomFileManager

struct StubCloudFS: CloudLocationFileSystem {
    enum Entry: Sendable {
        case candidate(CloudLocationCandidate)
        case unreadableFixture
        case regularFileFixture
    }

    private let roots: [Entry]

    init(_ roots: [Entry]) {
        self.roots = roots
    }

    func candidates() async -> [CloudLocationCandidate] {
        roots.compactMap {
            guard case let .candidate(candidate) = $0 else { return nil }
            return candidate
        }
    }
}

actor RecordingFileSystem: FileSystemAccess {
    enum Operation: Hashable, Sendable {
        case createDirectory(URL)
        case copy(URL, URL)
        case move(URL, URL)
        case remove(URL)
        case replace(URL, URL)
        case trash(URL)
        case checkedTrash(URL, FileIdentity)
        case names(URL)
        case volumeIdentifier(URL)
        case byteSize(URL)
        case availableCapacity(URL)
        case identity(URL)
        case checkedMove(URL, FileIdentity, URL)
        case checkedRemove(URL, FileIdentity)
        case checkedReplace(URL, FileIdentity, URL, FileIdentity)
        case fingerprint(URL)
        case removeStaging(URL, FileIdentity)
        case prepareHierarchy(URL, FileIdentity, [String])
        case removeOwnedDirectories(URL, FileIdentity, [[String]])

        var event: String {
            switch self {
            case let .createDirectory(url):
                "createDirectory:\(url.path)"
            case let .copy(source, destination):
                "copy:\(source.path)->\(destination.path)"
            case let .move(source, destination):
                "move:\(source.path)->\(destination.path)"
            case let .remove(url):
                "remove:\(url.path)"
            case let .replace(destination, stagedItem):
                "replace:\(destination.path)<-\(stagedItem.path)"
            case let .trash(url):
                "trash:\(url.path)"
            case let .checkedTrash(url, _):
                "trash:\(url.path)"
            case let .names(directory):
                "names:\(directory.path)"
            case let .volumeIdentifier(url):
                "volumeIdentifier:\(url.path)"
            case let .byteSize(url):
                "byteSize:\(url.path)"
            case let .availableCapacity(url):
                "availableCapacity:\(url.path)"
            case let .identity(url):
                "identity:\(url.path)"
            case let .checkedMove(source, _, destination):
                "moveChecked:\(source.path)->\(destination.path)"
            case let .checkedRemove(url, _):
                "removeChecked:\(url.path)"
            case let .checkedReplace(destination, _, stagedItem, _):
                "replaceChecked:\(destination.path)<-\(stagedItem.path)"
            case let .fingerprint(url):
                "fingerprint:\(url.path)"
            case let .removeStaging(url, _):
                "removeStaging:\(url.path)"
            case let .prepareHierarchy(root, _, components):
                "prepareHierarchy:\(root.path)/\(components.joined(separator: "/"))"
            case let .removeOwnedDirectories(root, _, components):
                "removeOwnedDirectories:\(root.path):\(components.map { $0.joined(separator: "/") }.joined(separator: ","))"
            }
        }
    }

    private(set) var events: [String] = []
    private(set) var existingURLs: Set<URL>
    private(set) var copiedDestinations: [URL] = []
    private(set) var removedURLs: [URL] = []
    private(set) var identities: [URL: FileIdentity]
    private let existsResponses: [URL: Bool]
    private let failures: [Operation: any Error]
    private let volumeIdentifiers: [URL: String]
    private let byteSizes: [URL: Int64]
    private let availableCapacities: [URL: Int64]
    private let injectedCopyError: (any Error)?
    private let cancelAfterCopy: Bool
    private let recordsExistenceChecks: Bool
    private let copyErrorAfterCreatingPartial: CocoaError?
    private let sourceRemovalErrorAfterSideEffect: CocoaError?
    private var replacementSourceIdentityBeforeRemoval: FileIdentity?
    private var losesSourceIdentityBeforeRemoval: Bool
    private let replacementStagingIdentityAfterPartialCopy: FileIdentity?
    private let replacementStagingIdentityAfterSuccessfulCopy: FileIdentity?
    private let stagingCleanupError: CocoaError?
    private let copyErrorsBySource: [URL: CocoaError]
    private let cancelFirstStagingReservation: Bool
    private let hidesCommittedDestinationIdentity: Bool
    private let mutatesSourcesAfterCopy: Set<URL>
    private let mutatesSourcesAfterCommit: Set<URL>
    private var fingerprintVersions: [URL: Int] = [:]
    private var fingerprintCallCount = 0
    private let cancelOnFingerprintCall: Int?
    private let stagingReservationIdentityError: CocoaError?
    private let cancelAfterCommit: Bool
    private let cancelAfterIdentityOf: URL?
    private let cancelAfterTrashOf: URL?
    private let caseInsensitivePaths: Bool
    private var didCancelStagingReservation = false
    private var nextIdentity = 0
    private var committedDestinations: Set<URL> = []

    init(
        existingURLs: Set<URL> = [],
        existsResponses: [URL: Bool] = [:],
        failures: [Operation: any Error] = [:],
        volumeIdentifiers: [URL: String] = [:],
        byteSizes: [URL: Int64] = [:],
        availableCapacities: [URL: Int64] = [:],
        injectedCopyError: (any Error)? = nil,
        cancelAfterCopy: Bool = false,
        recordsExistenceChecks: Bool = false,
        identities: [URL: FileIdentity] = [:],
        copyErrorAfterCreatingPartial: CocoaError? = nil,
        sourceRemovalErrorAfterSideEffect: CocoaError? = nil,
        replacementSourceIdentityBeforeRemoval: FileIdentity? = nil,
        losesSourceIdentityBeforeRemoval: Bool = false,
        replacementStagingIdentityAfterPartialCopy: FileIdentity? = nil,
        replacementStagingIdentityAfterSuccessfulCopy: FileIdentity? = nil,
        stagingCleanupError: CocoaError? = nil,
        copyErrorsBySource: [URL: CocoaError] = [:],
        cancelFirstStagingReservation: Bool = false,
        hidesCommittedDestinationIdentity: Bool = false,
        mutatesSourcesAfterCopy: Set<URL> = [],
        mutatesSourcesAfterCommit: Set<URL> = [],
        cancelOnFingerprintCall: Int? = nil,
        stagingReservationIdentityError: CocoaError? = nil,
        cancelAfterCommit: Bool = false,
        cancelAfterIdentityOf: URL? = nil,
        cancelAfterTrashOf: URL? = nil,
        caseInsensitivePaths: Bool = false
    ) {
        self.existingURLs = existingURLs
        self.existsResponses = existsResponses
        self.failures = failures
        self.volumeIdentifiers = volumeIdentifiers
        self.byteSizes = byteSizes
        self.availableCapacities = availableCapacities
        self.injectedCopyError = injectedCopyError
        self.cancelAfterCopy = cancelAfterCopy
        self.recordsExistenceChecks = recordsExistenceChecks
        var initialIdentities = identities
        for url in existingURLs where initialIdentities[url] == nil {
            initialIdentities[url] = FileIdentity(
                entryIdentifier: "recording:\(url.path)",
                resolvedIdentifier: "recording:\(url.path)"
            )
        }
        self.identities = initialIdentities
        self.copyErrorAfterCreatingPartial = copyErrorAfterCreatingPartial
        self.sourceRemovalErrorAfterSideEffect = sourceRemovalErrorAfterSideEffect
        self.replacementSourceIdentityBeforeRemoval = replacementSourceIdentityBeforeRemoval
        self.losesSourceIdentityBeforeRemoval = losesSourceIdentityBeforeRemoval
        self.replacementStagingIdentityAfterPartialCopy = replacementStagingIdentityAfterPartialCopy
        self.replacementStagingIdentityAfterSuccessfulCopy = replacementStagingIdentityAfterSuccessfulCopy
        self.stagingCleanupError = stagingCleanupError
        self.copyErrorsBySource = copyErrorsBySource
        self.cancelFirstStagingReservation = cancelFirstStagingReservation
        self.hidesCommittedDestinationIdentity = hidesCommittedDestinationIdentity
        self.mutatesSourcesAfterCopy = mutatesSourcesAfterCopy
        self.mutatesSourcesAfterCommit = mutatesSourcesAfterCommit
        self.cancelOnFingerprintCall = cancelOnFingerprintCall
        self.stagingReservationIdentityError = stagingReservationIdentityError
        self.cancelAfterCommit = cancelAfterCommit
        self.cancelAfterIdentityOf = cancelAfterIdentityOf
        self.cancelAfterTrashOf = cancelAfterTrashOf
        self.caseInsensitivePaths = caseInsensitivePaths
    }

    func exists(_ url: URL) async -> Bool {
        if recordsExistenceChecks {
            events.append("exists:\(url.path)")
        }
        if let response = existsResponses[url] { return response }
        if caseInsensitivePaths {
            return existingURLs.contains { $0.path.compare(url.path, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        }
        return existingURLs.contains(url)
    }

    func createDirectory(_ url: URL) async throws {
        let operation = Operation.createDirectory(url)
        try record(operation)
        if cancelFirstStagingReservation,
           !didCancelStagingReservation,
           url.lastPathComponent.hasPrefix(".bloom-staging-") {
            didCancelStagingReservation = true
            withUnsafeCurrentTask { $0?.cancel() }
            throw CocoaError(.fileWriteFileExists)
        }
        existingURLs.insert(url)
        identities[url] = makeIdentity()
    }

    func copyAndCaptureIdentity(_ source: URL, to destination: URL) async throws -> FileIdentity {
        let operation = Operation.copy(source, destination)
        try record(operation)
        if let error = copyErrorsBySource[source] {
            throw error
        }
        if let injectedCopyError {
            throw injectedCopyError
        }
        existingURLs.insert(destination)
        let copiedIdentity = makeIdentity()
        identities[destination] = copiedIdentity
        copiedDestinations.append(destination)
        if let copyErrorAfterCreatingPartial {
            if let replacementStagingIdentityAfterPartialCopy {
                identities[destination] = replacementStagingIdentityAfterPartialCopy
            }
            throw copyErrorAfterCreatingPartial
        }
        if mutatesSourcesAfterCopy.contains(source) {
            fingerprintVersions[source, default: 0] += 1
        }
        if let replacementStagingIdentityAfterSuccessfulCopy {
            identities[destination] = replacementStagingIdentityAfterSuccessfulCopy
        }
        if cancelAfterCopy {
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
        }
        return copiedIdentity
    }

    func move(_ source: URL, to destination: URL) async throws {
        let operation = Operation.move(source, destination)
        try record(operation)
        let identity = identities.removeValue(forKey: source)
        existingURLs.remove(source)
        existingURLs.insert(destination)
        identities[destination] = identity ?? makeIdentity()
    }

    func remove(_ url: URL) async throws {
        let operation = Operation.remove(url)
        try record(operation)
        existingURLs.remove(url)
        identities.removeValue(forKey: url)
        removedURLs.append(url)
    }

    func replace(_ destination: URL, with stagedItem: URL) async throws {
        let operation = Operation.replace(destination, stagedItem)
        try record(operation)
        let stagedIdentity = identities.removeValue(forKey: stagedItem)
        existingURLs.remove(stagedItem)
        existingURLs.insert(destination)
        identities[destination] = stagedIdentity ?? makeIdentity()
    }

    func trash(_ url: URL) async throws {
        let operation = Operation.trash(url)
        try record(operation)
        existingURLs.remove(url)
        identities.removeValue(forKey: url)
        if cancelAfterTrashOf == url {
            withUnsafeCurrentTask { $0?.cancel() }
        }
    }

    func trash(_ url: URL, identifiedBy identity: FileIdentity) async throws {
        try record(.checkedTrash(url, identity))
        guard identities[url] == identity else {
            throw FileSystemAccessError.identityMismatch(url)
        }
        existingURLs.remove(url)
        identities.removeValue(forKey: url)
        if cancelAfterTrashOf == url {
            withUnsafeCurrentTask { $0?.cancel() }
        }
    }

    func replaceIdentity(at url: URL, with identity: FileIdentity) {
        existingURLs.insert(url)
        identities[url] = identity
    }

    func names(in directory: URL) async throws -> Set<String> {
        let operation = Operation.names(directory)
        try record(operation)
        return Set(existingURLs.compactMap { url in
            url.deletingLastPathComponent().path == directory.path ? url.lastPathComponent : nil
        })
    }

    func volumeIdentifier(for url: URL) async throws -> String {
        let operation = Operation.volumeIdentifier(url)
        try record(operation)
        return volumeIdentifiers[url] ?? "recording-volume"
    }

    func byteSize(of url: URL) async throws -> Int64? {
        let operation = Operation.byteSize(url)
        try record(operation)
        return byteSizes[url]
    }

    func availableCapacity(at url: URL) async throws -> Int64? {
        let operation = Operation.availableCapacity(url)
        try record(operation)
        return availableCapacities[url]
    }

    func prepareDirectoryHierarchy(
        root: URL,
        identifiedBy rootIdentity: FileIdentity,
        relativeComponents: [String]
    ) async throws -> PreparedDirectoryHierarchy {
        try record(.prepareHierarchy(root, rootIdentity, relativeComponents))
        try relativeComponents.forEach(FilenameValidator.validate)
        guard identities[root] == rootIdentity else {
            throw FileSystemAccessError.identityMismatch(root)
        }
        var created: [PreparedDirectoryHierarchy.OwnedDirectory] = []
        var current = root
        for (index, component) in relativeComponents.enumerated() {
            current = current.appending(path: component, directoryHint: .isDirectory)
            if existingURLs.contains(current) {
                guard identities[current] != nil else {
                    throw FileSystemAccessError.identityMismatch(current)
                }
                continue
            }
            existingURLs.insert(current)
            let identity = makeIdentity()
            identities[current] = identity
            created.append(.init(
                relativeComponents: Array(relativeComponents.prefix(index + 1)),
                identity: identity
            ))
        }
        return PreparedDirectoryHierarchy(
            destinationDirectory: current,
            createdDirectories: created
        )
    }

    func removeEmptyOwnedDirectories(
        root: URL,
        identifiedBy rootIdentity: FileIdentity,
        directories: [PreparedDirectoryHierarchy.OwnedDirectory]
    ) async throws {
        try record(.removeOwnedDirectories(
            root,
            rootIdentity,
            directories.map(\.relativeComponents)
        ))
        guard identities[root] == rootIdentity else {
            throw FileSystemAccessError.identityMismatch(root)
        }
        for directory in directories.sorted(by: {
            $0.relativeComponents.count > $1.relativeComponents.count
        }) {
            let url = directory.relativeComponents.reduce(root) {
                $0.appending(path: $1, directoryHint: .isDirectory)
            }
            guard identities[url] == directory.identity else {
                throw FileSystemAccessError.identityMismatch(url)
            }
            let prefix = url.path + "/"
            guard !existingURLs.contains(where: { $0.path.hasPrefix(prefix) }) else { continue }
            existingURLs.remove(url)
            identities.removeValue(forKey: url)
            removedURLs.append(url)
        }
    }

    func identity(of url: URL) async throws -> FileIdentity? {
        try record(.identity(url))
        if url.lastPathComponent.hasPrefix(".bloom-staging-"),
           let stagingReservationIdentityError {
            throw stagingReservationIdentityError
        }
        if hidesCommittedDestinationIdentity, committedDestinations.contains(url) {
            return nil
        }
        let identity: FileIdentity?
        if caseInsensitivePaths {
            identity = identities.first(where: {
                $0.key.path.compare(url.path, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            })?.value
        } else {
            identity = identities[url]
        }
        if cancelAfterIdentityOf == url {
            withUnsafeCurrentTask { $0?.cancel() }
        }
        return identity
    }

    func move(_ source: URL, identifiedBy identity: FileIdentity, to destination: URL) async throws {
        try record(.checkedMove(source, identity, destination))
        guard identities[source] == identity else {
            throw FileSystemAccessError.identityMismatch(source)
        }
        let movedIdentity = identities.removeValue(forKey: source)
        existingURLs.remove(source)
        existingURLs.insert(destination)
        identities[destination] = movedIdentity
        if source.path.contains("/.bloom-staging-") {
            committedDestinations.insert(destination)
            for sourceToMutate in mutatesSourcesAfterCommit {
                fingerprintVersions[sourceToMutate, default: 0] += 1
            }
            if cancelAfterCommit {
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
    }

    func remove(_ url: URL, identifiedBy identity: FileIdentity) async throws {
        try record(.checkedRemove(url, identity))
        let isStagingPath = url.path.contains("/.bloom-staging-")

        if !isStagingPath, losesSourceIdentityBeforeRemoval {
            identities.removeValue(forKey: url)
            existingURLs.remove(url)
            losesSourceIdentityBeforeRemoval = false
        } else if !isStagingPath, let replacement = replacementSourceIdentityBeforeRemoval {
            identities[url] = replacement
            existingURLs.insert(url)
            replacementSourceIdentityBeforeRemoval = nil
        }

        guard identities[url] == identity else {
            throw FileSystemAccessError.identityMismatch(url)
        }
        if isStagingPath, let stagingCleanupError {
            throw stagingCleanupError
        }

        existingURLs = Set(existingURLs.filter { candidate in
            candidate != url && !candidate.path.hasPrefix(url.path + "/")
        })
        identities = identities.filter { candidate, _ in
            candidate != url && !candidate.path.hasPrefix(url.path + "/")
        }
        removedURLs.append(url)

        if !isStagingPath, let sourceRemovalErrorAfterSideEffect {
            throw sourceRemovalErrorAfterSideEffect
        }
    }

    func replace(
        _ destination: URL,
        identifiedBy destinationIdentity: FileIdentity,
        with stagedItem: URL,
        identifiedBy stagedIdentity: FileIdentity
    ) async throws {
        try record(.checkedReplace(destination, destinationIdentity, stagedItem, stagedIdentity))
        guard identities[destination] == destinationIdentity else {
            throw FileSystemAccessError.identityMismatch(destination)
        }
        guard identities[stagedItem] == stagedIdentity else {
            throw FileSystemAccessError.identityMismatch(stagedItem)
        }
        let movedIdentity = identities.removeValue(forKey: stagedItem)
        existingURLs.remove(stagedItem)
        existingURLs.insert(destination)
        identities[destination] = movedIdentity
        committedDestinations.insert(destination)
        if cancelAfterCommit {
            withUnsafeCurrentTask { $0?.cancel() }
        }
    }

    func reserveStagingDirectory(beside destination: URL) async throws -> StagingReservation {
        while true {
            try Task.checkCancellation()
            let directory = destination
                .deletingLastPathComponent()
                .appending(path: ".bloom-staging-\(UUID().uuidString)", directoryHint: .isDirectory)
            let operation = Operation.createDirectory(directory)
            try record(operation)
            if cancelFirstStagingReservation, !didCancelStagingReservation {
                didCancelStagingReservation = true
                withUnsafeCurrentTask { $0?.cancel() }
                continue
            }

            existingURLs.insert(directory)
            let directoryIdentity = makeIdentity()
            identities[directory] = directoryIdentity
            events.append("identity:\(directory.path)")
            if let stagingReservationIdentityError {
                existingURLs.remove(directory)
                identities.removeValue(forKey: directory)
                events.append("rmdir:\(directory.path)")
                throw stagingReservationIdentityError
            }
            return StagingReservation(
                directory: directory,
                directoryIdentity: directoryIdentity,
                item: directory.appending(path: "payload")
            )
        }
    }

    func fingerprint(of source: URL) async throws -> SourceFingerprint {
        try record(.fingerprint(source))
        fingerprintCallCount += 1
        if fingerprintCallCount == cancelOnFingerprintCall {
            withUnsafeCurrentTask { $0?.cancel() }
        }
        let prefix = source.path.hasSuffix("/") ? source.path : source.path + "/"
        let members = existingURLs
            .filter { $0 == source || $0.path.hasPrefix(prefix) }
            .sorted { $0.path < $1.path }
        return SourceFingerprint(
            entries: members.map { member in
                let relativePath = member == source
                    ? "."
                    : String(member.path.dropFirst(prefix.count))
                return SourceFingerprint.Entry(
                    relativePath: relativePath,
                    device: 1,
                    inode: UInt64(bitPattern: Int64(member.path.hashValue)),
                    mode: member.hasDirectoryPath ? UInt32(S_IFDIR) : UInt32(S_IFREG),
                    size: Int64(fingerprintVersions[source, default: 0]),
                    modificationSeconds: Int64(fingerprintVersions[source, default: 0]),
                    modificationNanoseconds: 0,
                    changeSeconds: Int64(fingerprintVersions[source, default: 0]),
                    changeNanoseconds: 0
                )
            }
        )
    }

    func removeStagingDirectory(_ reservation: StagingReservation) async throws {
        try record(.removeStaging(reservation.directory, reservation.directoryIdentity))
        guard identities[reservation.directory] == reservation.directoryIdentity else {
            throw FileSystemAccessError.identityMismatch(reservation.directory)
        }
        let prefix = reservation.directory.path + "/"
        guard existingURLs.contains(where: { $0.path.hasPrefix(prefix) }) == false else {
            throw CocoaError(.fileWriteUnknown)
        }
        existingURLs.remove(reservation.directory)
        identities.removeValue(forKey: reservation.directory)
        removedURLs.append(reservation.directory)
    }

    private func record(_ operation: Operation) throws {
        events.append(operation.event)
        if let failure = failures[operation] {
            throw failure
        }
    }

    private func makeIdentity() -> FileIdentity {
        nextIdentity += 1
        return FileIdentity(
            entryIdentifier: "generated:\(nextIdentity)",
            resolvedIdentifier: "generated:\(nextIdentity)"
        )
    }
}
