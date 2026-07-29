import Foundation
@testable import BloomFileManager

struct StubDirectoryListingService: DirectoryListingService {
    let values: [URL: [FileItem]]

    func batches(in directory: URL) -> AsyncThrowingStream<[FileItem], Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(values[directory] ?? [])
            continuation.finish()
        }
    }
}
