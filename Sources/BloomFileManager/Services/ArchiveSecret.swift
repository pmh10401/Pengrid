import Darwin
import EncryptedZIPCore
import Foundation

enum ArchiveSecretError: Error, Equatable {
    case confirmationMismatch
    case containsNull
    case invalidLength
    case unavailable
}

/// The only memory boundary used by ArchiveSecret.  Production uses the
/// secure allocator below; tests inject a recorder to prove clear-before-
/// deallocate ordering without exposing secret bytes through ArchiveSecret.
protocol ArchiveSecretMemoryAllocator: AnyObject {
    func allocate(byteCount: Int, alignment: Int) -> UnsafeMutableRawPointer
    func clear(_ bytes: UnsafeMutableRawPointer, length: Int)
    func deallocate(
        _ bytes: UnsafeMutableRawPointer,
        byteCount: Int,
        alignment: Int
    )
}

private final class SecureArchiveSecretMemoryAllocator: ArchiveSecretMemoryAllocator, @unchecked Sendable {
    static let shared = SecureArchiveSecretMemoryAllocator()

    func allocate(byteCount: Int, alignment: Int) -> UnsafeMutableRawPointer {
        UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: alignment)
    }

    func clear(_ bytes: UnsafeMutableRawPointer, length: Int) {
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

final class ArchiveSecret: @unchecked Sendable, CustomStringConvertible {
    private let lock = NSLock()
    private let length: Int
    private let allocationLength: Int
    private let allocationAlignment: Int
    private let allocator: any ArchiveSecretMemoryAllocator
    private var bytes: UnsafeMutableRawPointer?

    private init(
        bytes: UnsafeMutableRawPointer,
        length: Int,
        allocationLength: Int,
        allocationAlignment: Int,
        allocator: any ArchiveSecretMemoryAllocator
    ) {
        self.length = length
        self.allocationLength = allocationLength
        self.allocationAlignment = allocationAlignment
        self.allocator = allocator
        self.bytes = bytes
    }

    static func creation(
        password: String,
        confirmation: String,
        allocator: any ArchiveSecretMemoryAllocator = SecureArchiveSecretMemoryAllocator.shared
    ) throws -> ArchiveSecret {
        let passwordLength = try validatedByteCount(password, range: 8...256)
        let confirmationLength = try validatedByteCount(confirmation, range: 8...256)
        guard passwordLength == confirmationLength else {
            throw ArchiveSecretError.confirmationMismatch
        }

        return try construct(
            password: password,
            length: passwordLength,
            allocator: allocator
        ) { destination in
            var index = 0
            for byte in confirmation.utf8 {
                guard destination.load(fromByteOffset: index, as: UInt8.self) == byte else {
                    throw ArchiveSecretError.confirmationMismatch
                }
                index += 1
            }
        }
    }

    static func extraction(
        password: String,
        allocator: any ArchiveSecretMemoryAllocator = SecureArchiveSecretMemoryAllocator.shared
    ) throws -> ArchiveSecret {
        let length = try validatedByteCount(password, range: 1...1_024)
        return try construct(password: password, length: length, allocator: allocator)
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
        allocator.clear(bytes, length: allocationLength)
        allocator.deallocate(
            bytes,
            byteCount: allocationLength,
            alignment: allocationAlignment
        )
    }

    var description: String { "<redacted archive secret>" }

    deinit {
        invalidate()
    }

    private static func construct(
        password: String,
        length: Int,
        allocator: any ArchiveSecretMemoryAllocator,
        validate: ((UnsafeMutableRawPointer) throws -> Void)? = nil
    ) throws -> ArchiveSecret {
        let alignment = MemoryLayout<UInt8>.alignment
        let destination = allocator.allocate(byteCount: length, alignment: alignment)
        var ownsAllocation = true
        defer {
            if ownsAllocation {
                allocator.clear(destination, length: length)
                allocator.deallocate(destination, byteCount: length, alignment: alignment)
            }
        }

        var index = 0
        for byte in password.utf8 {
            destination.storeBytes(of: byte, toByteOffset: index, as: UInt8.self)
            index += 1
        }
        try validate?(destination)

        ownsAllocation = false
        return ArchiveSecret(
            bytes: destination,
            length: length,
            allocationLength: length,
            allocationAlignment: alignment,
            allocator: allocator
        )
    }

    private static func validatedByteCount(
        _ password: String,
        range: ClosedRange<Int>
    ) throws -> Int {
        guard password.unicodeScalars.allSatisfy({ $0.value != 0 }) else {
            throw ArchiveSecretError.containsNull
        }
        let count = password.utf8.count
        guard range.contains(count) else {
            throw ArchiveSecretError.invalidLength
        }
        return count
    }
}
