import Darwin
import EncryptedZIPCore
import Foundation
import Testing
@testable import BloomFileManager

@Suite("ProtectedZIPEngineWriterTests", .serialized)
struct ProtectedZIPEngineWriterTests {
    @Test func writerCreatesAES256WithoutPuttingSecretInMetadata() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let source = root.url.appending(path: "source", directoryHint: .isDirectory)
        let archiveURL = root.url.appending(path: "archive.zip")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let payload = Data("writer payload".utf8)
        try payload.write(to: source.appending(path: "payload.txt"))

        let sourceItem = try openedDirectory(source)
        defer { sourceItem.close() }
        let destination = try createDestination(archiveURL)
        defer { Darwin.close(destination.descriptor) }
        let archiveForReading = try openedRegularFile(archiveURL)
        defer { archiveForReading.close() }
        let secretText = "public-writer-test-passphrase"
        let secret = try ArchiveSecret.creation(password: secretText, confirmation: secretText)
        let progress = ProtectedZIPProgressCollector()
        let engine = LiveProtectedZIPEngine()

        try await engine.createAES256(
            sourceRoot: sourceItem,
            destination: destination,
            password: secret,
            progress: { await progress.append($0) }
        )

        let inspection = try await engine.inspect(archive: archiveForReading)
        #expect(inspection.hasEncryptedEntries)
        #expect(inspection.strongestAESStrength == 256)
        #expect(try Data(contentsOf: archiveURL).range(of: Data(secretText.utf8)) == nil)
        #expect(await progress.values.last?.completedByteCount == Int64(payload.count))
        #expect(await progress.values.first?.completedByteCount == 0)
        let completedValues = await progress.values.map(\.completedByteCount)
        #expect(completedValues == completedValues.sorted())
    }

    @Test func writerStoresEmptyFileNestedUnicodeNamesAndSymlinkTargetBytes() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let source = root.url.appending(path: "source", directoryHint: .isDirectory)
        let archiveURL = root.url.appending(path: "archive.zip")
        let nested = source.appending(path: "한국어/😀", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data().write(to: nested.appending(path: "빈 파일.txt"))
        let linkTarget = "빈 파일.txt"
        try FileManager.default.createSymbolicLink(
            at: source.appending(path: "링크"),
            withDestinationURL: URL(filePath: linkTarget)
        )
        let sourceItem = try openedDirectory(source)
        defer { sourceItem.close() }
        let destination = try createDestination(archiveURL)
        defer { Darwin.close(destination.descriptor) }
        let secret = try ArchiveSecret.creation(password: "unicode-passphrase", confirmation: "unicode-passphrase")
        let engine = LiveProtectedZIPEngine()

        try await engine.createAES256(
            sourceRoot: sourceItem,
            destination: destination,
            password: secret,
            progress: { _ in }
        )

        let archive = try Data(contentsOf: archiveURL)
        let expectedName = "한국어/😀/빈 파일.txt".decomposedStringWithCanonicalMapping
        let expectedTarget = linkTarget.decomposedStringWithCanonicalMapping
        #expect(archive.containsSubsequence(Array(expectedName.utf8)))
        #expect(archive.containsSubsequence(Array(expectedTarget.utf8)))
        #expect(archive.containsSubsequence([0x01, 0x00])) // ZIP64 extra-field identifier
    }

    @Test func writerRejectsFIFOWithoutFollowingIt() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let source = root.url.appending(path: "source", directoryHint: .isDirectory)
        let archiveURL = root.url.appending(path: "archive.zip")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let fifo = source.appending(path: "unsupported.fifo")
        #expect(fifo.path.withCString { Darwin.mkfifo($0, mode_t(S_IRUSR | S_IWUSR)) } == 0)
        let sourceItem = try openedDirectory(source)
        defer { sourceItem.close() }
        let destination = try createDestination(archiveURL)
        defer { Darwin.close(destination.descriptor) }
        let secret = try ArchiveSecret.creation(password: "fifo-passphrase", confirmation: "fifo-passphrase")
        let engine = LiveProtectedZIPEngine()

        await #expect(throws: ProtectedZIPError.unsafeEntry) {
            try await engine.createAES256(
                sourceRoot: sourceItem,
                destination: destination,
                password: secret,
                progress: { _ in }
            )
        }
    }

    @Test func writerCancellationStopsLongEntry() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let source = root.url.appending(path: "source", directoryHint: .isDirectory)
        let archiveURL = root.url.appending(path: "archive.zip")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        var bytes = Data(count: 64 * 1_024 * 1_024)
        for index in stride(from: 0, to: bytes.count, by: 4_096) {
            bytes[index] = UInt8(truncatingIfNeeded: index)
        }
        try bytes.write(to: source.appending(path: "large.bin"))
        let sourceItem = try openedDirectory(source)
        defer { sourceItem.close() }
        let destination = try createDestination(archiveURL)
        defer { Darwin.close(destination.descriptor) }
        let secret = try ArchiveSecret.creation(password: "cancel-passphrase", confirmation: "cancel-passphrase")
        let started = ProtectedZIPStartSignal()
        let cancellationHandle = ProtectedZIPTaskCancellationHandle()
        let engine = LiveProtectedZIPEngine()
        let task = Task {
            try await engine.createAES256(
                sourceRoot: sourceItem,
                destination: destination,
                password: secret,
                progress: { progress in
                    if progress.completedByteCount > 0 {
                        await started.signal()
                        await cancellationHandle.cancel()
                    }
                }
            )
        }
        cancellationHandle.install { task.cancel() }
        #expect(await started.wait(timeout: .seconds(5)))
        await #expect(throws: ProtectedZIPError.cancelled) { try await task.value }
    }
}

private actor ProtectedZIPProgressCollector {
    private(set) var values: [ProtectedZIPProgress] = []

    func append(_ value: ProtectedZIPProgress) {
        values.append(value)
    }
}

private actor ProtectedZIPStartSignal {
    private var signaled = false

    func signal() {
        signaled = true
    }

    func wait(timeout: Duration) async -> Bool {
        let start = ContinuousClock.now
        while !signaled {
            if start.duration(to: ContinuousClock.now) >= timeout { return false }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return true
    }
}

private final class ProtectedZIPTaskCancellationHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (() -> Void)?

    func install(_ action: @escaping () -> Void) {
        lock.lock()
        self.action = action
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        let action = self.action
        lock.unlock()
        action?()
    }
}

private func openedDirectory(_ url: URL) throws -> OpenedFileSystemItem {
    let descriptor = url.path.withCString {
        Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    }
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    return OpenedFileSystemItem(identity: archiveTestIdentity(for: url), descriptor: descriptor, url: url)
}

private func openedRegularFile(_ url: URL) throws -> OpenedFileSystemItem {
    let descriptor = url.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    return OpenedFileSystemItem(identity: archiveTestIdentity(for: url), descriptor: descriptor, url: url)
}

private func createDestination(_ url: URL) throws -> OpenedEmptyFileSystemItem {
    let descriptor = url.path.withCString {
        Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(S_IRUSR | S_IWUSR))
    }
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    return OpenedEmptyFileSystemItem(identity: archiveTestIdentity(for: url), descriptor: descriptor)
}

private extension Data {
    func containsSubsequence(_ bytes: [UInt8]) -> Bool {
        guard !bytes.isEmpty, bytes.count <= count else { return false }
        return withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return false }
            for index in 0...(count - bytes.count) {
                if bytes.enumerated().allSatisfy({ base[index + $0.offset] == $0.element }) { return true }
            }
            return false
        }
    }
}
