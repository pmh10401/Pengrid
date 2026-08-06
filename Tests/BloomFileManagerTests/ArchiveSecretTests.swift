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

private final class ArchiveSecretMemoryRecorder: ArchiveSecretMemoryAllocator {
    struct AllocationRecord {
        let id: Int
        let pointer: UnsafeMutableRawPointer
        let byteCount: Int
        let alignment: Int
        var clearCount = 0
        var clearCompleted = false
        var deallocateCount = 0
        var deallocatedAfterClear = false
        var zeroAtDeallocation = false
    }

    private let lock = NSLock()
    private var nextID = 0
    private var records: [Int: AllocationRecord] = [:]

    var allocationCount: Int {
        lock.withLock { records.count }
    }

    var recordsSnapshot: [AllocationRecord] {
        lock.withLock { Array(records.values).sorted { $0.id < $1.id } }
    }

    func allocate(byteCount: Int, alignment: Int) -> UnsafeMutableRawPointer {
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: alignment)
        pointer.initializeMemory(as: UInt8.self, repeating: 0xA5, count: byteCount)
        lock.withLock {
            nextID += 1
            records[nextID] = AllocationRecord(
                id: nextID,
                pointer: pointer,
                byteCount: byteCount,
                alignment: alignment
            )
        }
        return pointer
    }

    func clear(_ pointer: UnsafeMutableRawPointer, length: Int) {
        pengrid_secure_clear(pointer, length)
        lock.withLock {
            guard let id = id(for: pointer), var record = records[id] else { return }
            record.clearCount += 1
            record.clearCompleted = (0..<length).allSatisfy {
                pointer.load(fromByteOffset: $0, as: UInt8.self) == 0
            }
            records[id] = record
        }
    }

    func deallocate(
        _ pointer: UnsafeMutableRawPointer,
        byteCount: Int,
        alignment: Int
    ) {
        let allZero = (0..<byteCount).allSatisfy {
            pointer.load(fromByteOffset: $0, as: UInt8.self) == 0
        }
        lock.withLock {
            guard let id = id(for: pointer), var record = records[id] else { return }
            record.deallocateCount += 1
            record.deallocatedAfterClear = record.clearCompleted && allZero
            record.zeroAtDeallocation = allZero
            records[id] = record
        }
        pointer.deallocate()
    }

    func copiedBytes(for id: Int = 1) -> [UInt8] {
        lock.withLock {
            guard let record = records[id] else { return [] }
            return (0..<record.byteCount).map {
                record.pointer.load(fromByteOffset: $0, as: UInt8.self)
            }
        }
    }

    private func id(for pointer: UnsafeMutableRawPointer) -> Int? {
        records.first(where: { $0.value.pointer == pointer })?.key
    }
}

private final class BlockingArchiveSecretMemoryAllocator: ArchiveSecretMemoryAllocator {
    private let clearStarted: DispatchSemaphore
    private let releaseClear: DispatchSemaphore

    init(clearStarted: DispatchSemaphore, releaseClear: DispatchSemaphore) {
        self.clearStarted = clearStarted
        self.releaseClear = releaseClear
    }

    func allocate(byteCount: Int, alignment: Int) -> UnsafeMutableRawPointer {
        UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: alignment)
    }

    func clear(_ bytes: UnsafeMutableRawPointer, length: Int) {
        clearStarted.signal()
        _ = releaseClear.wait(timeout: .now() + 2)
        pengrid_secure_clear(bytes, length)
    }

    func deallocate(
        _ bytes: UnsafeMutableRawPointer,
        byteCount _: Int,
        alignment _: Int
    ) {
        bytes.deallocate()
    }
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
        let recorder = ArchiveSecretMemoryRecorder()
        let secret = try ArchiveSecret.extraction(
            password: "synchronization",
            allocator: recorder
        )
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
        let records = recorder.recordsSnapshot
        #expect(records.count == 1)
        #expect(records[0].clearCount == 1)
        #expect(records[0].deallocateCount == 1)
        #expect(records[0].deallocatedAfterClear)
        #expect(records[0].zeroAtDeallocation)
    }

    @Test func archiveSecretSecondInvalidationWaitsForBlockedSecureClear() throws {
        let clearStarted = DispatchSemaphore(value: 0)
        let releaseClear = DispatchSemaphore(value: 0)
        let firstReturned = DispatchSemaphore(value: 0)
        let secondStarted = DispatchSemaphore(value: 0)
        let secondReturned = DispatchSemaphore(value: 0)
        let secret = try ArchiveSecret.extraction(
            password: "synchronization",
            allocator: BlockingArchiveSecretMemoryAllocator(
                clearStarted: clearStarted,
                releaseClear: releaseClear
            )
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

    @Test func controlledAllocatorCopiesDirectUTF8AndClearsBeforeDeallocate() throws {
        let recorder = ArchiveSecretMemoryRecorder()
        let secret = try ArchiveSecret.extraction(
            password: "controlled-secret",
            allocator: recorder
        )

        #expect(recorder.allocationCount == 1)
        #expect(recorder.copiedBytes() == Array("controlled-secret".utf8))
        secret.invalidate()

        let records = recorder.recordsSnapshot
        #expect(records.count == 1)
        #expect(records[0].clearCount == 1)
        #expect(records[0].deallocateCount == 1)
        #expect(records[0].deallocatedAfterClear)
        #expect(records[0].zeroAtDeallocation)
    }

    @Test func controlledAllocatorCreationCopiesAndClearsOnInvalidate() throws {
        let recorder = ArchiveSecretMemoryRecorder()
        let secret = try ArchiveSecret.creation(
            password: "creation-secret",
            confirmation: "creation-secret",
            allocator: recorder
        )

        #expect(recorder.allocationCount == 1)
        #expect(recorder.copiedBytes() == Array("creation-secret".utf8))
        secret.invalidate()

        let records = recorder.recordsSnapshot
        #expect(records.count == 1)
        #expect(records[0].clearCount == 1)
        #expect(records[0].deallocateCount == 1)
        #expect(records[0].deallocatedAfterClear)
        #expect(records[0].zeroAtDeallocation)
    }

    @Test func controlledAllocatorExtractionDeinitClearsExactlyOnce() throws {
        let recorder = ArchiveSecretMemoryRecorder()
        do {
            let secret = try ArchiveSecret.extraction(
                password: "deinit-secret",
                allocator: recorder
            )
            #expect(try secret.withUnsafeBytes { $0.count } == 13)
            #expect(recorder.allocationCount == 1)
        }

        let records = recorder.recordsSnapshot
        #expect(records.count == 1)
        #expect(records[0].clearCount == 1)
        #expect(records[0].deallocateCount == 1)
        #expect(records[0].deallocatedAfterClear)
        #expect(records[0].zeroAtDeallocation)
    }

    @Test func controlledAllocatorClearsAndDeallocatesConfirmationMismatch() throws {
        let recorder = ArchiveSecretMemoryRecorder()
        #expect(throws: ArchiveSecretError.confirmationMismatch) {
            try ArchiveSecret.creation(
                password: "abcdefgh",
                confirmation: "abcdefgi",
                allocator: recorder
            )
        }

        let records = recorder.recordsSnapshot
        #expect(records.count == 1)
        #expect(records[0].clearCount == 1)
        #expect(records[0].deallocateCount == 1)
        #expect(records[0].deallocatedAfterClear)
        #expect(records[0].zeroAtDeallocation)
    }

    @Test func invalidInputsAreRejectedBeforeControlledAllocation() {
        for (password, confirmation) in [
            ("before\0after", "before\0after"),
            (String(repeating: "x", count: 7), String(repeating: "x", count: 7)),
            (String(repeating: "x", count: 257), String(repeating: "x", count: 257))
        ] {
            let recorder = ArchiveSecretMemoryRecorder()
            #expect(throws: ArchiveSecretError.self) {
                try ArchiveSecret.creation(
                    password: password,
                    confirmation: confirmation,
                    allocator: recorder
                )
            }
            #expect(recorder.allocationCount == 0)
        }

        for password in ["before\0after", "", String(repeating: "x", count: 1_025)] {
            let recorder = ArchiveSecretMemoryRecorder()
            #expect(throws: ArchiveSecretError.self) {
                try ArchiveSecret.extraction(password: password, allocator: recorder)
            }
            #expect(recorder.allocationCount == 0)
        }
    }

    @Test func cancellationInvalidatesConstructedSecretExactlyOnce() async throws {
        let recorder = ArchiveSecretMemoryRecorder()
        let secret = try ArchiveSecret.extraction(password: "cancel-secret", allocator: recorder)
        let task = Task {
            try await withTaskCancellationHandler {
                try await Task.sleep(for: .seconds(2))
            } onCancel: {
                secret.invalidate()
            }
        }
        task.cancel()
        _ = await task.result

        #expect(throws: ArchiveSecretError.unavailable) {
            try secret.withUnsafeBytes { _ in }
        }
        let records = recorder.recordsSnapshot
        #expect(records.count == 1)
        #expect(records[0].clearCount == 1)
        #expect(records[0].deallocateCount == 1)
        #expect(records[0].deallocatedAfterClear)
        #expect(records[0].zeroAtDeallocation)
    }

    @Test func archiveSecretSourceHasNoAvoidableUTF8ArrayConstruction() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repository
                .appendingPathComponent("Sources/BloomFileManager/Services/ArchiveSecret.swift"),
            encoding: .utf8
        )
        #expect(source.contains("Array(password.utf8") == false)
        #expect(source.contains("Array(confirmation.utf8") == false)
        #expect(source.contains("init(utf8: [UInt8]") == false)
    }
}
