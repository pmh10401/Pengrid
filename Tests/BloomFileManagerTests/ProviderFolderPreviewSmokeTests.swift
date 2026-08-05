import Foundation
import Testing
@testable import BloomFileManager

@Suite("ProviderFolderPreviewSmokeTests", .serialized)
struct ProviderFolderPreviewSmokeTests {
    @Test(.enabled(if: providerPreviewSmokeEnabled))
    func capturesMetadataOnlySnapshotsForInstalledProviders() async throws {
        let fileSystem = LiveFileSystemAccess()
        let listing = LiveFolderPreviewListing(fileSystem: fileSystem)
        let locations = await LiveCloudLocationDiscovery().discover()

        for provider in Provider.allCases {
            try await captureSnapshot(
                for: provider,
                locations: locations,
                fileSystem: fileSystem,
                listing: listing
            )
        }
    }

    private func captureSnapshot(
        for provider: Provider,
        locations: [StorageLocation],
        fileSystem: LiveFileSystemAccess,
        listing: LiveFolderPreviewListing
    ) async throws {
        guard let location = locations.first(where: { $0.provider == provider.cloudProvider }) else {
            throw ProviderPreviewSmokeFailure.missingRoot(provider.label)
        }

        do {
            guard let request = try await fileSystem.captureFolderPreviewRequest(
                paneID: .left,
                url: location.rootURL
            ) else {
                throw ProviderPreviewSmokeFailure.unavailable(provider.label)
            }
            guard request.paneID == .left,
                  request.url == location.rootURL.standardizedFileURL,
                  request.kind == .ordinaryDirectory
            else {
                throw ProviderPreviewSmokeFailure.requestMismatch(provider.label)
            }

            let snapshot = try await listing.snapshot(request, progress: { _ in })
            guard snapshot.request == request else {
                throw ProviderPreviewSmokeFailure.snapshotMismatch(provider.label)
            }
            print("\(provider.label) provider preview entries: \(snapshot.entries.count)")
        } catch let failure as ProviderPreviewSmokeFailure {
            throw failure
        } catch {
            throw ProviderPreviewSmokeFailure.providerCallFailed(
                provider.label,
                errorType: String(reflecting: type(of: error))
            )
        }
    }
}

private let providerPreviewSmokeEnabled =
    ProcessInfo.processInfo.environment["PENGRID_PROVIDER_PREVIEW_SMOKE"] == "1"

private enum Provider: CaseIterable {
    case googleDrive
    case oneDrive

    var label: String {
        switch self {
        case .googleDrive: "Google Drive"
        case .oneDrive: "OneDrive"
        }
    }

    var cloudProvider: CloudProviderKind {
        switch self {
        case .googleDrive: .googleDrive
        case .oneDrive: .oneDrive
        }
    }
}

private enum ProviderPreviewSmokeFailure: Error, CustomStringConvertible {
    case missingRoot(String)
    case unavailable(String)
    case requestMismatch(String)
    case snapshotMismatch(String)
    case providerCallFailed(String, errorType: String)

    var description: String {
        switch self {
        case .missingRoot(let provider):
            "\(provider) provider root is unavailable"
        case .unavailable(let provider):
            "\(provider) provider metadata is unavailable"
        case .requestMismatch(let provider):
            "\(provider) provider preview request did not round-trip"
        case .snapshotMismatch(let provider):
            "\(provider) provider preview snapshot did not round-trip"
        case .providerCallFailed(let provider, let errorType):
            "\(provider) provider metadata call failed (\(errorType))"
        }
    }
}
