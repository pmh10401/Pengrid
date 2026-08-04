import Foundation

enum FolderPreviewSourceKind: Hashable, Sendable {
    case ordinaryDirectory
}

struct FolderPreviewRequest: Hashable, Sendable {
    let paneID: PaneID
    let url: URL
    let identity: FileIdentity
    let kind: FolderPreviewSourceKind
}

struct FolderPreviewEntry: Identifiable, Equatable, Sendable {
    let name: String
    let isDirectory: Bool
    let isPackage: Bool
    let byteSize: Int64?
    let modifiedAt: Date?

    var id: String { name }
}

struct FolderPreviewSnapshot: Equatable, Sendable {
    let request: FolderPreviewRequest
    let entries: [FolderPreviewEntry]
}

enum FolderPreviewFailure: Equatable, Sendable {
    case folderChanged
    case unavailable
}

enum FolderPreviewPhase: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case failed(FolderPreviewFailure)
}
