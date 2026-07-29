import Foundation
import Testing
@testable import BloomFileManager

@Suite struct StorageModelTests {
    @Test func knownAndUnknownProvidersHaveStablePresentation() {
        #expect(CloudProviderKind.googleDrive.systemImage == "externaldrive.badge.icloud")
        #expect(CloudProviderKind.oneDrive.displayName == "OneDrive")
        #expect(CloudProviderKind.dropbox.displayName == "Dropbox")
        #expect(CloudProviderKind.other("Acme").displayName == "Acme")
    }

    @Test func fileProviderLocationIdentityUsesDomainAndRootIdentity() {
        let id = StorageLocationID.fileProvider(
            domainIdentifier: "com.example.drive",
            rootIdentity: Data([1, 2, 3])
        )

        #expect(id != .fileProvider(
            domainIdentifier: "com.example.drive",
            rootIdentity: Data([9])
        ))
    }

    @Test func capabilitySetsDoNotImplyUnsupportedRemoteOperations() {
        let capabilities: StorageCapabilities = [.browse, .materialize, .localFileOperations]

        #expect(capabilities.contains(.browse))
        #expect(!capabilities.contains(.remoteUpload))
    }

    @Test func unknownAvailabilityBlocksByteDependentWork() {
        #expect(CloudItemAvailability.unknown.requiresMaterialization)
        #expect(!CloudItemAvailability.availableLocally.requiresMaterialization)
    }
}
