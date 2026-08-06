import Darwin
import EncryptedZIPCore
import Foundation
import Testing
@testable import BloomFileManager

@_silgen_name("pengrid_root_test_fail_next_tracking")
private func pengrid_root_test_fail_next_tracking()

@_silgen_name("pengrid_root_test_fail_next_cleanup")
private func pengrid_root_test_fail_next_cleanup()

@_silgen_name("pengrid_root_test_substitute_next_cleanup_object")
private func pengrid_root_test_substitute_next_cleanup_object()

private typealias RootIdentityTestHook = @convention(c) () -> Void

private func rootIdentityTestHook(_ name: String) -> RootIdentityTestHook? {
    name.withCString { symbolName in
        guard let symbol = Darwin.dlsym(UnsafeMutableRawPointer(bitPattern: -2), symbolName) else { return nil }
        return unsafeBitCast(symbol, to: RootIdentityTestHook.self)
    }
}

@_cdecl("pengrid_test_reanchor_progress")
func pengrid_test_reanchor_progress(
    _ completed: UInt64,
    _ total: UInt64,
    _ context: UnsafeMutableRawPointer?
) -> Int32 {
    guard let context else { return 1 }
    let state = Unmanaged<NativeReanchorState>.fromOpaque(context).takeUnretainedValue()
    state.reanchorIfNeeded()
    return 0
}

@_cdecl("pengrid_test_cancel_during_native_read")
func pengrid_test_cancel_during_native_read(
    _ completed: UInt64,
    _ total: UInt64,
    _ context: UnsafeMutableRawPointer?
) -> Int32 {
    guard completed > 0 else { return 0 }
    guard let context else { return 1 }
    let state = Unmanaged<NativeCancellationState>.fromOpaque(context).takeUnretainedValue()
    state.didRead = true
    return 1
}

@Suite("ProtectedZIPEngineReaderTests", .serialized)
struct ProtectedZIPEngineReaderTests {
    @Test func readerExtractsIndependentAESAndLegacyFixtures() async throws {
        try await expectFixture(
            "7zip-aes256.zip",
            password: "fixture-aes256-passphrase",
            expectedName: "자료.txt",
            expectedBytes: Array("7-Zip AES-256 compatibility fixture\n".utf8)
        )
        try await expectFixture(
            "minizip-aes128.zip",
            password: "fixture-aes128-passphrase",
            expectedName: "Strength.txt",
            expectedBytes: Array("AES compatibility fixture\n".utf8)
        )
        try await expectFixture(
            "minizip-aes192.zip",
            password: "fixture-aes192-passphrase",
            expectedName: "Strength.txt",
            expectedBytes: Array("AES compatibility fixture\n".utf8)
        )
        try await expectFixture(
            "infozip-zipcrypto.zip",
            password: "fixture-zipcrypto-password",
            expectedName: "Legacy.txt",
            expectedBytes: Array("Info-ZIP ZipCrypto compatibility fixture\n".utf8)
        )
    }

    @Test func readerExtractsEmptyArchiveWithoutPublishingEntries() async throws {
        let root = try await extract(
            RawZIPFixtureBuilder.archive(entries: []),
            password: "fixture-password"
        )
        let contents = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        )
        #expect(contents.isEmpty)
    }

    @Test func readerAcceptsTaskFiveExtractionPasswordBoundaries() async throws {
        let cases = [
            ("aes-password-1.zip", String(repeating: "p", count: 1)),
            ("aes-password-257.zip", String(repeating: "p", count: 257)),
            ("aes-password-1024.zip", String(repeating: "p", count: 1_024))
        ]
        for (filename, password) in cases {
            let fixture = try Data(contentsOf: protectedZIPFixtureURL(filename))
            let root = try await extract(fixture, password: password)
            #expect(try String(contentsOf: root.appending(path: "Strength.txt"), encoding: .utf8) == "AES compatibility fixture\n")
        }
    }

    @Test func encryptedSymlinkAdvancesAuthenticatedProgressAndPublishesExactTarget() async throws {
        let fixture = try Data(contentsOf: protectedZIPFixtureURL("minizip-aes256-symlink.zip"))
        let progress = ReaderProgressRecorder()
        let root = try await extract(
            fixture,
            password: "fixture-aes-symlink-passphrase",
            progress: { event in await progress.record(event) }
        )
        let link = root.appending(path: "link")
        let target = try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
        #expect(target == "target.txt")
        let final = await progress.last
        #expect(final?.completedByteCount == final?.totalByteCount)
        #expect(final?.totalByteCount == Int64("target.txt".utf8.count))
    }

    @Test func symlinkPreflightRequiresCentralMetadataWithoutReadingPayload() async throws {
        let missingMetadata = RawZIPFixtureBuilder.Entry(
            nameBytes: Array("link".utf8),
            bytes: Array("target.txt".utf8),
            externalAttributes: UInt32(S_IFLNK | 0o777) << 16
        )
        await #expect(throws: ProtectedZIPError.unsafeEntry) {
            try await preflight(RawZIPFixtureBuilder.archive(entries: [missingMetadata]))
        }

        let nulMetadata = RawZIPFixtureBuilder.Entry.symlink(
            name: "link",
            targetBytes: Array("target\0evil".utf8)
        )
        await #expect(throws: ProtectedZIPError.unsafeEntry) {
            try await preflight(RawZIPFixtureBuilder.archive(entries: [nulMetadata]))
        }

        let absoluteMetadata = RawZIPFixtureBuilder.Entry.symlink(
            name: "link",
            targetBytes: Array("/outside".utf8)
        )
        await #expect(throws: ProtectedZIPError.unsafeEntry) {
            try await preflight(RawZIPFixtureBuilder.archive(entries: [absoluteMetadata]))
        }

        // Central-directory metadata is sufficient for preflight. The local
        // payload is deliberately truncated, so only authenticated extraction
        // should observe the damage.
        let truncatedPayload = RawZIPFixtureBuilder.Entry(
            nameBytes: Array("link".utf8),
            bytes: Array("target.txt".utf8),
            externalAttributes: UInt32(S_IFLNK | 0o777) << 16,
            declaredCompressedSize: 32,
            declaredUncompressedSize: 32,
            extraField: RawZIPFixtureBuilder.unixSymlinkExtra(targetBytes: Array("target.txt".utf8))
        )
        let truncatedFixture = RawZIPFixtureBuilder.archive(entries: [truncatedPayload])
        let inspection = try await preflight(truncatedFixture)
        #expect(inspection.entryCount == 1)
        await #expect(throws: ProtectedZIPError.incorrectPasswordOrDamagedData) {
            try await extract(truncatedFixture, password: "fixture-password")
        }

        let encryptedFixture = try Data(contentsOf: protectedZIPFixtureURL("minizip-aes256-symlink.zip"))
        var damagedBytes = Array(encryptedFixture)
        if let centralOffset = firstCentralDirectoryOffset(in: damagedBytes), centralOffset >= 26 {
            // Keep the local header and data descriptor intact while flipping
            // the final ciphertext byte immediately before the descriptor.
            damagedBytes[centralOffset - 25] ^= 0x01
        }
        let damagedFixture = Data(damagedBytes)
        let damagedInspection = try await preflight(damagedFixture)
        #expect(damagedInspection.entryCount == 1)
        await #expect(throws: ProtectedZIPError.incorrectPasswordOrDamagedData) {
            try await extract(damagedFixture, password: "fixture-aes-symlink-passphrase")
        }
    }

    @Test func authenticatedSymlinkPayloadMustMatchCentralMetadataAndContainNoNUL() async throws {
        let mismatch = RawZIPFixtureBuilder.Entry(
            nameBytes: Array("link".utf8),
            bytes: Array("other.txt".utf8),
            externalAttributes: UInt32(S_IFLNK | 0o777) << 16,
            extraField: RawZIPFixtureBuilder.unixSymlinkExtra(targetBytes: Array("target.txt".utf8))
        )
        await #expect(throws: ProtectedZIPError.malformedArchive) {
            try await extract(RawZIPFixtureBuilder.archive(entries: [mismatch]), password: "fixture-password")
        }

        let nulPayload = RawZIPFixtureBuilder.Entry(
            nameBytes: Array("link".utf8),
            bytes: Array("target\0evil".utf8),
            externalAttributes: UInt32(S_IFLNK | 0o777) << 16,
            extraField: RawZIPFixtureBuilder.unixSymlinkExtra(targetBytes: Array("target\0evil".utf8))
        )
        await #expect(throws: ProtectedZIPError.unsafeEntry) {
            try await extract(RawZIPFixtureBuilder.archive(entries: [nulPayload]), password: "fixture-password")
        }

        let encryptedMismatch = try Data(contentsOf: protectedZIPFixtureURL("minizip-aes256-symlink-mismatch.zip"))
        await #expect(throws: ProtectedZIPError.incorrectPasswordOrDamagedData) {
            try await extract(encryptedMismatch, password: "fixture-aes-symlink-passphrase")
        }

        let encryptedNUL = try Data(contentsOf: protectedZIPFixtureURL("minizip-aes256-symlink-nul.zip"))
        let encryptedNULInspection = try await preflight(encryptedNUL)
        #expect(encryptedNULInspection.entryCount == 1)
        await #expect(throws: ProtectedZIPError.unsafeEntry) {
            try await extract(encryptedNUL, password: "fixture-aes-symlink-passphrase")
        }
    }

    @Test func readerRejectsTraversalWithoutPublishingBytes() async throws {
        let fixture = RawZIPFixtureBuilder.archive(entries: [
            .regular(name: "../escape.txt", bytes: [1, 2, 3])
        ])
        let outside = FileManager.default.temporaryDirectory.appending(path: "escape.txt")
        try? FileManager.default.removeItem(at: outside)
        await #expect(throws: ProtectedZIPError.unsafeEntry) {
            try await extract(fixture, password: "fixture-password")
        }
        #expect(FileManager.default.fileExists(atPath: outside.path) == false)
    }

    @Test(arguments: [
        "/absolute.txt",
        "C:\\absolute.txt",
        "a/../../escape.txt",
        "a\\..\\escape.txt"
    ])
    func readerRejectsAbsoluteAndTraversalPaths(_ name: String) async throws {
        let fixture = RawZIPFixtureBuilder.archive(entries: [
            .regular(name: name, bytes: [1])
        ])
        await #expect(throws: ProtectedZIPError.unsafeEntry) {
            try await extract(fixture, password: "fixture-password")
        }
    }

    @Test func readerRejectsNULAndOverlongPaths() async throws {
        let nulName = RawZIPFixtureBuilder.Entry(nameBytes: [97, 0, 98, 46, 116, 120, 116], bytes: [1])
        let nulFixture = RawZIPFixtureBuilder.archive(entries: [nulName])
        await #expect(throws: ProtectedZIPError.unsafeEntry) {
            try await extract(nulFixture, password: "fixture-password")
        }

        let overlongName = String(repeating: "a", count: 5_000)
        let overlongFixture = RawZIPFixtureBuilder.archive(entries: [
            .regular(name: overlongName, bytes: [1])
        ])
        await #expect(throws: ProtectedZIPError.unsafeEntry) {
            try await extract(overlongFixture, password: "fixture-password")
        }
    }

    @Test func readerRejectsDuplicatesAndTopologyConflicts() async throws {
        let duplicate = RawZIPFixtureBuilder.archive(entries: [
            .regular(name: "same.txt", bytes: [1]),
            .regular(name: "same.txt", bytes: [2])
        ])
        await #expect(throws: ProtectedZIPError.unsafeEntry) {
            try await extract(duplicate, password: "fixture-password")
        }

        let fileDirectoryConflict = RawZIPFixtureBuilder.archive(entries: [
            .regular(name: "node", bytes: [1]),
            .regular(name: "node/child.txt", bytes: [2])
        ])
        await #expect(throws: ProtectedZIPError.unsafeEntry) {
            try await extract(fileDirectoryConflict, password: "fixture-password")
        }
    }

    @Test func readerRejectsEscapingLinksAndDescendantsBelowLinks() async throws {
        let escaping = RawZIPFixtureBuilder.archive(entries: [
            .symlink(name: "link", target: "../outside")
        ])
        await #expect(throws: ProtectedZIPError.unsafeEntry) {
            try await extract(escaping, password: "fixture-password")
        }

        let descendant = RawZIPFixtureBuilder.archive(entries: [
            .symlink(name: "link", target: "inside.txt"),
            .regular(name: "link/child.txt", bytes: [3])
        ])
        await #expect(throws: ProtectedZIPError.unsafeEntry) {
            try await extract(descendant, password: "fixture-password")
        }
    }

    @Test func readerRejectsSpecialFileModes() async throws {
        for entry in [
            RawZIPFixtureBuilder.Entry.fifo(name: "named-pipe"),
            RawZIPFixtureBuilder.Entry.blockDevice(name: "block-device"),
            RawZIPFixtureBuilder.Entry.socket(name: "socket")
        ] {
            await #expect(throws: ProtectedZIPError.unsafeEntry) {
                try await extract(RawZIPFixtureBuilder.archive(entries: [entry]), password: "fixture-password")
            }
        }
    }

    @Test func readerRejectsCaseAndUnicodeNormalizationCollisionsOnTheActualVolume() async throws {
        let caseCollision = RawZIPFixtureBuilder.archive(entries: [
            .regular(name: "Collision.txt", bytes: [1]),
            .regular(name: "collision.txt", bytes: [2])
        ])
        await #expect(throws: ProtectedZIPError.unsafeEntry) {
            try await preflight(caseCollision)
        }

        let unicodeCollision = RawZIPFixtureBuilder.archive(entries: [
            .regular(name: "Café.txt", bytes: [1]),
            .regular(name: "Cafe\u{301}.txt", bytes: [2])
        ])
        await #expect(throws: ProtectedZIPError.unsafeEntry) {
            try await preflight(unicodeCollision)
        }
    }

    @Test func preflightRejectsUnsupportedCompressionBeforePassword() async throws {
        let fixture = RawZIPFixtureBuilder.archive(entries: [
            .regular(name: "unsupported.bin", bytes: [1], compressionMethod: 12)
        ])
        await #expect(throws: ProtectedZIPError.unsupportedCompression) {
            try await preflight(fixture)
        }
    }

    @Test func preflightRejectsUnsupportedEncryptionBeforePassword() async throws {
        let fixture = RawZIPFixtureBuilder.archive(entries: [
            .regular(name: "strong.bin", bytes: [1], flags: (1 << 0) | (1 << 6))
        ])
        await #expect(throws: ProtectedZIPError.unsupportedEncryption) {
            try await preflight(fixture)
        }
    }

    @Test func readerRejectsMoreThanOneHundredThousandEntries() async throws {
        let entries = (0...100_000).map { index in
            RawZIPFixtureBuilder.Entry.regular(name: "entry-\(index).txt", bytes: [])
        }
        let fixture = RawZIPFixtureBuilder.archive(entries: entries)
        await #expect(throws: ProtectedZIPError.entryCountOverflow) {
            try await preflight(fixture)
        }
    }

    @Test func readerRejectsDeclaredSizeAndOutputBudgetOverflow() async throws {
        let fixture = RawZIPFixtureBuilder.archive(entries: [
            RawZIPFixtureBuilder.Entry(
                nameBytes: Array("oversized.bin".utf8),
                bytes: [1, 2, 3],
                declaredCompressedSize: 64,
                declaredUncompressedSize: 64
            )
        ])
        await #expect(throws: ProtectedZIPError.outputBudgetOverflow) {
            try await preflight(
                fixture,
                limits: ProtectedZIPLimits(maximumOutputByteCount: 32, capacityReserveByteCount: ProtectedZIPLimits.minimumCapacityReserve)
            )
        }

        let malformedDirectory = RawZIPFixtureBuilder.archive(entries: [
            RawZIPFixtureBuilder.Entry(
                nameBytes: Array("directory/".utf8),
                bytes: [1],
                externalAttributes: UInt32(S_IFDIR) << 16,
                declaredUncompressedSize: 1
            )
        ])
        await #expect(throws: ProtectedZIPError.malformedArchive) {
            try await preflight(malformedDirectory)
        }

        let aggregateOverflow = RawZIPFixtureBuilder.archive(entries: [
            .regular(name: "huge-a.bin", bytes: [], declaredUncompressedSize: UInt64(Int64.max) - 100),
            .regular(name: "huge-b.bin", bytes: [], declaredUncompressedSize: 200)
        ])
        let wideLimits = ProtectedZIPLimits(
            maximumOutputByteCount: Int64.max,
            capacityReserveByteCount: ProtectedZIPLimits.minimumCapacityReserve
        )
        await #expect(throws: ProtectedZIPError.entryCountOverflow) {
            try await preflight(aggregateOverflow, limits: wideLimits)
        }
        await #expect(throws: ProtectedZIPError.entryCountOverflow) {
            try await extract(aggregateOverflow, password: "fixture-password", limits: wideLimits)
        }
    }

    @Test func metadataRoundTripPreservesSanitizedModeAndDOSMTime() async throws {
        // 2024-01-02 03:04:06 in DOS date/time representation.
        let dosDate = UInt16((2024 - 1980) << 9 | 1 << 5 | 2)
        let dosTime = UInt16(3 << 11 | 4 << 5 | 3)
        let fixture = RawZIPFixtureBuilder.archive(entries: [
            RawZIPFixtureBuilder.Entry(
                nameBytes: Array("folder/file.txt".utf8),
                bytes: [7],
                externalAttributes: UInt32(S_IFREG | 0o640) << 16,
                dosTime: dosTime,
                dosDate: dosDate
            ),
            RawZIPFixtureBuilder.Entry(
                nameBytes: Array("folder/".utf8),
                bytes: [],
                externalAttributes: UInt32(S_IFDIR | 0o750) << 16,
                dosTime: dosTime,
                dosDate: dosDate
            )
        ])
        let root = try await extract(fixture, password: "fixture-password")
        let file = root.appending(path: "folder/file.txt")
        let folder = root.appending(path: "folder", directoryHint: .isDirectory)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let folderAttributes = try FileManager.default.attributesOfItem(atPath: folder.path)
        #expect((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o640)
        #expect((folderAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o750)
        let expected = DateComponents(calendar: Calendar.current, timeZone: TimeZone.current, year: 2024, month: 1, day: 2, hour: 3, minute: 4, second: 6).date!
        let actual = fileAttributes[.modificationDate] as! Date
        #expect(abs(actual.timeIntervalSince(expected)) <= 2)
    }

    @Test func nestedDirectoryMetadataAppliesDeepestFirst() async throws {
        // Child metadata is deliberately listed before its restrictive parent
        // in central-directory order. Extraction must apply directory metadata
        // deepest-first so reopening the child does not require execute access
        // through the already-restricted parent.
        let dosDate = UInt16((2024 - 1980) << 9 | 1 << 5 | 2)
        let dosTime = UInt16(3 << 11 | 4 << 5 | 3)
        let fixture = RawZIPFixtureBuilder.archive(entries: [
            RawZIPFixtureBuilder.Entry(
                nameBytes: Array("parent/child/".utf8),
                bytes: [],
                externalAttributes: UInt32(S_IFDIR | 0o750) << 16,
                dosTime: dosTime,
                dosDate: dosDate
            ),
            RawZIPFixtureBuilder.Entry(
                nameBytes: Array("parent/".utf8),
                bytes: [],
                externalAttributes: UInt32(S_IFDIR) << 16,
                dosTime: dosTime,
                dosDate: dosDate
            ),
            RawZIPFixtureBuilder.Entry(
                nameBytes: Array("parent/child/file.txt".utf8),
                bytes: [7],
                externalAttributes: UInt32(S_IFREG | 0o640) << 16,
                dosTime: dosTime,
                dosDate: dosDate
            )
        ])
        let root = try await extract(fixture, password: "fixture-password")
        let parent = root.appending(path: "parent", directoryHint: .isDirectory)
        let parentAttributes = try FileManager.default.attributesOfItem(atPath: parent.path)
        // A mode-000 parent cannot be traversed by ordinary path lookups; the
        // extraction helper has already returned, so restore execute access for
        // assertions without changing the on-disk metadata under test.
        #expect(Darwin.chmod(parent.path, 0o755) == 0)
        let child = parent.appending(path: "child", directoryHint: .isDirectory)
        let file = child.appending(path: "file.txt")
        let childAttributes = try FileManager.default.attributesOfItem(atPath: child.path)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((parentAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o000)
        #expect((childAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o750)
        #expect((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o640)
        let expected = DateComponents(calendar: Calendar.current, timeZone: TimeZone.current, year: 2024, month: 1, day: 2, hour: 3, minute: 4, second: 6).date!
        for attributes in [parentAttributes, childAttributes, fileAttributes] {
            let actual = attributes[.modificationDate] as! Date
            #expect(abs(actual.timeIntervalSince(expected)) <= 2)
        }
    }

    @Test func readerRejectsFalseDeclaredRegularSizeDuringExtraction() async throws {
        let fixture = RawZIPFixtureBuilder.archive(entries: [
            RawZIPFixtureBuilder.Entry(
                nameBytes: Array("oversized.bin".utf8),
                bytes: [1, 2, 3],
                declaredCompressedSize: 64,
                declaredUncompressedSize: 64
            )
        ])
        let generousLimits = ProtectedZIPLimits(
            maximumOutputByteCount: 1 * 1024 * 1024,
            capacityReserveByteCount: ProtectedZIPLimits.minimumCapacityReserve
        )
        await #expect(throws: ProtectedZIPError.incorrectPasswordOrDamagedData) {
            try await extract(fixture, password: "fixture-password", limits: generousLimits)
        }
    }

    @Test func readerRejectsTruncatedAuthenticationAndWrongPasswordAsRedactedDamage() async throws {
        let fixtureURL = protectedZIPFixtureURL("7zip-aes256.zip")
        let fixture = try Data(contentsOf: fixtureURL)
        var truncatedBytes = Array(fixture)
        // The final ten bytes before the central directory are the WinZip AES
        // authentication footer. Damage that footer while preserving EOCD
        // offsets so the failure is observed during authenticated reading.
        if let centralOffset = truncatedBytes.firstIndex(of: 0x50).flatMap({ first in
            stride(from: first, to: truncatedBytes.count - 3, by: 1).first {
                truncatedBytes[$0] == 0x50 && truncatedBytes[$0 + 1] == 0x4B
                    && truncatedBytes[$0 + 2] == 0x01 && truncatedBytes[$0 + 3] == 0x02
            }
        }), centralOffset >= 10 {
            for index in (centralOffset - 10)..<centralOffset { truncatedBytes[index] = 0 }
        }
        let truncated = Data(truncatedBytes)
        await #expect(throws: ProtectedZIPError.incorrectPasswordOrDamagedData) {
            try await extract(truncated, password: "fixture-aes256-passphrase")
        }

        await #expect(throws: ProtectedZIPError.incorrectPasswordOrDamagedData) {
            try await extract(fixture, password: "wrong-password")
        }
    }

    @Test func readerRejectsCapacityAndCancellationWithoutPartialOutput() async throws {
        let payload = [UInt8](repeating: 0x4A, count: 1 * 1024 * 1024)
        let fixture = RawZIPFixtureBuilder.archive(entries: [
            .regular(name: "large.bin", bytes: payload)
        ])
        await #expect(throws: ProtectedZIPError.insufficientCapacity) {
            try await extract(
                fixture,
                password: "fixture-password",
                limits: ProtectedZIPLimits(maximumOutputByteCount: Int64(payload.count), capacityReserveByteCount: Int64.max)
            )
        }

        let started = ReaderStartSignal()
        let cancellation = ReaderCancellationHandle()
        let task = Task {
            try await extract(
                fixture,
                password: "fixture-password",
                progress: { progress in
                    if progress.completedByteCount == 0 {
                        await started.signal()
                        try? await Task.sleep(for: .milliseconds(20))
                    }
                }
            )
        }
        cancellation.install { task.cancel() }
        #expect(await started.wait(timeout: .seconds(5)))
        task.cancel()
        cancellation.cancel()
        await #expect(throws: ProtectedZIPError.cancelled) { try await task.value }
    }

    @Test func cleanupTrackingFailureRollsBackNestedImplicitDirectories() async throws {
        pengrid_root_test_fail_next_tracking()
        let fixture = RawZIPFixtureBuilder.archive(entries: [
            .regular(name: "nested/implicit/payload.txt", bytes: [1, 2, 3])
        ])
        await #expect(throws: ProtectedZIPError.engineSetupFailed) {
            try await extract(fixture, password: "fixture-password")
        }
    }

    @Test func cleanupIdentitySubstitutionAndDeletionFailureEscalateRecoveryRequired() async throws {
        let fixture = RawZIPFixtureBuilder.archive(entries: [
            .regular(name: "payload.txt", bytes: [1, 2, 3])
        ])
        let limits = ProtectedZIPLimits(
            maximumOutputByteCount: 3,
            capacityReserveByteCount: Int64.max
        )
        pengrid_root_test_substitute_next_cleanup_object()
        await #expect(throws: ProtectedZIPError.recoveryRequired) {
            try await extract(fixture, password: "fixture-password", limits: limits)
        }
        pengrid_root_test_fail_next_cleanup()
        await #expect(throws: ProtectedZIPError.recoveryRequired) {
            try await extract(fixture, password: "fixture-password", limits: limits)
        }
    }

    @Test func identityStatFailureRollsBackRegularProbeWithoutResidue() async throws {
        guard let failIdentityStat = rootIdentityTestHook("pengrid_root_test_fail_next_identity_stat") else {
            #expect(Bool(false), "identity-stat test seam is not exported")
            return
        }
        failIdentityStat()
        let fixture = RawZIPFixtureBuilder.archive(entries: [
            .regular(name: "probe.txt", bytes: [1, 2, 3])
        ])
        await #expect(throws: ProtectedZIPError.engineSetupFailed) {
            try await preflight(fixture)
        }
    }

    @Test func identityStatFailureRollsBackDirectoryProbeWithoutResidue() async throws {
        guard let failIdentityStat = rootIdentityTestHook("pengrid_root_test_fail_next_identity_stat") else {
            #expect(Bool(false), "identity-stat test seam is not exported")
            return
        }
        failIdentityStat()
        let fixture = RawZIPFixtureBuilder.archive(entries: [
            .directory(name: "probe")
        ])
        await #expect(throws: ProtectedZIPError.engineSetupFailed) {
            try await preflight(fixture)
        }
    }

    @Test func identityStatFailureOnImplicitParentRollsBackNestedProbeWithoutResidue() async throws {
        guard let failIdentityStat = rootIdentityTestHook("pengrid_root_test_fail_next_identity_stat") else {
            #expect(Bool(false), "identity-stat test seam is not exported")
            return
        }
        failIdentityStat()
        let fixture = RawZIPFixtureBuilder.archive(entries: [
            .regular(name: "nested/implicit/probe.txt", bytes: [1])
        ])
        await #expect(throws: ProtectedZIPError.engineSetupFailed) {
            try await preflight(fixture)
        }
    }

    @Test func identityStatFailureOnSymlinkProbeEscalatesRecoveryWithResidue() async throws {
        guard let failSymlinkIdentityStat = rootIdentityTestHook("pengrid_root_test_fail_next_symlink_identity_stat") else {
            #expect(Bool(false), "symlink identity-stat test seam is not exported")
            return
        }
        failSymlinkIdentityStat()
        let fixture = RawZIPFixtureBuilder.archive(entries: [
            .symlink(name: "link", target: "target.txt")
        ])
        let (error, leftovers) = try await runExtractionFailure(
            fixture,
            password: "fixture-password"
        )
        #expect(error == .recoveryRequired)
        #expect(leftovers == ["link"])
    }

    @Test func identityStatRollbackFailureEscalatesRecoveryWithResidue() async throws {
        guard let failIdentityStat = rootIdentityTestHook("pengrid_root_test_fail_next_identity_stat"),
              let failRollback = rootIdentityTestHook("pengrid_root_test_fail_next_rollback") else {
            #expect(Bool(false), "identity-stat rollback test seams are not exported")
            return
        }
        failIdentityStat()
        failRollback()
        let fixture = RawZIPFixtureBuilder.archive(entries: [
            .regular(name: "payload.txt", bytes: [1, 2, 3])
        ])
        let (error, leftovers) = try await runPreflightFailure(fixture)
        #expect(error == .recoveryRequired)
        #expect(leftovers == ["payload.txt"])
    }

    @Test func nativeEntryReadCancellationLeavesOutputRootEmpty() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let archiveURL = temporary.url.appending(path: "archive.zip")
        let fixture = RawZIPFixtureBuilder.archive(entries: [
            .regular(name: "payload.bin", bytes: [UInt8](repeating: 0xA5, count: 128 * 1024))
        ])
        try fixture.write(to: archiveURL)
        let outputURL = temporary.url.appending(path: "output", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: false)
        let archiveDescriptor = try openedDescriptorForTest(archiveURL, flags: O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        let outputDescriptor = try openedDescriptorForTest(outputURL, flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        defer { Darwin.close(archiveDescriptor); Darwin.close(outputDescriptor) }
        let state = NativeCancellationState()
        let password = Array("fixture-password".utf8)
        let limits = pengrid_zip_limits_t(
            maximum_entry_count: 100_000,
            maximum_output_bytes: 16 * 1024 * 1024,
            capacity_reserve_bytes: 0
        )
        let status = password.withUnsafeBytes { bytes in
            pengrid_zip_extract(
                archiveDescriptor,
                outputDescriptor,
                bytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                bytes.count,
                limits,
                pengrid_test_cancel_during_native_read,
                Unmanaged.passUnretained(state).toOpaque()
            )
        }
        #expect(status == PENGRID_ZIP_STATUS_CANCELLED)
        #expect(state.didRead)
        #expect(try FileManager.default.contentsOfDirectory(at: outputURL, includingPropertiesForKeys: nil).isEmpty)
    }

    @Test func publicReaderAnchorsOwnedDescriptorsWhenCallerFdsAreClosedAndReused() throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let archiveURL = temporary.url.appending(path: "archive.zip")
        let replacementArchiveURL = temporary.url.appending(path: "replacement.zip")
        let outputURL = temporary.url.appending(path: "output", directoryHint: .isDirectory)
        let replacementOutputURL = temporary.url.appending(path: "replacement-output", directoryHint: .isDirectory)
        try RawZIPFixtureBuilder.archive(entries: [
            .regular(name: "payload.txt", bytes: Array("anchored".utf8))
        ]).write(to: archiveURL)
        try Data([0x50, 0x4B, 0x05, 0x06, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]).write(to: replacementArchiveURL)
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: replacementOutputURL, withIntermediateDirectories: false)
        let archiveDescriptor = try openedDescriptorForTest(archiveURL, flags: O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        let outputDescriptor = try openedDescriptorForTest(outputURL, flags: O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        defer { Darwin.close(archiveDescriptor); Darwin.close(outputDescriptor) }
        let state = NativeReanchorState(
            archiveDescriptor: archiveDescriptor,
            destinationDescriptor: outputDescriptor,
            replacementArchive: replacementArchiveURL,
            replacementDestination: replacementOutputURL
        )
        let limits = pengrid_zip_limits_t(
            maximum_entry_count: 100_000,
            maximum_output_bytes: 16 * 1024 * 1024,
            capacity_reserve_bytes: 0
        )
        let password = Array("fixture-password".utf8)
        let status = password.withUnsafeBytes { bytes in
            pengrid_zip_extract(
                archiveDescriptor,
                outputDescriptor,
                bytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                bytes.count,
                limits,
                pengrid_test_reanchor_progress,
                Unmanaged.passUnretained(state).toOpaque()
            )
        }
        #expect(status == PENGRID_ZIP_STATUS_OK)
        #expect(try String(contentsOf: outputURL.appending(path: "payload.txt"), encoding: .utf8) == "anchored")
        #expect(try FileManager.default.contentsOfDirectory(at: replacementOutputURL, includingPropertiesForKeys: nil).isEmpty)
        #expect(Darwin.fcntl(archiveDescriptor, F_GETFD) >= 0)
        #expect(Darwin.fcntl(outputDescriptor, F_GETFD) >= 0)
    }

    @Test func extractionSecretIsInvalidatedOnSuccessFailureAndCancellation() async throws {
        let successProbe = SecretCleanupProbe()
        _ = try await extract(
            RawZIPFixtureBuilder.archive(entries: [.regular(name: "ok.txt", bytes: [1])]),
            password: "fixture-password",
            secretCleanup: successProbe.cleanup
        )
        #expect(successProbe.didCleanup)

        let failureProbe = SecretCleanupProbe()
        await #expect(throws: ProtectedZIPError.incorrectPasswordOrDamagedData) {
            try await extract(
                try Data(contentsOf: protectedZIPFixtureURL("7zip-aes256.zip")),
                password: "wrong-password",
                secretCleanup: failureProbe.cleanup
            )
        }
        #expect(failureProbe.didCleanup)

        let cancellationProbe = SecretCleanupProbe()
        let payload = [UInt8](repeating: 0x5A, count: 1 * 1024 * 1024)
        let started = ReaderStartSignal()
        let task = Task {
            try await extract(
                RawZIPFixtureBuilder.archive(entries: [.regular(name: "cancel.bin", bytes: payload)]),
                password: "fixture-password",
                secretCleanup: cancellationProbe.cleanup,
                progress: { progress in
                    if progress.completedByteCount == 0 {
                        await started.signal()
                        try? await Task.sleep(for: .milliseconds(20))
                    }
                }
            )
        }
        #expect(await started.wait(timeout: .seconds(5)))
        task.cancel()
        await #expect(throws: ProtectedZIPError.cancelled) { try await task.value }
        #expect(cancellationProbe.didCleanup)
    }

    private func expectFixture(
        _ filename: String,
        password: String,
        expectedName: String,
        expectedBytes: [UInt8]
    ) async throws {
        let fixture = try Data(contentsOf: protectedZIPFixtureURL(filename))
        let root = try await extract(fixture, password: password)
        let item = root.appending(path: expectedName)
        #expect(FileManager.default.fileExists(atPath: item.path))
        #expect(try Array(Data(contentsOf: item)) == expectedBytes)
    }

    @discardableResult
    private func preflight(
        _ fixture: Data,
        limits: ProtectedZIPLimits = ProtectedZIPLimits(
            maximumOutputByteCount: 16 * 1024 * 1024,
            capacityReserveByteCount: ProtectedZIPLimits.minimumCapacityReserve
        )
    ) async throws -> ProtectedZIPInspection {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let archiveURL = temporary.url.appending(path: "archive.zip")
        try fixture.write(to: archiveURL)
        let archive = try openedArchive(archiveURL)
        defer { archive.close() }
        let probeURL = temporary.url.appending(path: "probe", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: probeURL, withIntermediateDirectories: false)
        let probe = try openedDirectoryRoot(probeURL)
        defer { Darwin.close(probe.descriptor) }
        do {
            let result = try await LiveProtectedZIPEngine().preflight(
                archive: archive,
                destinationProbeRoot: probe,
                limits: limits
            )
            #expect(try FileManager.default.contentsOfDirectory(at: probeURL, includingPropertiesForKeys: nil).isEmpty)
            return result
        } catch {
            #expect(try FileManager.default.contentsOfDirectory(at: probeURL, includingPropertiesForKeys: nil).isEmpty)
            throw error
        }
    }

    private func runPreflightFailure(_ fixture: Data) async throws -> (ProtectedZIPError, [String]) {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let archiveURL = temporary.url.appending(path: "archive.zip")
        try fixture.write(to: archiveURL)
        let archive = try openedArchive(archiveURL)
        defer { archive.close() }
        let probeURL = temporary.url.appending(path: "probe", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: probeURL, withIntermediateDirectories: false)
        let probe = try openedDirectoryRoot(probeURL)
        defer { Darwin.close(probe.descriptor) }
        do {
            _ = try await LiveProtectedZIPEngine().preflight(
                archive: archive,
                destinationProbeRoot: probe,
                limits: ProtectedZIPLimits(
                    maximumOutputByteCount: 16 * 1024 * 1024,
                    capacityReserveByteCount: ProtectedZIPLimits.minimumCapacityReserve
                )
            )
            return (.engineSetupFailed, try directoryNames(at: probeURL))
        } catch let error as ProtectedZIPError {
            return (error, try directoryNames(at: probeURL))
        }
    }

    private func runExtractionFailure(
        _ fixture: Data,
        password: String
    ) async throws -> (ProtectedZIPError, [String]) {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let archiveURL = temporary.url.appending(path: "archive.zip")
        try fixture.write(to: archiveURL)
        let archive = try openedArchive(archiveURL)
        defer { archive.close() }
        let destinationURL = temporary.url.appending(path: "output", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: false)
        let destination = try openedDirectoryRoot(destinationURL)
        defer { Darwin.close(destination.descriptor) }
        do {
            let secret = try ArchiveSecret.extraction(password: password)
            try await LiveProtectedZIPEngine().extract(
                archive: archive,
                destinationRoot: destination,
                password: secret,
                limits: ProtectedZIPLimits(
                    maximumOutputByteCount: 16 * 1024 * 1024,
                    capacityReserveByteCount: ProtectedZIPLimits.minimumCapacityReserve
                ),
                progress: { _ in }
            )
            return (.engineSetupFailed, try directoryNames(at: destinationURL))
        } catch let error as ProtectedZIPError {
            return (error, try directoryNames(at: destinationURL))
        }
    }

    private func directoryNames(at url: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            .map(\.lastPathComponent)
            .sorted()
    }

    private func extract(
        _ fixture: Data,
        password: String,
        limits: ProtectedZIPLimits = ProtectedZIPLimits(
            maximumOutputByteCount: 16 * 1024 * 1024,
            capacityReserveByteCount: ProtectedZIPLimits.minimumCapacityReserve
        ),
        secretCleanup: ((UnsafeMutableRawPointer, Int) -> Void)? = nil,
        progress: @escaping @Sendable (ProtectedZIPProgress) async -> Void = { _ in }
    ) async throws -> URL {
        let temporary = try TemporaryDirectory()
        let archiveURL = temporary.url.appending(path: "archive.zip")
        try fixture.write(to: archiveURL)
        let archive = try openedArchive(archiveURL)
        let destinationURL = temporary.url.appending(path: "output", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: false)
        let destination = try openedDirectoryRoot(destinationURL)
        do {
            let secret: ArchiveSecret
            if let secretCleanup {
                secret = ArchiveSecret(utf8: Array(password.utf8), cleanup: secretCleanup)
            } else {
                secret = try ArchiveSecret.extraction(password: password)
            }
            try await LiveProtectedZIPEngine().extract(
                archive: archive,
                destinationRoot: destination,
                password: secret,
                limits: limits,
                progress: progress
            )
        } catch {
            if (error as? ProtectedZIPError) != .recoveryRequired {
                let leftovers = try FileManager.default.contentsOfDirectory(at: destinationURL, includingPropertiesForKeys: nil)
                #expect(leftovers.isEmpty)
            }
            archive.close()
            Darwin.close(destination.descriptor)
            let snapshot = temporary.url
            // Keep the root alive long enough for callers that need to inspect
            // it only on success; failed calls are expected to leave no files.
            try? FileManager.default.removeItem(at: snapshot)
            throw error
        }
        archive.close()
        Darwin.close(destination.descriptor)
        let result = destinationURL
        // The temporary directory is intentionally retained by moving the
        // output into a second temporary location for the assertion helper.
        let retained = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: retained, withIntermediateDirectories: false)
        let retainedOutput = retained.appending(path: "output", directoryHint: .isDirectory)
        try FileManager.default.moveItem(at: result, to: retainedOutput)
        try? FileManager.default.removeItem(at: temporary.url)
        return retainedOutput
    }

    private func protectedZIPFixtureURL(_ filename: String) -> URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures/ProtectedZIP", directoryHint: .isDirectory)
            .appending(path: filename)
    }

    private func firstCentralDirectoryOffset(in bytes: [UInt8]) -> Int? {
        guard bytes.count >= 4 else { return nil }
        return stride(from: 0, to: bytes.count - 3, by: 1).first { index in
            bytes[index] == 0x50 && bytes[index + 1] == 0x4B
                && bytes[index + 2] == 0x01 && bytes[index + 3] == 0x02
        }
    }

    private func openedArchive(_ url: URL) throws -> OpenedFileSystemItem {
        let descriptor = url.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) }
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return OpenedFileSystemItem(identity: archiveTestIdentity(for: url), descriptor: descriptor, url: url)
    }

    private func openedDirectoryRoot(_ url: URL) throws -> OpenedEmptyFileSystemItem {
        let descriptor = url.path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return OpenedEmptyFileSystemItem(identity: archiveTestIdentity(for: url), descriptor: descriptor)
    }
}

private actor ReaderStartSignal {
    private var signaled = false

    func signal() { signaled = true }

    func wait(timeout: Duration) async -> Bool {
        let start = ContinuousClock.now
        while !signaled {
            if start.duration(to: ContinuousClock.now) >= timeout { return false }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return true
    }
}

private actor ReaderProgressRecorder {
    private(set) var last: ProtectedZIPProgress?

    func record(_ progress: ProtectedZIPProgress) {
        last = progress
    }
}

private final class ReaderCancellationHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (() -> Void)?

    func install(_ action: @escaping () -> Void) {
        lock.lock()
        self.action = action
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        let action = self.action
        lock.unlock()
        action?()
    }
}

private final class NativeReanchorState: @unchecked Sendable {
    let archiveDescriptor: Int32
    let destinationDescriptor: Int32
    let replacementArchive: URL
    let replacementDestination: URL
    private let lock = NSLock()
    private var didReanchor = false

    init(
        archiveDescriptor: Int32,
        destinationDescriptor: Int32,
        replacementArchive: URL,
        replacementDestination: URL
    ) {
        self.archiveDescriptor = archiveDescriptor
        self.destinationDescriptor = destinationDescriptor
        self.replacementArchive = replacementArchive
        self.replacementDestination = replacementDestination
    }

    func reanchorIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard !didReanchor else { return }
        didReanchor = true
        Darwin.close(archiveDescriptor)
        let replacementArchiveDescriptor = replacementArchive.path.withCString {
            Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        if replacementArchiveDescriptor >= 0 {
            if replacementArchiveDescriptor != archiveDescriptor {
                _ = Darwin.dup2(replacementArchiveDescriptor, archiveDescriptor)
                Darwin.close(replacementArchiveDescriptor)
            }
        }
        Darwin.close(destinationDescriptor)
        let replacementDestinationDescriptor = replacementDestination.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        if replacementDestinationDescriptor >= 0 {
            if replacementDestinationDescriptor != destinationDescriptor {
                _ = Darwin.dup2(replacementDestinationDescriptor, destinationDescriptor)
                Darwin.close(replacementDestinationDescriptor)
            }
        }
    }
}

private final class NativeCancellationState: @unchecked Sendable {
    var didRead = false
}

private func openedDescriptorForTest(_ url: URL, flags: Int32) throws -> Int32 {
    let descriptor = url.path.withCString { Darwin.open($0, flags) }
    guard descriptor >= 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return descriptor
}

private final class SecretCleanupProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var cleaned = false

    var didCleanup: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cleaned
    }

    func cleanup(_ bytes: UnsafeMutableRawPointer, _ length: Int) {
        pengrid_secure_clear(bytes, length)
        lock.lock()
        cleaned = true
        lock.unlock()
    }
}
