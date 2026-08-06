import Darwin
import EncryptedZIPCore
import Foundation
import Testing

@Test func encryptedZIPCoreIsPinnedAndClearsBuffers() {
    #expect(String(cString: pengrid_zip_core_version()) == "minizip-ng 4.2.2")
    var bytes = Array("public-test-secret".utf8)
    bytes.withUnsafeMutableBytes { buffer in
        pengrid_secure_clear(buffer.baseAddress, buffer.count)
    }
    #expect(bytes.allSatisfy { $0 == 0 })
}

@Test func encryptedZIPCoreInspectsAPlainZIPWithoutConsumingTheCallerDescriptor() throws {
    let root = try TemporaryDirectory()
    defer { root.remove() }
    let source = root.url.appending(path: "source", directoryHint: .isDirectory)
    let payload = source.appending(path: "payload.txt")
    let archive = root.url.appending(path: "archive.zip")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
    try Data("plain zip payload".utf8).write(to: payload)

    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/ditto")
    process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", source.path, archive.path]
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)

    let descriptor = Darwin.open(archive.path, O_RDONLY | O_CLOEXEC)
    #expect(descriptor >= 0)
    defer { Darwin.close(descriptor) }

    var inspection = pengrid_zip_inspection_t()
    #expect(pengrid_zip_inspect_fd(descriptor, &inspection) == 0)
    #expect(inspection.entry_count > 0)
    #expect(inspection.total_uncompressed_bytes > 0)
    #expect(inspection.has_encrypted_entries == 0)
    #expect(inspection.has_unsupported_encryption == 0)
    #expect(inspection.has_unsupported_compression == 0)
    #expect(Darwin.fcntl(descriptor, F_GETFD) >= 0)
}

@Test func encryptedZIPCoreRejectsZIPStrongEncryptionAsUnsupported() throws {
    let root = try TemporaryDirectory()
    defer { root.remove() }
    let archive = root.url.appending(path: "strong.zip")
    try makeInspectionZIP(entries: [
        InspectionZIPEntry(name: "strong.txt", method: 0, flags: 0x0041, payload: Array(repeating: 0, count: 15), uncompressedSize: 3)
    ]).write(to: archive)

    let descriptor = try requireOpenedDescriptor(at: archive)
    defer { Darwin.close(descriptor) }
    var inspection = pengrid_zip_inspection_t()

    #expect(pengrid_zip_inspect_fd(descriptor, &inspection) == 0)
    #expect(inspection.has_encrypted_entries == 1)
    #expect(inspection.has_unsupported_encryption == 1)
    #expect(inspection.strongest_aes_strength == 0)
}

@Test(arguments: [UInt8(1), UInt8(2), UInt8(3)])
func encryptedZIPCoreReportsEachWinZipAESStrength(_ strength: UInt8) throws {
    let root = try TemporaryDirectory()
    defer { root.remove() }
    let archive = root.url.appending(path: "aes-\(strength).zip")
    let saltLength = [0, 8, 12, 16][Int(strength)]
    let payload = Array(repeating: UInt8(strength), count: saltLength + 2 + 1 + 10)
    try makeInspectionZIP(entries: [
        InspectionZIPEntry(
            name: "aes.txt",
            method: 99,
            flags: 0x0001,
            extra: aesExtraField(strength: strength),
            payload: payload,
            uncompressedSize: 1
        )
    ]).write(to: archive)

    let descriptor = try requireOpenedDescriptor(at: archive)
    defer { Darwin.close(descriptor) }
    var inspection = pengrid_zip_inspection_t()

    #expect(pengrid_zip_inspect_fd(descriptor, &inspection) == 0)
    #expect(inspection.entry_count == 1)
    #expect(inspection.has_encrypted_entries == 1)
    #expect(inspection.has_unsupported_encryption == 0)
    #expect(inspection.strongest_aes_strength == strength)
}

@Test func encryptedZIPCoreReportsTraditionalPKWAREAndUnsupportedCompression() throws {
    let root = try TemporaryDirectory()
    defer { root.remove() }
    let archive = root.url.appending(path: "mixed.zip")
    try makeInspectionZIP(entries: [
        InspectionZIPEntry(name: "legacy.txt", method: 0, flags: 0x0001, payload: Array(repeating: 0, count: 15), uncompressedSize: 3),
        InspectionZIPEntry(name: "bzip2.bin", method: 12, flags: 0, payload: [0x42, 0x5a], uncompressedSize: 2)
    ]).write(to: archive)

    let descriptor = try requireOpenedDescriptor(at: archive)
    defer { Darwin.close(descriptor) }
    var inspection = pengrid_zip_inspection_t()

    #expect(pengrid_zip_inspect_fd(descriptor, &inspection) == 0)
    #expect(inspection.entry_count == 2)
    #expect(inspection.total_uncompressed_bytes == 5)
    #expect(inspection.has_encrypted_entries == 1)
    #expect(inspection.has_unsupported_encryption == 0)
    #expect(inspection.has_unsupported_compression == 1)
}

@Test func encryptedZIPCoreReturnsMalformedStatusForTruncatedArchive() throws {
    let root = try TemporaryDirectory()
    defer { root.remove() }
    let archive = root.url.appending(path: "truncated.zip")
    try Data([0x50, 0x4b, 0x03, 0x04, 0x00]).write(to: archive)

    let descriptor = try requireOpenedDescriptor(at: archive)
    defer { Darwin.close(descriptor) }
    var inspection = pengrid_zip_inspection_t()

    #expect(pengrid_zip_inspect_fd(descriptor, &inspection) == -2002)
}

private struct InspectionZIPEntry {
    let name: String
    let method: UInt16
    let flags: UInt16
    var extra: [UInt8] = []
    let payload: [UInt8]
    let uncompressedSize: UInt32
}

private func aesExtraField(strength: UInt8) -> [UInt8] {
    [0x01, 0x99, 0x07, 0x00, 0x02, 0x00, 0x41, 0x45, strength, 0x00, 0x00]
}

private func makeInspectionZIP(entries: [InspectionZIPEntry]) -> Data {
    var bytes: [UInt8] = []
    var localOffsets: [UInt32] = []
    for entry in entries {
        let name = Array(entry.name.utf8)
        localOffsets.append(UInt32(bytes.count))
        appendUInt32(0x0403_4b50, to: &bytes)
        appendUInt16(20, to: &bytes)
        appendUInt16(entry.flags, to: &bytes)
        appendUInt16(entry.method, to: &bytes)
        appendUInt16(0, to: &bytes)
        appendUInt16(0, to: &bytes)
        appendUInt32(0, to: &bytes)
        appendUInt32(UInt32(entry.payload.count), to: &bytes)
        appendUInt32(entry.uncompressedSize, to: &bytes)
        appendUInt16(UInt16(name.count), to: &bytes)
        appendUInt16(UInt16(entry.extra.count), to: &bytes)
        bytes.append(contentsOf: name)
        bytes.append(contentsOf: entry.extra)
        bytes.append(contentsOf: entry.payload)
    }

    let centralOffset = UInt32(bytes.count)
    for (index, entry) in entries.enumerated() {
        let name = Array(entry.name.utf8)
        appendUInt32(0x0201_4b50, to: &bytes)
        appendUInt16(20, to: &bytes)
        appendUInt16(20, to: &bytes)
        appendUInt16(entry.flags, to: &bytes)
        appendUInt16(entry.method, to: &bytes)
        appendUInt16(0, to: &bytes)
        appendUInt16(0, to: &bytes)
        appendUInt32(0, to: &bytes)
        appendUInt32(UInt32(entry.payload.count), to: &bytes)
        appendUInt32(entry.uncompressedSize, to: &bytes)
        appendUInt16(UInt16(name.count), to: &bytes)
        appendUInt16(UInt16(entry.extra.count), to: &bytes)
        appendUInt16(0, to: &bytes)
        appendUInt16(0, to: &bytes)
        appendUInt16(0, to: &bytes)
        appendUInt32(0, to: &bytes)
        appendUInt32(localOffsets[index], to: &bytes)
        bytes.append(contentsOf: name)
        bytes.append(contentsOf: entry.extra)
    }

    let centralSize = UInt32(bytes.count) - centralOffset
    appendUInt32(0x0605_4b50, to: &bytes)
    appendUInt16(0, to: &bytes)
    appendUInt16(0, to: &bytes)
    appendUInt16(UInt16(entries.count), to: &bytes)
    appendUInt16(UInt16(entries.count), to: &bytes)
    appendUInt32(centralSize, to: &bytes)
    appendUInt32(centralOffset, to: &bytes)
    appendUInt16(0, to: &bytes)
    return Data(bytes)
}

private func appendUInt16(_ value: UInt16, to bytes: inout [UInt8]) {
    bytes.append(UInt8(truncatingIfNeeded: value))
    bytes.append(UInt8(truncatingIfNeeded: value >> 8))
}

private func appendUInt32(_ value: UInt32, to bytes: inout [UInt8]) {
    appendUInt16(UInt16(truncatingIfNeeded: value), to: &bytes)
    appendUInt16(UInt16(truncatingIfNeeded: value >> 16), to: &bytes)
}

private func requireOpenedDescriptor(at url: URL) throws -> Int32 {
    let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    return descriptor
}
