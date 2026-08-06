import Testing
@testable import BloomFileManager

@Suite("ArchiveSecretTests", .serialized)
struct ArchiveSecretTests {
    @Test func archiveSecretEnforcesModeLimitsAndBecomesUnavailable() throws {
        #expect(throws: ArchiveSecretError.confirmationMismatch) {
            try ArchiveSecret.creation(password: "abcdefgh", confirmation: "abcdefgi")
        }
        #expect(throws: ArchiveSecretError.containsNull) {
            try ArchiveSecret.extraction(password: "before\0after")
        }
        let secret = try ArchiveSecret.creation(
            password: "long-passphrase",
            confirmation: "long-passphrase"
        )
        #expect(try secret.withUnsafeBytes { $0.count } == 15)
        secret.invalidate()
        #expect(throws: ArchiveSecretError.unavailable) {
            try secret.withUnsafeBytes { $0.count }
        }
        #expect(secret.description == "<redacted archive secret>")
    }
}
