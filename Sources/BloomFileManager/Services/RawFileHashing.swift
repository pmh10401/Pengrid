import CryptoKit
import Darwin
import Foundation

struct RawFileFingerprint: Sendable, Equatable {
    let device: UInt64
    let inode: UInt64
    let mode: UInt32
    let logicalByteCount: Int64
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let changeSeconds: Int64
    let changeNanoseconds: Int64

    init(
        device: UInt64,
        inode: UInt64,
        mode: UInt32,
        logicalByteCount: Int64,
        modificationSeconds: Int64,
        modificationNanoseconds: Int64,
        changeSeconds: Int64,
        changeNanoseconds: Int64
    ) {
        self.device = device
        self.inode = inode
        self.mode = mode
        self.logicalByteCount = logicalByteCount
        self.modificationSeconds = modificationSeconds
        self.modificationNanoseconds = modificationNanoseconds
        self.changeSeconds = changeSeconds
        self.changeNanoseconds = changeNanoseconds
    }

    init(descriptor: Int32) throws {
        var information = stat()
        guard Darwin.fstat(descriptor, &information) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        self.init(
            device: UInt64(information.st_dev),
            inode: UInt64(information.st_ino),
            mode: UInt32(information.st_mode),
            logicalByteCount: Int64(information.st_size),
            modificationSeconds: Int64(information.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(information.st_mtimespec.tv_nsec),
            changeSeconds: Int64(information.st_ctimespec.tv_sec),
            changeNanoseconds: Int64(information.st_ctimespec.tv_nsec)
        )
    }
}

enum RawFileReadResult: Sendable, Equatable {
    case bytes(Int)
    case interrupted
    case failed(POSIXErrorCode)
}

protocol RawFileReadDriving: Sendable {
    func read(
        descriptor: Int32,
        into buffer: UnsafeMutableRawBufferPointer
    ) -> RawFileReadResult
}

struct DarwinRawFileReadDriver: RawFileReadDriving {
    init() {}

    func read(
        descriptor: Int32,
        into buffer: UnsafeMutableRawBufferPointer
    ) -> RawFileReadResult {
        let count = Darwin.read(descriptor, buffer.baseAddress, buffer.count)
        if count >= 0 { return .bytes(count) }
        if errno == EINTR { return .interrupted }
        return .failed(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

enum RawFileHashingError: Error, Equatable {
    case notRegularFile
    case descriptorIdentityChanged
    case logicalSizeChanged
    case stabilityChanged
    case invalidChunkSize
    case invalidReadResult
    case readFailed(POSIXErrorCode)
}

protocol RawFileHashing: Sendable {
    func checksum(
        descriptor: Int32,
        expected: RawFileFingerprint,
        chunkSize: Int,
        progress: @escaping @Sendable (Int64) async -> Void
    ) async throws -> Data

    func checksumPair(
        sourceDescriptor: Int32,
        sourceExpected: RawFileFingerprint,
        stagedDescriptor: Int32,
        stagedExpected: RawFileFingerprint,
        chunkSize: Int,
        progress: @escaping @Sendable (Int64) async -> Void
    ) async throws -> (source: Data, staged: Data)
}

struct LiveRawFileHasher: RawFileHashing {
    private let readDriver: any RawFileReadDriving

    init(readDriver: any RawFileReadDriving = DarwinRawFileReadDriver()) {
        self.readDriver = readDriver
    }

    func checksum(
        descriptor: Int32,
        expected: RawFileFingerprint,
        chunkSize: Int,
        progress: @escaping @Sendable (Int64) async -> Void
    ) async throws -> Data {
        guard chunkSize > 0 else { throw RawFileHashingError.invalidChunkSize }
        try validate(descriptor: descriptor, expected: expected)

        let worker = Task.detached(priority: .utility) { [readDriver] in
            var hasher = SHA256()
            var buffer = [UInt8](repeating: 0, count: chunkSize)
            while true {
                try Task.checkCancellation()
                let count = try Self.performRead(
                    descriptor: descriptor,
                    into: &buffer,
                    driver: readDriver
                )
                guard count > 0 else { break }
                hasher.update(data: Data(buffer[..<count]))
                await progress(Int64(count))
            }
            return hasher.finalize()
        }
        let digest = try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: { worker.cancel() }
        try validate(descriptor: descriptor, expected: expected)
        try Task.checkCancellation()
        return Data(digest)
    }

    func checksumPair(
        sourceDescriptor: Int32,
        sourceExpected: RawFileFingerprint,
        stagedDescriptor: Int32,
        stagedExpected: RawFileFingerprint,
        chunkSize: Int,
        progress: @escaping @Sendable (Int64) async -> Void
    ) async throws -> (source: Data, staged: Data) {
        guard chunkSize > 0 else { throw RawFileHashingError.invalidChunkSize }
        try validate(descriptor: sourceDescriptor, expected: sourceExpected)
        try validate(descriptor: stagedDescriptor, expected: stagedExpected)

        struct PairDigest: Sendable {
            var sourceDigest: SHA256.Digest
            var stagedDigest: SHA256.Digest
        }

        let pairWorker = Task.detached(priority: .utility) { [readDriver] in
            var sourceHasher = SHA256()
            var stagedHasher = SHA256()
            var sourceConsumed = Int64(0)
            var stagedConsumed = Int64(0)
            var reported = Int64(0)
            var sourceBuffer = [UInt8](repeating: 0, count: chunkSize)
            var stagedBuffer = [UInt8](repeating: 0, count: chunkSize)
            var sourceFinished = false
            var stagedFinished = false

            while !(sourceFinished && stagedFinished) {
                try Task.checkCancellation()
                if !sourceFinished {
                    let count = try Self.performRead(
                        descriptor: sourceDescriptor,
                        into: &sourceBuffer,
                        driver: readDriver
                    )
                    if count == 0 {
                        sourceFinished = true
                    } else {
                        sourceHasher.update(data: Data(sourceBuffer[..<count]))
                        sourceConsumed += Int64(count)
                    }
                }
                try Task.checkCancellation()
                if !stagedFinished {
                    let count = try Self.performRead(
                        descriptor: stagedDescriptor,
                        into: &stagedBuffer,
                        driver: readDriver
                    )
                    if count == 0 {
                        stagedFinished = true
                    } else {
                        stagedHasher.update(data: Data(stagedBuffer[..<count]))
                        stagedConsumed += Int64(count)
                    }
                }
                let matched = min(sourceConsumed, stagedConsumed)
                if matched > reported {
                    await progress(matched - reported)
                    reported = matched
                }
            }

            return PairDigest(
                sourceDigest: sourceHasher.finalize(),
                stagedDigest: stagedHasher.finalize()
            )
        }
        let pairDigests = try await withTaskCancellationHandler {
            try await pairWorker.value
        } onCancel: { pairWorker.cancel() }
        try validate(descriptor: sourceDescriptor, expected: sourceExpected)
        try validate(descriptor: stagedDescriptor, expected: stagedExpected)
        try Task.checkCancellation()
        return (Data(pairDigests.sourceDigest), Data(pairDigests.stagedDigest))
    }

    private static func performRead(
        descriptor: Int32,
        into buffer: inout [UInt8],
        driver: any RawFileReadDriving
    ) throws -> Int {
        while true {
            try Task.checkCancellation()
            let result = buffer.withUnsafeMutableBytes { bytes in
                driver.read(descriptor: descriptor, into: bytes)
            }
            switch result {
            case .bytes(let count):
                guard count >= 0, count <= buffer.count else {
                    throw RawFileHashingError.invalidReadResult
                }
                return count
            case .interrupted:
                try Task.checkCancellation()
                continue
            case .failed(let code):
                throw RawFileHashingError.readFailed(code)
            }
        }
    }

    private func validate(descriptor: Int32, expected: RawFileFingerprint) throws {
        let actual = try RawFileFingerprint(descriptor: descriptor)
        guard actual.mode & UInt32(S_IFMT) == UInt32(S_IFREG) else {
            throw RawFileHashingError.notRegularFile
        }
        guard actual.device == expected.device, actual.inode == expected.inode else {
            throw RawFileHashingError.descriptorIdentityChanged
        }
        guard actual.logicalByteCount == expected.logicalByteCount else {
            throw RawFileHashingError.logicalSizeChanged
        }
        guard actual.mode == expected.mode,
              actual.modificationSeconds == expected.modificationSeconds,
              actual.modificationNanoseconds == expected.modificationNanoseconds,
              actual.changeSeconds == expected.changeSeconds,
              actual.changeNanoseconds == expected.changeNanoseconds else {
            throw RawFileHashingError.stabilityChanged
        }
    }
}
