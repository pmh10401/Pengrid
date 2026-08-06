import Testing
import Foundation
import EncryptedZIPCore
@testable import BloomFileManager

private actor ArchiveSecretTestLatch {
    private var signaled = false

    func signal() {
        signaled = true
    }

    func isSignaled() -> Bool {
        signaled
    }
}

private func waitForArchiveSecretSignal(
    _ latch: ArchiveSecretTestLatch,
    timeout: Duration = .seconds(1)
) async -> Bool {
    let start = ContinuousClock.now
    while !(await latch.isSignaled()) {
        if start.duration(to: ContinuousClock.now) >= timeout { return false }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return true
}

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

    @Test func archiveSecretAcceptsExactCreationAndExtractionByteBoundaries() throws {
        for count in [8, 256] {
            let password = String(repeating: "x", count: count)
            let secret = try ArchiveSecret.creation(password: password, confirmation: password)
            #expect(try secret.withUnsafeBytes { $0.count } == count)
        }
        for count in [1, 1_024] {
            let secret = try ArchiveSecret.extraction(password: String(repeating: "y", count: count))
            #expect(try secret.withUnsafeBytes { $0.count } == count)
        }
        #expect(try ArchiveSecret.creation(password: "éééé", confirmation: "éééé").withUnsafeBytes { $0.count } == 8)
        #expect(throws: ArchiveSecretError.invalidLength) {
            try ArchiveSecret.creation(password: String(repeating: "x", count: 7), confirmation: String(repeating: "x", count: 7))
        }
        #expect(throws: ArchiveSecretError.invalidLength) {
            try ArchiveSecret.extraction(password: "")
        }
    }

    @Test func archiveSecretInvalidationWaitsForAnActiveBorrowAndConcurrentTeardownCompletes() async throws {
        let secret = try ArchiveSecret.extraction(password: "synchronization")
        let release = DispatchSemaphore(value: 0)
        let enteredLatch = ArchiveSecretTestLatch()
        let borrowFinished = ArchiveSecretTestLatch()
        DispatchQueue.global().async {
            _ = try? secret.withUnsafeBytes { bytes in
                Task { await enteredLatch.signal() }
                _ = release.wait(timeout: .now() + 2)
                return bytes.count
            }
            Task { await borrowFinished.signal() }
        }
        #expect(await waitForArchiveSecretSignal(enteredLatch))

        let invalidationFinished = ArchiveSecretTestLatch()
        DispatchQueue.global().async {
            secret.invalidate()
            Task { await invalidationFinished.signal() }
        }
        #expect(!(await waitForArchiveSecretSignal(
            invalidationFinished,
            timeout: .milliseconds(50)
        )))
        release.signal()
        #expect(await waitForArchiveSecretSignal(invalidationFinished))
        #expect(await waitForArchiveSecretSignal(borrowFinished))

        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            secret.invalidate()
        }
        #expect(throws: ArchiveSecretError.unavailable) {
            try secret.withUnsafeBytes { $0.count }
        }
    }

    @Test func archiveSecretSecondInvalidationWaitsForBlockedSecureClear() throws {
        let clearStarted = DispatchSemaphore(value: 0)
        let releaseClear = DispatchSemaphore(value: 0)
        let firstReturned = DispatchSemaphore(value: 0)
        let secondStarted = DispatchSemaphore(value: 0)
        let secondReturned = DispatchSemaphore(value: 0)
        let secret = ArchiveSecret(
            utf8: Array("synchronization".utf8),
            cleanup: { bytes, length in
                clearStarted.signal()
                _ = releaseClear.wait(timeout: .now() + 2)
                pengrid_secure_clear(bytes, length)
            }
        )

        DispatchQueue.global().async {
            secret.invalidate()
            firstReturned.signal()
        }
        #expect(clearStarted.wait(timeout: .now() + 1) == .success)

        DispatchQueue.global().async {
            secondStarted.signal()
            secret.invalidate()
            secondReturned.signal()
        }
        #expect(secondStarted.wait(timeout: .now() + 1) == .success)
        #expect(secondReturned.wait(timeout: .now() + .milliseconds(50)) == .timedOut)

        releaseClear.signal()
        #expect(firstReturned.wait(timeout: .now() + 1) == .success)
        #expect(secondReturned.wait(timeout: .now() + 1) == .success)
    }
}
