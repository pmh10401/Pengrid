import Foundation

protocol DirectoryListingService: Sendable {
    func batches(in directory: URL) -> AsyncThrowingStream<[FileItem], Error>
}
