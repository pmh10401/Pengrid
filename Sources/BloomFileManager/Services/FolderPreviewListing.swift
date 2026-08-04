import Foundation

protocol FolderPreviewListing: Sendable {
    func snapshot(
        _ request: FolderPreviewRequest,
        progress: @escaping @Sendable (Int) -> Void
    ) async throws -> FolderPreviewSnapshot
}

struct LiveFolderPreviewListing: FolderPreviewListing {
    let fileSystem: any FileSystemAccess
    let visibility: DirectoryVisibilityPolicy

    init(
        fileSystem: any FileSystemAccess = LiveFileSystemAccess(),
        visibility: DirectoryVisibilityPolicy = .baseline
    ) {
        self.fileSystem = fileSystem
        self.visibility = visibility
    }

    func snapshot(
        _ request: FolderPreviewRequest,
        progress: @escaping @Sendable (Int) -> Void
    ) async throws -> FolderPreviewSnapshot {
        let snapshot = try await fileSystem.snapshotFolder(
            request,
            visibility: visibility,
            progress: progress
        )
        guard snapshot.request == request else {
            throw FileSystemAccessError.identityMismatch(request.url)
        }
        return snapshot
    }
}
