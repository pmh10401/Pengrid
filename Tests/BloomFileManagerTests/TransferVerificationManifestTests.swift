import Darwin
import Foundation
import Testing
@testable import BloomFileManager

@Suite(.serialized)
struct TransferVerificationManifestTests {
    @Test func productionBudgetAcceptsDocumentedBoundariesAndRejectsOverflow() throws {
        var entryBudget = TransferVerificationBudget(limits: .production)
        for _ in 0..<250_000 {
            try entryBudget.includeDescendant(atDepth: 1, regularFileSize: nil)
        }
        #expect(entryBudget.descendantCount == 250_000)
        #expect(throws: TransferVerificationManifestError.scopeTooLarge) {
            try entryBudget.includeDescendant(atDepth: 1, regularFileSize: nil)
        }

        var depthBudget = TransferVerificationBudget(limits: .production)
        try depthBudget.includeDescendant(atDepth: 256, regularFileSize: nil)
        #expect(throws: TransferVerificationManifestError.scopeTooLarge) {
            try depthBudget.includeDescendant(atDepth: 257, regularFileSize: nil)
        }

        var byteBudget = TransferVerificationBudget(limits: .production)
        try byteBudget.includeRoot(regularFileSize: .max)
        #expect(byteBudget.logicalByteCount == .max)
        #expect(throws: TransferVerificationManifestError.scopeTooLarge) {
            try byteBudget.includeDescendant(atDepth: 1, regularFileSize: 1)
        }
    }

    @Test func comparisonKeysNormalizeCanonicallyAndHonorCasePolicy() throws {
        let decomposed = "e\u{301}"
        let composed = "\u{e9}"

        #expect(
            TransferVerificationComparisonKeyBuilder.key(
                for: ["Folder", decomposed],
                policy: .caseSensitiveCanonical
            ) == ["Folder", composed]
        )
        #expect(
            TransferVerificationComparisonKeyBuilder.key(
                for: ["FOLDER", composed],
                policy: .caseInsensitiveCanonical
            ) == ["folder", composed]
        )
        try TransferVerificationComparisonKeyBuilder.requireUnique(
            [["A"], ["a"]],
            policy: .caseSensitiveCanonical
        )
        #expect(throws: TransferVerificationManifestError.structureMismatch) {
            try TransferVerificationComparisonKeyBuilder.requireUnique(
                [["A"], ["a"]],
                policy: .caseInsensitiveCanonical
            )
        }
        #expect(throws: TransferVerificationManifestError.structureMismatch) {
            try TransferVerificationComparisonKeyBuilder.requireUnique(
                [[decomposed], [composed]],
                policy: .caseSensitiveCanonical
            )
        }
        var productionSiblingKeys = Set<String>()
        try TransferVerificationComparisonKeyBuilder.insertUnique(
            FilenameComparisonPolicy.caseInsensitiveCanonical.key(for: "Alpha"),
            into: &productionSiblingKeys
        )
        #expect(throws: TransferVerificationManifestError.structureMismatch) {
            try TransferVerificationComparisonKeyBuilder.insertUnique(
                FilenameComparisonPolicy.caseInsensitiveCanonical.key(for: "alpha"),
                into: &productionSiblingKeys
            )
        }
    }

    @Test func syntheticQuarterMillionDeepLeavesPairWithoutPathArrayRetention() throws {
        let fixture = try TransferVerificationManifest.makeSyntheticPairForTesting(
            descendantCount: 250_000,
            regularFileDepth: 256
        )
        defer {
            fixture.source.close()
            fixture.staged.close()
        }

        #expect(fixture.source.pathStorageMetrics.nodeCount == 250_001)
        #expect(
            fixture.source.pathStorageMetrics.retainedPathComponentCount == 250_000
        )
        #expect(fixture.source.regularFileCount > 249_000)
        #expect(!fixture.source.sharesAuthorityForTesting(with: fixture.staged))

        let pairs = try fixture.source.regularFilePairs(matching: fixture.staged)
        #expect(pairs.count == fixture.source.regularFileCount)
        #expect(pairs.count > 249_000)
        #expect(pairs.first?.source.comparisonKey.count == 256)
        #expect(pairs.last?.staged.comparisonKey.count == 256)
    }

    @Test func stableChildComparisonCancellationReturnsCancelledAtOffset256() async throws {
        let fixture = try TransferVerificationManifest.makeSyntheticPairForTesting(
            descendantCount: 1_024,
            regularFileDepth: 1
        )
        defer {
            fixture.source.close()
            fixture.staged.close()
        }

        let entered = DispatchSemaphore(value: 0)
        let proceed = DispatchSemaphore(value: 0)
        let hooks = TransferVerificationManifestTestHooks(
            duringStableChildComparison: { childOffset in
                guard childOffset == 256 else { return }
                entered.signal()
                _ = proceed.wait(timeout: .now() + 2)
            }
        )
        let task = Task {
            try LiveTransferVerificationManifestBuilder(testHooks: hooks).requireStable(
                fixture.source,
                against: fixture.staged
            )
        }

        #expect(await waitForManifestSemaphore(entered, timeout: 2))
        task.cancel()
        proceed.signal()
        await #expect(throws: TransferVerificationManifestError.cancelled) {
            try await task.value
        }
    }

    @Test func rootPathParserRejectsUnsafeOrNonUTF8RawBasenames() throws {
        let parsed = try TransferVerificationRootPathParser.split(Array("/tmp/file".utf8))
        #expect(parsed.parentPath == Array("/tmp".utf8))
        #expect(parsed.rootName == Array("file".utf8))

        for invalid in [
            Array("/tmp/".utf8),
            Array("/tmp/.".utf8),
            Array("/tmp/..".utf8),
            Array("relative".utf8),
            Array("/tmp/".utf8) + [0xff]
        ] {
            #expect(throws: TransferVerificationManifestError.unsupportedName) {
                _ = try TransferVerificationRootPathParser.split(invalid)
            }
        }
    }

    @Test func namespaceErrnosDistinguishReplacementFromReadFailure() {
        #expect(TransferVerificationPOSIXErrorClassifier.namespaceFailure(ENOENT) == .changed)
        #expect(TransferVerificationPOSIXErrorClassifier.namespaceFailure(ENOTDIR) == .changed)
        #expect(TransferVerificationPOSIXErrorClassifier.namespaceFailure(ELOOP) == .changed)
        #expect(TransferVerificationPOSIXErrorClassifier.namespaceFailure(EMFILE) == .readFailed)
        #expect(TransferVerificationPOSIXErrorClassifier.namespaceFailure(EIO) == .readFailed)
    }

    @Test func syntheticDirectoryCollectorStopsAtRemainingBudgetAndChecksCancellation() throws {
        let rawNames = [".", "..", "a", "b", "c", "unreached"].map { Array($0.utf8) }
        let source = SyntheticRawNameSource(rawNames)
        #expect(throws: TransferVerificationManifestError.scopeTooLarge) {
            _ = try TransferVerificationDirectoryNameCollector.collect(
                maximumNames: 2,
                next: source.next,
                checkCancellation: {}
            )
        }
        #expect(source.callCount == 5)

        let cancellation = SyntheticCancellationCheck(cancelAt: 3)
        let cancellableSource = SyntheticRawNameSource(
            (0..<20).map { Array("item-\($0)".utf8) }
        )
        #expect(throws: TransferVerificationManifestError.cancelled) {
            _ = try TransferVerificationDirectoryNameCollector.collect(
                maximumNames: 20,
                next: cancellableSource.next,
                checkCancellation: cancellation.check
            )
        }
        #expect(cancellableSource.callCount < 20)
    }

    @Test func regularFileRootCapturesCountsAndProvidesCloexecReader() async throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let file = temporary.url.appending(path: "payload.bin")
        try Data("pengrid".utf8).write(to: file)
        let manifest = try await capture(file)
        defer { manifest.close() }

        #expect(manifest.regularFileCount == 1)
        #expect(manifest.logicalByteCount == 7)
        let entry = try #require(manifest.regularFiles.first)
        #expect(entry.comparisonKey == [])
        #expect(entry.logicalByteCount == 7)

        let bytes = try await entry.withReaderDescriptor { descriptor in
            #expect(Darwin.fcntl(descriptor, F_GETFD) & FD_CLOEXEC != 0)
            var buffer = [UInt8](repeating: 0, count: 16)
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            guard count >= 0 else { throw POSIXError(.EIO) }
            return Array(buffer.prefix(count))
        }
        #expect(bytes == Array("pengrid".utf8))

        manifest.close()
        manifest.close()
        await #expect(throws: TransferVerificationManifestError.changed) {
            try await entry.withReaderDescriptor { _ in true }
        }
    }

    @Test func emptyRegularFileIsStillAHashableEntry() async throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let file = temporary.url.appending(path: "empty")
        try Data().write(to: file)

        let manifest = try await capture(file)
        defer { manifest.close() }
        #expect(manifest.regularFileCount == 1)
        #expect(manifest.logicalByteCount == 0)
        #expect(manifest.regularFiles.count == 1)
    }

    @Test func nestedDirectoryPackageAndSymlinksAreCapturedWithoutFollowingLinks() async throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let root = temporary.url.appending(path: "Root", directoryHint: .isDirectory)
        let nested = root.appending(path: "Nested", directoryHint: .isDirectory)
        let package = root.appending(path: "Sample.app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data("abc".utf8).write(to: nested.appending(path: "a.txt"))
        try Data("de".utf8).write(to: package.appending(path: "inside.bin"))
        try FileManager.default.createSymbolicLink(
            atPath: nested.appending(path: "link").path,
            withDestinationPath: "../Sample.app"
        )

        let manifest = try await capture(root)
        defer { manifest.close() }
        #expect(manifest.regularFileCount == 2)
        #expect(manifest.logicalByteCount == 5)
        #expect(Set(manifest.regularFiles.map(\.comparisonKey)) == [
            ["Nested", "a.txt"], ["Sample.app", "inside.bin"]
        ])

        let recaptured = try await LiveTransferVerificationManifestBuilder().recapture(manifest)
        defer { recaptured.close() }
        try LiveTransferVerificationManifestBuilder().requireStable(
            recaptured,
            against: manifest
        )
    }

    @Test func retainedPathStorageChargesEachFilesystemComponentOnce() async throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let root = temporary.url.appending(path: "Root", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        var leaf = root
        for _ in 0..<64 {
            leaf = leaf.appending(path: "d", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: leaf, withIntermediateDirectories: false)
        }
        let fileNames = (0..<64).map { "file-\($0)" }
        for fileName in fileNames {
            try Data().write(to: leaf.appending(path: fileName))
        }

        let manifest = try await capture(root)
        defer { manifest.close() }
        let before = manifest.pathStorageMetrics
        #expect(before.nodeCount == 1 + 64 + fileNames.count)
        #expect(before.retainedPathComponentCount == 64 + fileNames.count)
        #expect(
            before.rawComponentByteCount
                == 64 + fileNames.reduce(0) { $0 + $1.utf8.count }
        )

        let keys = manifest.regularFiles.map(\.comparisonKey)
        #expect(keys.count == fileNames.count)
        #expect(keys.allSatisfy { $0.count == 65 })
        #expect(manifest.pathStorageMetrics == before)
    }

    @Test func symbolicLinkRootAndOpaqueNonUTF8PayloadRemainStable() async throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let target = temporary.url.appending(path: "target")
        try Data("target".utf8).write(to: target)
        let link = temporary.url.appending(path: "root-link")
        try createRawSymbolicLink(payload: [0xff, 0xfe], at: link)

        let manifest = try await capture(link)
        defer { manifest.close() }
        #expect(manifest.regularFileCount == 0)
        #expect(manifest.logicalByteCount == 0)

        let recaptured = try await LiveTransferVerificationManifestBuilder().recapture(manifest)
        defer { recaptured.close() }
        try LiveTransferVerificationManifestBuilder().requireStable(
            recaptured,
            against: manifest
        )
    }

    @Test func sameRootStabilityUsesNofollowEntryIdentityNotResolvedTargetIdentity() async throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let target = temporary.url.appending(path: "target")
        let link = temporary.url.appending(path: "link")
        try Data("target".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let identity = try await requiredIdentity(of: link)
        let captured = try await LiveTransferVerificationManifestBuilder().capture(
            at: link,
            identifiedBy: identity,
            comparisonPolicy: .caseSensitiveCanonical
        )
        defer { captured.close() }
        let sameEntryDifferentResolvedIdentity = FileIdentity(
            entryIdentifier: identity.entryIdentifier,
            resolvedIdentifier: "different-resolved-target"
        )
        let current = try await LiveTransferVerificationManifestBuilder().capture(
            at: link,
            identifiedBy: sameEntryDifferentResolvedIdentity,
            comparisonPolicy: .caseSensitiveCanonical
        )
        defer { current.close() }

        try LiveTransferVerificationManifestBuilder().requireStable(
            current,
            against: captured
        )
    }

    @Test func nestedNonUTF8SymlinkPayloadIsComparedAsRawBytes() async throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let root = temporary.url.appending(path: "Root", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let link = root.appending(path: "opaque-link")
        try createRawSymbolicLink(payload: [0xff], at: link)
        let captured = try await capture(root)
        defer { captured.close() }

        try removeRawItem(at: link)
        try createRawSymbolicLink(payload: [0xfe], at: link)
        let current = try await LiveTransferVerificationManifestBuilder().recapture(captured)
        defer { current.close() }

        #expect(throws: TransferVerificationManifestError.changed) {
            try LiveTransferVerificationManifestBuilder().requireStable(current, against: captured)
        }
    }

    @Test func readlinkatBufferGrowsAtCapacityBoundaries() async throws {
        for (sourceLength, stagedLength) in [(256, 257), (512, 513)] {
            let temporary = try TemporaryDirectory()
            defer { temporary.remove() }
            let source = temporary.url.appending(
                path: "Source",
                directoryHint: .isDirectory
            )
            let staged = temporary.url.appending(
                path: "Staged",
                directoryHint: .isDirectory
            )
            try FileManager.default.createDirectory(
                at: source,
                withIntermediateDirectories: false
            )
            try FileManager.default.createDirectory(
                at: staged,
                withIntermediateDirectories: false
            )
            let name = "link-\(sourceLength)"
            try createRawSymbolicLink(
                payload: Array(repeating: UInt8(ascii: "x"), count: sourceLength),
                at: source.appending(path: name)
            )
            try createRawSymbolicLink(
                payload: Array(repeating: UInt8(ascii: "x"), count: stagedLength),
                at: staged.appending(path: name)
            )
            let sourceManifest = try await capture(source)
            defer { sourceManifest.close() }
            let stagedManifest = try await capture(staged)
            defer { stagedManifest.close() }

            #expect(throws: TransferVerificationManifestError.structureMismatch) {
                try LiveTransferVerificationManifestBuilder().requireEquivalentContentShape(
                    source: sourceManifest,
                    staged: stagedManifest
                )
            }
        }
    }

    @Test func fifoRootAndNestedFIFOAreRejectedWithoutBlocking() async throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let fifo = temporary.url.appending(path: "pipe")
        try makeFIFO(at: fifo)
        await #expect(throws: TransferVerificationManifestError.unsupportedItem) {
            _ = try await capture(fifo)
        }

        let root = temporary.url.appending(path: "Root", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try makeFIFO(at: root.appending(path: "nested-pipe"))
        await #expect(throws: TransferVerificationManifestError.unsupportedItem) {
            _ = try await capture(root)
        }
    }

    @Test func invalidUTF8ChildNameFailsClosedWithoutReplacementCharacters() async throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let root = temporary.url.appending(path: "Root", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        do {
            try createRawRegularFile(named: [0xff], in: root)
        } catch let error as POSIXError where error.code == .EILSEQ {
            #expect(throws: TransferVerificationManifestError.unsupportedName) {
                _ = try TransferVerificationFilenameDecoder.decode([0xff])
            }
            return
        }

        await #expect(throws: TransferVerificationManifestError.unsupportedName) {
            _ = try await capture(root)
        }
    }

    @Test func wrongIdentityAndRootReplacementFailClosed() async throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let file = temporary.url.appending(path: "file")
        let other = temporary.url.appending(path: "other")
        try Data("first".utf8).write(to: file)
        try Data("other".utf8).write(to: other)
        let otherIdentity = try await requiredIdentity(of: other)
        await #expect(throws: TransferVerificationManifestError.changed) {
            _ = try await LiveTransferVerificationManifestBuilder().capture(
                at: file,
                identifiedBy: otherIdentity,
                comparisonPolicy: .caseSensitiveCanonical
            )
        }

        let captured = try await capture(file)
        defer { captured.close() }
        try FileManager.default.removeItem(at: file)
        try Data("replacement".utf8).write(to: file)
        await #expect(throws: TransferVerificationManifestError.changed) {
            _ = try await LiveTransferVerificationManifestBuilder().recapture(captured)
        }
    }

    @Test func recaptureReportsChangedWhenRootParentNamespaceDisappears() async throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let parent = temporary.url.appending(path: "Parent", directoryHint: .isDirectory)
        let file = parent.appending(path: "payload")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        try Data("payload".utf8).write(to: file)
        let captured = try await capture(file)
        defer { captured.close() }

        try FileManager.default.removeItem(at: parent)

        await #expect(throws: TransferVerificationManifestError.changed) {
            _ = try await LiveTransferVerificationManifestBuilder().recapture(captured)
        }
    }

    @Test func directoryRootNamespaceReplacementAfterOpenIsRejected() async throws {
        if try runIsolatedManifestTestIfNeeded(
            named: "TransferVerificationManifestTests.directoryRootNamespaceReplacementAfterOpenIsRejected",
            environmentKey: "PENGRID_MANIFEST_ROOT_RACE_WORKER"
        ) {
            return
        }
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let root = temporary.url.appending(path: "Root", directoryHint: .isDirectory)
        let parked = temporary.url.appending(path: "Parked", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try Data("original".utf8).write(to: root.appending(path: "original"))
        let identity = try await requiredIdentity(of: root)
        let once = ManifestOneShot()
        let hooks = TransferVerificationManifestTestHooks(
            afterRootDirectoryOpen: {
                guard once.claim() else { return }
                try FileManager.default.moveItem(at: root, to: parked)
                try FileManager.default.createDirectory(
                    at: root,
                    withIntermediateDirectories: false
                )
                try Data("attacker".utf8).write(to: root.appending(path: "attacker"))
            }
        )

        await #expect(throws: TransferVerificationManifestError.changed) {
            _ = try await LiveTransferVerificationManifestBuilder(testHooks: hooks).capture(
                at: root,
                identifiedBy: identity,
                comparisonPolicy: .caseSensitiveCanonical
            )
        }
    }

    @Test func regularFileToFIFORaceIsRejectedWithoutOpeningBlockingEndpoint() async throws {
        if try runIsolatedManifestTestIfNeeded(
            named: "TransferVerificationManifestTests.regularFileToFIFORaceIsRejectedWithoutOpeningBlockingEndpoint",
            environmentKey: "PENGRID_MANIFEST_FIFO_RACE_WORKER"
        ) {
            return
        }
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let root = temporary.url.appending(path: "Root", directoryHint: .isDirectory)
        let payload = root.appending(path: "payload")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try Data("original".utf8).write(to: payload)
        let identity = try await requiredIdentity(of: root)
        let once = ManifestOneShot()
        let hooks = TransferVerificationManifestTestHooks(
            afterRegularFileInspection: { components in
                guard components == ["payload"], once.claim() else { return }
                try FileManager.default.removeItem(at: payload)
                try makeFIFO(at: payload)
            }
        )

        await #expect(throws: TransferVerificationManifestError.changed) {
            _ = try await LiveTransferVerificationManifestBuilder(testHooks: hooks).capture(
                at: root,
                identifiedBy: identity,
                comparisonPolicy: .caseSensitiveCanonical
            )
        }
    }

    @Test func regularFileToUnixSocketRaceReportsChanged() async throws {
        let temporaryURL = URL(filePath: "/tmp", directoryHint: .isDirectory)
            .appending(path: "pengrid-transfer-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: temporaryURL, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        let root = temporaryURL.appending(path: "Root", directoryHint: .isDirectory)
        let payload = root.appending(path: "payload")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try Data("original".utf8).write(to: payload)
        let identity = try await requiredIdentity(of: root)
        let socket = BoundUnixSocket()
        defer { socket.close() }
        let once = ManifestOneShot()
        let hooks = TransferVerificationManifestTestHooks(
            afterRegularFileInspection: { components in
                guard components == ["payload"], once.claim() else { return }
                try FileManager.default.removeItem(at: payload)
                try socket.bind(at: payload)
            }
        )

        await #expect(throws: TransferVerificationManifestError.changed) {
            _ = try await LiveTransferVerificationManifestBuilder(testHooks: hooks).capture(
                at: root,
                identifiedBy: identity,
                comparisonPolicy: .caseSensitiveCanonical
            )
        }
    }

    @Test func replacingSymlinkTargetDoesNotReplaceLinkButReplacingLinkIsDetected() async throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let external = temporary.url.appending(path: "External", directoryHint: .isDirectory)
        let root = temporary.url.appending(path: "Root", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let target = external.appending(path: "target")
        try Data("one".utf8).write(to: target)
        let link = root.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let captured = try await capture(root)
        defer { captured.close() }

        try Data("two".utf8).write(to: target)
        let targetChanged = try await LiveTransferVerificationManifestBuilder().recapture(captured)
        defer { targetChanged.close() }
        try LiveTransferVerificationManifestBuilder().requireStable(
            targetChanged,
            against: captured
        )

        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let linkChanged = try await LiveTransferVerificationManifestBuilder().recapture(captured)
        defer { linkChanged.close() }
        #expect(throws: TransferVerificationManifestError.changed) {
            try LiveTransferVerificationManifestBuilder().requireStable(
                linkChanged,
                against: captured
            )
        }
    }

    @Test func readerRejectsDirectoryNamespaceReplacementAfterComponentOpen() async throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let root = temporary.url.appending(path: "Root", directoryHint: .isDirectory)
        let folder = root.appending(path: "Folder", directoryHint: .isDirectory)
        let parked = root.appending(path: "Parked", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("original".utf8).write(to: folder.appending(path: "file"))
        let identity = try await requiredIdentity(of: root)
        let once = ManifestOneShot()
        let hooks = TransferVerificationManifestTestHooks(
            afterReaderDirectoryOpen: { components in
                guard components == ["Folder"], once.claim() else { return }
                try FileManager.default.moveItem(at: folder, to: parked)
                try FileManager.default.createDirectory(
                    at: folder,
                    withIntermediateDirectories: false
                )
                try Data("attacker".utf8).write(to: folder.appending(path: "file"))
            }
        )
        let manifest = try await LiveTransferVerificationManifestBuilder(
            testHooks: hooks
        ).capture(
            at: root,
            identifiedBy: identity,
            comparisonPolicy: .caseSensitiveCanonical
        )
        defer { manifest.close() }
        let file = try #require(manifest.regularFiles.first)

        await #expect(throws: TransferVerificationManifestError.changed) {
            try await file.withReaderDescriptor { _ in true }
        }
    }

    @Test func readerClosesParentDuplicateWhenRootDuplicationFails() async throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let root = temporary.url.appending(path: "Root", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try Data("payload".utf8).write(to: root.appending(path: "file"))
        let identity = try await requiredIdentity(of: root)
        let duplicates = InjectedDescriptorDuplicator(failAtCall: 2)
        let hooks = TransferVerificationManifestTestHooks(
            duplicateDescriptor: duplicates.duplicate
        )
        let manifest = try await LiveTransferVerificationManifestBuilder(
            testHooks: hooks
        ).capture(
            at: root,
            identifiedBy: identity,
            comparisonPolicy: .caseSensitiveCanonical
        )
        defer { manifest.close() }
        let file = try #require(manifest.regularFiles.first)

        await #expect(throws: TransferVerificationManifestError.readFailed) {
            try await file.withReaderDescriptor { _ in true }
        }
        #expect(duplicates.successfulDescriptors.count == 1)
        assertManifestDescriptorsAreClosed(duplicates.successfulDescriptors)
    }

    @Test func readerClosesBothDuplicatesWhenRootNamespaceDisappears() async throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let root = temporary.url.appending(path: "Root", directoryHint: .isDirectory)
        let parked = temporary.url.appending(path: "Parked", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try Data("payload".utf8).write(to: root.appending(path: "file"))
        let identity = try await requiredIdentity(of: root)
        let duplicates = InjectedDescriptorDuplicator()
        let hooks = TransferVerificationManifestTestHooks(
            duplicateDescriptor: duplicates.duplicate
        )
        let manifest = try await LiveTransferVerificationManifestBuilder(
            testHooks: hooks
        ).capture(
            at: root,
            identifiedBy: identity,
            comparisonPolicy: .caseSensitiveCanonical
        )
        defer { manifest.close() }
        let file = try #require(manifest.regularFiles.first)
        try FileManager.default.moveItem(at: root, to: parked)

        await #expect(throws: TransferVerificationManifestError.changed) {
            try await file.withReaderDescriptor { _ in true }
        }
        #expect(duplicates.successfulDescriptors.count == 2)
        assertManifestDescriptorsAreClosed(duplicates.successfulDescriptors)
    }

    @Test func readerHonorsCancellationBeforeDescriptorWalk() async throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let fileURL = temporary.url.appending(path: "file")
        try Data("payload".utf8).write(to: fileURL)
        let manifest = try await capture(fileURL)
        defer { manifest.close() }
        let file = try #require(manifest.regularFiles.first)
        let entered = DispatchSemaphore(value: 0)
        let proceed = DispatchSemaphore(value: 0)
        let task = Task {
            await waitForManifestRelease(entered: entered, proceed: proceed)
            return try await file.withReaderDescriptor { _ in true }
        }
        #expect(await waitForManifestSemaphore(entered, timeout: 2))
        task.cancel()
        proceed.signal()

        await #expect(throws: TransferVerificationManifestError.cancelled) {
            _ = try await task.value
        }
    }

    @Test func childReplacementAdditionRemovalAndTypeTransitionAreDetected() async throws {
        let mutations: [(URL) throws -> Void] = [
            { root in
                let child = root.appending(path: "child")
                try FileManager.default.removeItem(at: child)
                try Data("same".utf8).write(to: child)
            },
            { root in try Data("new".utf8).write(to: root.appending(path: "added")) },
            { root in try FileManager.default.removeItem(at: root.appending(path: "child")) },
            { root in
                let child = root.appending(path: "child")
                try FileManager.default.removeItem(at: child)
                try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
            }
        ]

        for mutate in mutations {
            let temporary = try TemporaryDirectory()
            defer { temporary.remove() }
            let root = temporary.url.appending(path: "Root", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            try Data("same".utf8).write(to: root.appending(path: "child"))
            let captured = try await capture(root)
            defer { captured.close() }
            try mutate(root)
            let current = try await LiveTransferVerificationManifestBuilder().recapture(captured)
            defer { current.close() }
            #expect(throws: TransferVerificationManifestError.changed) {
                try LiveTransferVerificationManifestBuilder().requireStable(
                    current,
                    against: captured
                )
            }
        }
    }

    @Test func contentShapeIgnoresIdentityAndMetadataButChecksKindSizeAndLinkPayload() async throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let source = temporary.url.appending(path: "Source", directoryHint: .isDirectory)
        let staged = temporary.url.appending(path: "Staged", directoryHint: .isDirectory)
        try makeEquivalentTree(at: source, fileData: Data("abc".utf8), linkPayload: "file")
        try makeEquivalentTree(at: staged, fileData: Data("xyz".utf8), linkPayload: "file")
        let sourceManifest = try await capture(source)
        defer { sourceManifest.close() }
        var stagedManifest = try await capture(staged)
        defer { stagedManifest.close() }

        try LiveTransferVerificationManifestBuilder().requireEquivalentContentShape(
            source: sourceManifest,
            staged: stagedManifest
        )
        let pairs = try sourceManifest.regularFilePairs(matching: stagedManifest)
        #expect(pairs.count == 1)
        #expect(pairs.first?.source.comparisonKey == ["file"])
        #expect(pairs.first?.staged.comparisonKey == ["file"])

        stagedManifest.close()
        try Data("longer".utf8).write(to: staged.appending(path: "file"))
        stagedManifest = try await capture(staged)
        #expect(throws: TransferVerificationManifestError.structureMismatch) {
            try LiveTransferVerificationManifestBuilder().requireEquivalentContentShape(
                source: sourceManifest,
                staged: stagedManifest
            )
        }

        stagedManifest.close()
        try Data("xyz".utf8).write(to: staged.appending(path: "file"))
        try FileManager.default.removeItem(at: staged.appending(path: "link"))
        try FileManager.default.createSymbolicLink(
            atPath: staged.appending(path: "link").path,
            withDestinationPath: "different"
        )
        stagedManifest = try await capture(staged)
        #expect(throws: TransferVerificationManifestError.structureMismatch) {
            try LiveTransferVerificationManifestBuilder().requireEquivalentContentShape(
                source: sourceManifest,
                staged: stagedManifest
            )
        }

        stagedManifest.close()
        try FileManager.default.removeItem(at: staged.appending(path: "link"))
        try FileManager.default.createSymbolicLink(
            atPath: staged.appending(path: "link").path,
            withDestinationPath: "file"
        )
        try FileManager.default.removeItem(at: staged.appending(path: "file"))
        try FileManager.default.createDirectory(
            at: staged.appending(path: "file", directoryHint: .isDirectory),
            withIntermediateDirectories: false
        )
        stagedManifest = try await capture(staged)
        #expect(throws: TransferVerificationManifestError.structureMismatch) {
            try LiveTransferVerificationManifestBuilder().requireEquivalentContentShape(
                source: sourceManifest,
                staged: stagedManifest
            )
        }

        stagedManifest.close()
        try FileManager.default.removeItem(at: staged.appending(path: "file"))
        try Data("xyz".utf8).write(to: staged.appending(path: "file"))
        try Data("extra".utf8).write(to: staged.appending(path: "extra"))
        stagedManifest = try await capture(staged)
        #expect(throws: TransferVerificationManifestError.structureMismatch) {
            try LiveTransferVerificationManifestBuilder().requireEquivalentContentShape(
                source: sourceManifest,
                staged: stagedManifest
            )
        }

        stagedManifest.close()
        try FileManager.default.removeItem(at: staged.appending(path: "extra"))
        try FileManager.default.removeItem(at: staged.appending(path: "file"))
        stagedManifest = try await capture(staged)
        #expect(throws: TransferVerificationManifestError.structureMismatch) {
            try LiveTransferVerificationManifestBuilder().requireEquivalentContentShape(
                source: sourceManifest,
                staged: stagedManifest
            )
        }
    }

    @Test func stableComparisonCancellationReturnsCancelledAtAnIntermediateNode() async throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let root = temporary.url.appending(path: "Root", directoryHint: .isDirectory)
        try makeTwoRegularFileTree(at: root)
        let manifest = try await capture(root)
        defer { manifest.close() }

        let entered = DispatchSemaphore(value: 0)
        let proceed = DispatchSemaphore(value: 0)
        let hooks = TransferVerificationManifestTestHooks(
            duringStableNodeComparison: { nodeIndex in
                guard nodeIndex == 1 else { return }
                entered.signal()
                _ = proceed.wait(timeout: .now() + 2)
            }
        )
        let task = Task {
            try LiveTransferVerificationManifestBuilder(testHooks: hooks).requireStable(
                manifest,
                against: manifest
            )
        }

        #expect(await waitForManifestSemaphore(entered, timeout: 2))
        task.cancel()
        proceed.signal()
        await #expect(throws: TransferVerificationManifestError.cancelled) {
            try await task.value
        }
    }

    @Test func contentShapeComparisonCancellationReturnsCancelledAtAnIntermediateNode() async throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let source = temporary.url.appending(path: "Source", directoryHint: .isDirectory)
        let staged = temporary.url.appending(path: "Staged", directoryHint: .isDirectory)
        try makeTwoRegularFileTree(at: source)
        try makeTwoRegularFileTree(at: staged)
        let sourceManifest = try await capture(source)
        defer { sourceManifest.close() }
        let stagedManifest = try await capture(staged)
        defer { stagedManifest.close() }

        let entered = DispatchSemaphore(value: 0)
        let proceed = DispatchSemaphore(value: 0)
        let hooks = TransferVerificationManifestTestHooks(
            duringContentShapeNodeComparison: { nodeIndex in
                guard nodeIndex == 1 else { return }
                entered.signal()
                _ = proceed.wait(timeout: .now() + 2)
            }
        )
        let task = Task {
            try LiveTransferVerificationManifestBuilder(testHooks: hooks)
                .requireEquivalentContentShape(
                    source: sourceManifest,
                    staged: stagedManifest
                )
        }

        #expect(await waitForManifestSemaphore(entered, timeout: 2))
        task.cancel()
        proceed.signal()
        await #expect(throws: TransferVerificationManifestError.cancelled) {
            try await task.value
        }
    }

    @Test func regularFilePairMaterializationCancellationReturnsCancelledMidway() async throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let source = temporary.url.appending(path: "Source", directoryHint: .isDirectory)
        let staged = temporary.url.appending(path: "Staged", directoryHint: .isDirectory)
        try makeTwoRegularFileTree(at: source)
        try makeTwoRegularFileTree(at: staged)
        let sourceManifest = try await capture(source)
        defer { sourceManifest.close() }
        let stagedManifest = try await capture(staged)
        defer { stagedManifest.close() }

        let entered = DispatchSemaphore(value: 0)
        let proceed = DispatchSemaphore(value: 0)
        let hooks = TransferVerificationManifestTestHooks(
            duringRegularFilePairMaterialization: { pairIndex in
                guard pairIndex == 0 else { return }
                entered.signal()
                _ = proceed.wait(timeout: .now() + 2)
            }
        )
        let task = Task {
            try sourceManifest.regularFilePairs(
                matching: stagedManifest,
                testHooks: hooks
            )
        }

        #expect(await waitForManifestSemaphore(entered, timeout: 2))
        task.cancel()
        proceed.signal()
        await #expect(throws: TransferVerificationManifestError.cancelled) {
            _ = try await task.value
        }
    }

    @Test func regularFilePairsMatchCanonicalParentSubtreesAcrossRawSiblingOrder() async throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let source = temporary.url.appending(path: "Source", directoryHint: .isDirectory)
        let staged = temporary.url.appending(path: "Staged", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: false)

        // The source is raw-sorted as Alpha, beta. The staged tree is raw-sorted
        // as BETA, alpha, while canonical case-insensitive order pairs alpha
        // with alpha and beta with beta.
        try makeDirectoryWithSizedFile(
            named: "Alpha",
            fileSize: 3,
            in: source
        )
        try makeDirectoryWithSizedFile(
            named: "beta",
            fileSize: 7,
            in: source
        )
        try makeDirectoryWithSizedFile(
            named: "BETA",
            fileSize: 7,
            in: staged
        )
        try makeDirectoryWithSizedFile(
            named: "alpha",
            fileSize: 3,
            in: staged
        )

        let sourceManifest = try await capture(
            source,
            policy: .caseInsensitiveCanonical
        )
        defer { sourceManifest.close() }
        let stagedManifest = try await capture(
            staged,
            policy: .caseInsensitiveCanonical
        )
        defer { stagedManifest.close() }

        let pairs = try sourceManifest.regularFilePairs(matching: stagedManifest)
        #expect(pairs.count == 2)
        #expect(pairs.allSatisfy { $0.source.comparisonKey == $0.staged.comparisonKey })

        let sizesByCanonicalPath = Dictionary(
            uniqueKeysWithValues: pairs.map {
                ($0.source.comparisonKey, ($0.source.logicalByteCount, $0.staged.logicalByteCount))
            }
        )
        #expect(sizesByCanonicalPath[["alpha", "payload"]]?.0 == 3)
        #expect(sizesByCanonicalPath[["alpha", "payload"]]?.1 == 3)
        #expect(sizesByCanonicalPath[["beta", "payload"]]?.0 == 7)
        #expect(sizesByCanonicalPath[["beta", "payload"]]?.1 == 7)
    }

    @Test func configuredDepthAndDescendantLimitsFailClosed() async throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let root = temporary.url.appending(path: "Root", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: root.appending(path: "one/two", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        let identity = try await requiredIdentity(of: root)

        await #expect(throws: TransferVerificationManifestError.scopeTooLarge) {
            _ = try await LiveTransferVerificationManifestBuilder(
                limits: .init(maxDescendants: 10, maxDepth: 1)
            ).capture(
                at: root,
                identifiedBy: identity,
                comparisonPolicy: .caseSensitiveCanonical
            )
        }
        await #expect(throws: TransferVerificationManifestError.scopeTooLarge) {
            _ = try await LiveTransferVerificationManifestBuilder(
                limits: .init(maxDescendants: 1, maxDepth: 10)
            ).capture(
                at: root,
                identifiedBy: identity,
                comparisonPolicy: .caseSensitiveCanonical
            )
        }
    }

    @Test func depthBoundaryWorksUnderLowDescriptorLimit() async throws {
        if try runIsolatedManifestTestIfNeeded(
            named: "TransferVerificationManifestTests.depthBoundaryWorksUnderLowDescriptorLimit",
            environmentKey: "PENGRID_MANIFEST_LOW_FD_WORKER",
            timeout: 8
        ) {
            return
        }

        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else {
            throw currentManifestTestPOSIXError()
        }
        limit.rlim_cur = 32
        guard setrlimit(RLIMIT_NOFILE, &limit) == 0 else {
            throw currentManifestTestPOSIXError()
        }

        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let root = temporary.url.appending(path: "Root", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        var directory = root
        for _ in 0..<256 {
            directory = directory.appending(path: "d", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false
            )
        }

        let manifest = try await capture(root)
        manifest.close()
    }

    @Test func cancellationClosesEnumerationDuplicateAndPreservesCloexec() async throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let root = temporary.url.appending(path: "Root", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let identity = try await requiredIdentity(of: root)
        let entered = DispatchSemaphore(value: 0)
        let proceed = DispatchSemaphore(value: 0)
        let probes = DescriptorProbeRecorder()
        let hooks = TransferVerificationManifestTestHooks(
            onDuplicatedDescriptor: { descriptor in
                probes.record(
                    descriptor: descriptor,
                    hasCloexec: Darwin.fcntl(descriptor, F_GETFD) & FD_CLOEXEC != 0
                )
                entered.signal()
                _ = proceed.wait(timeout: .now() + 2)
            }
        )
        let task = Task {
            try await LiveTransferVerificationManifestBuilder(testHooks: hooks).capture(
                at: root,
                identifiedBy: identity,
                comparisonPolicy: .caseSensitiveCanonical
            )
        }

        #expect(await waitForManifestSemaphore(entered, timeout: 2))
        task.cancel()
        proceed.signal()
        await #expect(throws: TransferVerificationManifestError.cancelled) {
            _ = try await task.value
        }
        let recorded = probes.values
        #expect(recorded.count == 1)
        #expect(recorded.allSatisfy { $0.hasCloexec })
        for probe in recorded {
            #expect(Darwin.fcntl(probe.descriptor, F_GETFD) == -1)
            #expect(errno == EBADF)
        }
    }

    @Test func ownedDescriptorClosesExactlyOnceAndSetsCloexecOnDuplicates() throws {
        let descriptors = try makePipeDescriptors()
        defer { Darwin.close(descriptors.write) }
        let recorder = DescriptorCloseRecorder()
        let owner = TransferVerificationOwnedDescriptor(
            descriptor: descriptors.read,
            closeDescriptor: { descriptor in
                recorder.record(descriptor)
                _ = Darwin.close(descriptor)
            }
        )
        let duplicate = try owner.duplicate()
        defer { Darwin.close(duplicate) }
        #expect(Darwin.fcntl(duplicate, F_GETFD) & FD_CLOEXEC != 0)

        owner.close()
        owner.close()
        #expect(recorder.descriptors == [descriptors.read])
        #expect(Darwin.fcntl(descriptors.read, F_GETFD) == -1)
        #expect(errno == EBADF)
    }

    @Test func dedicatedPOSIXErrorContextsDistinguishNamespaceLossFromResourceFailure() {
        for error in [ENOENT, ENOTDIR, ELOOP, ESTALE] {
            #expect(
                TransferVerificationPOSIXErrorClassifier.parentOpenFailure(error) == .changed
            )
        }
        for error in [EMFILE, EIO] {
            #expect(
                TransferVerificationPOSIXErrorClassifier.parentOpenFailure(error) == .readFailed
            )
        }

        for error in [EOPNOTSUPP, ENXIO] {
            #expect(
                TransferVerificationPOSIXErrorClassifier.postInspectionOpenFailure(error) == .changed
            )
        }
        for error in [EMFILE, EIO] {
            #expect(
                TransferVerificationPOSIXErrorClassifier.postInspectionOpenFailure(error) == .readFailed
            )
        }

        #expect(
            TransferVerificationPOSIXErrorClassifier.readLinkFailure(EINVAL) == .changed
        )
        for error in [EMFILE, EIO] {
            #expect(
                TransferVerificationPOSIXErrorClassifier.readLinkFailure(error) == .readFailed
            )
        }
    }

    @Test func descriptorLifecycleBalancesCaptureAndReaderBodyThrow() async throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let root = temporary.url.appending(path: "Root", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try Data("payload".utf8).write(to: root.appending(path: "payload"))
        let recorder = DescriptorLifecycleRecorder()
        let hooks = TransferVerificationManifestTestHooks(
            onDescriptorEvent: recorder.record
        )
        let identity = try await requiredIdentity(of: root)
        let manifest = try await LiveTransferVerificationManifestBuilder(
            testHooks: hooks
        ).capture(
            at: root,
            identifiedBy: identity,
            comparisonPolicy: .caseSensitiveCanonical
        )
        let entry = try #require(manifest.regularFiles.first)

        let value = try await entry.withReaderDescriptor { descriptor in
            Darwin.fcntl(descriptor, F_GETFD) & FD_CLOEXEC != 0
        }
        #expect(value)
        await #expect(throws: ManifestReaderTestError.body) {
            try await entry.withReaderDescriptor { _ in
                throw ManifestReaderTestError.body
            }
        }

        manifest.close()
        assertDescriptorLifecycleIsBalanced(recorder)
    }

    @Test func descriptorLifecycleBalancesReaderBodyCancellation() async throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let fileURL = temporary.url.appending(path: "payload")
        try Data("payload".utf8).write(to: fileURL)
        let recorder = DescriptorLifecycleRecorder()
        let hooks = TransferVerificationManifestTestHooks(
            onDescriptorEvent: recorder.record
        )
        let identity = try await requiredIdentity(of: fileURL)
        let manifest = try await LiveTransferVerificationManifestBuilder(
            testHooks: hooks
        ).capture(
            at: fileURL,
            identifiedBy: identity,
            comparisonPolicy: .caseSensitiveCanonical
        )
        let entry = try #require(manifest.regularFiles.first)
        let entered = DispatchSemaphore(value: 0)
        let proceed = DispatchSemaphore(value: 0)
        let task = Task {
            try await entry.withReaderDescriptor { _ in
                entered.signal()
                _ = await waitForManifestSemaphore(proceed, timeout: 2)
                try Task.checkCancellation()
                return true
            }
        }

        #expect(await waitForManifestSemaphore(entered, timeout: 2))
        task.cancel()
        proceed.signal()
        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }

        manifest.close()
        assertDescriptorLifecycleIsBalanced(recorder)
    }

    @Test func descriptorLifecycleBalancesEnumerationCancellation() async throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let root = temporary.url.appending(path: "Root", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try Data("payload".utf8).write(to: root.appending(path: "payload"))
        let identity = try await requiredIdentity(of: root)
        let recorder = DescriptorLifecycleRecorder()
        let entered = DispatchSemaphore(value: 0)
        let proceed = DispatchSemaphore(value: 0)
        let hooks = TransferVerificationManifestTestHooks(
            onDuplicatedDescriptor: { _ in
                entered.signal()
                _ = proceed.wait(timeout: .now() + 2)
            },
            onDescriptorEvent: recorder.record
        )
        let task = Task {
            try await LiveTransferVerificationManifestBuilder(
                testHooks: hooks
            ).capture(
                at: root,
                identifiedBy: identity,
                comparisonPolicy: .caseSensitiveCanonical
            )
        }

        #expect(await waitForManifestSemaphore(entered, timeout: 2))
        task.cancel()
        proceed.signal()
        await #expect(throws: TransferVerificationManifestError.cancelled) {
            _ = try await task.value
        }
        assertDescriptorLifecycleIsBalanced(recorder)
    }

    @Test func materializationCancellationClosesEveryDescriptorLease() async throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let root = temporary.url.appending(path: "Root", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try Data("first".utf8).write(to: root.appending(path: "first"))
        try Data("second".utf8).write(to: root.appending(path: "second"))
        let identity = try await requiredIdentity(of: root)
        let recorder = DescriptorLifecycleRecorder()
        let entered = DispatchSemaphore(value: 0)
        let proceed = DispatchSemaphore(value: 0)
        let hooks = TransferVerificationManifestTestHooks(
            onDescriptorEvent: recorder.record,
            duringRegularFileMaterialization: { entryIndex in
                guard entryIndex == 0 else { return }
                entered.signal()
                _ = proceed.wait(timeout: .now() + 2)
            }
        )
        let task = Task {
            try await LiveTransferVerificationManifestBuilder(
                testHooks: hooks
            ).capture(
                at: root,
                identifiedBy: identity,
                comparisonPolicy: .caseSensitiveCanonical
            )
        }

        #expect(await waitForManifestSemaphore(entered, timeout: 2))
        task.cancel()
        proceed.signal()
        await #expect(throws: TransferVerificationManifestError.cancelled) {
            _ = try await task.value
        }
        assertDescriptorLifecycleIsBalanced(recorder)
    }

    @Test func descriptorLifecycleBalancesReaderComponentHookFailure() async throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let root = temporary.url.appending(path: "Root", directoryHint: .isDirectory)
        let folder = root.appending(path: "Folder", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("payload".utf8).write(to: folder.appending(path: "payload"))
        let identity = try await requiredIdentity(of: root)
        let recorder = DescriptorLifecycleRecorder()
        let hooks = TransferVerificationManifestTestHooks(
            onDescriptorEvent: recorder.record,
            afterReaderDirectoryOpen: { components in
                guard components == ["Folder"] else { return }
                throw TransferVerificationManifestError.readFailed
            }
        )
        let manifest = try await LiveTransferVerificationManifestBuilder(
            testHooks: hooks
        ).capture(
            at: root,
            identifiedBy: identity,
            comparisonPolicy: .caseSensitiveCanonical
        )
        let entry = try #require(manifest.regularFiles.first)

        await #expect(throws: TransferVerificationManifestError.readFailed) {
            try await entry.withReaderDescriptor { _ in true }
        }
        manifest.close()
        assertDescriptorLifecycleIsBalanced(recorder)
    }

    @Test func readerComponentWalkCancellationAtFirstComponentClosesEveryLease() async throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let root = temporary.url.appending(path: "Root", directoryHint: .isDirectory)
        let folder = root.appending(path: "Folder", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("payload".utf8).write(to: folder.appending(path: "payload"))
        let identity = try await requiredIdentity(of: root)
        let recorder = DescriptorLifecycleRecorder()
        let entered = DispatchSemaphore(value: 0)
        let proceed = DispatchSemaphore(value: 0)
        let hooks = TransferVerificationManifestTestHooks(
            onDescriptorEvent: recorder.record,
            afterReaderDirectoryOpen: { components in
                guard components == ["Folder"] else { return }
                entered.signal()
                _ = proceed.wait(timeout: .now() + 2)
            }
        )
        let manifest = try await LiveTransferVerificationManifestBuilder(
            testHooks: hooks
        ).capture(
            at: root,
            identifiedBy: identity,
            comparisonPolicy: .caseSensitiveCanonical
        )
        let entry = try #require(manifest.regularFiles.first)
        let task = Task {
            try await entry.withReaderDescriptor { _ in true }
        }

        #expect(await waitForManifestSemaphore(entered, timeout: 2))
        task.cancel()
        proceed.signal()
        await #expect(throws: TransferVerificationManifestError.cancelled) {
            _ = try await task.value
        }
        manifest.close()
        assertDescriptorLifecycleIsBalanced(recorder)
    }

    @Test func symlinkToRegularReplacementDuringInspectionFailsAsChanged() async throws {
        let temporary = try TemporaryDirectory()
        defer { temporary.remove() }
        let root = temporary.url.appending(path: "Root", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let target = temporary.url.appending(path: "target")
        try Data("target".utf8).write(to: target)
        let link = root.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let identity = try await requiredIdentity(of: root)
        let once = ManifestOneShot()
        let hooks = TransferVerificationManifestTestHooks(
            afterSymbolicLinkInspection: { components in
                guard components == ["link"], once.claim() else { return }
                try FileManager.default.removeItem(at: link)
                try Data("replacement".utf8).write(to: link)
            }
        )

        await #expect(throws: TransferVerificationManifestError.changed) {
            _ = try await LiveTransferVerificationManifestBuilder(
                testHooks: hooks
            ).capture(
                at: root,
                identifiedBy: identity,
                comparisonPolicy: .caseSensitiveCanonical
            )
        }
    }
}

private func capture(
    _ url: URL,
    policy: FilenameComparisonPolicy = .caseSensitiveCanonical
) async throws -> TransferVerificationManifest {
    let identity = try await requiredIdentity(of: url)
    return try await LiveTransferVerificationManifestBuilder().capture(
        at: url,
        identifiedBy: identity,
        comparisonPolicy: policy
    )
}

private func requiredIdentity(of url: URL) async throws -> FileIdentity {
    try #require(try await LiveFileSystemAccess().identity(of: url))
}

private func makeEquivalentTree(at root: URL, fileData: Data, linkPayload: String) throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    try fileData.write(to: root.appending(path: "file"))
    try FileManager.default.createSymbolicLink(
        atPath: root.appending(path: "link").path,
        withDestinationPath: linkPayload
    )
}

private func makeTwoRegularFileTree(at root: URL) throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    try Data("first".utf8).write(to: root.appending(path: "first"))
    try Data("second".utf8).write(to: root.appending(path: "second"))
}

private func makeDirectoryWithSizedFile(
    named name: String,
    fileSize: Int,
    in parent: URL
) throws {
    let directory = parent.appending(path: name, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    try Data(repeating: 0x70, count: fileSize).write(to: directory.appending(path: "payload"))
}

private func makeFIFO(at url: URL) throws {
    let status = url.withUnsafeFileSystemRepresentation { path in
        guard let path else { return Int32(-1) }
        return Darwin.mkfifo(path, 0o600)
    }
    guard status == 0 else { throw currentManifestTestPOSIXError() }
}

private final class BoundUnixSocket: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32 = -1

    func bind(at url: URL) throws {
        let opened = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard opened >= 0 else { throw currentManifestTestPOSIXError() }
        do {
            try bindUnixSocket(opened, at: url)
        } catch {
            _ = Darwin.close(opened)
            throw error
        }
        lock.withLock { descriptor = opened }
    }

    func close() {
        let descriptorToClose = lock.withLock {
            let value = descriptor
            descriptor = -1
            return value
        }
        if descriptorToClose >= 0 {
            _ = Darwin.close(descriptorToClose)
        }
    }

    deinit {
        close()
    }
}

private func bindUnixSocket(_ descriptor: Int32, at url: URL) throws {
    let pathBytes = Array(url.path.utf8)
    var address = sockaddr_un()
    let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
    guard pathBytes.count < pathCapacity else {
        throw POSIXError(.ENAMETOOLONG)
    }
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { destination in
        destination.initializeMemory(as: UInt8.self, repeating: 0)
        destination.prefix(pathBytes.count).copyBytes(from: pathBytes)
    }
    let result = withUnsafePointer(to: &address) { addressPointer in
        addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(
                descriptor,
                $0,
                socklen_t(MemoryLayout<sockaddr_un>.size)
            )
        }
    }
    guard result == 0 else { throw currentManifestTestPOSIXError() }
}

private func createRawRegularFile(named name: [UInt8], in directory: URL) throws {
    let directoryDescriptor = directory.withUnsafeFileSystemRepresentation { path in
        guard let path else { return Int32(-1) }
        return Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    }
    guard directoryDescriptor >= 0 else { throw currentManifestTestPOSIXError() }
    defer { Darwin.close(directoryDescriptor) }
    let descriptor = withRawCString(name) {
        Darwin.openat(
            directoryDescriptor,
            $0,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
            mode_t(0o600)
        )
    }
    guard descriptor >= 0 else { throw currentManifestTestPOSIXError() }
    Darwin.close(descriptor)
}

private func createRawSymbolicLink(payload: [UInt8], at url: URL) throws {
    let parent = url.deletingLastPathComponent()
    let directoryDescriptor = parent.withUnsafeFileSystemRepresentation { path in
        guard let path else { return Int32(-1) }
        return Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    }
    guard directoryDescriptor >= 0 else { throw currentManifestTestPOSIXError() }
    defer { Darwin.close(directoryDescriptor) }
    let result = withRawCString(payload) { payloadPointer in
        url.lastPathComponent.withCString { namePointer in
            Darwin.symlinkat(payloadPointer, directoryDescriptor, namePointer)
        }
    }
    guard result == 0 else { throw currentManifestTestPOSIXError() }
}

private func removeRawItem(at url: URL) throws {
    let status = url.withUnsafeFileSystemRepresentation { path in
        guard let path else { return Int32(-1) }
        return Darwin.unlink(path)
    }
    guard status == 0 else { throw currentManifestTestPOSIXError() }
}

private func withRawCString<T>(_ bytes: [UInt8], body: (UnsafePointer<CChar>) -> T) -> T {
    precondition(!bytes.contains(0))
    var terminated = bytes + [0]
    return terminated.withUnsafeMutableBytes {
        body($0.baseAddress!.assumingMemoryBound(to: CChar.self))
    }
}

private func makePipeDescriptors() throws -> (read: Int32, write: Int32) {
    var descriptors = [Int32](repeating: -1, count: 2)
    guard Darwin.pipe(&descriptors) == 0 else { throw currentManifestTestPOSIXError() }
    return (descriptors[0], descriptors[1])
}

private func currentManifestTestPOSIXError() -> POSIXError {
    POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
}

private func runIsolatedManifestTestIfNeeded(
    named testName: String,
    environmentKey: String,
    timeout: TimeInterval = 4
) throws -> Bool {
    guard ProcessInfo.processInfo.environment[environmentKey] != "1" else {
        return false
    }

    let buildDirectory = URL(filePath: FileManager.default.currentDirectoryPath)
        .appending(path: ".build/debug", directoryHint: .isDirectory)
    let testExecutable = buildDirectory.appending(
        path: "BloomFileManagerPackageTests.xctest/Contents/MacOS/BloomFileManagerPackageTests"
    )
    let process = Process()
    process.executableURL = URL(filePath: try manifestSwiftPMTestingHelperPath())
    process.arguments = [
        "--test-bundle-path", testExecutable.path,
        "--filter", testName,
        testExecutable.path,
        "--testing-library", "swift-testing"
    ]
    process.currentDirectoryURL = URL(filePath: FileManager.default.currentDirectoryPath)

    var environment = ProcessInfo.processInfo.environment
    environment[environmentKey] = "1"
    let frameworkPath = try manifestSwiftTestingFrameworkSearchPath()
    if let inherited = environment["DYLD_FRAMEWORK_PATH"], !inherited.isEmpty {
        environment["DYLD_FRAMEWORK_PATH"] = [frameworkPath, inherited]
            .joined(separator: ":")
    } else {
        environment["DYLD_FRAMEWORK_PATH"] = frameworkPath
    }
    process.environment = environment

    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()

    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning, Date() < deadline {
        usleep(10_000)
    }

    var timedOut = false
    if process.isRunning {
        timedOut = true
        process.terminate()
        let terminateDeadline = Date().addingTimeInterval(0.5)
        while process.isRunning, Date() < terminateDeadline {
            usleep(10_000)
        }
        if process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
        }
    }
    process.waitUntilExit()

    let outputText = String(
        decoding: output.fileHandleForReading.readDataToEndOfFile(),
        as: UTF8.self
    )
    #expect(
        !timedOut,
        Comment(rawValue: "Timed out after \(timeout)s\n\(outputText)")
    )
    #expect(process.terminationStatus == 0, Comment(rawValue: outputText))
    return true
}

private func manifestSwiftPMTestingHelperPath() throws -> String {
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/xcrun")
    process.arguments = ["--find", "swift"]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw CocoaError(.executableNotLoadable)
    }
    let swiftPath = String(decoding: data, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return URL(filePath: swiftPath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "libexec/swift/pm/swiftpm-testing-helper")
        .path
}

private func manifestSwiftTestingFrameworkSearchPath() throws -> String {
    let inherited = ProcessInfo.processInfo.environment["DYLD_FRAMEWORK_PATH"]?
        .split(separator: ":")
        .map(String.init)
        .first {
            FileManager.default.fileExists(
                atPath: URL(filePath: $0)
                    .appending(path: "Testing.framework", directoryHint: .isDirectory)
                    .path
            )
        }
    if let inherited {
        return inherited
    }

    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/xcrun")
    process.arguments = ["--sdk", "macosx", "--show-sdk-platform-path"]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw CocoaError(.executableNotLoadable)
    }
    let platform = String(decoding: data, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let frameworks = URL(filePath: platform)
        .appending(path: "Developer/Library/Frameworks", directoryHint: .isDirectory)
    guard FileManager.default.fileExists(
        atPath: frameworks.appending(path: "Testing.framework").path
    ) else {
        throw CocoaError(.fileNoSuchFile)
    }
    return frameworks.path
}

private func waitForManifestSemaphore(
    _ semaphore: DispatchSemaphore,
    timeout: TimeInterval
) async -> Bool {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            continuation.resume(
                returning: semaphore.wait(timeout: .now() + timeout) == .success
            )
        }
    }
}

private func waitForManifestRelease(
    entered: DispatchSemaphore,
    proceed: DispatchSemaphore
) async {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            entered.signal()
            _ = proceed.wait(timeout: .now() + 2)
            continuation.resume()
        }
    }
}

private func assertManifestDescriptorsAreClosed(_ descriptors: [Int32]) {
    for descriptor in descriptors {
        #expect(Darwin.fcntl(descriptor, F_GETFD) == -1)
        #expect(errno == EBADF)
    }
}

private final class ManifestOneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            guard !claimed else { return false }
            claimed = true
            return true
        }
    }
}

private final class DescriptorCloseRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Int32] = []

    var descriptors: [Int32] { lock.withLock { storage } }

    func record(_ descriptor: Int32) {
        lock.withLock { storage.append(descriptor) }
    }
}

private enum ManifestReaderTestError: Error, Equatable {
    case body
}

private final class DescriptorLifecycleRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [TransferVerificationDescriptorEvent] = []

    var events: [TransferVerificationDescriptorEvent] {
        lock.withLock { storage }
    }

    func record(_ event: TransferVerificationDescriptorEvent) {
        lock.withLock { storage.append(event) }
    }
}

private func assertDescriptorLifecycleIsBalanced(
    _ recorder: DescriptorLifecycleRecorder,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let events = recorder.events
    #expect(!events.isEmpty, sourceLocation: sourceLocation)
    let grouped = Dictionary(grouping: events, by: \.leaseID)
    for leaseEvents in grouped.values {
        #expect(
            leaseEvents.filter { $0.action == .acquired }.count == 1,
            sourceLocation: sourceLocation
        )
        #expect(
            leaseEvents.filter { $0.action == .closed }.count == 1,
            sourceLocation: sourceLocation
        )
        #expect(leaseEvents.count == 2, sourceLocation: sourceLocation)
        if leaseEvents.count == 2 {
            #expect(leaseEvents[0].action == .acquired, sourceLocation: sourceLocation)
            #expect(leaseEvents[1].action == .closed, sourceLocation: sourceLocation)
            #expect(
                leaseEvents[0].descriptor == leaseEvents[1].descriptor,
                sourceLocation: sourceLocation
            )
            #expect(
                leaseEvents[0].role == leaseEvents[1].role,
                sourceLocation: sourceLocation
            )
        }
    }
}

private final class DescriptorProbeRecorder: @unchecked Sendable {
    struct Probe: Sendable {
        let descriptor: Int32
        let hasCloexec: Bool
    }

    private let lock = NSLock()
    private var storage: [Probe] = []

    var values: [Probe] { lock.withLock { storage } }

    func record(descriptor: Int32, hasCloexec: Bool) {
        lock.withLock {
            storage.append(Probe(descriptor: descriptor, hasCloexec: hasCloexec))
        }
    }
}

private final class InjectedDescriptorDuplicator: @unchecked Sendable {
    private let lock = NSLock()
    private let failAtCall: Int?
    private var callCount = 0
    private var storage: [Int32] = []

    init(failAtCall: Int? = nil) {
        self.failAtCall = failAtCall
    }

    var successfulDescriptors: [Int32] { lock.withLock { storage } }

    func duplicate(_ descriptor: Int32) -> Int32 {
        lock.withLock {
            callCount += 1
            if callCount == failAtCall {
                errno = EMFILE
                return -1
            }
            let duplicate = Darwin.fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
            if duplicate >= 0 {
                storage.append(duplicate)
            }
            return duplicate
        }
    }
}

private final class SyntheticRawNameSource: @unchecked Sendable {
    private let lock = NSLock()
    private let names: [[UInt8]]
    private var index = 0

    init(_ names: [[UInt8]]) {
        self.names = names
    }

    var callCount: Int { lock.withLock { index } }

    func next() -> [UInt8]? {
        lock.withLock {
            guard index < names.count else { return nil }
            defer { index += 1 }
            return names[index]
        }
    }
}

private final class SyntheticCancellationCheck: @unchecked Sendable {
    private let lock = NSLock()
    private let cancelAt: Int
    private var checks = 0

    init(cancelAt: Int) {
        self.cancelAt = cancelAt
    }

    func check() throws {
        try lock.withLock {
            checks += 1
            if checks >= cancelAt {
                throw TransferVerificationManifestError.cancelled
            }
        }
    }
}
