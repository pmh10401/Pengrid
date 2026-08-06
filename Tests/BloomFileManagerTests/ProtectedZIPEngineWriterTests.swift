import Darwin
import EncryptedZIPCore
import Foundation
import Testing
@testable import BloomFileManager

@_silgen_name("pengrid_fd_stream_create")
private func testPengridFDStreamCreate(_ descriptor: Int32) -> UnsafeMutableRawPointer?

@_silgen_name("mz_zip_reader_create")
private func testMZZipReaderCreate() -> UnsafeMutableRawPointer?

@_silgen_name("mz_zip_reader_delete")
private func testMZZipReaderDelete(_ handle: UnsafeMutablePointer<UnsafeMutableRawPointer?>)

@_silgen_name("mz_zip_reader_open")
private func testMZZipReaderOpen(_ handle: UnsafeMutableRawPointer?, _ stream: UnsafeMutableRawPointer?) -> Int32

@_silgen_name("mz_zip_reader_close")
private func testMZZipReaderClose(_ handle: UnsafeMutableRawPointer?) -> Int32

@_silgen_name("mz_zip_reader_set_password")
private func testMZZipReaderSetPassword(_ handle: UnsafeMutableRawPointer?, _ password: UnsafePointer<CChar>?)

@_silgen_name("mz_zip_reader_goto_first_entry")
private func testMZZipReaderGotoFirstEntry(_ handle: UnsafeMutableRawPointer?) -> Int32

@_silgen_name("mz_zip_reader_locate_entry")
private func testMZZipReaderLocateEntry(_ handle: UnsafeMutableRawPointer?, _ name: UnsafePointer<CChar>?, _ ignoreCase: UInt8) -> Int32

@_silgen_name("mz_zip_reader_entry_open")
private func testMZZipReaderEntryOpen(_ handle: UnsafeMutableRawPointer?) -> Int32

@_silgen_name("mz_zip_reader_entry_read")
private func testMZZipReaderEntryRead(_ handle: UnsafeMutableRawPointer?, _ buffer: UnsafeMutableRawPointer?, _ length: Int32) -> Int32

@_silgen_name("mz_zip_reader_entry_close")
private func testMZZipReaderEntryClose(_ handle: UnsafeMutableRawPointer?) -> Int32

@_silgen_name("mz_stream_delete")
private func testMZStreamDelete(_ stream: UnsafeMutablePointer<UnsafeMutableRawPointer?>)

private enum ProtectedZIPReaderTestError: Error {
    case open(Int32)
    case read(Int32)
    case close(Int32)
    case missingStream
    case missingReader
}

private struct ArchiveEntryStructure: Equatable {
    let name: String
    let compressionMethod: UInt16
    let aesStrength: UInt8
    let aesVendorMethod: UInt16
    let hasZIP64Extra: Bool
    let flags: UInt16
    let compressedSize: UInt64
    let uncompressedSize: UInt64
    let externalAttributes: UInt32
    let modifiedDate: UInt16
    let modifiedTime: UInt16
    let localHeaderOffset: UInt64
    let dataOffset: Int
}

private struct ArchiveStructure {
    let eocdDiskNumber: UInt16
    let eocdCentralDirectoryDiskNumber: UInt16
    let entries: [ArchiveEntryStructure]

    var entryNames: [String] { entries.map(\.name) }
}

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
        let linkTargetBytes = try readSymbolicLinkBytes(source.appending(path: "링크"))
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
        #expect(archive.containsSubsequence(Array(expectedName.utf8)))
        #expect(archive.containsSubsequence(Array(linkTargetBytes)))
        #expect(archive.containsSubsequence([0x01, 0x00])) // ZIP64 extra-field identifier
        let structure = try parseArchiveStructure(archive)
        #expect(Set(structure.entryNames) == Set([
            "한국어/".decomposedStringWithCanonicalMapping,
            expectedName,
            "한국어/😀/".decomposedStringWithCanonicalMapping,
            "링크".decomposedStringWithCanonicalMapping
        ]))
        let linkName = "링크".decomposedStringWithCanonicalMapping
        let linkEntry = try #require(structure.entries.first { $0.name == linkName })
        #expect(linkEntry.compressionMethod == 99)
        #expect(linkEntry.aesStrength == 3)
        #expect(linkEntry.aesVendorMethod == 0)
        #expect(linkEntry.hasZIP64Extra)
        #expect(try readAESArchiveEntry(at: archiveURL, password: "unicode-passphrase", entryName: linkName) == linkTargetBytes)
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

    @Test func writerSupportsMaximumLengthPasswordAndReaderAuthenticatesBytes() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let source = root.url.appending(path: "source", directoryHint: .isDirectory)
        let archiveURL = root.url.appending(path: "archive.zip")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let payload = Data((0..<4096).map { UInt8(truncatingIfNeeded: $0) })
        try payload.write(to: source.appending(path: "payload.bin"))
        let sourceItem = try openedDirectory(source)
        defer { sourceItem.close() }
        let destination = try createDestination(archiveURL)
        defer { Darwin.close(destination.descriptor) }
        let password = String(repeating: "p", count: 256)
        let secret = try ArchiveSecret.creation(password: password, confirmation: password)
        try await LiveProtectedZIPEngine().createAES256(
            sourceRoot: sourceItem,
            destination: destination,
            password: secret,
            progress: { _ in }
        )

        #expect(try readFirstAESArchiveEntry(at: archiveURL, password: password) == payload)
        #expect(try Data(contentsOf: archiveURL).containsSubsequence(Array(password.utf8)) == false)
    }

    @Test func writerArchiveHasUnsplitEOCDAndStructuredAESZIP64Metadata() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let source = root.url.appending(path: "source", directoryHint: .isDirectory)
        let archiveURL = root.url.appending(path: "archive.zip")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try Data("one".utf8).write(to: source.appending(path: "z.txt"))
        try Data("two".utf8).write(to: source.appending(path: "a.txt"))
        let sourceItem = try openedDirectory(source)
        defer { sourceItem.close() }
        let destination = try createDestination(archiveURL)
        defer { Darwin.close(destination.descriptor) }
        let password = "structured-password"
        let secret = try ArchiveSecret.creation(password: password, confirmation: password)
        try await LiveProtectedZIPEngine().createAES256(
            sourceRoot: sourceItem,
            destination: destination,
            password: secret,
            progress: { _ in }
        )

        let structure = try parseArchiveStructure(Data(contentsOf: archiveURL))
        #expect(structure.eocdDiskNumber == 0)
        #expect(structure.eocdCentralDirectoryDiskNumber == 0)
        #expect(structure.entryNames == ["a.txt", "z.txt"])
        #expect(structure.entries.allSatisfy { entry in
            entry.compressionMethod == 99 && entry.aesStrength == 3 && entry.aesVendorMethod == 8 && entry.hasZIP64Extra
        })
    }

    @Test func parserUsesCentralDirectoryWhenLocalDescriptorSizesAreZero() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let source = root.url.appending(path: "source", directoryHint: .isDirectory)
        let archiveURL = root.url.appending(path: "archive.zip")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try Data(repeating: 0x11, count: 128).write(to: source.appending(path: "z.bin"))
        try Data(repeating: 0x22, count: 256).write(to: source.appending(path: "a.bin"))
        let sourceItem = try openedDirectory(source)
        defer { sourceItem.close() }
        let destination = try createDestination(archiveURL)
        defer { Darwin.close(destination.descriptor) }
        let password = "central-directory-parser-password"
        let secret = try ArchiveSecret.creation(password: password, confirmation: password)
        try await LiveProtectedZIPEngine().createAES256(
            sourceRoot: sourceItem,
            destination: destination,
            password: secret,
            progress: { _ in }
        )

        let original = try parseArchiveStructure(Data(contentsOf: archiveURL))
        var localSizesZero = try Data(contentsOf: archiveURL)
        for entry in original.entries {
            let localOffset = Int(entry.localHeaderOffset)
            setLittleEndianUInt32(&localSizesZero, at: localOffset + 18, value: 0)
            setLittleEndianUInt32(&localSizesZero, at: localOffset + 22, value: 0)
        }
        let reparsed = try parseArchiveStructure(localSizesZero)
        #expect(reparsed.entryNames == original.entryNames)
        #expect(reparsed.entries.map(\.dataOffset) == original.entries.map(\.dataOffset))
        #expect(reparsed.entries.map(\.compressedSize) == original.entries.map(\.compressedSize))
    }

    @Test func readerRejectsTamperedEncryptedPayload() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let source = root.url.appending(path: "source", directoryHint: .isDirectory)
        let archiveURL = root.url.appending(path: "archive.zip")
        let tamperedURL = root.url.appending(path: "tampered.zip")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try Data(repeating: 0x2A, count: 4_096).write(to: source.appending(path: "payload.bin"))
        let sourceItem = try openedDirectory(source)
        defer { sourceItem.close() }
        let destination = try createDestination(archiveURL)
        defer { Darwin.close(destination.descriptor) }
        let password = "tamper-detection-password"
        let secret = try ArchiveSecret.creation(password: password, confirmation: password)
        try await LiveProtectedZIPEngine().createAES256(
            sourceRoot: sourceItem,
            destination: destination,
            password: secret,
            progress: { _ in }
        )

        var bytes = try Data(contentsOf: archiveURL)
        let structure = try parseArchiveStructure(bytes)
        guard let entry = structure.entries.first else { throw ProtectedZIPReaderTestError.read(-1) }
        let ciphertextOffset = entry.dataOffset + 18 // AES-256 salt (16) + verifier (2)
        guard ciphertextOffset < entry.dataOffset + Int(entry.compressedSize) - 10 else {
            throw ProtectedZIPReaderTestError.read(-1)
        }
        bytes[ciphertextOffset] ^= 0x01
        try bytes.write(to: tamperedURL)
        #expect(throws: ProtectedZIPReaderTestError.self) {
            _ = try readFirstAESArchiveEntry(at: tamperedURL, password: password)
        }

        let authTamperedURL = root.url.appending(path: "auth-tampered.zip")
        var authTampered = try Data(contentsOf: archiveURL)
        let authOffset = entry.dataOffset + Int(entry.compressedSize) - 10
        guard authOffset >= entry.dataOffset, authOffset + 10 <= authTampered.count else {
            throw ProtectedZIPReaderTestError.read(-1)
        }
        authTampered[authOffset] ^= 0x01
        try authTampered.write(to: authTamperedURL)
        #expect(throws: ProtectedZIPReaderTestError.self) {
            _ = try readFirstAESArchiveEntry(at: authTamperedURL, password: password)
        }
    }

    @Test func writerPreservesDeterministicOrderModesAndDOSModificationTimes() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let source = root.url.appending(path: "source", directoryHint: .isDirectory)
        let archiveURL = root.url.appending(path: "archive.zip")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let firstURL = source.appending(path: "z.txt")
        let secondURL = source.appending(path: "a.txt")
        try Data("z".utf8).write(to: firstURL)
        try Data("a".utf8).write(to: secondURL)
        #expect(firstURL.path.withCString { Darwin.chmod($0, mode_t(0o740)) } == 0)
        #expect(secondURL.path.withCString { Darwin.chmod($0, mode_t(0o604)) } == 0)
        let firstDate = Date(timeIntervalSince1970: 1_700_000_000)
        let secondDate = Date(timeIntervalSince1970: 1_700_000_100)
        try FileManager.default.setAttributes([.modificationDate: firstDate], ofItemAtPath: firstURL.path)
        try FileManager.default.setAttributes([.modificationDate: secondDate], ofItemAtPath: secondURL.path)
        let firstInformation = try fileStat(firstURL)
        let secondInformation = try fileStat(secondURL)

        let sourceItem = try openedDirectory(source)
        defer { sourceItem.close() }
        let destination = try createDestination(archiveURL)
        defer { Darwin.close(destination.descriptor) }
        let password = "metadata-round-trip-password"
        let secret = try ArchiveSecret.creation(password: password, confirmation: password)
        try await LiveProtectedZIPEngine().createAES256(
            sourceRoot: sourceItem,
            destination: destination,
            password: secret,
            progress: { _ in }
        )

        let structure = try parseArchiveStructure(Data(contentsOf: archiveURL))
        #expect(structure.entryNames == ["a.txt", "z.txt"])
        let first = try #require(structure.entries.first { $0.name == "a.txt" })
        let second = try #require(structure.entries.first { $0.name == "z.txt" })
        #expect(first.externalAttributes >> 16 & 0o7777 == UInt32(secondInformation.st_mode & 0o7777))
        #expect(second.externalAttributes >> 16 & 0o7777 == UInt32(firstInformation.st_mode & 0o7777))
        #expect(abs(dosDateTime(first.modifiedDate, first.modifiedTime).distance(to: secondDate)) <= 2)
        #expect(abs(dosDateTime(second.modifiedDate, second.modifiedTime).distance(to: firstDate)) <= 2)
    }

    @Test func writerRejectsMutationAfterEnumerationBeforeOpen() throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let source = root.url.appending(path: "source", directoryHint: .isDirectory)
        let archiveURL = root.url.appending(path: "archive.zip")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let payloadURL = source.appending(path: "payload.bin")
        try Data(repeating: 0x5A, count: 1024).write(to: payloadURL)
        let sourceItem = try openedDirectory(source)
        defer { sourceItem.close() }
        let destination = try createDestination(archiveURL)
        defer { Darwin.close(destination.descriptor) }
        let password = Array("mutation-race-password".utf8)
        let context = MutationRaceContext(url: payloadURL)
        let status = try sourceItem.withUnsafeDescriptor { sourceDescriptor in
            password.withUnsafeBufferPointer { passwordBuffer in
                pengrid_zip_create_aes256(
                    sourceDescriptor,
                    destination.descriptor,
                    passwordBuffer.baseAddress,
                    passwordBuffer.count,
                    mutationRaceProgressCallback,
                    Unmanaged.passUnretained(context).toOpaque()
                )
            }
        }
        #expect(context.didMutate)
        #expect(status == PENGRID_ZIP_STATUS_IO_ERROR)
    }

    @Test func writerProgressFinalBoundaryHonorsStrictTenHertz() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let source = root.url.appending(path: "source", directoryHint: .isDirectory)
        let archiveURL = root.url.appending(path: "archive.zip")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try Data("tiny".utf8).write(to: source.appending(path: "payload.txt"))
        let sourceItem = try openedDirectory(source)
        defer { sourceItem.close() }
        let destination = try createDestination(archiveURL)
        defer { Darwin.close(destination.descriptor) }
        let password = "strict-progress-password"
        let secret = try ArchiveSecret.creation(password: password, confirmation: password)
        let progress = ProtectedZIPProgressCollector()
        try await LiveProtectedZIPEngine().createAES256(
            sourceRoot: sourceItem,
            destination: destination,
            password: secret,
            progress: { await progress.append($0) }
        )

        let samples = await progress.samples
        #expect(samples.first?.value.completedByteCount == 0)
        #expect(samples.last?.value.totalByteCount == 4)
        let final = try #require(samples.last)
        #expect(final.value.completedByteCount == 4)
        #expect(final.value.completedByteCount == final.value.totalByteCount)
        #expect(samples.count >= 2)
        for pair in zip(samples, samples.dropFirst()) {
            #expect(pair.0.at.duration(to: pair.1.at) >= .milliseconds(100))
        }
    }

    @Test func writerEmptyInputDeliversExactlyOneLogicalZeroProgressBoundary() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let source = root.url.appending(path: "source", directoryHint: .isDirectory)
        let archiveURL = root.url.appending(path: "archive.zip")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let sourceItem = try openedDirectory(source)
        defer { sourceItem.close() }
        let destination = try createDestination(archiveURL)
        defer { Darwin.close(destination.descriptor) }
        let password = "empty-progress-password"
        let secret = try ArchiveSecret.creation(password: password, confirmation: password)
        let progress = ProtectedZIPProgressCollector()
        try await LiveProtectedZIPEngine().createAES256(
            sourceRoot: sourceItem,
            destination: destination,
            password: secret,
            progress: { await progress.append($0) }
        )

        let values = await progress.values
        #expect(values.count == 1)
        #expect(values == [ProtectedZIPProgress(completedByteCount: 0, totalByteCount: 0)])
    }

    @Test func writerKeepsSlowProgressDeliveryBoundedAndCallerDescriptorsOwned() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let source = root.url.appending(path: "source", directoryHint: .isDirectory)
        let archiveURL = root.url.appending(path: "archive.zip")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try Data(repeating: 0x37, count: 512 * 1_024).write(to: source.appending(path: "payload.bin"))
        let sourceItem = try openedDirectory(source)
        defer { sourceItem.close() }
        let destination = try createDestination(archiveURL)
        defer { Darwin.close(destination.descriptor) }
        #expect(Darwin.lseek(destination.descriptor, 0, SEEK_SET) == 0)
        let password = "slow-progress-password"
        let secret = try ArchiveSecret.creation(password: password, confirmation: password)
        let progress = ProtectedZIPProgressCollector()
        try await LiveProtectedZIPEngine().createAES256(
            sourceRoot: sourceItem,
            destination: destination,
            password: secret,
            progress: {
                await progress.append($0)
                try? await Task.sleep(for: .milliseconds(20))
            }
        )
        let values = await progress.values
        #expect(values.count <= 6)
        #expect(values.map(\.completedByteCount) == values.map(\.completedByteCount).sorted())
        #expect(Darwin.fcntl(destination.descriptor, F_GETFD) >= 0)
        #expect(Darwin.lseek(destination.descriptor, 0, SEEK_CUR) == 0)
        let sourceDescriptorStatus = try sourceItem.withUnsafeDescriptor { Darwin.fcntl($0, F_GETFD) }
        #expect(sourceDescriptorStatus >= 0)
    }
}

private struct ProtectedZIPProgressSample: Sendable {
    let value: ProtectedZIPProgress
    let at: ContinuousClock.Instant
}

private actor ProtectedZIPProgressCollector {
    private(set) var values: [ProtectedZIPProgress] = []
    private(set) var samples: [ProtectedZIPProgressSample] = []

    func append(_ value: ProtectedZIPProgress) {
        values.append(value)
        samples.append(ProtectedZIPProgressSample(value: value, at: .now))
    }
}

private final class MutationRaceContext: @unchecked Sendable {
    let url: URL
    var didMutate = false

    init(url: URL) {
        self.url = url
    }
}

private func mutationRaceProgressCallback(
    _ completed: UInt64,
    _ total: UInt64,
    _ rawContext: UnsafeMutableRawPointer?
) -> Int32 {
    guard completed == 0, let rawContext else { return 0 }
    let context = Unmanaged<MutationRaceContext>.fromOpaque(rawContext).takeUnretainedValue()
    guard !context.didMutate else { return 0 }
    let descriptor = context.url.path.withCString {
        Darwin.open($0, O_WRONLY | O_APPEND | O_CLOEXEC | O_NOFOLLOW)
    }
    guard descriptor >= 0 else { return 1 }
    var marker: UInt8 = 0xA5
    let written = Darwin.write(descriptor, &marker, 1)
    _ = Darwin.close(descriptor)
    guard written == 1 else { return 1 }
    context.didMutate = true
    return 0
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

private func readFirstAESArchiveEntry(at url: URL, password: String) throws -> Data {
    try readAESArchiveEntry(at: url, password: password, entryName: nil)
}

private func readAESArchiveEntry(at url: URL, password: String, entryName: String?) throws -> Data {
    let descriptor = url.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { Darwin.close(descriptor) }

    var stream = testPengridFDStreamCreate(descriptor)
    guard stream != nil else { throw ProtectedZIPReaderTestError.missingStream }
    defer {
        withUnsafeMutablePointer(to: &stream) { testMZStreamDelete($0) }
    }

    var reader: UnsafeMutableRawPointer? = testMZZipReaderCreate()
    guard let readerHandle = reader else { throw ProtectedZIPReaderTestError.missingReader }
    var opened = false
    defer {
        if opened { _ = testMZZipReaderClose(readerHandle) }
        withUnsafeMutablePointer(to: &reader) { testMZZipReaderDelete($0) }
    }

    var status = testMZZipReaderOpen(readerHandle, stream)
    guard status == 0 else { throw ProtectedZIPReaderTestError.open(status) }
    opened = true
    password.withCString { testMZZipReaderSetPassword(readerHandle, $0) }
    if let entryName {
        status = entryName.withCString { testMZZipReaderLocateEntry(readerHandle, $0, 0) }
    } else {
        status = testMZZipReaderGotoFirstEntry(readerHandle)
    }
    guard status == 0 else { throw ProtectedZIPReaderTestError.open(status) }
    status = testMZZipReaderEntryOpen(readerHandle)
    guard status == 0 else { throw ProtectedZIPReaderTestError.open(status) }

    var output = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while true {
        let read = buffer.withUnsafeMutableBytes {
            testMZZipReaderEntryRead(readerHandle, $0.baseAddress, Int32($0.count))
        }
        if read < 0 { throw ProtectedZIPReaderTestError.read(read) }
        if read == 0 { break }
        output.append(contentsOf: buffer.prefix(Int(read)))
    }
    status = testMZZipReaderEntryClose(readerHandle)
    guard status == 0 else { throw ProtectedZIPReaderTestError.close(status) }
    return output
}

private func parseArchiveStructure(_ data: Data) throws -> ArchiveStructure {
    let eocdSignature: UInt32 = 0x06054B50
    let centralSignature: UInt32 = 0x02014B50
    let localSignature: UInt32 = 0x04034B50
    let eocdOffset = try findLastSignature(eocdSignature, in: data)
    let diskNumber = try littleEndianUInt16(data, at: eocdOffset + 4)
    let centralDiskNumber = try littleEndianUInt16(data, at: eocdOffset + 6)
    let centralOffset32 = try littleEndianUInt32(data, at: eocdOffset + 16)
    let centralSize32 = try littleEndianUInt32(data, at: eocdOffset + 12)
    guard centralOffset32 != UInt32.max, centralSize32 != UInt32.max else {
        throw ProtectedZIPReaderTestError.read(-1)
    }
    let centralOffset = Int(centralOffset32)
    let centralEnd = centralOffset + Int(centralSize32)
    guard centralOffset >= 0, centralEnd >= centralOffset, centralEnd <= eocdOffset else {
        throw ProtectedZIPReaderTestError.read(-1)
    }

    var entries: [ArchiveEntryStructure] = []
    var centralCursor = centralOffset
    while centralCursor < centralEnd {
        guard centralCursor + 46 <= centralEnd,
              try littleEndianUInt32(data, at: centralCursor) == centralSignature else {
            throw ProtectedZIPReaderTestError.read(-1)
        }
        let flags = try littleEndianUInt16(data, at: centralCursor + 8)
        let compressionMethod = try littleEndianUInt16(data, at: centralCursor + 10)
        let modifiedTime = try littleEndianUInt16(data, at: centralCursor + 12)
        let modifiedDate = try littleEndianUInt16(data, at: centralCursor + 14)
        let uncompressedSize32 = try littleEndianUInt32(data, at: centralCursor + 24)
        let compressedSize32 = try littleEndianUInt32(data, at: centralCursor + 20)
        let nameLength = Int(try littleEndianUInt16(data, at: centralCursor + 28))
        let extraLength = Int(try littleEndianUInt16(data, at: centralCursor + 30))
        let commentLength = Int(try littleEndianUInt16(data, at: centralCursor + 32))
        let externalAttributes = try littleEndianUInt32(data, at: centralCursor + 38)
        let nameOffset = centralCursor + 46
        let extraOffset = nameOffset + nameLength
        let recordEnd = extraOffset + extraLength + commentLength
        guard recordEnd >= extraOffset, recordEnd <= centralEnd, recordEnd <= data.count else {
            throw ProtectedZIPReaderTestError.read(-1)
        }
        let nameBytes = data[nameOffset..<(nameOffset + nameLength)]
        guard let name = String(bytes: nameBytes, encoding: .utf8) else {
            throw ProtectedZIPReaderTestError.read(-1)
        }
        let extra = try parseArchiveExtras(data, offset: extraOffset, length: extraLength)
        var zip64Index = 0
        let uncompressedSize: UInt64
        if uncompressedSize32 == UInt32.max {
            guard zip64Index < extra.zip64Values.count else { throw ProtectedZIPReaderTestError.read(-1) }
            uncompressedSize = extra.zip64Values[zip64Index]
            zip64Index += 1
        } else {
            uncompressedSize = UInt64(uncompressedSize32)
        }
        let compressedSize: UInt64
        if compressedSize32 == UInt32.max {
            guard zip64Index < extra.zip64Values.count else { throw ProtectedZIPReaderTestError.read(-1) }
            compressedSize = extra.zip64Values[zip64Index]
            zip64Index += 1
        } else {
            compressedSize = UInt64(compressedSize32)
        }
        let localHeaderOffset32 = try littleEndianUInt32(data, at: centralCursor + 42)
        let localHeaderOffset: UInt64
        if localHeaderOffset32 == UInt32.max {
            guard zip64Index < extra.zip64Values.count else { throw ProtectedZIPReaderTestError.read(-1) }
            localHeaderOffset = extra.zip64Values[zip64Index]
        } else {
            localHeaderOffset = UInt64(localHeaderOffset32)
        }
        guard localHeaderOffset <= UInt64(Int.max) else { throw ProtectedZIPReaderTestError.read(-1) }
        let dataOffset = try parseLocalDataOffset(data, at: Int(localHeaderOffset), signature: localSignature)
        guard compressedSize <= UInt64(data.count - dataOffset) else {
            throw ProtectedZIPReaderTestError.read(-1)
        }
        entries.append(
            ArchiveEntryStructure(
                name: name,
                compressionMethod: compressionMethod,
                aesStrength: extra.aesStrength,
                aesVendorMethod: extra.aesVendorMethod,
                hasZIP64Extra: extra.hasZIP64,
                flags: flags,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                externalAttributes: externalAttributes,
                modifiedDate: modifiedDate,
                modifiedTime: modifiedTime,
                localHeaderOffset: localHeaderOffset,
                dataOffset: dataOffset
            )
        )
        centralCursor = recordEnd
    }
    guard centralCursor == centralEnd, !entries.isEmpty || centralOffset == eocdOffset else {
        throw ProtectedZIPReaderTestError.read(-1)
    }
    return ArchiveStructure(
        eocdDiskNumber: diskNumber,
        eocdCentralDirectoryDiskNumber: centralDiskNumber,
        entries: entries
    )
}

private struct ParsedArchiveExtras {
    var aesStrength: UInt8 = 0
    var aesVendorMethod: UInt16 = 0
    var hasZIP64 = false
    var zip64Values: [UInt64] = []
}

private func parseArchiveExtras(_ data: Data, offset: Int, length: Int) throws -> ParsedArchiveExtras {
    var result = ParsedArchiveExtras()
    var cursor = offset
    let end = offset + length
    while cursor + 4 <= end {
        let fieldType = try littleEndianUInt16(data, at: cursor)
        let fieldLength = Int(try littleEndianUInt16(data, at: cursor + 2))
        let payload = cursor + 4
        guard payload + fieldLength <= end else { throw ProtectedZIPReaderTestError.read(-1) }
        if fieldType == 0x9901, fieldLength >= 7 {
            result.aesStrength = data[payload + 4]
            result.aesVendorMethod = try littleEndianUInt16(data, at: payload + 5)
        } else if fieldType == 0x0001 {
            result.hasZIP64 = true
            guard fieldLength % 8 == 0 else { throw ProtectedZIPReaderTestError.read(-1) }
            for valueOffset in stride(from: payload, to: payload + fieldLength, by: 8) {
                result.zip64Values.append(try littleEndianUInt64(data, at: valueOffset))
            }
        }
        cursor = payload + fieldLength
    }
    return result
}

private func parseLocalDataOffset(_ data: Data, at offset: Int, signature: UInt32) throws -> Int {
    guard offset >= 0, offset + 30 <= data.count,
          try littleEndianUInt32(data, at: offset) == signature else {
        throw ProtectedZIPReaderTestError.read(-1)
    }
    let nameLength = Int(try littleEndianUInt16(data, at: offset + 26))
    let extraLength = Int(try littleEndianUInt16(data, at: offset + 28))
    let dataOffset = offset + 30 + nameLength + extraLength
    guard dataOffset >= offset, dataOffset <= data.count else {
        throw ProtectedZIPReaderTestError.read(-1)
    }
    return dataOffset
}

private func findLastSignature(_ signature: UInt32, in data: Data) throws -> Int {
    guard data.count >= 4 else { throw ProtectedZIPReaderTestError.read(-1) }
    for offset in stride(from: data.count - 4, through: 0, by: -1) {
        if try littleEndianUInt32(data, at: offset) == signature { return offset }
    }
    throw ProtectedZIPReaderTestError.read(-1)
}

private func littleEndianUInt16(_ data: Data, at offset: Int) throws -> UInt16 {
    guard offset >= 0, offset + 2 <= data.count else { throw ProtectedZIPReaderTestError.read(-1) }
    return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
}

private func littleEndianUInt32(_ data: Data, at offset: Int) throws -> UInt32 {
    guard offset >= 0, offset + 4 <= data.count else { throw ProtectedZIPReaderTestError.read(-1) }
    return UInt32(data[offset]) |
        (UInt32(data[offset + 1]) << 8) |
        (UInt32(data[offset + 2]) << 16) |
        (UInt32(data[offset + 3]) << 24)
}

private func setLittleEndianUInt32(_ data: inout Data, at offset: Int, value: UInt32) {
    data[offset] = UInt8(truncatingIfNeeded: value)
    data[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    data[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
    data[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
}

private func littleEndianUInt64(_ data: Data, at offset: Int) throws -> UInt64 {
    var value: UInt64 = 0
    guard offset >= 0, offset + 8 <= data.count else { throw ProtectedZIPReaderTestError.read(-1) }
    for index in 0..<8 {
        value |= UInt64(data[offset + index]) << (index * 8)
    }
    return value
}

private func fileStat(_ url: URL) throws -> stat {
    let descriptor = url.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    defer { Darwin.close(descriptor) }
    var information = stat()
    guard Darwin.fstat(descriptor, &information) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return information
}

private func dosDateTime(_ date: UInt16, _ time: UInt16) -> Date {
    var components = tm()
    components.tm_year = Int32(((date >> 9) & 0x7F) + 1980 - 1900)
    components.tm_mon = Int32(((date >> 5) & 0x0F) - 1)
    components.tm_mday = Int32(date & 0x1F)
    components.tm_hour = Int32((time >> 11) & 0x1F)
    components.tm_min = Int32((time >> 5) & 0x3F)
    components.tm_sec = Int32((time & 0x1F) * 2)
    components.tm_isdst = -1
    let seconds = mktime(&components)
    return Date(timeIntervalSince1970: TimeInterval(seconds))
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

private func readSymbolicLinkBytes(_ url: URL) throws -> Data {
    var bytes = [UInt8](repeating: 0, count: Int(PATH_MAX))
    let length = url.path.withCString { pathPointer in
        bytes.withUnsafeMutableBytes { buffer in
            Darwin.readlink(pathPointer, buffer.baseAddress, buffer.count)
        }
    }
    guard length >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    guard length < bytes.count else { throw POSIXError(.ENAMETOOLONG) }
    return Data(bytes.prefix(Int(length)))
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
