import Darwin
import Foundation

protocol FolderSynchronizationScopedAccessLease: Sendable {
    func finish()
}

protocol FolderSynchronizationScopedAccessing: Sendable {
    func acquireAccess(for roots: [URL]) throws -> [any FolderSynchronizationScopedAccessLease]
}

private struct CloudFolderSynchronizationScopedAccess: FolderSynchronizationScopedAccessing {
    let coordinator: CloudLocationScopedAccessCoordinator

    init(coordinator: CloudLocationScopedAccessCoordinator) {
        self.coordinator = coordinator
    }

    func acquireAccess(for roots: [URL]) throws -> [any FolderSynchronizationScopedAccessLease] {
        try coordinator.acquireAccess(for: roots).map(CloudFolderSynchronizationLease.init)
    }
}

private final class CloudFolderSynchronizationLease: FolderSynchronizationScopedAccessLease, @unchecked Sendable {
    private let lease: CloudLocationScopedAccessLease

    init(_ lease: CloudLocationScopedAccessLease) { self.lease = lease }

    func finish() { lease.finish() }
}

struct FolderSynchronizationRootEvidence: Sendable, Equatable {
    let identity: FileIdentity
    /// This URL is descriptor-derived and retained solely for later authority revalidation.
    let canonicalURL: URL
    let volumeIdentifier: String
    /// Descriptor-derived mount instance. A same-volume relationship through different
    /// mounts is ambiguous without stronger backing-store ancestry evidence.
    let mountIdentifier: String
}

struct FolderSynchronizationRootAuthority: Sendable, Equatable {
    let source: FolderSynchronizationRootEvidence
    let destination: FolderSynchronizationRootEvidence
}

/// Implementations must derive canonical paths from an open, no-follow descriptor.
/// Preparation deliberately fails closed for a file-system implementation that cannot
/// supply this proof; standardized or symlink-resolved path strings are not authority.
protocol FolderSynchronizationRootAuthorityProviding: FileSystemAccess {
    func captureFolderSynchronizationRootAuthority(
        at url: URL,
        expectedIdentity: FileIdentity
    ) async throws -> FolderSynchronizationRootEvidence
}

enum FolderSynchronizationPreparationRoot: Sendable, Equatable {
    case source
    case destination
}

enum FolderSynchronizationPreparationError: LocalizedError, Sendable, Equatable {
    case scopedAccessDenied
    case rootAuthorityUnavailable
    case rootUnavailable(FolderSynchronizationPreparationRoot)
    case rootChanged(FolderSynchronizationPreparationRoot)
    case unsafeRootRelationship
    case sourceChanged(ComparisonRelativePath)
    case destinationChanged(ComparisonRelativePath)
    case expectedDestinationAbsenceOccupied(ComparisonRelativePath)
    case destinationFilenamePolicyUnavailable
    case destinationFilenamePolicyChanged
    case destinationCapacityUnavailable
    case insufficientDestinationCapacity(required: Int64, available: Int64)
    case itemUnavailable

    var errorDescription: String? {
        switch self {
        case .scopedAccessDenied:
            "The selected folders are not currently accessible."
        case .rootAuthorityUnavailable:
            "Folder relationship safety could not be verified."
        case .rootUnavailable:
            "A selected folder is no longer available."
        case .rootChanged:
            "A selected folder changed while the review was being prepared."
        case .unsafeRootRelationship:
            "The selected folders overlap through a canonical, alias, mount, or symbolic-link path."
        case let .sourceChanged(path):
            "\(path.string) changed while the review was being prepared."
        case let .destinationChanged(path):
            "\(path.string) changed while the review was being prepared."
        case let .expectedDestinationAbsenceOccupied(path):
            "\(path.string) appeared in the destination while the review was being prepared."
        case .destinationFilenamePolicyUnavailable:
            "Destination filename comparison safety could not be verified."
        case .destinationFilenamePolicyChanged:
            "Destination filename comparison behavior changed while the review was being prepared."
        case .destinationCapacityUnavailable:
            "Destination capacity could not be verified."
        case let .insufficientDestinationCapacity(required, available):
            "The destination has \(available) bytes available but \(required) bytes are required."
        case .itemUnavailable:
            "An item is not immediately available."
        }
    }
}

struct PreparedFolderSynchronizationPlan: Sendable, Equatable {
    let draft: FolderSynchronizationPlanDraft
    let sourceFingerprints: [ComparisonRelativePath: SourceFingerprint]
    let destinationFingerprints: [ComparisonRelativePath: SourceFingerprint]
    let expectedAbsentDestinations: Set<ComparisonRelativePath>
    let requiredCapacityBytes: Int64
    let destinationFilenameComparisonPolicy: FilenameComparisonPolicy
    let rootAuthority: FolderSynchronizationRootAuthority
    /// Identity of each existing destination parent that will receive a staging or
    /// exclusive publication.  Root identity alone cannot authorize a replaced
    /// intermediate directory.
    let destinationParentIdentities: [ComparisonRelativePath: FileIdentity]

    init(
        draft: FolderSynchronizationPlanDraft,
        sourceFingerprints: [ComparisonRelativePath: SourceFingerprint],
        destinationFingerprints: [ComparisonRelativePath: SourceFingerprint],
        expectedAbsentDestinations: Set<ComparisonRelativePath>,
        requiredCapacityBytes: Int64,
        destinationFilenameComparisonPolicy: FilenameComparisonPolicy,
        rootAuthority: FolderSynchronizationRootAuthority,
        destinationParentIdentities: [ComparisonRelativePath: FileIdentity] = [:]
    ) {
        self.draft = draft
        self.sourceFingerprints = sourceFingerprints
        self.destinationFingerprints = destinationFingerprints
        self.expectedAbsentDestinations = expectedAbsentDestinations
        self.requiredCapacityBytes = requiredCapacityBytes
        self.destinationFilenameComparisonPolicy = destinationFilenameComparisonPolicy
        self.rootAuthority = rootAuthority
        self.destinationParentIdentities = destinationParentIdentities
    }
}

protocol FolderSynchronizationPreparing: Sendable {
    func prepare(_ draft: FolderSynchronizationPlanDraft) async throws -> PreparedFolderSynchronizationPlan
}

actor FolderSynchronizationPreparationService: FolderSynchronizationPreparing {
    private let fileSystem: any FileSystemAccess
    private let scopedAccess: any FolderSynchronizationScopedAccessing
    private let availabilityReader: any CloudItemAvailabilityReading

    init(
        fileSystem: any FileSystemAccess = LiveFileSystemAccess(),
        scopedAccess: any FolderSynchronizationScopedAccessing = CloudFolderSynchronizationScopedAccess(
            coordinator: .init()
        ),
        availabilityReader: any CloudItemAvailabilityReading = LiveCloudItemAvailabilityService()
    ) {
        self.fileSystem = fileSystem
        self.scopedAccess = scopedAccess
        self.availabilityReader = availabilityReader
    }

    func prepare(_ draft: FolderSynchronizationPlanDraft) async throws -> PreparedFolderSynchronizationPlan {
        let leases: [any FolderSynchronizationScopedAccessLease]
        do {
            leases = try scopedAccess.acquireAccess(for: [draft.sourceRoot, draft.destinationRoot])
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw FolderSynchronizationPreparationError.scopedAccessDenied
        }
        defer { leases.forEach { $0.finish() } }

        try Task.checkCancellation()
        let initialRoots = try await captureRoots(for: draft)
        try requireDisjointRoots(initialRoots)

        var sourceFingerprints: [ComparisonRelativePath: SourceFingerprint] = [:]
        var destinationFingerprints: [ComparisonRelativePath: SourceFingerprint] = [:]
        var expectedAbsentDestinations = Set<ComparisonRelativePath>()
        var destinationParentIdentities: [ComparisonRelativePath: FileIdentity] = [:]

        for action in draft.actions {
            try Task.checkCancellation()
            switch action.kind {
            case .copy:
                guard let source = action.source else { throw FolderSynchronizationPreparationError.itemUnavailable }
                let fingerprint = try await captureSource(source, relativePath: action.relativePath)
                sourceFingerprints[action.relativePath] = fingerprint
                try await requireAbsentDestination(at: action.relativePath, in: draft)
                expectedAbsentDestinations.insert(action.relativePath)
            case .replace:
                guard let source = action.source, let destination = action.destination else {
                    throw FolderSynchronizationPreparationError.itemUnavailable
                }
                sourceFingerprints[action.relativePath] = try await captureSource(
                    source,
                    relativePath: action.relativePath
                )
                destinationFingerprints[action.relativePath] = try await captureDestination(
                    destination,
                    relativePath: action.relativePath
                )
            case .moveDestinationToTrash:
                guard let destination = action.destination else {
                    throw FolderSynchronizationPreparationError.itemUnavailable
                }
                destinationFingerprints[action.relativePath] = try await captureDestination(
                    destination,
                    relativePath: action.relativePath
                )
            }
        }

        // Every mutation, including a Trash-only quarantine and its possible
        // restoration, is parent-namespace sensitive.
        for action in draft.actions {
            let destination = draft.destinationRoot.appending(path: action.relativePath.string)
            let parent = destination.deletingLastPathComponent().standardizedFileURL
            guard let identity = try await fileSystem.identity(of: parent) else {
                throw FolderSynchronizationPreparationError.destinationChanged(action.relativePath)
            }
            destinationParentIdentities[action.relativePath] = identity
        }

        let initialFilenamePolicy = try await captureDestinationFilenamePolicy(in: draft)

        for (path, captured) in sourceFingerprints {
            guard let action = draft.actions.first(where: { $0.relativePath == path }), let source = action.source,
                  try await captureSource(source, relativePath: path) == captured else {
                throw FolderSynchronizationPreparationError.sourceChanged(path)
            }
        }
        for (path, captured) in destinationFingerprints {
            guard let action = draft.actions.first(where: { $0.relativePath == path }), let destination = action.destination,
                  try await captureDestination(destination, relativePath: path) == captured else {
                throw FolderSynchronizationPreparationError.destinationChanged(path)
            }
        }
        for path in expectedAbsentDestinations {
            try await requireAbsentDestination(at: path, in: draft)
        }

        let requiredCapacityBytes = requiredCopyCapacity(sourceFingerprints.values)
        let availableCapacity: Int64
        do {
            guard let capacity = try await fileSystem.availableCapacity(at: draft.destinationRoot) else {
                throw FolderSynchronizationPreparationError.destinationCapacityUnavailable
            }
            availableCapacity = capacity
        } catch let error as FolderSynchronizationPreparationError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw FolderSynchronizationPreparationError.destinationCapacityUnavailable
        }
        guard availableCapacity >= requiredCapacityBytes else {
            throw FolderSynchronizationPreparationError.insufficientDestinationCapacity(
                required: requiredCapacityBytes,
                available: availableCapacity
            )
        }
        try Task.checkCancellation()

        let finalFilenamePolicy = try await captureDestinationFilenamePolicy(in: draft)
        guard finalFilenamePolicy == initialFilenamePolicy else {
            throw FolderSynchronizationPreparationError.destinationFilenamePolicyChanged
        }

        // This is intentionally the final filesystem evidence capture, after all second
        // fingerprints, availability, absences, filename policy, and capacity evidence.
        let finalRoots = try await captureRoots(for: draft)
        guard finalRoots == initialRoots else {
            if finalRoots.source != initialRoots.source {
                throw FolderSynchronizationPreparationError.rootChanged(.source)
            }
            throw FolderSynchronizationPreparationError.rootChanged(.destination)
        }
        try requireDisjointRoots(finalRoots)

        return PreparedFolderSynchronizationPlan(
            draft: draft,
            sourceFingerprints: sourceFingerprints,
            destinationFingerprints: destinationFingerprints,
            expectedAbsentDestinations: expectedAbsentDestinations,
            requiredCapacityBytes: requiredCapacityBytes,
            destinationFilenameComparisonPolicy: finalFilenamePolicy,
            rootAuthority: finalRoots,
            destinationParentIdentities: destinationParentIdentities
        )
    }

    private func captureRoots(
        for draft: FolderSynchronizationPlanDraft
    ) async throws -> FolderSynchronizationRootAuthority {
        let source = try await captureRoot(
            draft.sourceRoot,
            expectedIdentity: draft.sourceRootIdentity,
            role: .source
        )
        let destination = try await captureRoot(
            draft.destinationRoot,
            expectedIdentity: draft.destinationRootIdentity,
            role: .destination
        )
        return .init(source: source, destination: destination)
    }

    private func captureRoot(
        _ root: URL,
        expectedIdentity: FileIdentity,
        role: FolderSynchronizationPreparationRoot
    ) async throws -> FolderSynchronizationRootEvidence {
        guard let provider = fileSystem as? any FolderSynchronizationRootAuthorityProviding else {
            throw FolderSynchronizationPreparationError.rootAuthorityUnavailable
        }
        do {
            guard try await fileSystem.identity(of: root) == expectedIdentity else {
                if try await fileSystem.identity(of: root) == nil {
                    throw FolderSynchronizationPreparationError.rootUnavailable(role)
                }
                throw FolderSynchronizationPreparationError.rootChanged(role)
            }
            let evidence = try await provider.captureFolderSynchronizationRootAuthority(
                at: root,
                expectedIdentity: expectedIdentity
            )
            guard evidence.identity == expectedIdentity else {
                throw FolderSynchronizationPreparationError.rootChanged(role)
            }
            return evidence
        } catch let error as FolderSynchronizationPreparationError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw FolderSynchronizationPreparationError.rootChanged(role)
        }
    }

    private func requireDisjointRoots(_ roots: FolderSynchronizationRootAuthority) throws {
        guard roots.source.identity != roots.destination.identity,
              !roots.source.identity.refersToSameItem(as: roots.destination.identity),
              !isEqualOrAncestor(roots.source.canonicalURL, roots.destination.canonicalURL) else {
            throw FolderSynchronizationPreparationError.unsafeRootRelationship
        }
        guard roots.source.volumeIdentifier == roots.destination.volumeIdentifier else { return }
        // F_GETPATH proves canonical ancestry only inside one mount instance. Distinct
        // mounts of the same filesystem may be aliases of an overlapping backing tree.
        guard roots.source.mountIdentifier == roots.destination.mountIdentifier,
              !isEqualOrAncestor(roots.source.canonicalURL, roots.destination.canonicalURL) else {
            throw FolderSynchronizationPreparationError.unsafeRootRelationship
        }
    }

    private func captureSource(
        _ source: ComparisonEntry,
        relativePath: ComparisonRelativePath
    ) async throws -> SourceFingerprint {
        guard try await fileSystem.identity(of: source.url) == source.fingerprint.identity else {
            throw FolderSynchronizationPreparationError.sourceChanged(relativePath)
        }
        let fingerprint: SourceFingerprint
        do {
            fingerprint = try await fileSystem.fingerprint(of: source.url)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw FolderSynchronizationPreparationError.itemUnavailable
        }
        guard fingerprintMatchesComparisonEntry(fingerprint, source) else {
            throw FolderSynchronizationPreparationError.sourceChanged(relativePath)
        }
        try await requireLocallyAvailableFingerprintEntries(fingerprint, under: source.url)
        return fingerprint
    }

    private func captureDestination(
        _ destination: ComparisonEntry,
        relativePath: ComparisonRelativePath
    ) async throws -> SourceFingerprint {
        guard try await fileSystem.identity(of: destination.url) == destination.fingerprint.identity else {
            throw FolderSynchronizationPreparationError.destinationChanged(relativePath)
        }
        let fingerprint: SourceFingerprint
        do {
            fingerprint = try await fileSystem.fingerprint(of: destination.url)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw FolderSynchronizationPreparationError.itemUnavailable
        }
        guard fingerprintMatchesComparisonEntry(fingerprint, destination) else {
            throw FolderSynchronizationPreparationError.destinationChanged(relativePath)
        }
        return fingerprint
    }

    private func requireAbsentDestination(
        at relativePath: ComparisonRelativePath,
        in draft: FolderSynchronizationPlanDraft
    ) async throws {
        let destination = draft.destinationRoot.appending(path: relativePath.string)
        guard await !fileSystem.exists(destination) else {
            throw FolderSynchronizationPreparationError.expectedDestinationAbsenceOccupied(relativePath)
        }
    }

    private func captureDestinationFilenamePolicy(
        in draft: FolderSynchronizationPlanDraft
    ) async throws -> FilenameComparisonPolicy {
        do {
            return try await fileSystem.filenameComparisonPolicy(in: draft.destinationRoot)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw FolderSynchronizationPreparationError.destinationFilenamePolicyUnavailable
        }
    }

    private func requireLocallyAvailableFingerprintEntries(
        _ fingerprint: SourceFingerprint,
        under source: URL
    ) async throws {
        for entry in fingerprint.entries {
            try Task.checkCancellation()
            let entryURL = try fingerprintEntryURL(entry.relativePath, under: source)
            guard await availabilityReader.availability(of: entryURL) == .availableLocally else {
                throw FolderSynchronizationPreparationError.itemUnavailable
            }
        }
    }

    private func fingerprintEntryURL(_ relativePath: String, under source: URL) throws -> URL {
        if relativePath == "." { return source }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") })
        else {
            throw FolderSynchronizationPreparationError.itemUnavailable
        }
        let relative = try ComparisonRelativePath(components: components)
        let candidate = source.appending(path: relative.string).standardizedFileURL
        let sourceComponents = source.standardizedFileURL.pathComponents
        guard candidate.pathComponents.count > sourceComponents.count,
              candidate.pathComponents.prefix(sourceComponents.count).elementsEqual(sourceComponents)
        else {
            throw FolderSynchronizationPreparationError.itemUnavailable
        }
        return candidate
    }

    private func fingerprintMatchesComparisonEntry(
        _ fingerprint: SourceFingerprint,
        _ entry: ComparisonEntry
    ) -> Bool {
        guard let root = fingerprint.entries.first(where: { $0.relativePath == "." }) else {
            return false
        }
        if let expectedBytes = entry.fingerprint.byteSize, root.size != expectedBytes {
            return false
        }
        if let expectedRawModifiedAt = entry.fingerprint.rawModifiedAt {
            if root.modificationSeconds != expectedRawModifiedAt.seconds
                || root.modificationNanoseconds != expectedRawModifiedAt.nanoseconds {
                return false
            }
        } else if let expectedModifiedAt = entry.fingerprint.modifiedAt,
                  root.modificationSeconds != Int64(expectedModifiedAt.timeIntervalSince1970) {
            return false
        }
        return true
    }

    private func requiredCopyCapacity(_ fingerprints: Dictionary<ComparisonRelativePath, SourceFingerprint>.Values) -> Int64 {
        fingerprints.reduce(into: Int64(0)) { total, fingerprint in
            for entry in fingerprint.entries where entry.mode & UInt32(S_IFMT) == UInt32(S_IFREG) {
                let size = max(0, entry.size)
                total = total > Int64.max - size ? Int64.max : total + size
            }
        }
    }

    private func isEqualOrAncestor(_ first: URL, _ second: URL) -> Bool {
        let firstComponents = first.standardizedFileURL.pathComponents
        let secondComponents = second.standardizedFileURL.pathComponents
        return firstComponents == secondComponents
            || isStrictPrefix(firstComponents, of: secondComponents)
            || isStrictPrefix(secondComponents, of: firstComponents)
    }

    private func isStrictPrefix(_ prefix: [String], of value: [String]) -> Bool {
        prefix.count < value.count && zip(prefix, value).allSatisfy(==)
    }
}

extension LiveFileSystemAccess: FolderSynchronizationRootAuthorityProviding {
    func captureFolderSynchronizationRootAuthority(
        at url: URL,
        expectedIdentity: FileIdentity
    ) async throws -> FolderSynchronizationRootEvidence {
        let item = try await openItem(url, kind: .directory, identifiedBy: expectedIdentity)
        defer { item.close() }
        guard item.identity == expectedIdentity else {
            throw FileSystemAccessError.identityMismatch(url)
        }
        let descriptorEvidence = try item.withUnsafeDescriptor { descriptor -> (URL, String) in
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            guard Darwin.fcntl(descriptor, F_GETPATH, &buffer) != -1 else {
                throw POSIXError(.init(rawValue: errno) ?? .EINVAL)
            }
            let path = String(
                decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
                as: UTF8.self
            )
            var filesystem = statfs()
            guard Darwin.fstatfs(descriptor, &filesystem) == 0 else {
                throw POSIXError(.init(rawValue: errno) ?? .EINVAL)
            }
            let mountPath = withUnsafeBytes(of: &filesystem.f_mntonname) { bytes in
                String(
                    decoding: bytes.bindMemory(to: CChar.self).prefix { $0 != 0 }.map {
                        UInt8(bitPattern: $0)
                    },
                    as: UTF8.self
                )
            }
            return (URL(fileURLWithPath: path).standardizedFileURL, mountPath)
        }
        let volumeIdentifier = try volumeIdentifier(for: descriptorEvidence.0)
        return FolderSynchronizationRootEvidence(
            identity: item.identity,
            canonicalURL: descriptorEvidence.0,
            volumeIdentifier: volumeIdentifier,
            mountIdentifier: "\(volumeIdentifier):\(descriptorEvidence.1)"
        )
    }
}
