import Darwin
import Foundation

/// Small, dependency-free ZIP builder used to make malformed and hostile test
/// archives. It deliberately writes only the local header, central directory,
/// and EOCD records needed by the reader; no production code uses it.
enum RawZIPFixtureBuilder {
    struct Entry {
        let nameBytes: [UInt8]
        let bytes: [UInt8]
        var compressionMethod: UInt16 = 0
        var flags: UInt16 = 0
        var versionMadeBy: UInt16 = (3 << 8) | 20
        var versionNeeded: UInt16 = 20
        var externalAttributes: UInt32 = 0
        var declaredCompressedSize: UInt64?
        var declaredUncompressedSize: UInt64?
        var extraField: [UInt8] = []
        var dosTime: UInt16 = 0
        var dosDate: UInt16 = 0

        init(
            nameBytes: [UInt8],
            bytes: [UInt8],
            compressionMethod: UInt16 = 0,
            flags: UInt16 = 0,
            versionMadeBy: UInt16 = (3 << 8) | 20,
            versionNeeded: UInt16 = 20,
            externalAttributes: UInt32 = 0,
            declaredCompressedSize: UInt64? = nil,
            declaredUncompressedSize: UInt64? = nil,
            extraField: [UInt8] = [],
            dosTime: UInt16 = 0,
            dosDate: UInt16 = 0
        ) {
            self.nameBytes = nameBytes
            self.bytes = bytes
            self.compressionMethod = compressionMethod
            self.flags = flags
            self.versionMadeBy = versionMadeBy
            self.versionNeeded = versionNeeded
            self.externalAttributes = externalAttributes
            self.declaredCompressedSize = declaredCompressedSize
            self.declaredUncompressedSize = declaredUncompressedSize
            self.extraField = extraField
            self.dosTime = dosTime
            self.dosDate = dosDate
        }

        static func regular(
            name: String,
            bytes: [UInt8],
            compressionMethod: UInt16 = 0,
            flags: UInt16 = 0,
            externalAttributes: UInt32 = 0,
            declaredCompressedSize: UInt64? = nil,
            declaredUncompressedSize: UInt64? = nil
        ) -> Self {
            return Self(
                nameBytes: Array(name.utf8),
                bytes: bytes,
                compressionMethod: compressionMethod,
                flags: flags,
                externalAttributes: externalAttributes,
                declaredCompressedSize: declaredCompressedSize,
                declaredUncompressedSize: declaredUncompressedSize
            )
        }

        static func directory(name: String) -> Self {
            let directoryName = name.hasSuffix("/") ? name : name + "/"
            return Self(
                nameBytes: Array(directoryName.utf8),
                bytes: [],
                externalAttributes: (UInt32(S_IFDIR | 0o755) << 16)
            )
        }

        static func symlink(name: String, target: String) -> Self {
            return symlink(name: name, targetBytes: Array(target.utf8))
        }

        static func symlink(name: String, targetBytes: [UInt8]) -> Self {
            var unixExtra: [UInt8] = []
            appendUInt16(&unixExtra, 0x000D)
            appendUInt16(&unixExtra, UInt16(clamping: 12 + targetBytes.count))
            appendUInt32(&unixExtra, 0)
            appendUInt32(&unixExtra, 0)
            appendUInt16(&unixExtra, 0)
            appendUInt16(&unixExtra, 0)
            unixExtra.append(contentsOf: targetBytes)
            return Self(
                nameBytes: Array(name.utf8),
                bytes: targetBytes,
                externalAttributes: (UInt32(S_IFLNK | 0o777) << 16),
                extraField: unixExtra
            )
        }

        static func fifo(name: String) -> Self {
            Self(
                nameBytes: Array(name.utf8),
                bytes: [],
                externalAttributes: (UInt32(S_IFIFO | 0o600) << 16)
            )
        }

        static func blockDevice(name: String) -> Self {
            Self(
                nameBytes: Array(name.utf8),
                bytes: [],
                externalAttributes: (UInt32(S_IFBLK | 0o600) << 16)
            )
        }

        static func socket(name: String) -> Self {
            Self(
                nameBytes: Array(name.utf8),
                bytes: [],
                externalAttributes: (UInt32(S_IFSOCK | 0o600) << 16)
            )
        }
    }

    static func entry(name: String, bytes: [UInt8]) throws -> Data {
        archive(entries: [.regular(name: name, bytes: bytes)])
    }

    static func unixSymlinkExtra(targetBytes: [UInt8]) -> [UInt8] {
        var unixExtra: [UInt8] = []
        appendUInt16(&unixExtra, 0x000D)
        appendUInt16(&unixExtra, UInt16(clamping: 12 + targetBytes.count))
        appendUInt32(&unixExtra, 0)
        appendUInt32(&unixExtra, 0)
        appendUInt16(&unixExtra, 0)
        appendUInt16(&unixExtra, 0)
        unixExtra.append(contentsOf: targetBytes)
        return unixExtra
    }

    static func archive(entries: [Entry]) -> Data {
        var localAndCentral = Data()
        var centralDirectory = Data()
        var localOffset: UInt32 = 0

        for entry in entries {
            let name = entry.nameBytes
            let actualCompressedSize = UInt64(entry.bytes.count)
            let actualUncompressedSize = UInt64(entry.bytes.count)
            let compressedSize = entry.declaredCompressedSize ?? actualCompressedSize
            let uncompressedSize = entry.declaredUncompressedSize ?? actualUncompressedSize
            let needsZIP64 = compressedSize > UInt64(UInt32.max)
                || uncompressedSize > UInt64(UInt32.max)
                || localOffset == UInt32.max
            let localExtra = zip64Extra(
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                includeCompressed: needsZIP64,
                includeUncompressed: needsZIP64
            ) + entry.extraField
            let localCompressed32 = needsZIP64 ? UInt32.max : UInt32(compressedSize)
            let localUncompressed32 = needsZIP64 ? UInt32.max : UInt32(uncompressedSize)
            appendUInt32(&localAndCentral, 0x04034B50)
            appendUInt16(&localAndCentral, entry.versionNeeded)
            appendUInt16(&localAndCentral, entry.flags)
            appendUInt16(&localAndCentral, entry.compressionMethod)
            appendUInt16(&localAndCentral, entry.dosTime)
            appendUInt16(&localAndCentral, entry.dosDate)
            appendUInt32(&localAndCentral, crc32(entry.bytes))
            appendUInt32(&localAndCentral, localCompressed32)
            appendUInt32(&localAndCentral, localUncompressed32)
            appendUInt16(&localAndCentral, UInt16(clamping: name.count))
            appendUInt16(&localAndCentral, UInt16(clamping: localExtra.count))
            localAndCentral.append(contentsOf: name)
            localAndCentral.append(contentsOf: localExtra)
            localAndCentral.append(contentsOf: entry.bytes)

            let centralExtra = zip64Extra(
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                includeCompressed: needsZIP64,
                includeUncompressed: needsZIP64
            ) + entry.extraField
            let centralCompressed32 = needsZIP64 ? UInt32.max : UInt32(compressedSize)
            let centralUncompressed32 = needsZIP64 ? UInt32.max : UInt32(uncompressedSize)
            appendUInt32(&centralDirectory, 0x02014B50)
            appendUInt16(&centralDirectory, entry.versionMadeBy)
            appendUInt16(&centralDirectory, entry.versionNeeded)
            appendUInt16(&centralDirectory, entry.flags)
            appendUInt16(&centralDirectory, entry.compressionMethod)
            appendUInt16(&centralDirectory, entry.dosTime)
            appendUInt16(&centralDirectory, entry.dosDate)
            appendUInt32(&centralDirectory, crc32(entry.bytes))
            appendUInt32(&centralDirectory, centralCompressed32)
            appendUInt32(&centralDirectory, centralUncompressed32)
            appendUInt16(&centralDirectory, UInt16(clamping: name.count))
            appendUInt16(&centralDirectory, UInt16(clamping: centralExtra.count))
            appendUInt16(&centralDirectory, 0)
            appendUInt16(&centralDirectory, 0)
            appendUInt16(&centralDirectory, 0)
            appendUInt32(&centralDirectory, entry.externalAttributes)
            appendUInt32(&centralDirectory, localOffset)
            centralDirectory.append(contentsOf: name)
            centralDirectory.append(contentsOf: centralExtra)

            let localLength = 30 + name.count + localExtra.count + entry.bytes.count
            localOffset = localOffset &+ UInt32(clamping: localLength)
        }

        let centralOffset = localAndCentral.count
        localAndCentral.append(centralDirectory)
        if entries.count > Int(UInt16.max) || centralDirectory.count > Int(UInt32.max) || centralOffset > Int(UInt32.max) {
            let zip64Offset = localAndCentral.count
            appendUInt32(&localAndCentral, 0x06064B50)
            appendUInt64(&localAndCentral, 44)
            appendUInt16(&localAndCentral, 45)
            appendUInt16(&localAndCentral, 45)
            appendUInt32(&localAndCentral, 0)
            appendUInt32(&localAndCentral, 0)
            appendUInt64(&localAndCentral, UInt64(entries.count))
            appendUInt64(&localAndCentral, UInt64(entries.count))
            appendUInt64(&localAndCentral, UInt64(centralDirectory.count))
            appendUInt64(&localAndCentral, UInt64(centralOffset))
            appendUInt32(&localAndCentral, 0x07064B50)
            appendUInt32(&localAndCentral, 0)
            appendUInt64(&localAndCentral, UInt64(zip64Offset))
            appendUInt32(&localAndCentral, 1)
            appendUInt32(&localAndCentral, 0x06054B50)
            appendUInt16(&localAndCentral, UInt16.max)
            appendUInt16(&localAndCentral, UInt16.max)
            appendUInt16(&localAndCentral, UInt16.max)
            appendUInt16(&localAndCentral, UInt16.max)
            appendUInt32(&localAndCentral, UInt32.max)
            appendUInt32(&localAndCentral, UInt32.max)
            appendUInt16(&localAndCentral, 0)
        } else {
            appendUInt32(&localAndCentral, 0x06054B50)
            appendUInt16(&localAndCentral, 0)
            appendUInt16(&localAndCentral, 0)
            appendUInt16(&localAndCentral, UInt16(entries.count))
            appendUInt16(&localAndCentral, UInt16(entries.count))
            appendUInt32(&localAndCentral, UInt32(centralDirectory.count))
            appendUInt32(&localAndCentral, UInt32(centralOffset))
            appendUInt16(&localAndCentral, 0)
        }
        return localAndCentral
    }

    private static func zip64Extra(
        compressedSize: UInt64,
        uncompressedSize: UInt64,
        includeCompressed: Bool,
        includeUncompressed: Bool
    ) -> [UInt8] {
        guard includeCompressed || includeUncompressed else { return [] }
        var body: [UInt8] = []
        if includeUncompressed { appendUInt64(&body, uncompressedSize) }
        if includeCompressed { appendUInt64(&body, compressedSize) }
        var result: [UInt8] = []
        appendUInt16(&result, 0x0001)
        appendUInt16(&result, UInt16(clamping: body.count))
        result.append(contentsOf: body)
        return result
    }

    private static func appendUInt16(_ data: inout Data, _ value: UInt16) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    private static func appendUInt16(_ data: inout [UInt8], _ value: UInt16) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    private static func appendUInt32(_ data: inout Data, _ value: UInt32) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 24))
    }

    private static func appendUInt64(_ data: inout Data, _ value: UInt64) {
        for shift in stride(from: 0, through: 56, by: 8) {
            data.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }

    private static func appendUInt32(_ data: inout [UInt8], _ value: UInt32) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 24))
    }

    private static func appendUInt64(_ data: inout [UInt8], _ value: UInt64) {
        for shift in stride(from: 0, through: 56, by: 8) {
            data.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }

    private static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc >> 1) ^ (0xEDB8_8320 & (0 &- (crc & 1)))
            }
        }
        return ~crc
    }
}
