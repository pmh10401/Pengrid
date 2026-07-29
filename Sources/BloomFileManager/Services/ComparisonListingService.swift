import Darwin
import Foundation

struct ComparisonListingRequest: Sendable {
    let root: URL
    let seed: [FileItem]?
    let subtree: ComparisonRelativePath?
    let options: ComparisonOptions
}

extension ComparisonListingRequest {
    static func recursive(root: URL) -> Self {
        .init(
            root: root,
            seed: nil,
            subtree: nil,
            options: .init(includeSubfolders: true, includeHiddenItems: false)
        )
    }
}

enum ComparisonListingRecord: Sendable {
    case entry(ComparisonEntry)
    case failure(path: ComparisonRelativePath, message: String)

    var entry: ComparisonEntry? {
        if case let .entry(value) = self { return value }
        return nil
    }
}

struct ComparisonListingBatch: Sendable {
    let records: [ComparisonListingRecord]
}

protocol ComparisonListingService: Sendable {
    func identity(of root: URL) async throws -> FileIdentity
    func batches(for request: ComparisonListingRequest)
        -> AsyncThrowingStream<ComparisonListingBatch, Error>
}

extension ComparisonListingService {
    func collect(_ request: ComparisonListingRequest) async throws -> [ComparisonListingRecord] {
        var records: [ComparisonListingRecord] = []
        for try await batch in batches(for: request) {
            records += batch.records
        }
        return records
    }
}

struct LiveComparisonListingService: ComparisonListingService {
    let batchSize: Int
    private let accessCoordinator: CloudLocationScopedAccessCoordinator

    init(
        batchSize: Int = 256,
        accessCoordinator: CloudLocationScopedAccessCoordinator = .init()
    ) {
        self.batchSize = max(1, batchSize)
        self.accessCoordinator = accessCoordinator
    }

    func identity(of root: URL) async throws -> FileIdentity {
        let lease = try accessCoordinator.acquireAccess(for: root)
        defer { lease?.finish() }
        return try await Task.detached { try noFollowIdentity(root) }.value
    }

    func batches(for request: ComparisonListingRequest)
        -> AsyncThrowingStream<ComparisonListingBatch, Error> {
        let producer = ComparisonListingBatchProducer(
            request: request,
            batchSize: batchSize,
            accessCoordinator: accessCoordinator
        )
        return AsyncThrowingStream(unfolding: { try await producer.nextBatch() })
    }
}

private enum ComparisonListingError: Error {
    case pathOutsideRoot(URL, URL)
}

private actor ComparisonListingBatchProducer {
    private let request: ComparisonListingRequest
    private let batchSize: Int
    private let accessCoordinator: CloudLocationScopedAccessCoordinator
    private var listingSource: ComparisonListingURLSource?
    private var accessLease: CloudLocationScopedAccessLease?

    init(
        request: ComparisonListingRequest,
        batchSize: Int,
        accessCoordinator: CloudLocationScopedAccessCoordinator
    ) {
        self.request = request
        self.batchSize = batchSize
        self.accessCoordinator = accessCoordinator
    }

    func nextBatch() throws -> ComparisonListingBatch? {
        if accessLease == nil {
            accessLease = try accessCoordinator.acquireAccess(for: request.root)
        }
        do {
            let batch = try produceNextBatch()
            if batch == nil {
                accessLease?.finish()
                accessLease = nil
            }
            return batch
        } catch {
            accessLease?.finish()
            accessLease = nil
            throw error
        }
    }

    private func produceNextBatch() throws -> ComparisonListingBatch? {
        try checkCancellation()
        let source = try sourceForListing()
        var records: [ComparisonListingRecord] = []

        while records.count < batchSize {
            try checkCancellation()
            guard let discovery = source.next() else { break }
            switch discovery {
            case let .failure(url, message):
                records.append(.failure(
                    path: try relativePath(url, beneath: request.root),
                    message: message
                ))
            case let .url(url):
                do {
                    let information = try lstatInfo(for: url)
                    let mode = information.st_mode & S_IFMT
                    if mode == S_IFLNK { source.skipDescendants() }
                    if !request.options.includeHiddenItems, isHidden(url) {
                        if mode == S_IFDIR { source.skipDescendants() }
                        continue
                    }
                    records.append(.entry(try makeEntry(
                        url,
                        root: request.root,
                        information: information
                    )))
                } catch {
                    records.append(.failure(
                        path: try relativePath(url, beneath: request.root),
                        message: error.localizedDescription
                    ))
                }
            }
        }
        return records.isEmpty ? nil : .init(records: records)
    }

    private func sourceForListing() throws -> ComparisonListingURLSource {
        if let listingSource { return listingSource }
        let source = try ComparisonListingURLSource(request: request)
        self.listingSource = source
        return source
    }

    private func checkCancellation() throws {
        try Task.checkCancellation()
    }
}

private final class ComparisonListingURLSource {
    enum Discovery {
        case url(URL)
        case failure(URL, String)
    }

    private var urls: [URL]?
    private var urlIndex = 0
    private var enumerator: FileManager.DirectoryEnumerator?
    private let failureBuffer: ComparisonEnumerationFailureBuffer?
    private var pending: [Discovery] = []

    init(request: ComparisonListingRequest) throws {
        if !request.options.includeSubfolders, let seed = request.seed {
            urls = seed.map(\.url)
            failureBuffer = nil
            return
        }
        guard request.options.includeSubfolders else {
            urls = try shallowURLs(in: request.root)
            failureBuffer = nil
            return
        }

        let start = request.subtree.map { subtree in
            subtree.components.reduce(request.root) {
                $0.appending(path: $1, directoryHint: .isDirectory)
            }
        } ?? request.root
        let failureBuffer = ComparisonEnumerationFailureBuffer()
        guard let enumerator = FileManager.default.enumerator(
            at: start,
            includingPropertiesForKeys: [.isPackageKey],
            options: [.skipsPackageDescendants],
            errorHandler: { url, error in
                failureBuffer.append(url: url, message: error.localizedDescription)
                return true
            }
        ) else {
            throw POSIXError(.ENOENT)
        }
        self.enumerator = enumerator
        self.failureBuffer = failureBuffer
    }

    func next() -> Discovery? {
        if !pending.isEmpty { return pending.removeFirst() }
        if let urls {
            guard urlIndex < urls.count else { return nil }
            defer { urlIndex += 1 }
            return .url(urls[urlIndex])
        }
        guard let enumerator else { return nil }
        let url = enumerator.nextObject() as? URL
        if let failureBuffer {
            pending += failureBuffer.take()
        }
        if let url { pending.append(.url(url)) }
        return pending.isEmpty ? nil : pending.removeFirst()
    }

    func skipDescendants() {
        enumerator?.skipDescendants()
    }
}

private final class ComparisonEnumerationFailureBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ComparisonListingURLSource.Discovery] = []

    func append(url: URL, message: String) {
        lock.lock()
        values.append(.failure(url, message))
        lock.unlock()
    }

    func take() -> [ComparisonListingURLSource.Discovery] {
        lock.lock()
        defer { lock.unlock() }
        let values = values
        self.values.removeAll(keepingCapacity: true)
        return values
    }
}

private func shallowURLs(in root: URL) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: nil,
        options: []
    )
}

private func isHidden(_ url: URL) -> Bool {
    url.lastPathComponent.hasPrefix(".")
}

private func relativePath(_ url: URL, beneath root: URL) throws -> ComparisonRelativePath {
    let standardizedURL = standardizedLocation(url)
    let standardizedRoot = standardizedLocation(root)
    let urlComponents = standardizedURL.pathComponents
    let rootComponents = standardizedRoot.pathComponents
    guard urlComponents.starts(with: rootComponents), urlComponents.count > rootComponents.count else {
        throw ComparisonListingError.pathOutsideRoot(standardizedURL, standardizedRoot)
    }
    return try ComparisonRelativePath(components: Array(urlComponents.dropFirst(rootComponents.count)))
}

private func standardizedLocation(_ url: URL) -> URL {
    let standardizedURL = url.standardizedFileURL
    let parent = standardizedURL.deletingLastPathComponent()
        .resolvingSymlinksInPath()
        .standardizedFileURL
    return parent.appendingPathComponent(
        standardizedURL.lastPathComponent,
        isDirectory: standardizedURL.hasDirectoryPath
    ).standardizedFileURL
}

private func noFollowIdentity(_ url: URL) throws -> FileIdentity {
    let information = try lstatInfo(for: url)
    let identifier = "\(UInt64(information.st_dev)):\(UInt64(information.st_ino))"
    return FileIdentity(entryIdentifier: identifier, resolvedIdentifier: identifier)
}

private func lstatInfo(for url: URL) throws -> stat {
    var information = stat()
    let status: Int32 = url.withUnsafeFileSystemRepresentation { path in
        guard let path else { return -1 }
        return Darwin.lstat(path, &information)
    }
    guard status == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return information
}

private func makeEntry(_ url: URL, root: URL, information: stat) throws -> ComparisonEntry {
    let mode = information.st_mode & S_IFMT
    let kind: ComparisonEntryKind
    switch mode {
    case S_IFREG: kind = .regularFile
    case S_IFDIR:
        let resourceValues = try url.resourceValues(forKeys: [.isPackageKey])
        kind = resourceValues.isPackage == true ? .package : .directory
    case S_IFLNK: kind = .symbolicLink
    default: kind = .special
    }
    let byteSize = kind == .regularFile ? Int64(information.st_size) : nil
    let modifiedAt = Date(timeIntervalSince1970: TimeInterval(information.st_mtimespec.tv_sec)
        + TimeInterval(information.st_mtimespec.tv_nsec) / 1_000_000_000)
    let typeDescription: String
    if kind == .symbolicLink {
        typeDescription = "Symbolic Link"
    } else {
        typeDescription = try url.resourceValues(forKeys: [.localizedTypeDescriptionKey])
            .localizedTypeDescription ?? kind.rawValue
    }
    return ComparisonEntry(
        relativePath: try relativePath(url, beneath: root),
        url: url.standardizedFileURL,
        kind: kind,
        fingerprint: .init(
            identity: try noFollowIdentity(url),
            byteSize: byteSize,
            modifiedAt: modifiedAt,
            rawModifiedAt: .init(
                seconds: Int64(information.st_mtimespec.tv_sec),
                nanoseconds: Int64(information.st_mtimespec.tv_nsec)
            )
        ),
        symbolicLinkTarget: kind == .symbolicLink ? try symbolicLinkTarget(at: url) : nil,
        typeDescription: typeDescription
    )
}

private func symbolicLinkTarget(at url: URL) throws -> String {
    var size = 256
    while size <= 65_536 {
        var buffer = [CChar](repeating: 0, count: size)
        let count: Int = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return buffer.withUnsafeMutableBufferPointer { Darwin.readlink(path, $0.baseAddress, $0.count) }
        }
        guard count >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        if count < size {
            return String(decoding: buffer.prefix(count).map(UInt8.init(bitPattern:)), as: UTF8.self)
        }
        size *= 2
    }
    throw POSIXError(.ENAMETOOLONG)
}
