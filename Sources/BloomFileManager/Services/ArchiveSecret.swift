import Darwin
import EncryptedZIPCore
import Foundation

enum ArchiveSecretError: Error, Equatable {
    case confirmationMismatch
    case containsNull
    case invalidLength
    case unavailable
}

final class ArchiveSecret: @unchecked Sendable, CustomStringConvertible {
    private let lock = NSLock()
    private let length: Int
    private var bytes: UnsafeMutableRawPointer?
    private let cleanup: (UnsafeMutableRawPointer, Int) -> Void

    private convenience init(utf8: [UInt8]) {
        self.init(utf8: utf8, cleanup: ArchiveSecret.clearBytes)
    }

    init(utf8: [UInt8], cleanup: @escaping (UnsafeMutableRawPointer, Int) -> Void) {
        length = utf8.count
        self.cleanup = cleanup
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: utf8.count,
            alignment: MemoryLayout<UInt8>.alignment
        )
        storage.copyMemory(from: utf8, byteCount: utf8.count)
        bytes = storage
    }

    static func creation(password: String, confirmation: String) throws -> ArchiveSecret {
        let passwordBytes = try validatedBytes(password, range: 8...256)
        let confirmationBytes = try validatedBytes(confirmation, range: 8...256)
        guard passwordBytes == confirmationBytes else {
            throw ArchiveSecretError.confirmationMismatch
        }
        return ArchiveSecret(utf8: passwordBytes)
    }

    static func extraction(password: String) throws -> ArchiveSecret {
        ArchiveSecret(utf8: try validatedBytes(password, range: 1...1_024))
    }

    func withUnsafeBytes<T>(_ body: (UnsafeRawBufferPointer) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard let bytes else {
            throw ArchiveSecretError.unavailable
        }
        return try body(UnsafeRawBufferPointer(start: bytes, count: length))
    }

    func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        guard let bytes else {
            return
        }
        self.bytes = nil
        cleanup(bytes, length)
        bytes.deallocate()
    }

    var description: String { "<redacted archive secret>" }

    deinit {
        invalidate()
    }

    private static func clearBytes(_ bytes: UnsafeMutableRawPointer, _ length: Int) {
        pengrid_secure_clear(bytes, length)
    }

    private static func validatedBytes(_ password: String, range: ClosedRange<Int>) throws -> [UInt8] {
        guard password.unicodeScalars.allSatisfy({ $0.value != 0 }) else {
            throw ArchiveSecretError.containsNull
        }
        let bytes = Array(password.utf8)
        guard range.contains(bytes.count) else {
            throw ArchiveSecretError.invalidLength
        }
        return bytes
    }
}
