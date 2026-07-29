import Foundation

enum CloudProviderKind: Hashable, Codable, Sendable {
    case iCloudDrive
    case googleDrive
    case oneDrive
    case dropbox
    case other(String)

    var displayName: String {
        switch self {
        case .iCloudDrive: "iCloud Drive"
        case .googleDrive: "Google Drive"
        case .oneDrive: "OneDrive"
        case .dropbox: "Dropbox"
        case let .other(name): name
        }
    }

    var systemImage: String {
        switch self {
        case .iCloudDrive: "icloud"
        case .googleDrive: "externaldrive.badge.icloud"
        case .oneDrive: "cloud"
        case .dropbox: "shippingbox"
        case .other: "externaldrive.badge.icloud"
        }
    }
}

enum StorageLocationID: Hashable, Sendable {
    case fileProvider(domainIdentifier: String, rootIdentity: Data)
    case manualBookmark(UUID)
}

struct StorageCapabilities: OptionSet, Hashable, Codable, Sendable {
    let rawValue: UInt16

    static let browse = Self(rawValue: 1 << 0)
    static let materialize = Self(rawValue: 1 << 1)
    static let localFileOperations = Self(rawValue: 1 << 2)
    static let remoteUpload = Self(rawValue: 1 << 3)
    static let remoteDownload = Self(rawValue: 1 << 4)
}

struct StorageLocation: Identifiable, Hashable, Sendable {
    let id: StorageLocationID
    let provider: CloudProviderKind
    var displayName: String
    let rootURL: URL
    var isAvailable: Bool
    let capabilities: StorageCapabilities
    let source: Source

    enum Source: Hashable, Sendable {
        case discovered
        case manualBookmark
    }
}
