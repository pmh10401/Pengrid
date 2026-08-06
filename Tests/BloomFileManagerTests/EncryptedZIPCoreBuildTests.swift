import EncryptedZIPCore
import Testing

@Test func encryptedZIPCoreIsPinnedAndClearsBuffers() {
    #expect(String(cString: pengrid_zip_core_version()) == "minizip-ng 4.2.2")
    var bytes = Array("public-test-secret".utf8)
    bytes.withUnsafeMutableBytes { buffer in
        pengrid_secure_clear(buffer.baseAddress, buffer.count)
    }
    #expect(bytes.allSatisfy { $0 == 0 })
}
