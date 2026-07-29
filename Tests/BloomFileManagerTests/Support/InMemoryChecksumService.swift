import Darwin
import Foundation
@testable import BloomFileManager

actor ChecksumConcurrencyProbe {
    private(set) var highWater = 0
    private var active = 0

    func enter() {
        active += 1
        highWater = max(highWater, active)
    }

    func leave() {
        active -= 1
    }
}

actor PermitWaiterCancellationProbe {
    enum Outcome: Equatable {
        case acquired
        case cancelled
        case failed
    }

    private(set) var started = false
    private(set) var outcome: Outcome?

    func markStarted() { started = true }
    func markAcquired() { outcome = .acquired }
    func markCancelled() { outcome = .cancelled }
    func markFailed() { outcome = .failed }
}

actor InMemoryChecksumService: ChecksumService {
    private let permits = AsyncPermitPool(limit: 2)
    private let probe: ChecksumConcurrencyProbe

    init(probe: ChecksumConcurrencyProbe) {
        self.probe = probe
    }

    func checksum(
        for request: ChecksumRequest,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> ChecksumResult {
        try await permits.acquire()
        var enteredProbe = false
        do {
            try Task.checkCancellation()
            await probe.enter()
            enteredProbe = true
            try await Task.sleep(for: .milliseconds(30))
            await progress(1)
            let result = ChecksumResult(digest: Data(request.url.path.utf8))
            await probe.leave()
            await permits.release()
            return result
        } catch {
            if enteredProbe {
                await probe.leave()
            }
            await permits.release()
            throw error
        }
    }
}

enum ChecksumFixture {
    static func equalFiles() throws -> ChecksumFilePair {
        let directory = try TemporaryDirectory()
        let contents = Data(repeating: 0xA5, count: 12_000)
        let left = directory.url.appending(path: "left.bin")
        let right = directory.url.appending(path: "right.bin")
        try contents.write(to: left)
        try contents.write(to: right)
        return try ChecksumFilePair(
            directory: directory,
            leftRequest: request(for: left),
            rightRequest: request(for: right)
        )
    }

    static func replacedAfterFirstChunk() throws -> ReplacingChecksumFixture {
        let directory = try TemporaryDirectory()
        let target = directory.url.appending(path: "target.bin")
        let replacement = directory.url.appending(path: "replacement.bin")
        try Data(repeating: 0x11, count: 16_384).write(to: target)
        try Data(repeating: 0x22, count: 16_384).write(to: replacement)
        return try ReplacingChecksumFixture(
            directory: directory,
            service: LiveChecksumService(chunkSize: 4_096),
            request: request(for: target),
            target: target,
            replacement: replacement
        )
    }

    static func nanosecondMutationAfterFirstChunk() throws -> NanosecondMutationChecksumFixture {
        let directory = try TemporaryDirectory()
        let target = directory.url.appending(path: "nanosecond.bin")
        try Data(repeating: 0x33, count: 16_384).write(to: target)
        let initial = ComparisonModificationTimestamp(seconds: 1_700_000_000, nanoseconds: 123_456_700)
        let changed = ComparisonModificationTimestamp(seconds: 1_700_000_000, nanoseconds: 123_456_701)
        try setModificationTime(target, to: initial)
        return try NanosecondMutationChecksumFixture(
            directory: directory,
            service: LiveChecksumService(chunkSize: 4_096),
            request: request(for: target),
            target: target,
            changedRawModifiedAt: changed
        )
    }

    static func symbolicLinkRequest() throws -> ChecksumFilePair {
        let directory = try TemporaryDirectory()
        let target = directory.url.appending(path: "target.bin")
        let link = directory.url.appending(path: "link.bin")
        try Data(repeating: 0x44, count: 4_096).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let linkRequest = try request(for: link)
        return try ChecksumFilePair(
            directory: directory,
            leftRequest: linkRequest,
            rightRequest: linkRequest
        )
    }

    static func sizeMutationAfterFirstChunk() throws -> SizeMutationChecksumFixture {
        let directory = try TemporaryDirectory()
        let target = directory.url.appending(path: "growing.bin")
        try Data(repeating: 0x55, count: 16_384).write(to: target)
        return try SizeMutationChecksumFixture(
            directory: directory,
            service: LiveChecksumService(chunkSize: 4_096),
            request: request(for: target),
            target: target
        )
    }

    static func fiveRequests() -> [ChecksumRequest] {
        (0 ..< 5).map { index in
            let identity = "1:\(index)"
            return ChecksumRequest(
                url: URL(filePath: "/memory/\(index)"),
                fingerprint: .init(
                    identity: .init(entryIdentifier: identity, resolvedIdentifier: identity),
                    byteSize: 1,
                    modifiedAt: Date(timeIntervalSince1970: 1)
                )
            )
        }
    }

    static func checkingRow() throws -> ComparisonRow {
        let path = try ComparisonRelativePath(components: ["report.bin"])
        let requests = fiveRequests()
        let left = ComparisonEntry(
            relativePath: path,
            url: requests[0].url,
            kind: .regularFile,
            fingerprint: requests[0].fingerprint,
            symbolicLinkTarget: nil,
            typeDescription: "Data"
        )
        let right = ComparisonEntry(
            relativePath: path,
            url: requests[1].url,
            kind: .regularFile,
            fingerprint: requests[1].fingerprint,
            symbolicLinkTarget: nil,
            typeDescription: "Data"
        )
        return ComparisonRow(relativePath: path, left: left, right: right, status: .checking(nil))
    }

    private static func request(for url: URL) throws -> ChecksumRequest {
        var information = stat()
        let status = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.lstat(path, &information)
        }
        guard status == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let identity = "\(UInt64(information.st_dev)):\(UInt64(information.st_ino))"
        let modifiedAt = Date(
            timeIntervalSince1970: TimeInterval(information.st_mtimespec.tv_sec)
                + TimeInterval(information.st_mtimespec.tv_nsec) / 1_000_000_000
        )
        return ChecksumRequest(
            url: url,
            fingerprint: .init(
                identity: .init(entryIdentifier: identity, resolvedIdentifier: identity),
                byteSize: Int64(information.st_size),
                modifiedAt: modifiedAt,
                rawModifiedAt: .init(
                    seconds: Int64(information.st_mtimespec.tv_sec),
                    nanoseconds: Int64(information.st_mtimespec.tv_nsec)
                )
            )
        )
    }
}

private func setModificationTime(_ url: URL, to timestamp: ComparisonModificationTimestamp) throws {
    var times = [
        timespec(tv_sec: Int(timestamp.seconds), tv_nsec: Int(timestamp.nanoseconds)),
        timespec(tv_sec: Int(timestamp.seconds), tv_nsec: Int(timestamp.nanoseconds))
    ]
    let status = url.withUnsafeFileSystemRepresentation { path in
        guard let path else { return Int32(-1) }
        return times.withUnsafeMutableBufferPointer { buffer in
            Darwin.utimensat(AT_FDCWD, path, buffer.baseAddress, AT_SYMLINK_NOFOLLOW)
        }
    }
    guard status == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

final class ChecksumFilePair: @unchecked Sendable {
    let directory: TemporaryDirectory
    let leftRequest: ChecksumRequest
    let rightRequest: ChecksumRequest

    init(
        directory: TemporaryDirectory,
        leftRequest: ChecksumRequest,
        rightRequest: ChecksumRequest
    ) throws {
        self.directory = directory
        self.leftRequest = leftRequest
        self.rightRequest = rightRequest
    }

    deinit {
        directory.remove()
    }
}

final class ReplacingChecksumFixture: @unchecked Sendable {
    let directory: TemporaryDirectory
    let service: LiveChecksumService
    let request: ChecksumRequest
    private let replacement: ReplacementCoordinator

    init(
        directory: TemporaryDirectory,
        service: LiveChecksumService,
        request: ChecksumRequest,
        target: URL,
        replacement: URL
    ) throws {
        self.directory = directory
        self.service = service
        self.request = request
        self.replacement = ReplacementCoordinator(target: target, replacement: replacement)
    }

    func replaceAfterFirstChunk() async {
        await replacement.replaceOnce()
    }

    deinit {
        directory.remove()
    }
}

final class NanosecondMutationChecksumFixture: @unchecked Sendable {
    let directory: TemporaryDirectory
    let service: LiveChecksumService
    let request: ChecksumRequest
    let changedRawModifiedAt: ComparisonModificationTimestamp
    private let mutation: NanosecondMutationCoordinator

    var changedModifiedAt: Date {
        Date(
            timeIntervalSince1970: TimeInterval(changedRawModifiedAt.seconds)
                + TimeInterval(changedRawModifiedAt.nanoseconds) / 1_000_000_000
        )
    }

    init(
        directory: TemporaryDirectory,
        service: LiveChecksumService,
        request: ChecksumRequest,
        target: URL,
        changedRawModifiedAt: ComparisonModificationTimestamp
    ) throws {
        self.directory = directory
        self.service = service
        self.request = request
        self.changedRawModifiedAt = changedRawModifiedAt
        mutation = NanosecondMutationCoordinator(target: target, timestamp: changedRawModifiedAt)
    }

    func mutateAfterFirstChunk() async {
        await mutation.mutateOnce()
    }

    deinit {
        directory.remove()
    }
}

final class SizeMutationChecksumFixture: @unchecked Sendable {
    let directory: TemporaryDirectory
    let service: LiveChecksumService
    let request: ChecksumRequest
    private let mutation: SizeMutationCoordinator

    init(
        directory: TemporaryDirectory,
        service: LiveChecksumService,
        request: ChecksumRequest,
        target: URL
    ) throws {
        self.directory = directory
        self.service = service
        self.request = request
        mutation = SizeMutationCoordinator(target: target)
    }

    func mutateAfterFirstChunk() async {
        await mutation.mutateOnce()
    }

    deinit {
        directory.remove()
    }
}

private actor ReplacementCoordinator {
    private var hasReplaced = false
    private let target: URL
    private let replacement: URL

    init(target: URL, replacement: URL) {
        self.target = target
        self.replacement = replacement
    }

    func replaceOnce() {
        guard !hasReplaced else { return }
        hasReplaced = true
        _ = replacement.withUnsafeFileSystemRepresentation { replacementPath in
            target.withUnsafeFileSystemRepresentation { targetPath in
                guard let replacementPath, let targetPath else { return Int32(-1) }
                return Darwin.rename(replacementPath, targetPath)
            }
        }
    }
}

private actor NanosecondMutationCoordinator {
    private var hasMutated = false
    private let target: URL
    private let timestamp: ComparisonModificationTimestamp

    init(target: URL, timestamp: ComparisonModificationTimestamp) {
        self.target = target
        self.timestamp = timestamp
    }

    func mutateOnce() {
        guard !hasMutated else { return }
        hasMutated = true
        try? setModificationTime(target, to: timestamp)
    }
}

private actor SizeMutationCoordinator {
    private var hasMutated = false
    private let target: URL

    init(target: URL) {
        self.target = target
    }

    func mutateOnce() {
        guard !hasMutated else { return }
        hasMutated = true
        guard let handle = try? FileHandle(forWritingTo: target) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: Data([0x66]))
        } catch {}
    }
}

actor ChecksumProgressRecorder {
    private(set) var values: [Double] = []

    func record(_ value: Double) {
        values.append(value)
    }
}
