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
        bytes[entry.dataOffset + 16] ^= 0x01
        try bytes.write(to: tamperedURL)
        #expect(throws: ProtectedZIPReaderTestError.self) {
            _ = try readFirstAESArchiveEntry(at: tamperedURL, password: password)
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
    let centralOffset = Int(try littleEndianUInt32(data, at: eocdOffset + 16))
    guard centralOffset >= 0, centralOffset < data.count else {
        throw ProtectedZIPReaderTestError.read(-1)
    }

    var localCursor = 0
    var localDataOffsets: [Int: Int] = [:]
    while localCursor + 4 <= centralOffset,
          try littleEndianUInt32(data, at: localCursor) == localSignature {
        let compressedSize32 = try littleEndianUInt32(data, at: localCursor + 18)
        let nameLength = Int(try littleEndianUInt16(data, at: localCursor + 26))
        let extraLength = Int(try littleEndianUInt16(data, at: localCursor + 28))
        let dataOffset = localCursor + 30 + nameLength + extraLength
        guard dataOffset <= data.count else { throw ProtectedZIPReaderTestError.read(-1) }
        let compressedSize: UInt64
        if compressedSize32 == UInt32.max {
            compressedSize = try zip64CompressedSize(data, extraOffset: localCursor + 30 + nameLength, extraLength: extraLength)
        } else {
            compressedSize = UInt64(compressedSize32)
        }
        guard compressedSize <= UInt64(data.count - dataOffset) else {
            throw ProtectedZIPReaderTestError.read(-1)
        }
        localDataOffsets[localCursor] = dataOffset
        localCursor = dataOffset + Int(compressedSize)
    }

    var entries: [ArchiveEntryStructure] = []
    var centralCursor = centralOffset
    while centralCursor + 4 <= data.count,
          try littleEndianUInt32(data, at: centralCursor) == centralSignature {
        let compressionMethod = try littleEndianUInt16(data, at: centralCursor + 10)
        let compressedSize32 = try littleEndianUInt32(data, at: centralCursor + 20)
        let nameLength = Int(try littleEndianUInt16(data, at: centralCursor + 28))
        let extraLength = Int(try littleEndianUInt16(data, at: centralCursor + 30))
        let commentLength = Int(try littleEndianUInt16(data, at: centralCursor + 32))
        let nameOffset = centralCursor + 46
        let extraOffset = nameOffset + nameLength
        guard extraOffset + extraLength + commentLength <= data.count else {
            throw ProtectedZIPReaderTestError.read(-1)
        }
        let nameBytes = data[nameOffset..<(nameOffset + nameLength)]
        guard let name = String(bytes: nameBytes, encoding: .utf8) else {
            throw ProtectedZIPReaderTestError.read(-1)
        }
        let extra = try parseArchiveExtras(data, offset: extraOffset, length: extraLength)
        let localHeaderOffset32 = try littleEndianUInt32(data, at: centralCursor + 42)
        let localHeaderOffset: UInt64? = localHeaderOffset32 == UInt32.max
            ? extra.zip64LocalHeaderOffset
            : UInt64(localHeaderOffset32)
        let dataOffset = localHeaderOffset.flatMap { localDataOffsets[Int($0)] } ?? 0
        _ = compressedSize32
        entries.append(
            ArchiveEntryStructure(
                name: name,
                compressionMethod: compressionMethod,
                aesStrength: extra.aesStrength,
                aesVendorMethod: extra.aesVendorMethod,
                hasZIP64Extra: extra.hasZIP64,
                dataOffset: dataOffset
            )
        )
        centralCursor = extraOffset + extraLength + commentLength
    }
    guard !entries.isEmpty || centralOffset == eocdOffset else {
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
    var zip64LocalHeaderOffset: UInt64?
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
            if fieldLength >= 24 {
                result.zip64LocalHeaderOffset = try littleEndianUInt64(data, at: payload + 16)
            }
        }
        cursor = payload + fieldLength
    }
    return result
}

private func zip64CompressedSize(_ data: Data, extraOffset: Int, extraLength: Int) throws -> UInt64 {
    var cursor = extraOffset
    let end = extraOffset + extraLength
    while cursor + 4 <= end {
        let fieldType = try littleEndianUInt16(data, at: cursor)
        let fieldLength = Int(try littleEndianUInt16(data, at: cursor + 2))
        let payload = cursor + 4
        guard payload + fieldLength <= end else { throw ProtectedZIPReaderTestError.read(-1) }
        if fieldType == 0x0001 {
            guard fieldLength >= 16 else { throw ProtectedZIPReaderTestError.read(-1) }
            return try littleEndianUInt64(data, at: payload + 8)
        }
        cursor = payload + fieldLength
    }
    throw ProtectedZIPReaderTestError.read(-1)
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

private func littleEndianUInt64(_ data: Data, at offset: Int) throws -> UInt64 {
    var value: UInt64 = 0
    guard offset >= 0, offset + 8 <= data.count else { throw ProtectedZIPReaderTestError.read(-1) }
    for index in 0..<8 {
        value |= UInt64(data[offset + index]) << (index * 8)
    }
    return value
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
