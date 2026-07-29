import Darwin
import Foundation
import Testing
@testable import BloomFileManager

@Suite struct StorageScanServiceTests {
    @MainActor
    @Test func locationPolicyBindsIdentityClassificationAndAuthorizationIntoAdmission() async throws {
        let fixture = try StorageScanFixture()
        let store = fixture.emptyCloudStore()
        try await store.scanInitially()
        let policy = LiveStorageScanLocationPolicy(
            cloudLocations: store,
            volumeClassification: { _ in .local }
        )

        let admission = try #require(policy.decision(for: fixture.root).admission)
        let expectedIdentity = await fixture.listing.identity(of: fixture.root)

        #expect(admission.root == fixture.root.standardizedFileURL)
        #expect(admission.rootIdentity == expectedIdentity)
        #expect(admission.rootKind == .directory)
        #expect(admission.volumeClassification == .local)
        #expect(!admission.authorization.isProtectedLocation)
        #expect(admission.authorization.cleanupAuthorized)
    }

    @MainActor
    @Test func locationPolicyRejectsKnownCloudRootsAndRequiresProtectedAcknowledgement() async throws {
        let fixture = try StorageScanFixture()
        let cloudRoot = fixture.directory("Cloud")
        try FileManager.default.createDirectory(
            at: cloudRoot,
            withIntermediateDirectories: false
        )
        let cloudStore = try await fixture.cloudStore(root: cloudRoot)
        let policy = LiveStorageScanLocationPolicy(cloudLocations: cloudStore)

        #expect(policy.decision(for: cloudRoot).isRejected)
        #expect(policy.decision(for: URL(filePath: "/System")).isProtected)
    }

    @MainActor
    @Test func locationPolicyRejectsFilesPackagesAndMissingRootsButAllowsLocalDirectories() async throws {
        let fixture = try StorageScanFixture()
        let store = fixture.emptyCloudStore()
        try await store.scanInitially()
        let policy = LiveStorageScanLocationPolicy(
            cloudLocations: store,
            volumeClassification: { _ in .local }
        )
        let file = try fixture.file("note.txt", contents: "note")
        let package = fixture.directory("Demo.app")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)

        #expect(policy.decision(for: file).isRejected)
        #expect(policy.decision(for: package).isRejected)
        #expect(policy.decision(for: fixture.root.appending(path: "missing")).isRejected)
        #expect(policy.decision(for: fixture.root).admission != nil)
    }

    @MainActor
    @Test func locationPolicyFailsClosedWhileInitialCloudDiscoveryIsPending() throws {
        let fixture = try StorageScanFixture()
        let policy = LiveStorageScanLocationPolicy(
            cloudLocations: fixture.emptyCloudStore(),
            volumeClassification: { _ in .local }
        )

        #expect(policy.decision(for: fixture.root).isRejected)
    }

    @MainActor
    @Test func locationPolicyRejectsNetworkMountedRootsAfterDiscovery() async throws {
        let fixture = try StorageScanFixture()
        let store = fixture.emptyCloudStore()
        try await store.scanInitially()
        let policy = LiveStorageScanLocationPolicy(
            cloudLocations: store,
            volumeClassification: { _ in .network }
        )

        #expect(policy.decision(for: fixture.root).isRejected)
    }

    @MainActor
    @Test func locationPolicyRejectsUndiscoveredFileProviderRoots() async throws {
        let fixture = try StorageScanFixture()
        let store = fixture.emptyCloudStore()
        try await store.scanInitially()
        let policy = LiveStorageScanLocationPolicy(
            cloudLocations: store,
            volumeClassification: { _ in .fileProvider }
        )

        #expect(!store.intersectsKnownLocation(fixture.root))
        #expect(policy.decision(for: fixture.root).isRejected)
    }

    @MainActor
    @Test func undiscoveredProviderUnderUserLibraryIsRejectedNotProtected() async throws {
        let fixture = try StorageScanFixture()
        let store = fixture.emptyCloudStore()
        try await store.scanInitially()
        let userLibrary = try #require(FileManager.default.urls(
            for: .libraryDirectory,
            in: .userDomainMask
        ).first)
        let policy = LiveStorageScanLocationPolicy(
            cloudLocations: store,
            volumeClassification: { candidate in
                #expect(candidate == userLibrary.standardizedFileURL)
                return .fileProvider
            }
        )

        #expect(!store.intersectsKnownLocation(userLibrary))
        let decision = policy.decision(for: userLibrary)
        #expect(decision.isRejected)
        #expect(!decision.isProtected)
    }

    @MainActor
    @Test func protectedLocationDetectionIncludesAncestorsOfProtectedRoots() async throws {
        let fixture = try StorageScanFixture()
        let store = fixture.emptyCloudStore()
        try await store.scanInitially()
        let policy = LiveStorageScanLocationPolicy(
            cloudLocations: store,
            volumeClassification: { _ in .local }
        )

        #expect(policy.decision(for: URL(filePath: "/", directoryHint: .isDirectory)).isProtected)
        #expect(policy.decision(
            for: FileManager.default.homeDirectoryForCurrentUser
        ).isProtected)
    }

    @MainActor
    @Test func locationPolicyRejectsSymbolicLinkAliasesToKnownCloudRoots() async throws {
        let fixture = try StorageScanFixture()
        let cloudRoot = fixture.directory("Cloud")
        let alias = fixture.root.appending(path: "Cloud Alias")
        try FileManager.default.createDirectory(
            at: cloudRoot,
            withIntermediateDirectories: false
        )
        try FileManager.default.createSymbolicLink(
            at: alias,
            withDestinationURL: cloudRoot
        )
        let cloudStore = try await fixture.cloudStore(root: cloudRoot)
        let policy = LiveStorageScanLocationPolicy(cloudLocations: cloudStore)

        #expect(policy.decision(for: alias).isRejected)
    }

    @MainActor
    @Test func locationPolicyRejectsNonFileURLsWhosePathsNameLocalDirectories() throws {
        let fixture = try StorageScanFixture()
        var components = URLComponents()
        components.scheme = "https"
        components.host = "example.com"
        components.path = fixture.root.path
        let nonFileURL = try #require(components.url)
        let policy = LiveStorageScanLocationPolicy(
            cloudLocations: fixture.emptyCloudStore()
        )

        #expect(nonFileURL.isFileURL == false)
        #expect(nonFileURL.path == fixture.root.path)
        #expect(policy.decision(for: nonFileURL).isRejected)
    }

    @MainActor
    @Test func locationPolicyRejectsWhenPackageMetadataCannotBeRead() throws {
        let fixture = try StorageScanFixture()
        let policy = LiveStorageScanLocationPolicy(
            cloudLocations: fixture.emptyCloudStore(),
            packageMetadata: { _ in
                throw StorageScanLocationTestError.metadataUnavailable
            }
        )

        #expect(policy.decision(for: fixture.root).isRejected)
    }

    @Test func scannerMapsProgressiveRecordsWithoutFollowingLinksOrPackages() async throws {
        let fixture = try StorageScanFixture.treeWithLinkPackageHiddenAndFailure()
        let service = LiveStorageScanService(listing: fixture.listing)
        let request = StorageScanRequest(
            admission: fixture.admission(),
            options: .init(includeHiddenItems: false)
        )

        let batches = try await service.collect(request)
        let records = batches.flatMap(\.records)
        let listingRequest = try #require(await fixture.listing.requests.first)
        #expect(batches.count > 1)
        #expect(listingRequest.root == fixture.root)
        #expect(listingRequest.seed == nil)
        #expect(listingRequest.subtree == nil)
        #expect(listingRequest.options == ComparisonOptions(
            includeSubfolders: true,
            includeHiddenItems: false
        ))
        #expect(records.containsPackageNamed("Demo.app"))
        #expect(records.containsDescendant(of: "Demo.app") == false)
        #expect(records.containsSymlinkNamed("alias"))
        #expect(records.containsDescendant(of: "alias") == false)
        #expect(records.containsName(".hidden") == false)
        #expect(records.failureCount == 1)
        #expect(records.failureMessages.allSatisfy { !$0.contains("blocked-item") })
        #expect(records.entry(named: "note.txt")?.category == .document)
        #expect(records.entry(named: "Demo.app")?.category == .application)
        #expect(records.entry(named: "note.txt")?.fingerprint == fixture.regularFingerprint)
    }

    @Test func scannerRejectsRootIdentityMismatchBeforeStartingListing() async throws {
        let fixture = try StorageScanFixture.treeWithLinkPackageHiddenAndFailure()
        let service = LiveStorageScanService(listing: fixture.listing)
        let mismatchedIdentity = FileIdentity(
            entryIdentifier: "replacement-entry",
            resolvedIdentifier: "replacement-resolved"
        )
        let request = StorageScanRequest(
            admission: fixture.admission(identity: mismatchedIdentity),
            options: .init()
        )

        await #expect(throws: StorageScanError.admissionInvalid) {
            _ = try await service.collect(request)
        }
        #expect(await fixture.listing.requests.isEmpty)
    }

    @Test func scannerRejectsClassificationSwapAfterAdmissionBeforeListing() async throws {
        let fixture = try StorageScanFixture.treeWithLinkPackageHiddenAndFailure()
        let service = LiveStorageScanService(
            listing: fixture.listing,
            volumeClassification: { _ in .network }
        )
        let request = StorageScanRequest(
            admission: fixture.admission(),
            options: .init()
        )

        await #expect(throws: StorageScanError.admissionInvalid) {
            _ = try await service.collect(request)
        }
        #expect(await fixture.listing.requests.isEmpty)
    }

    @Test func slowConsumerReceivesEveryCriticalBatchThroughBoundedAdapter() async throws {
        let fixture = try StorageScanFixture()
        let batches = try (0 ..< 24).map { index in
            let name = "batch-\(index).bin"
            return ComparisonListingBatch(records: [
                .entry(ComparisonEntry(
                    relativePath: try ComparisonRelativePath(components: [name]),
                    url: fixture.root.appending(path: name),
                    kind: .regularFile,
                    fingerprint: .init(
                        identity: .init(
                            entryIdentifier: "batch-\(index)",
                            resolvedIdentifier: "batch-\(index)"
                        ),
                        byteSize: Int64(index + 1),
                        modifiedAt: nil
                    ),
                    symbolicLinkTarget: nil,
                    typeDescription: "Data"
                ))
            ])
        }
        let listing = StorageScanListingFixture(
            identity: fixture.rootIdentity,
            batches: batches
        )
        let observer = StorageScanBufferRecorder()
        let service = LiveStorageScanService(
            listing: listing,
            bufferCapacity: 3,
            bufferObserver: observer
        )

        var received: [String] = []
        for try await batch in service.batches(for: .init(
            admission: fixture.admission(),
            options: .init()
        )) {
            try await Task.sleep(for: .milliseconds(2))
            received += batch.records.compactMap {
                $0.entry?.relativePath.components.last
            }
        }

        #expect(received == (0 ..< 24).map { "batch-\($0).bin" })
        #expect(await observer.maximumBufferedCount <= 3)
        #expect(await observer.backpressureCount > 0)
    }

    @Test func scannerIdentityDelegatesToTheNoFollowListingIdentity() async throws {
        let fixture = try StorageScanFixture.treeWithLinkPackageHiddenAndFailure()
        let service = LiveStorageScanService(listing: fixture.listing)

        let identity = try await service.identity(of: fixture.root)

        #expect(identity == fixture.rootIdentity)
    }

    @Test func fingerprintReaderUsesExactNoFollowStatFieldsForSymbolicLinks() async throws {
        let fixture = try StorageScanFixture()
        let target = try fixture.file(
            "large-target.bin",
            contents: String(repeating: "x", count: 4_096)
        )
        let link = fixture.root.appending(path: "alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let expected = try lstatForStorageScanTest(link)

        let fingerprint = try await LiveStorageEntryFingerprintReader().fingerprint(of: link)

        #expect(fingerprint.identity.entryIdentifier
            == "\(UInt64(expected.st_dev)):\(UInt64(expected.st_ino))")
        #expect(fingerprint.identity.resolvedIdentifier
            == "\(UInt64(expected.st_dev)):\(UInt64(expected.st_ino))")
        #expect(fingerprint.byteSize == Int64(expected.st_size))
        #expect(fingerprint.rawModifiedAt == ComparisonModificationTimestamp(
            seconds: Int64(expected.st_mtimespec.tv_sec),
            nanoseconds: Int64(expected.st_mtimespec.tv_nsec)
        ))
        #expect(fingerprint.byteSize != Int64(try Data(contentsOf: target).count))
    }
}

private enum StorageScanLocationTestError: Error {
    case metadataUnavailable
}

private extension StorageScanning {
    func collect(_ request: StorageScanRequest) async throws -> [StorageScanBatch] {
        var values: [StorageScanBatch] = []
        for try await batch in batches(for: request) {
            values.append(batch)
        }
        return values
    }
}

private final class StorageScanFixture {
    let temporary: TemporaryDirectory
    let root: URL
    let rootIdentity: FileIdentity
    let listing: StorageScanListingFixture
    let regularFingerprint: ComparisonFingerprint

    init() throws {
        temporary = try TemporaryDirectory()
        root = temporary.url
        rootIdentity = try storageScanTestIdentity(of: root)
        regularFingerprint = ComparisonFingerprint(
            identity: FileIdentity(
                entryIdentifier: "note-entry",
                resolvedIdentifier: "note-resolved"
            ),
            byteSize: 4,
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            rawModifiedAt: .init(seconds: 1_700_000_000, nanoseconds: 123_456_789)
        )
        listing = StorageScanListingFixture(identity: rootIdentity, batches: [])
    }

    private init(
        temporary: TemporaryDirectory,
        rootIdentity: FileIdentity,
        listing: StorageScanListingFixture,
        regularFingerprint: ComparisonFingerprint
    ) {
        self.temporary = temporary
        root = temporary.url
        self.rootIdentity = rootIdentity
        self.listing = listing
        self.regularFingerprint = regularFingerprint
    }

    deinit {
        temporary.remove()
    }

    static func treeWithLinkPackageHiddenAndFailure() throws -> StorageScanFixture {
        let temporary = try TemporaryDirectory()
        let root = temporary.url
        let note = root.appending(path: "note.txt")
        let package = root.appending(path: "Demo.app", directoryHint: .isDirectory)
        let packageChild = package.appending(path: "Contents/private.txt")
        let target = root.appending(path: "target", directoryHint: .isDirectory)
        let alias = root.appending(path: "alias")
        let hidden = root.appending(path: ".hidden")
        try Data("note".utf8).write(to: note)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(
            at: packageChild.deletingLastPathComponent(),
            withIntermediateDirectories: false
        )
        try Data("private".utf8).write(to: packageChild)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try Data("linked".utf8).write(to: target.appending(path: "linked.txt"))
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        try Data("hidden".utf8).write(to: hidden)

        let rootIdentity = try storageScanTestIdentity(of: root)
        let regularFingerprint = ComparisonFingerprint(
            identity: FileIdentity(
                entryIdentifier: "note-entry",
                resolvedIdentifier: "note-resolved"
            ),
            byteSize: 4,
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            rawModifiedAt: .init(seconds: 1_700_000_000, nanoseconds: 123_456_789)
        )
        let packageFingerprint = ComparisonFingerprint(
            identity: FileIdentity(
                entryIdentifier: "package-entry",
                resolvedIdentifier: "package-resolved"
            ),
            byteSize: nil,
            modifiedAt: nil
        )
        let linkFingerprint = ComparisonFingerprint(
            identity: FileIdentity(
                entryIdentifier: "link-entry",
                resolvedIdentifier: "link-resolved"
            ),
            byteSize: nil,
            modifiedAt: nil
        )
        let hiddenFingerprint = ComparisonFingerprint(
            identity: FileIdentity(
                entryIdentifier: "hidden-entry",
                resolvedIdentifier: "hidden-resolved"
            ),
            byteSize: 6,
            modifiedAt: nil
        )
        let batches = [
            ComparisonListingBatch(records: [
                .entry(try comparisonEntry(
                    path: ["note.txt"],
                    url: note,
                    kind: .regularFile,
                    fingerprint: regularFingerprint,
                    typeDescription: "Plain Text"
                )),
                .entry(try comparisonEntry(
                    path: ["Demo.app"],
                    url: package,
                    kind: .package,
                    fingerprint: packageFingerprint,
                    typeDescription: "Application"
                ))
            ]),
            ComparisonListingBatch(records: [
                .entry(try comparisonEntry(
                    path: ["alias"],
                    url: alias,
                    kind: .symbolicLink,
                    fingerprint: linkFingerprint,
                    typeDescription: "Symbolic Link"
                )),
                .entry(try comparisonEntry(
                    path: [".hidden"],
                    url: hidden,
                    kind: .regularFile,
                    fingerprint: hiddenFingerprint,
                    typeDescription: "Plain Text"
                ))
            ]),
            ComparisonListingBatch(records: [
                .failure(
                    path: try ComparisonRelativePath(components: ["blocked-item"]),
                    message: "Cannot read blocked-item"
                )
            ])
        ]
        let listing = StorageScanListingFixture(identity: rootIdentity, batches: batches)
        return StorageScanFixture(
            temporary: temporary,
            rootIdentity: rootIdentity,
            listing: listing,
            regularFingerprint: regularFingerprint
        )
    }

    func directory(_ basename: String) -> URL {
        root.appending(path: basename, directoryHint: .isDirectory)
    }

    func admission(identity: FileIdentity? = nil) -> StorageScanAdmissionToken {
        StorageScanAdmissionToken(
            root: root.standardizedFileURL,
            rootIdentity: identity ?? rootIdentity,
            rootKind: .directory,
            volumeClassification: .local,
            authorization: .init(
                isProtectedLocation: false,
                protectedScanAuthorized: true,
                cleanupAuthorized: false
            )
        )
    }

    func file(_ basename: String, contents: String) throws -> URL {
        let url = root.appending(path: basename)
        try Data(contents.utf8).write(to: url)
        return url
    }

    @MainActor
    func cloudStore(root cloudRoot: URL) async throws -> CloudLocationsStore {
        let location = StorageLocation(
            id: .fileProvider(
                domainIdentifier: "com.example.storage-scan",
                rootIdentity: Data([0x42])
            ),
            provider: .other("Example"),
            displayName: cloudRoot.lastPathComponent,
            rootURL: cloudRoot,
            isAvailable: true,
            capabilities: [.browse, .materialize, .localFileOperations],
            source: .discovered
        )
        let store = CloudLocationsStore(
            storageURL: root.appending(path: "cloud-locations.json"),
            discovery: StorageScanCloudDiscovery([location]),
            bookmarking: InMemoryCloudLocationBookmarking()
        )
        try await store.rescan()
        return store
    }

    @MainActor
    func emptyCloudStore() -> CloudLocationsStore {
        CloudLocationsStore(
            storageURL: root.appending(path: "empty-cloud-locations.json"),
            discovery: StorageScanCloudDiscovery([]),
            bookmarking: InMemoryCloudLocationBookmarking()
        )
    }

    private static func comparisonEntry(
        path: [String],
        url: URL,
        kind: ComparisonEntryKind,
        fingerprint: ComparisonFingerprint,
        typeDescription: String
    ) throws -> ComparisonEntry {
        ComparisonEntry(
            relativePath: try ComparisonRelativePath(components: path),
            url: url,
            kind: kind,
            fingerprint: fingerprint,
            symbolicLinkTarget: nil,
            typeDescription: typeDescription
        )
    }
}

private actor StorageScanListingFixture: ComparisonListingService {
    private let expectedIdentity: FileIdentity
    private let configuredBatches: [ComparisonListingBatch]
    private(set) var requests: [ComparisonListingRequest] = []

    init(identity: FileIdentity, batches: [ComparisonListingBatch]) {
        expectedIdentity = identity
        configuredBatches = batches
    }

    func identity(of root: URL) -> FileIdentity {
        expectedIdentity
    }

    nonisolated func batches(for request: ComparisonListingRequest)
        -> AsyncThrowingStream<ComparisonListingBatch, Error> {
        AsyncThrowingStream { continuation in
            Task {
                let batches = await batchesAndRecord(request)
                for batch in batches {
                    continuation.yield(batch)
                }
                continuation.finish()
            }
        }
    }

    private func batchesAndRecord(
        _ request: ComparisonListingRequest
    ) -> [ComparisonListingBatch] {
        requests.append(request)
        guard !request.options.includeHiddenItems else {
            return configuredBatches
        }
        return configuredBatches.compactMap { batch in
            let visible = batch.records.filter { record in
                switch record {
                case let .entry(entry):
                    !entry.relativePath.components.contains {
                        $0.hasPrefix(".")
                    }
                case .failure:
                    true
                }
            }
            return visible.isEmpty ? nil : ComparisonListingBatch(records: visible)
        }
    }
}

private actor StorageScanBufferRecorder: StorageScanBufferObserving {
    private(set) var maximumBufferedCount = 0
    private(set) var backpressureCount = 0

    func didEnqueue(bufferedCount: Int) {
        maximumBufferedCount = max(maximumBufferedCount, bufferedCount)
    }

    func didApplyBackpressure() {
        backpressureCount += 1
    }
}

private struct StorageScanCloudDiscovery: CloudLocationDiscovering {
    let locations: [StorageLocation]

    init(_ locations: [StorageLocation]) {
        self.locations = locations
    }

    func discover() async -> [StorageLocation] {
        locations
    }
}

private extension Array where Element == StorageScanRecord {
    func containsPackageNamed(_ name: String) -> Bool {
        contains { record in
            record.entry?.relativePath.components == [name]
                && record.entry?.kind == .package
        }
    }

    func containsSymlinkNamed(_ name: String) -> Bool {
        contains { record in
            record.entry?.relativePath.components == [name]
                && record.entry?.kind == .symbolicLink
        }
    }

    func containsDescendant(of name: String) -> Bool {
        compactMap(\.entry).contains { entry in
            entry.relativePath.components.count > 1
                && entry.relativePath.components.first == name
        }
    }

    func containsName(_ name: String) -> Bool {
        compactMap(\.entry).contains {
            $0.relativePath.components.last == name
        }
    }

    var failureCount: Int {
        count(where: {
            if case .failure = $0 { true } else { false }
        })
    }

    var failureMessages: [String] {
        compactMap {
            if case let .failure(_, message) = $0 { message } else { nil }
        }
    }

    func entry(named name: String) -> StorageEntry? {
        compactMap(\.entry).first {
            $0.relativePath.components.last == name
        }
    }
}

private extension StorageScanRecord {
    var entry: StorageEntry? {
        if case let .entry(entry) = self { entry } else { nil }
    }
}

private func lstatForStorageScanTest(_ url: URL) throws -> stat {
    var information = stat()
    let result: Int32 = url.withUnsafeFileSystemRepresentation { path in
        guard let path else { return Int32(-1) }
        return Darwin.lstat(path, &information)
    }
    guard result == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return information
}

private func storageScanTestIdentity(of url: URL) throws -> FileIdentity {
    let information = try lstatForStorageScanTest(url)
    let identifier = "\(UInt64(information.st_dev)):\(UInt64(information.st_ino))"
    return FileIdentity(entryIdentifier: identifier, resolvedIdentifier: identifier)
}
