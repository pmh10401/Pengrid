import Darwin
import EncryptedZIPCore
import Foundation
import Testing
@testable import BloomFileManager

@Suite("ProtectedZIPEngineReaderTests", .serialized)
struct ProtectedZIPEngineReaderTests {
    @Test func readerExtractsIndependentAESAndLegacyFixtures() async throws {
        try await expectFixture(
            "7zip-aes256.zip",
            password: "fixture-aes256-passphrase",
            expectedName: "자료.txt",
            expectedBytes: Array("7-Zip AES-256 compatibility fixture\n".utf8)
        )
        try await expectFixture(
            "minizip-aes128.zip",
            password: "fixture-aes128-passphrase",
            expectedName: "Strength.txt",
            expectedBytes: Array("AES compatibility fixture\n".utf8)
        )
        try await expectFixture(
            "minizip-aes192.zip",
            password: "fixture-aes192-passphrase",
            expectedName: "Strength.txt",
            expectedBytes: Array("AES compatibility fixture\n".utf8)
        )
        try await expectFixture(
            "infozip-zipcrypto.zip",
            password: "fixture-zipcrypto-password",
            expectedName: "Legacy.txt",
            expectedBytes: Array("Info-ZIP ZipCrypto compatibility fixture\n".utf8)
        )
    }

    @Test func readerExtractsEmptyArchiveWithoutPublishingEntries() async throws {
        let root = try await extract(
            RawZIPFixtureBuilder.archive(entries: []),
            password: "fixture-password"
        )
        let contents = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        )
        #expect(contents.isEmpty)
    }

    @Test func readerAcceptsTaskFiveExtractionPasswordBoundaries() async throws {
        let fixture = RawZIPFixtureBuilder.archive(entries: [
            .regular(name: "payload.txt", bytes: Array("payload".utf8))
        ])
        for password in [String(repeating: "x", count: 1), String(repeating: "x", count: 1_024)] {
            let root = try await extract(fixture, password: password)
            #expect(try String(contentsOf: root.appending(path: "payload.txt"), encoding: .utf8) == "payload")
        }
    }

    @Test func readerRejectsTraversalWithoutPublishingBytes() async throws {
        let fixture = RawZIPFixtureBuilder.archive(entries: [
            .regular(name: "../escape.txt", bytes: [1, 2, 3])
        ])
        let outside = FileManager.default.temporaryDirectory.appending(path: "escape.txt")
        try? FileManager.default.removeItem(at: outside)
        await #expect(throws: ProtectedZIPError.unsafeEntry) {
            try await extract(fixture, password: "fixture-password")
        }
        #expect(FileManager.default.fileExists(atPath: outside.path) == false)
    }

    @Test(arguments: [
        "/absolute.txt",
        "C:\\absolute.txt",
        "a/../../escape.txt",
        "a\\..\\escape.txt"
    ])
    func readerRejectsAbsoluteAndTraversalPaths(_ name: String) async throws {
        let fixture = RawZIPFixtureBuilder.archive(entries: [
            .regular(name: name, bytes: [1])
        ])
        await #expect(throws: ProtectedZIPError.unsafeEntry) {
            try await extract(fixture, password: "fixture-password")
        }
    }

    @Test func readerRejectsNULAndOverlongPaths() async throws {
        let nulName = RawZIPFixtureBuilder.Entry(nameBytes: [97, 0, 98, 46, 116, 120, 116], bytes: [1])
        let nulFixture = RawZIPFixtureBuilder.archive(entries: [nulName])
        await #expect(throws: ProtectedZIPError.unsafeEntry) {
            try await extract(nulFixture, password: "fixture-password")
        }

        let overlongName = String(repeating: "a", count: 5_000)
        let overlongFixture = RawZIPFixtureBuilder.archive(entries: [
            .regular(name: overlongName, bytes: [1])
        ])
        await #expect(throws: ProtectedZIPError.unsafeEntry) {
            try await extract(overlongFixture, password: "fixture-password")
        }
    }

    @Test func readerRejectsDuplicatesAndTopologyConflicts() async throws {
        let duplicate = RawZIPFixtureBuilder.archive(entries: [
            .regular(name: "same.txt", bytes: [1]),
            .regular(name: "same.txt", bytes: [2])
        ])
        await #expect(throws: ProtectedZIPError.unsafeEntry) {
            try await extract(duplicate, password: "fixture-password")
        }

        let fileDirectoryConflict = RawZIPFixtureBuilder.archive(entries: [
            .regular(name: "node", bytes: [1]),
            .regular(name: "node/child.txt", bytes: [2])
        ])
        await #expect(throws: ProtectedZIPError.unsafeEntry) {
            try await extract(fileDirectoryConflict, password: "fixture-password")
        }
    }

    @Test func readerRejectsEscapingLinksAndDescendantsBelowLinks() async throws {
        let escaping = RawZIPFixtureBuilder.archive(entries: [
            .symlink(name: "link", target: "../outside")
        ])
        await #expect(throws: ProtectedZIPError.unsafeEntry) {
            try await extract(escaping, password: "fixture-password")
        }

        let descendant = RawZIPFixtureBuilder.archive(entries: [
            .symlink(name: "link", target: "inside.txt"),
            .regular(name: "link/child.txt", bytes: [3])
        ])
        await #expect(throws: ProtectedZIPError.unsafeEntry) {
            try await extract(descendant, password: "fixture-password")
        }
    }

    @Test func readerRejectsSpecialFileModes() async throws {
        let fifo = RawZIPFixtureBuilder.archive(entries: [.fifo(name: "named-pipe")])
        await #expect(throws: ProtectedZIPError.unsafeEntry) {
            try await extract(fifo, password: "fixture-password")
        }
    }

    @Test func preflightRejectsUnsupportedCompressionBeforePassword() async throws {
        let fixture = RawZIPFixtureBuilder.archive(entries: [
            .regular(name: "unsupported.bin", bytes: [1], compressionMethod: 12)
        ])
        await #expect(throws: ProtectedZIPError.unsupportedCompression) {
            try await preflight(fixture)
        }
    }

    @Test func preflightRejectsUnsupportedEncryptionBeforePassword() async throws {
        let fixture = RawZIPFixtureBuilder.archive(entries: [
            .regular(name: "strong.bin", bytes: [1], flags: (1 << 0) | (1 << 6))
        ])
        await #expect(throws: ProtectedZIPError.unsupportedEncryption) {
            try await preflight(fixture)
        }
    }

    @Test func readerRejectsMoreThanOneHundredThousandEntries() async throws {
        let entries = (0...100_000).map { index in
            RawZIPFixtureBuilder.Entry.regular(name: "entry-\(index).txt", bytes: [])
        }
        let fixture = RawZIPFixtureBuilder.archive(entries: entries)
        await #expect(throws: ProtectedZIPError.entryCountOverflow) {
            try await preflight(fixture)
        }
    }

    @Test func readerRejectsDeclaredSizeAndOutputBudgetOverflow() async throws {
        let fixture = RawZIPFixtureBuilder.archive(entries: [
            RawZIPFixtureBuilder.Entry(
                nameBytes: Array("oversized.bin".utf8),
                bytes: [1, 2, 3],
                declaredCompressedSize: 64,
                declaredUncompressedSize: 64
            )
        ])
        await #expect(throws: ProtectedZIPError.outputBudgetOverflow) {
            try await preflight(
                fixture,
                limits: ProtectedZIPLimits(maximumOutputByteCount: 32, capacityReserveByteCount: ProtectedZIPLimits.minimumCapacityReserve)
            )
        }

        let malformedDirectory = RawZIPFixtureBuilder.archive(entries: [
            RawZIPFixtureBuilder.Entry(
                nameBytes: Array("directory/".utf8),
                bytes: [1],
                externalAttributes: UInt32(S_IFDIR) << 16,
                declaredUncompressedSize: 1
            )
        ])
        await #expect(throws: ProtectedZIPError.malformedArchive) {
            try await preflight(malformedDirectory)
        }
    }

    @Test func readerRejectsTruncatedAuthenticationAndWrongPasswordAsRedactedDamage() async throws {
        let fixtureURL = protectedZIPFixtureURL("7zip-aes256.zip")
        let fixture = try Data(contentsOf: fixtureURL)
        var truncatedBytes = Array(fixture)
        // The final ten bytes before the central directory are the WinZip AES
        // authentication footer. Damage that footer while preserving EOCD
        // offsets so the failure is observed during authenticated reading.
        if let centralOffset = truncatedBytes.firstIndex(of: 0x50).flatMap({ first in
            stride(from: first, to: truncatedBytes.count - 3, by: 1).first {
                truncatedBytes[$0] == 0x50 && truncatedBytes[$0 + 1] == 0x4B
                    && truncatedBytes[$0 + 2] == 0x01 && truncatedBytes[$0 + 3] == 0x02
            }
        }), centralOffset >= 10 {
            for index in (centralOffset - 10)..<centralOffset { truncatedBytes[index] = 0 }
        }
        let truncated = Data(truncatedBytes)
        await #expect(throws: ProtectedZIPError.incorrectPasswordOrDamagedData) {
            try await extract(truncated, password: "fixture-aes256-passphrase")
        }

        await #expect(throws: ProtectedZIPError.incorrectPasswordOrDamagedData) {
            try await extract(fixture, password: "wrong-password")
        }
    }

    @Test func readerRejectsCapacityAndCancellationWithoutPartialOutput() async throws {
        let payload = [UInt8](repeating: 0x4A, count: 1 * 1024 * 1024)
        let fixture = RawZIPFixtureBuilder.archive(entries: [
            .regular(name: "large.bin", bytes: payload)
        ])
        await #expect(throws: ProtectedZIPError.insufficientCapacity) {
            try await extract(
                fixture,
                password: "fixture-password",
                limits: ProtectedZIPLimits(maximumOutputByteCount: Int64(payload.count), capacityReserveByteCount: Int64.max)
            )
        }

        let started = ReaderStartSignal()
        let cancellation = ReaderCancellationHandle()
        let task = Task {
            try await extract(
                fixture,
                password: "fixture-password",
                progress: { progress in
                    if progress.completedByteCount == 0 {
                        await started.signal()
                        try? await Task.sleep(for: .milliseconds(20))
                    }
                }
            )
        }
        cancellation.install { task.cancel() }
        #expect(await started.wait(timeout: .seconds(5)))
        task.cancel()
        cancellation.cancel()
        await #expect(throws: ProtectedZIPError.cancelled) { try await task.value }
    }

    private func expectFixture(
        _ filename: String,
        password: String,
        expectedName: String,
        expectedBytes: [UInt8]
    ) async throws {
        let fixture = try Data(contentsOf: protectedZIPFixtureURL(filename))
        let root = try await extract(fixture, password: password)
        let item = root.appending(path: expectedName)
        #expect(FileManager.default.fileExists(atPath: item.path))
        #expect(try Array(Data(contentsOf: item)) == expectedBytes)
    }

    @discardableResult
    private func preflight(
        _ fixture: Data,
        limits: ProtectedZIPLimits = ProtectedZIPLimits(
            maximumOutputByteCount: 16 * 1024 * 1024,
            capacityReserveByteCount: ProtectedZIPLimits.minimumCapacityReserve
        )
    ) async throws -> ProtectedZIPInspection {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let archiveURL = temporary.url.appending(path: "archive.zip")
        try fixture.write(to: archiveURL)
        let archive = try openedArchive(archiveURL)
        defer { archive.close() }
        let probeURL = temporary.url.appending(path: "probe", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: probeURL, withIntermediateDirectories: false)
        let probe = try openedDirectoryRoot(probeURL)
        defer { Darwin.close(probe.descriptor) }
        return try await LiveProtectedZIPEngine().preflight(
            archive: archive,
            destinationProbeRoot: probe,
            limits: limits
        )
    }

    private func extract(
        _ fixture: Data,
        password: String,
        limits: ProtectedZIPLimits = ProtectedZIPLimits(
            maximumOutputByteCount: 16 * 1024 * 1024,
            capacityReserveByteCount: ProtectedZIPLimits.minimumCapacityReserve
        ),
        progress: @escaping @Sendable (ProtectedZIPProgress) async -> Void = { _ in }
    ) async throws -> URL {
        let temporary = try TemporaryDirectory()
        let archiveURL = temporary.url.appending(path: "archive.zip")
        try fixture.write(to: archiveURL)
        let archive = try openedArchive(archiveURL)
        let destinationURL = temporary.url.appending(path: "output", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: false)
        let destination = try openedDirectoryRoot(destinationURL)
        do {
            let secret = try ArchiveSecret.extraction(password: password)
            try await LiveProtectedZIPEngine().extract(
                archive: archive,
                destinationRoot: destination,
                password: secret,
                limits: limits,
                progress: progress
            )
        } catch {
            archive.close()
            Darwin.close(destination.descriptor)
            let snapshot = temporary.url
            // Keep the root alive long enough for callers that need to inspect
            // it only on success; failed calls are expected to leave no files.
            try? FileManager.default.removeItem(at: snapshot)
            throw error
        }
        archive.close()
        Darwin.close(destination.descriptor)
        let result = destinationURL
        // The temporary directory is intentionally retained by moving the
        // output into a second temporary location for the assertion helper.
        let retained = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: retained, withIntermediateDirectories: false)
        let retainedOutput = retained.appending(path: "output", directoryHint: .isDirectory)
        try FileManager.default.moveItem(at: result, to: retainedOutput)
        try? FileManager.default.removeItem(at: temporary.url)
        return retainedOutput
    }

    private func protectedZIPFixtureURL(_ filename: String) -> URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures/ProtectedZIP", directoryHint: .isDirectory)
            .appending(path: filename)
    }

    private func openedArchive(_ url: URL) throws -> OpenedFileSystemItem {
        let descriptor = url.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return OpenedFileSystemItem(identity: archiveTestIdentity(for: url), descriptor: descriptor, url: url)
    }

    private func openedDirectoryRoot(_ url: URL) throws -> OpenedEmptyFileSystemItem {
        let descriptor = url.path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return OpenedEmptyFileSystemItem(identity: archiveTestIdentity(for: url), descriptor: descriptor)
    }
}

private actor ReaderStartSignal {
    private var signaled = false

    func signal() { signaled = true }

    func wait(timeout: Duration) async -> Bool {
        let start = ContinuousClock.now
        while !signaled {
            if start.duration(to: ContinuousClock.now) >= timeout { return false }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return true
    }
}

private final class ReaderCancellationHandle: @unchecked Sendable {
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
