import Foundation

protocol CloudItemAvailabilityReading: Sendable {
    func availability(of url: URL) async -> CloudItemAvailability
}

enum CloudItemDownloadingStatus: Sendable, Equatable {
    case notDownloaded
    case downloaded
    case current
}

struct CloudItemResourceMetadata: Sendable, Equatable {
    let isUbiquitousItem: Bool?
    let isDownloading: Bool?
    let downloadingStatus: CloudItemDownloadingStatus?
    let percentDownloaded: Double?
    let isInsideKnownCloudRoot: Bool
}

protocol CloudItemMetadataReading: Sendable {
    func metadata(of url: URL) async throws -> CloudItemResourceMetadata
}

struct LiveCloudItemAvailabilityService: CloudItemAvailabilityReading {
    private let metadataReader: any CloudItemMetadataReading

    init(
        metadataReader: any CloudItemMetadataReading = LiveCloudItemMetadataReader()
    ) {
        self.metadataReader = metadataReader
    }

    func availability(of url: URL) async -> CloudItemAvailability {
        let metadata: CloudItemResourceMetadata
        do {
            metadata = try await metadataReader.metadata(of: url)
        } catch {
            return .unknown
        }

        if metadata.isDownloading == true {
            let progress = metadata.percentDownloaded.map {
                min(max($0 / 100, 0), 1)
            }
            return .downloading(progress: progress)
        }

        switch metadata.downloadingStatus {
        case .current, .downloaded:
            return .availableLocally
        case .notDownloaded:
            return .onlineOnly
        case nil:
            break
        }

        if metadata.isUbiquitousItem == true || metadata.isInsideKnownCloudRoot {
            return .unknown
        }
        return .availableLocally
    }
}

struct LiveCloudItemMetadataReader: CloudItemMetadataReading {
    private static let percentDownloadedKey = URLResourceKey(
        rawValue: "NSURLUbiquitousItemPercentDownloadedKey"
    )

    private let knownCloudRoots: [URL]

    init(knownCloudRoots: [URL] = [Self.defaultCloudStorageRoot]) {
        self.knownCloudRoots = knownCloudRoots.map(\.standardizedFileURL)
    }

    func metadata(of url: URL) throws -> CloudItemResourceMetadata {
        let keys: Set<URLResourceKey> = [
            .isUbiquitousItemKey,
            .ubiquitousItemIsDownloadingKey,
            .ubiquitousItemDownloadingStatusKey,
            Self.percentDownloadedKey
        ]
        let values = try url.resourceValues(forKeys: keys)
        let status: CloudItemDownloadingStatus?
        switch values.ubiquitousItemDownloadingStatus {
        case .notDownloaded:
            status = .notDownloaded
        case .downloaded:
            status = .downloaded
        case .current:
            status = .current
        case nil:
            status = nil
        default:
            status = nil
        }
        let percent = (values.allValues[Self.percentDownloadedKey] as? NSNumber)?.doubleValue

        return CloudItemResourceMetadata(
            isUbiquitousItem: values.isUbiquitousItem,
            isDownloading: values.ubiquitousItemIsDownloading,
            downloadingStatus: status,
            percentDownloaded: percent,
            isInsideKnownCloudRoot: isInsideKnownCloudRoot(url)
        )
    }

    private func isInsideKnownCloudRoot(_ url: URL) -> Bool {
        let candidate = url.standardizedFileURL.pathComponents
        return knownCloudRoots.contains { root in
            let rootComponents = root.pathComponents
            return candidate.count >= rootComponents.count
                && candidate.prefix(rootComponents.count).elementsEqual(rootComponents)
        }
    }

    private static var defaultCloudStorageRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/CloudStorage", directoryHint: .isDirectory)
    }
}
