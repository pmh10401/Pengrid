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
