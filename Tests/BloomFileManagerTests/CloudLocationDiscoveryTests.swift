import Foundation
import Testing
@testable import BloomFileManager

@Suite struct CloudLocationDiscoveryTests {
    @Test func classifiesKnownProvidersAndKeepsUnknownProviders() async {
        let roots = [
            fixture("GoogleDrive-minho@example.invalid", domain: "com.google.drivefs"),
            fixture("OneDrive-Personal", domain: "com.microsoft.OneDrive"),
            fixture("Dropbox", domain: "com.getdropbox.dropbox"),
            fixture("Acme Vault", domain: "com.acme.files")
        ]

        let locations = await LiveCloudLocationDiscovery(fileSystem: StubCloudFS(roots)).discover()

        #expect(locations.map(\.provider) == [
            .other("Acme Vault"), .dropbox, .googleDrive, .oneDrive
        ])
    }

    @Test func domainIdentifierWinsOverConflictingGoogleDisplayName() async {
        let locations = await LiveCloudLocationDiscovery(
            fileSystem: StubCloudFS([
                fixture("Google Archive", domain: "com.microsoft.OneDrive")
            ])
        ).discover()

        #expect(locations.map(\.provider) == [.oneDrive])
    }

    @Test func domainIdentifierWinsOverConflictingOneDriveDisplayName() async {
        let locations = await LiveCloudLocationDiscovery(
            fileSystem: StubCloudFS([
                fixture("OneDrive Backup", domain: "com.getdropbox.dropbox")
            ])
        ).discover()

        #expect(locations.map(\.provider) == [.dropbox])
    }

    @Test func deduplicatesAliasesByCanonicalRootIdentity() async {
        let identity = Data([4, 2])
        let roots = [
            fixture("Alias A", domain: "com.acme.files", identity: identity),
            fixture("Alias B", domain: "com.acme.files", identity: identity)
        ]

        let locations = await LiveCloudLocationDiscovery(fileSystem: StubCloudFS(roots)).discover()

        #expect(locations.count == 1)
    }

    @Test func supportsMultipleRootsFromTheSameProvider() async {
        let roots = [
            fixture("OneDrive A", domain: "com.microsoft.OneDrive", identity: Data([1])),
            fixture("OneDrive B", domain: "com.microsoft.OneDrive", identity: Data([2]))
        ]

        let locations = await LiveCloudLocationDiscovery(fileSystem: StubCloudFS(roots)).discover()

        #expect(locations.count == 2)
        #expect(locations.allSatisfy { $0.provider == .oneDrive })
    }

    @Test func readOnlyCandidateDoesNotAdvertiseLocalFileOperations() async throws {
        let locations = await LiveCloudLocationDiscovery(
            fileSystem: StubCloudFS([
                fixture(
                    "Read Only",
                    domain: "com.acme.readonly",
                    supportsLocalFileOperations: false
                )
            ])
        ).discover()

        let location = try #require(locations.first)
        #expect(location.capabilities.contains(.browse))
        #expect(location.capabilities.contains(.materialize))
        #expect(!location.capabilities.contains(.localFileOperations))
    }

    @Test func missingCloudStorageDirectoryReturnsEmpty() async {
        let locations = await LiveCloudLocationDiscovery(fileSystem: StubCloudFS([])).discover()

        #expect(locations.isEmpty)
    }

    @Test func unreadableOrNonDirectoryCandidatesAreExcluded() async {
        let locations = await LiveCloudLocationDiscovery(
            fileSystem: StubCloudFS([.unreadableFixture, .regularFileFixture])
        ).discover()

        #expect(locations.isEmpty)
    }

    @Test func sortsEqualDisplayNamesByStableRootIdentityBytes() async {
        let roots = [
            fixture("Same", domain: "com.acme.files", identity: Data([9])),
            fixture("Same", domain: "com.acme.files", identity: Data([1]))
        ]

        let locations = await LiveCloudLocationDiscovery(fileSystem: StubCloudFS(roots)).discover()

        #expect(locations.map(\.id) == [
            .fileProvider(domainIdentifier: "com.acme.files", rootIdentity: Data([1])),
            .fileProvider(domainIdentifier: "com.acme.files", rootIdentity: Data([9]))
        ])
    }

    @Test func encodesPropertyListResourceIdentifiersToStableData() throws {
        let identifier: [String: Any] = ["volume": "fixture", "item": Data([1, 2])]

        let first = try #require(CloudLocationRootIdentityEncoder.encode(identifier))
        let second = try #require(CloudLocationRootIdentityEncoder.encode(identifier))

        #expect(first == second)
    }

    @Test func rejectsResourceIdentifiersThatAreNotPropertyLists() {
        #expect(CloudLocationRootIdentityEncoder.encode(URL(fileURLWithPath: "/fixture")) == nil)
    }

    private func fixture(
        _ name: String,
        domain: String,
        identity: Data? = nil,
        supportsLocalFileOperations: Bool = true
    ) -> StubCloudFS.Entry {
        let url = URL(fileURLWithPath: "/fixture/CloudStorage").appending(path: name, directoryHint: .isDirectory)
        return .candidate(
            CloudLocationCandidate(
                url: url,
                canonicalURL: url,
                rootIdentity: identity ?? Data(name.utf8),
                domainIdentifier: domain,
                systemDisplayName: name,
                supportsLocalFileOperations: supportsLocalFileOperations
            )
        )
    }
}
