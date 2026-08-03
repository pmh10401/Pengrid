import AppKit
import Darwin
import Foundation
import SwiftUI
import Testing
@testable import BloomFileManager

@Suite("Final review safety regressions")
struct FinalReviewFixTests {
    @Test func symlinkDestinationRegularReplacementIsRejected() async throws {
        if try runIsolatedTestIfNeeded(
            named: "FinalReviewFixTests.symlinkDestinationRegularReplacementIsRejected",
            environmentKey: "BLOOM_SYMLINK_REGULAR_WORKER"
        ) { return }
        try await assertSymlinkDestinationReplacementIsRejected(.regularFile)
    }

    @Test func symlinkDestinationDirectoryReplacementIsRejected() async throws {
        if try runIsolatedTestIfNeeded(
            named: "FinalReviewFixTests.symlinkDestinationDirectoryReplacementIsRejected",
            environmentKey: "BLOOM_SYMLINK_DIRECTORY_WORKER"
        ) { return }
        try await assertSymlinkDestinationReplacementIsRejected(.directory)
    }

    @Test func symlinkDestinationFIFOReplacementDoesNotBlockAndIsRejected() async throws {
        if try runIsolatedTestIfNeeded(
            named: "FinalReviewFixTests.symlinkDestinationFIFOReplacementDoesNotBlockAndIsRejected",
            environmentKey: "BLOOM_SYMLINK_FIFO_WORKER"
        ) { return }
        try await assertSymlinkDestinationReplacementIsRejected(.fifo)
    }

    @Test func sourceSymlinkFIFOReplacementDoesNotBlockAndIsRejected() async throws {
        if try runIsolatedTestIfNeeded(
            named: "FinalReviewFixTests.sourceSymlinkFIFOReplacementDoesNotBlockAndIsRejected",
            environmentKey: "BLOOM_SOURCE_SYMLINK_FIFO_WORKER"
        ) { return }

        let root = try TemporaryDirectory()
        defer { root.remove() }
        let source = root.url.appending(path: "source-link")
        let replacement = root.url.appending(path: "external-fifo")
        let destination = root.url.appending(path: "destination", directoryHint: .isDirectory)
        try FileManager.default.createSymbolicLink(atPath: source.path, withDestinationPath: "target")
        guard mkfifo(replacement.path, 0o600) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let gate = OneShotGate()
        let fileSystem = LiveFileSystemAccess(onBeforeCopySourceEntryOpen: { opened in
            guard gate.claim() else { return }
            try? FileManager.default.removeItem(at: opened)
            try? FileManager.default.moveItem(at: replacement, to: opened)
        })

        let result = await FileOperationService(fileSystem: fileSystem).transfer(
            [source], to: destination, mode: .copy,
            resolveConflict: { _ in .cancel }, progress: { _ in }
        )

        #expect(result.hasFailures)
        #expect(try fileType(at: source) == S_IFIFO)
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
    }

    @Test func sourceRegularFIFOReplacementDoesNotBlockAndIsRejected() async throws {
        if try runIsolatedTestIfNeeded(
            named: "FinalReviewFixTests.sourceRegularFIFOReplacementDoesNotBlockAndIsRejected",
            environmentKey: "BLOOM_SOURCE_REGULAR_FIFO_WORKER"
        ) { return }

        let root = try TemporaryDirectory()
        defer { root.remove() }
        let source = root.url.appending(path: "source.bin")
        let replacement = root.url.appending(path: "external-fifo")
        let destination = root.url.appending(path: "destination", directoryHint: .isDirectory)
        try Data("source".utf8).write(to: source)
        guard mkfifo(replacement.path, 0o600) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let gate = OneShotGate()
        let fileSystem = LiveFileSystemAccess(onBeforeCopySourceEntryOpen: { opened in
            guard gate.claim() else { return }
            try? FileManager.default.removeItem(at: opened)
            try? FileManager.default.moveItem(at: replacement, to: opened)
        })

        let result = await FileOperationService(fileSystem: fileSystem).transfer(
            [source], to: destination, mode: .copy,
            resolveConflict: { _ in .cancel }, progress: { _ in }
        )

        #expect(result.hasFailures)
        #expect(try fileType(at: source) == S_IFIFO)
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
    }

    @Test func sourceDirectoryReplacementIsRejectedWithoutCopyingExternalContents() async throws {
        if try runIsolatedTestIfNeeded(
            named: "FinalReviewFixTests.sourceDirectoryReplacementIsRejectedWithoutCopyingExternalContents",
            environmentKey: "BLOOM_SOURCE_DIRECTORY_WORKER"
        ) { return }

        let root = try TemporaryDirectory()
        defer { root.remove() }
        let source = root.url.appending(path: "source", directoryHint: .isDirectory)
        let replacement = root.url.appending(path: "external", directoryHint: .isDirectory)
        let destination = root.url.appending(path: "destination", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try Data("source".utf8).write(to: source.appending(path: "source.txt"))
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: false)
        try Data("external".utf8).write(to: replacement.appending(path: "attacker.txt"))
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let gate = OneShotGate()
        let createdNames = StringRecorder()
        let fileSystem = LiveFileSystemAccess(
            onBeforeCopyEntryCreate: { createdNames.append($0.lastPathComponent) },
            onBeforeCopySourceEntryOpen: { opened in
                guard gate.claim() else { return }
                try? FileManager.default.removeItem(at: opened)
                try? FileManager.default.moveItem(at: replacement, to: opened)
            }
        )

        let result = await FileOperationService(fileSystem: fileSystem).transfer(
            [source], to: destination, mode: .copy,
            resolveConflict: { _ in .cancel }, progress: { _ in }
        )

        #expect(result.hasFailures)
        #expect(try Data(contentsOf: source.appending(path: "attacker.txt")) == Data("external".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
        #expect(createdNames.values.contains("attacker.txt") == false)
    }

    @Test func directoryDestinationReplacementIsRejectedWithoutAdoptingExternalContents() async throws {
        if try runIsolatedTestIfNeeded(
            named: "FinalReviewFixTests.directoryDestinationReplacementIsRejectedWithoutAdoptingExternalContents",
            environmentKey: "BLOOM_DIRECTORY_REPLACEMENT_WORKER"
        ) { return }

        let root = try TemporaryDirectory()
        defer { root.remove() }
        let source = root.url.appending(path: "source", directoryHint: .isDirectory)
        let external = root.url.appending(path: "external", directoryHint: .isDirectory)
        let destination = root.url.appending(path: "destination", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try Data("source".utf8).write(to: source.appending(path: "source.txt"))
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
        try Data("external".utf8).write(to: external.appending(path: "attacker.txt"))
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let gate = OneShotGate()
        let fileSystem = LiveFileSystemAccess(onCopyEntryCreatedBeforeOpen: { created in
            guard gate.claim() else { return }
            try? FileManager.default.removeItem(at: created)
            try? FileManager.default.moveItem(at: external, to: created)
        })

        let result = await FileOperationService(fileSystem: fileSystem).transfer(
            [source], to: destination, mode: .copy,
            resolveConflict: { _ in .cancel }, progress: { _ in }
        )

        #expect(result.hasFailures)
        #expect(FileManager.default.fileExists(atPath: destination.appending(path: "source").path) == false)
        let attackerFiles = allDescendants(of: destination).filter { $0.lastPathComponent == "attacker.txt" }
        #expect(attackerFiles.count == 1)
        #expect(try Data(contentsOf: attackerFiles[0]) == Data("external".utf8))
        #expect(allDescendants(of: destination).contains { $0.lastPathComponent == "source.txt" } == false)
    }

    @Test func lowFileDescriptorLimitCopiesLargeNestedTreeWithBoundedHighWater() async throws {
        if ProcessInfo.processInfo.environment["BLOOM_LOW_FD_WORKER"] != "1" {
            let buildDirectory = URL(filePath: FileManager.default.currentDirectoryPath)
                .appending(path: ".build/debug", directoryHint: .isDirectory)
            let testBundle = buildDirectory.appending(
                path: "BloomFileManagerPackageTests.xctest",
                directoryHint: .isDirectory
            )
            let testExecutable = testBundle.appending(path: "Contents/MacOS/BloomFileManagerPackageTests")
            let process = Process()
            process.executableURL = URL(filePath: "/bin/zsh")
            process.arguments = [
                "-c",
                "ulimit -n 256; export DYLD_FRAMEWORK_PATH=\"$BLOOM_TEST_FRAMEWORKS\"; exec \"$BLOOM_TEST_HELPER\" --test-bundle-path \"$BLOOM_TEST_BUNDLE\" --filter 'FinalReviewFixTests.lowFileDescriptorLimitCopiesLargeNestedTreeWithBoundedHighWater' \"$BLOOM_TEST_EXECUTABLE\" --testing-library swift-testing"
            ]
            process.currentDirectoryURL = URL(filePath: FileManager.default.currentDirectoryPath)
            var environment = ProcessInfo.processInfo.environment
            environment["BLOOM_LOW_FD_WORKER"] = "1"
            environment["BLOOM_TEST_HELPER"] = try swiftPMTestingHelperPath()
            environment["BLOOM_TEST_FRAMEWORKS"] = try swiftTestingFrameworkSearchPath()
            environment["BLOOM_TEST_BUNDLE"] = testExecutable.path
            environment["BLOOM_TEST_EXECUTABLE"] = testExecutable.path
            process.environment = environment
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            try process.run()
            let outputData = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let outputText = String(decoding: outputData, as: UTF8.self)
            #expect(process.terminationStatus == 0, Comment(rawValue: outputText))
            return
        }

        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        #expect(limit.rlim_cur == 256)
        let descriptorLimit = Int(limit.rlim_cur)

        let root = try TemporaryDirectory()
        defer { root.remove() }
        let source = root.url.appending(path: "large-tree", directoryHint: .isDirectory)
        let destination = root.url.appending(path: "destination", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        var directory = source
        for depth in 0..<5 {
            for index in 0..<105 {
                try Data([UInt8(index % 251)]).write(
                    to: directory.appending(path: "file-\(depth)-\(index).bin")
                )
            }
            directory = directory.appending(path: "level-\(depth)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        }
        let highWater = FileDescriptorHighWater()
        let fileSystem = LiveFileSystemAccess(onCopyEntryCreated: { _ in
            highWater.observeCurrentCount(upTo: descriptorLimit)
        })

        let result = await FileOperationService(fileSystem: fileSystem).transfer(
            [source], to: destination, mode: .copy,
            resolveConflict: { _ in .cancel }, progress: { _ in }
        )
        let copied = destination.appending(path: source.lastPathComponent, directoryHint: .isDirectory)
        let copiedFiles = allDescendants(of: copied).filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }

        #expect(result.hasFailures == false)
        #expect(copiedFiles.count == 525)
        #expect(highWater.maximum <= 64)
    }

    @Test func immutableMetadataIsDeferredUntilCommitWithoutStagingResidue() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let source = root.url.appending(path: "locked.txt")
        let destination = root.url.appending(path: "destination", directoryHint: .isDirectory)
        try Data("locked".utf8).write(to: source)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        guard chflags(source.path, UInt32(UF_IMMUTABLE)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer {
            _ = chflags(source.path, 0)
            _ = chflags(destination.appending(path: "locked.txt").path, 0)
        }

        let result = await FileOperationService(fileSystem: LiveFileSystemAccess()).transfer(
            [source], to: destination, mode: .copy,
            resolveConflict: { _ in .cancel }, progress: { _ in }
        )
        let copied = destination.appending(path: "locked.txt")

        #expect(result.hasFailures == false)
        #expect(try fileFlags(at: copied) & UInt32(UF_IMMUTABLE) != 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).allSatisfy {
            !$0.hasPrefix(".bloom-staging-")
        })
    }

    @Test func immutableMetadataFailureStillClearsFlagsAndRemovesOwnedStagingPayload() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let source = root.url.appending(path: "locked-failure.txt")
        let destination = root.url.appending(path: "destination", directoryHint: .isDirectory)
        try Data("locked".utf8).write(to: source)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        guard chflags(source.path, UInt32(UF_IMMUTABLE)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { _ = chflags(source.path, 0) }
        let fileSystem = LiveFileSystemAccess(onCopyMetadataApplied: {
            throw InjectedMetadataFailure()
        })

        let result = await FileOperationService(fileSystem: fileSystem).transfer(
            [source], to: destination, mode: .copy,
            resolveConflict: { _ in .cancel }, progress: { _ in }
        )

        #expect(result.hasFailures)
        #expect(FileManager.default.fileExists(atPath: destination.appending(path: "locked-failure.txt").path) == false)
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
    }

    @Test func readOnlyDirectoryMetadataFailureLeavesNoOwnedStagingTree() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let source = root.url.appending(path: "readonly-failure", directoryHint: .isDirectory)
        let destination = root.url.appending(path: "destination", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try Data("child".utf8).write(to: source.appending(path: "child.txt"))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: source.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.path) }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let failure = NthCallFailure(target: 2)
        let fileSystem = LiveFileSystemAccess(onCopyMetadataApplied: {
            if failure.shouldFail() { throw InjectedMetadataFailure() }
        })

        let result = await FileOperationService(fileSystem: fileSystem).transfer(
            [source], to: destination, mode: .copy,
            resolveConflict: { _ in .cancel }, progress: { _ in }
        )

        #expect(result.hasFailures)
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
    }

    @Test func symlinkCopyAncestorSwapLeavesNoBloomPayloadInDetachedTree() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let sourceDirectory = root.url.appending(path: "source", directoryHint: .isDirectory)
        let destination = root.url.appending(path: "destination", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let source = sourceDirectory.appending(path: "alias")
        try FileManager.default.createSymbolicLink(atPath: source.path, withDestinationPath: "target")
        let gate = OneShotGate()
        let detached = destination.appending(path: "detached-staging", directoryHint: .isDirectory)
        let fileSystem = LiveFileSystemAccess(onBeforeCopyEntryCreate: { created in
            guard gate.claim() else { return }
            let staging = created.deletingLastPathComponent()
            try? FileManager.default.moveItem(at: staging, to: detached)
            try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        })

        let result = await FileOperationService(fileSystem: fileSystem).transfer(
            [source], to: destination, mode: .copy,
            resolveConflict: { _ in .cancel }, progress: { _ in }
        )

        #expect(result.hasFailures)
        #expect(FileManager.default.fileExists(atPath: detached.appending(path: "payload").path) == false)
        let detachedNames = (try? FileManager.default.contentsOfDirectory(atPath: detached.path)) ?? []
        #expect(detachedNames.contains("payload") == false)
        #expect(allDescendants(of: destination).contains { $0.lastPathComponent == "payload" } == false)
    }

    @Test func liveCopyPreservesExtendedMetadataACLFlagsAndCreationDate() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let source = root.url.appending(path: "metadata.bin")
        let destinationDirectory = root.url.appending(path: "destination", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: false)
        try Data("data".utf8).write(to: source)
        try setExtendedAttribute("com.example.bloom-test", data: Data("custom".utf8), at: source)
        try setExtendedAttribute("com.apple.ResourceFork", data: Data("resource".utf8), at: source)
        var finderInfo = Data(repeating: 0, count: 32)
        finderInfo[8] = 0x40
        try setExtendedAttribute("com.apple.FinderInfo", data: finderInfo, at: source)
        let creationDate = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.creationDate: creationDate], ofItemAtPath: source.path)
        let sourceCreationDate = try creationDateOf(source)
        guard chflags(source.path, UInt32(UF_HIDDEN)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try addReadACL(to: source)

        let result = await FileOperationService(fileSystem: LiveFileSystemAccess()).transfer(
            [source], to: destinationDirectory, mode: .copy,
            resolveConflict: { _ in .cancel }, progress: { _ in }
        )
        let copied = destinationDirectory.appending(path: source.lastPathComponent)

        #expect(result.hasFailures == false)
        #expect(try extendedAttribute("com.example.bloom-test", at: copied) == Data("custom".utf8))
        #expect(try extendedAttribute("com.apple.ResourceFork", at: copied) == Data("resource".utf8))
        #expect(try extendedAttribute("com.apple.FinderInfo", at: copied) == finderInfo)
        #expect(try fileFlags(at: copied) & UInt32(UF_HIDDEN) != 0)
        #expect(abs((try creationDateOf(copied)).timeIntervalSince(sourceCreationDate)) < 2)
        #expect(try aclText(of: copied).contains("everyone allow read"))
    }

    @Test func liveCopyPopulatesReadOnlyDirectoryThenRestoresFinalPermissions() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let source = root.url.appending(path: "readonly", directoryHint: .isDirectory)
        let destination = root.url.appending(path: "destination", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try Data("child".utf8).write(to: source.appending(path: "child.txt"))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: source.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.path) }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)

        let result = await FileOperationService(fileSystem: LiveFileSystemAccess()).transfer(
            [source], to: destination, mode: .copy,
            resolveConflict: { _ in .cancel }, progress: { _ in }
        )
        let copied = destination.appending(path: "readonly", directoryHint: .isDirectory)

        #expect(result.hasFailures == false)
        #expect(try Data(contentsOf: copied.appending(path: "child.txt")) == Data("child".utf8))
        let permissions = try FileManager.default.attributesOfItem(atPath: copied.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o555)
    }

    @Test func liveCopyNeverAdoptsReplacementAfterIdentityCaptureBeforePathVerification() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let source = root.url.appending(path: "source.bin")
        let destination = root.url.appending(path: "destination", directoryHint: .isDirectory)
        try Data(repeating: 1, count: 32_768).write(to: source)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let replacementGate = OneShotGate()
        let fileSystem = LiveFileSystemAccess(onCopyEntryCreated: { created in
            if replacementGate.claim() {
                let original = created.appendingPathExtension("original")
                try? FileManager.default.moveItem(at: created, to: original)
                try? Data("external".utf8).write(to: created)
            }
        })

        let result = await FileOperationService(fileSystem: fileSystem).transfer(
            [source], to: destination, mode: .copy,
            resolveConflict: { _ in .cancel }, progress: { _ in }
        )

        #expect(result.hasFailures)
        #expect(FileManager.default.fileExists(atPath: destination.appending(path: "source.bin").path) == false)
    }

    @Test func keepBothProbesCaseInsensitiveDestinationUntilCandidateIsFree() async {
        let source = URL(filePath: "/source/report.txt")
        let directory = URL(filePath: "/destination")
        let fileSystem = RecordingFileSystem(
            existingURLs: [
                source,
                directory.appending(path: "REPORT.TXT"),
                directory.appending(path: "Report 2.txt")
            ],
            caseInsensitivePaths: true
        )

        let result = await FileOperationService(fileSystem: fileSystem).transfer(
            [source], to: directory, mode: .copy,
            resolveConflict: { _ in .keepBoth }, progress: { _ in }
        )

        #expect(result.outcomes == [
            .succeeded(source: source, destination: directory.appending(path: "report 3.txt"))
        ])
    }

    @Test func liveTransferRejectsDirectoryDestinationInsideSourceBeforeStaging() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let source = root.url.appending(path: "source", directoryHint: .isDirectory)
        let descendant = source.appending(path: "child", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: descendant, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: source.appending(path: "keep.txt"))
        let service = FileOperationService(fileSystem: LiveFileSystemAccess())

        let result = await service.transfer(
            [source], to: descendant, mode: .copy,
            resolveConflict: { _ in .cancel }, progress: { _ in }
        )

        #expect(result.hasFailures)
        #expect(try FileManager.default.contentsOfDirectory(atPath: descendant.path).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: source.path).contains("keep.txt"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: source.path).contains {
            $0.hasPrefix(".bloom-staging-")
        } == false)
    }

    @Test func liveTransferRejectsDescendantReachedThroughSymlinkAlias() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let source = root.url.appending(path: "source", directoryHint: .isDirectory)
        let descendant = source.appending(path: "child", directoryHint: .isDirectory)
        let alias = root.url.appending(path: "alias", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: descendant, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: descendant)
        let service = FileOperationService(fileSystem: LiveFileSystemAccess())

        let result = await service.transfer(
            [source], to: alias, mode: .copy,
            resolveConflict: { _ in .cancel }, progress: { _ in }
        )

        #expect(result.hasFailures)
        #expect(try FileManager.default.contentsOfDirectory(atPath: descendant.path).isEmpty)
    }

    @Test func liveCopyPreservesRegularDirectoryAndSymlinkKinds() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let sources = root.url.appending(path: "sources", directoryHint: .isDirectory)
        let destination = root.url.appending(path: "destination", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let file = sources.appending(path: "file.txt")
        let folder = sources.appending(path: "folder", directoryHint: .isDirectory)
        let link = sources.appending(path: "link")
        try Data("contents".utf8).write(to: file)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data("nested".utf8).write(to: folder.appending(path: "nested.txt"))
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)

        let result = await FileOperationService(fileSystem: LiveFileSystemAccess()).transfer(
            [file, folder, link], to: destination, mode: .copy,
            resolveConflict: { _ in .cancel }, progress: { _ in }
        )

        #expect(result.hasFailures == false)
        #expect(try Data(contentsOf: destination.appending(path: "file.txt")) == Data("contents".utf8))
        #expect(try Data(contentsOf: destination.appending(path: "folder/nested.txt")) == Data("nested".utf8))
        let values = try destination.appending(path: "link").resourceValues(forKeys: [.isSymbolicLinkKey])
        #expect(values.isSymbolicLink == true)
    }

    @Test func liveReplaceKeepBothAndSameVolumeMoveProduceExpectedArtifacts() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let sourceDirectory = root.url.appending(path: "sources", directoryHint: .isDirectory)
        let destination = root.url.appending(path: "destination", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let service = FileOperationService(fileSystem: LiveFileSystemAccess())

        let replaceSource = sourceDirectory.appending(path: "replace.txt")
        try Data("new".utf8).write(to: replaceSource)
        try Data("old".utf8).write(to: destination.appending(path: "replace.txt"))
        let replaced = await service.transfer(
            [replaceSource], to: destination, mode: .copy,
            resolveConflict: { _ in .replace }, progress: { _ in }
        )
        #expect(replaced.hasFailures == false)
        #expect(try Data(contentsOf: destination.appending(path: "replace.txt")) == Data("new".utf8))

        let keepSource = sourceDirectory.appending(path: "keep.txt")
        try Data("second".utf8).write(to: keepSource)
        try Data("first".utf8).write(to: destination.appending(path: "keep.txt"))
        let kept = await service.transfer(
            [keepSource], to: destination, mode: .copy,
            resolveConflict: { _ in .keepBoth }, progress: { _ in }
        )
        #expect(kept.outcomes == [
            .succeeded(source: keepSource, destination: destination.appending(path: "keep 2.txt"))
        ])
        #expect(try Data(contentsOf: destination.appending(path: "keep 2.txt")) == Data("second".utf8))

        let moveSource = sourceDirectory.appending(path: "move.txt")
        try Data("move".utf8).write(to: moveSource)
        let moved = await service.transfer(
            [moveSource], to: destination, mode: .move,
            resolveConflict: { _ in .cancel }, progress: { _ in }
        )
        #expect(moved.hasFailures == false)
        #expect(FileManager.default.fileExists(atPath: moveSource.path) == false)
        #expect(try Data(contentsOf: destination.appending(path: "move.txt")) == Data("move".utf8))
    }

    @Test func liveCaseInsensitiveKeepBothUsesNumberedCandidateWhenVolumeRequiresIt() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let sourceDirectory = root.url.appending(path: "sources", directoryHint: .isDirectory)
        let destination = root.url.appending(path: "destination", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let source = sourceDirectory.appending(path: "report.txt")
        try Data("new".utf8).write(to: source)
        try Data("old".utf8).write(to: destination.appending(path: "REPORT.TXT"))
        guard FileManager.default.fileExists(atPath: destination.appending(path: "report.txt").path) else {
            return // This live filesystem is case-sensitive; the fake covers that policy deterministically.
        }

        let result = await FileOperationService(fileSystem: LiveFileSystemAccess()).transfer(
            [source], to: destination, mode: .copy,
            resolveConflict: { _ in .keepBoth }, progress: { _ in }
        )

        #expect(result.outcomes == [
            .succeeded(source: source, destination: destination.appending(path: "report 2.txt"))
        ])
    }

    @Test func liveCancellationRemovesOwnedPartialCopy() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let source = root.url.appending(path: "large.bin")
        let destination = root.url.appending(path: "destination", directoryHint: .isDirectory)
        try Data(repeating: 0x5a, count: 2_000_000).write(to: source)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        let fileSystem = LiveFileSystemAccess(copyChunkSize: 4096) {
            withUnsafeCurrentTask { $0?.cancel() }
        }

        let result = await FileOperationService(fileSystem: fileSystem).transfer(
            [source], to: destination, mode: .copy,
            resolveConflict: { _ in .cancel }, progress: { _ in }
        )

        #expect(result.outcomes == [.cancelled(source: source)])
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(FileManager.default.fileExists(atPath: destination.appending(path: "large.bin").path) == false)
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
    }

    @Test func resultDetailsUseBasenamesSanitizedGuidanceAndExplicitCancellation() {
        let secret = URL(filePath: "/private/test-user/secret.txt")
        let result = FileOperationResult(outcomes: [
            .failed(source: secret, message: "Permission denied at /private/test-user/secret.txt"),
            .skipped(source: URL(filePath: "/tmp/skipped.txt")),
            .cancelled(source: URL(filePath: "/tmp/cancelled.txt"))
        ])

        let details = OperationResultDetails(result: result)

        #expect(details.items.map(\.name) == ["secret.txt", "skipped.txt", "cancelled.txt"])
        #expect(details.items.map(\.status) == [.failed, .skipped, .cancelled])
        #expect(details.items.allSatisfy { !$0.guidance.contains("/private/") && !$0.guidance.contains("/tmp/") })
        #expect(details.accessibilityLabel.contains("1 cancelled"))
    }
}

@MainActor
@Suite("Final review controller and AppKit races")
struct FinalReviewControllerTests {
    @Test func consumedPresentationRequestRetainsIdentityThroughLiveReturnRename() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let source = root.url.appending(path: "original.txt")
        let renamed = root.url.appending(path: "renamed.txt")
        try Data("data".utf8).write(to: source)
        let item = FileItem(
            url: source, name: source.lastPathComponent, isDirectory: false, isPackage: false,
            modifiedAt: nil, byteSize: 4, typeDescription: "File"
        )
        let listing = StubDirectoryListingService(values: [root.url: [item]])
        let workspace = WorkspaceState(leftURL: root.url, rightURL: root.url, listingService: listing)
        let controller = FileOperationController(service: FileOperationService(fileSystem: LiveFileSystemAccess()))
        await workspace.left.navigate(to: root.url, recordHistory: false)
        workspace.left.selection = [source]

        #expect(await controller.requestRename(in: workspace))
        let requestID = try #require(workspace.left.renameRequestID)
        workspace.left.consumeInlineRenameRequest(requestID)
        #expect(workspace.left.pendingRenameTarget?.url == source)
        controller.commitPendingRename(in: workspace.left, to: "renamed.txt", workspace: workspace)
        await waitUntilIdle(controller)

        #expect(controller.lastResult == FileOperationResult(outcomes: [
            .succeeded(source: source, destination: renamed)
        ]))
        #expect(FileManager.default.fileExists(atPath: renamed.path))
        #expect(workspace.left.pendingRenameTarget == nil)
    }

    @Test func renameTargetClearsOnEscapeUnchangedSelectionChangeAndNavigation() async {
        let source = URL(filePath: "/workspace/original.txt")
        let identity = FileIdentity(entryIdentifier: "entry", resolvedIdentifier: "entry")
        let pane = FilePaneState(
            directory: URL(filePath: "/workspace"),
            listingService: StubDirectoryListingService(values: [:])
        )

        for termination in 0..<4 {
            pane.selection = [source]
            #expect(pane.requestInlineRename(IdentifiedFileRequest(url: source, identity: identity)))
            switch termination {
            case 0:
                pane.cancelPendingRename()
            case 1:
                pane.finishPendingRenameWithoutChange()
            case 2:
                pane.selection = []
            default:
                await pane.navigate(to: URL(filePath: "/other"), recordHistory: false)
            }
            #expect(pane.pendingRenameTarget == nil)
        }
    }

    @Test func failedInitialRestoreFallsBackPerPaneAndPersistsOnlyFallbacks() async {
        let invalidLeft = URL(filePath: "/removed/left", directoryHint: .isDirectory)
        let invalidRight = URL(filePath: "/removed/right", directoryHint: .isDirectory)
        let home = URL(filePath: "/valid/home", directoryHint: .isDirectory)
        let downloads = URL(filePath: "/valid/downloads", directoryHint: .isDirectory)
        let fixture = UserDefaults(suiteName: "FinalRestore.\(UUID().uuidString)")!
        let persistence = WorkspacePersistence(defaults: fixture)
        let service = FailingInitialListingService(failing: [invalidLeft, invalidRight])
        let workspace = WorkspaceState(
            leftURL: invalidLeft,
            rightURL: invalidRight,
            leftFallbackURL: home,
            rightFallbackURL: downloads,
            listingService: service,
            persistence: persistence
        )

        await workspace.loadInitialDirectories()

        #expect(workspace.left.currentDirectory == home)
        #expect(workspace.right.currentDirectory == downloads)
        #expect(persistence.load()?.leftPath == home.path)
        #expect(persistence.load()?.rightPath == downloads.path)
    }

    @Test func renameRequestKeepsInitiationIdentityAndRefusesReplacement() async {
        let source = URL(filePath: "/workspace/original")
        let oldIdentity = FileIdentity(entryIdentifier: "old", resolvedIdentifier: "old")
        let replacementIdentity = FileIdentity(entryIdentifier: "replacement", resolvedIdentifier: "replacement")
        let fileSystem = RecordingFileSystem(existingURLs: [source], identities: [source: oldIdentity])
        let controller = FileOperationController(service: FileOperationService(fileSystem: fileSystem))
        let workspace = WorkspaceState(
            leftURL: URL(filePath: "/workspace"), rightURL: URL(filePath: "/other"),
            listingService: StubDirectoryListingService(values: [:])
        )
        workspace.left.selection = [source]

        #expect(await controller.requestRename(in: workspace))
        await fileSystem.replaceIdentity(at: source, with: replacementIdentity)
        controller.commitPendingRename(in: workspace.left, to: "renamed", workspace: workspace)
        await waitUntilIdle(controller)

        #expect(controller.lastResult?.hasFailures == true)
        #expect(await fileSystem.existingURLs.contains(source))
        #expect(await fileSystem.existingURLs.contains(URL(filePath: "/workspace/renamed")) == false)
    }

    @Test func trashConfirmationKeepsInitiationIdentitiesAndRefusesReplacement() async {
        let source = URL(filePath: "/workspace/item")
        let oldIdentity = FileIdentity(entryIdentifier: "old", resolvedIdentifier: "old")
        let replacementIdentity = FileIdentity(entryIdentifier: "replacement", resolvedIdentifier: "replacement")
        let fileSystem = RecordingFileSystem(existingURLs: [source], identities: [source: oldIdentity])
        let controller = FileOperationController(service: FileOperationService(fileSystem: fileSystem))
        let workspace = WorkspaceState(
            leftURL: URL(filePath: "/workspace"), rightURL: URL(filePath: "/other"),
            listingService: StubDirectoryListingService(values: [:])
        )
        workspace.left.selection = [source]

        await controller.requestTrashConfirmation(for: [source], workspace: workspace)
        let request = try! #require(workspace.pendingTrashRequest)
        await fileSystem.replaceIdentity(at: source, with: replacementIdentity)
        controller.trash(request.items, workspace: workspace)
        await waitUntilIdle(controller)

        #expect(controller.lastResult?.hasFailures == true)
        #expect(await fileSystem.existingURLs.contains(source))
    }

    @Test func missingTrashTargetRemainsAnExplicitPerItemFailure() async {
        let source = URL(filePath: "/workspace/missing")
        let fileSystem = RecordingFileSystem()
        let controller = FileOperationController(service: FileOperationService(fileSystem: fileSystem))
        let workspace = WorkspaceState(
            leftURL: URL(filePath: "/workspace"), rightURL: URL(filePath: "/other"),
            listingService: StubDirectoryListingService(values: [:])
        )
        workspace.left.selection = [source]

        await controller.requestTrashConfirmation(for: [source], workspace: workspace)
        let request = try! #require(workspace.pendingTrashRequest)
        #expect(request.urls == [source])
        controller.trash(request.items, workspace: workspace)
        await waitUntilIdle(controller)

        #expect(controller.lastResult?.outcomes.count == 1)
        #expect(controller.lastResult?.hasFailures == true)
    }

    @Test func trashConfirmationIsDiscardedWhenSelectionChangesDuringCapture() async {
        let source = URL(filePath: "/workspace/old-selection")
        let replacementSelection = URL(filePath: "/workspace/new-selection")
        let fileSystem = RecordingFileSystem(
            existingURLs: [source, replacementSelection],
            suspendIdentityOf: source
        )
        let controller = FileOperationController(
            service: FileOperationService(fileSystem: fileSystem)
        )
        let workspace = WorkspaceState(
            leftURL: URL(filePath: "/workspace"),
            rightURL: URL(filePath: "/other"),
            listingService: StubDirectoryListingService(values: [:])
        )
        workspace.left.selection = [source]

        let request = Task {
            await controller.requestTrashConfirmation(for: [source], workspace: workspace)
        }
        await waitUntilFinalReview { await fileSystem.hasSuspendedIdentity }
        workspace.left.selection = [replacementSelection]
        await fileSystem.releaseSuspendedIdentity()
        await request.value

        #expect(workspace.pendingTrashRequest == nil)
    }

    @Test func tableFirstResponderActivationDoesNotDependOnSelectionChange() {
        var activations = 0
        let selection = FinalSelectionRecorder()
        let view = FileTableView(
            items: [], selection: selection.binding,
            onActivatePane: { activations += 1 }, onOpen: { _ in }, onSortChange: { _ in }
        )
        let coordinator = view.makeCoordinator()
        let scrollView = view.makeScrollView(coordinator: coordinator)
        let table = try! #require(scrollView.documentView as? PaneActivatingTableView)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = scrollView

        #expect(window.makeFirstResponder(table))
        #expect(activations == 1)
    }

    private func waitUntilIdle(_ controller: FileOperationController) async {
        while controller.isRunning { await Task.yield() }
    }
}

@MainActor
private func waitUntilFinalReview(
    _ condition: @escaping @MainActor () async -> Bool
) async {
    let deadline = ContinuousClock.now.advanced(by: .seconds(1))
    while ContinuousClock.now < deadline {
        if await condition() { return }
        await Task.yield()
    }
}

@MainActor
private final class FinalSelectionRecorder {
    var value: Set<URL> = []
    var binding: Binding<Set<URL>> {
        Binding(get: { self.value }, set: { self.value = $0 })
    }
}

private struct FailingInitialListingService: DirectoryListingService {
    let failing: Set<URL>

    func batches(in directory: URL) -> AsyncThrowingStream<[FileItem], Error> {
        AsyncThrowingStream { continuation in
            if failing.contains(directory) {
                continuation.finish(throwing: CocoaError(.fileReadNoSuchFile))
            } else {
                continuation.finish()
            }
        }
    }
}

private func setExtendedAttribute(_ name: String, data: Data, at url: URL) throws {
    let status: Int32 = data.withUnsafeBytes { bytes in
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return name.withCString { attributeName in
                setxattr(path, attributeName, bytes.baseAddress, bytes.count, 0, 0)
            }
        }
    }
    guard status == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}

private func extendedAttribute(_ name: String, at url: URL) throws -> Data {
    let count: Int = url.withUnsafeFileSystemRepresentation { path in
        guard let path else { return -1 }
        return name.withCString { getxattr(path, $0, nil, 0, 0, 0) }
    }
    guard count >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    var data = Data(count: count)
    let readCount: Int = data.withUnsafeMutableBytes { bytes in
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return name.withCString { getxattr(path, $0, bytes.baseAddress, bytes.count, 0, 0) }
        }
    }
    guard readCount == count else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    return data
}

private func fileFlags(at url: URL) throws -> UInt32 {
    var information = stat()
    let status: Int32 = url.withUnsafeFileSystemRepresentation { path in
        guard let path else { return -1 }
        return lstat(path, &information)
    }
    guard status == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    return information.st_flags
}

private final class OneShotGate: @unchecked Sendable {
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

private struct InjectedMetadataFailure: Error {}

private enum SymlinkDestinationReplacement {
    case regularFile
    case directory
    case fifo
}

private final class NthCallFailure: @unchecked Sendable {
    private let lock = NSLock()
    private let target: Int
    private var count = 0

    init(target: Int) { self.target = target }

    func shouldFail() -> Bool {
        lock.withLock {
            count += 1
            return count == target
        }
    }
}

private final class FileDescriptorHighWater: @unchecked Sendable {
    private let lock = NSLock()
    private var observedMaximum = 0

    var maximum: Int { lock.withLock { observedMaximum } }

    func observeCurrentCount(upTo limit: Int) {
        var count = 0
        for descriptor in 0..<limit where Darwin.fcntl(Int32(descriptor), F_GETFD) >= 0 {
            count += 1
        }
        lock.withLock { observedMaximum = max(observedMaximum, count) }
    }
}

private final class StringRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] { lock.withLock { storage } }

    func append(_ value: String) {
        lock.withLock { storage.append(value) }
    }
}

private func creationDateOf(_ url: URL) throws -> Date {
    try #require(url.resourceValues(forKeys: [.creationDateKey]).creationDate)
}

private func addReadACL(to url: URL) throws {
    let process = Process()
    process.executableURL = URL(filePath: "/bin/chmod")
    process.arguments = ["+a", "everyone allow read", url.path]
    let errorPipe = Pipe()
    process.standardError = errorPipe
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        let error = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: error])
    }
}

private func aclText(of url: URL) throws -> String {
    let process = Process()
    process.executableURL = URL(filePath: "/bin/ls")
    process.arguments = ["-lde", url.path]
    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        let error = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: error])
    }
    return String(decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
}

private func allDescendants(of directory: URL) -> [URL] {
    guard let enumerator = FileManager.default.enumerator(
        at: directory,
        includingPropertiesForKeys: nil,
        options: [],
        errorHandler: nil
    ) else { return [] }
    return enumerator.compactMap { $0 as? URL }
}

private func assertSymlinkDestinationReplacementIsRejected(
    _ replacement: SymlinkDestinationReplacement
) async throws {
    let root = try TemporaryDirectory()
    defer { root.remove() }
    let source = root.url.appending(path: "source-link")
    let external = root.url.appending(path: "external")
    let destination = root.url.appending(path: "destination", directoryHint: .isDirectory)
    try FileManager.default.createSymbolicLink(atPath: source.path, withDestinationPath: "target")
    switch replacement {
    case .regularFile:
        try Data("external".utf8).write(to: external)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: external.path)
    case .directory:
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: false)
        try Data("external".utf8).write(to: external.appending(path: "attacker.txt"))
        try FileManager.default.setAttributes([.posixPermissions: 0o750], ofItemAtPath: external.path)
    case .fifo:
        guard mkfifo(external.path, 0o600) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
    let gate = OneShotGate()
    let fileSystem = LiveFileSystemAccess(onCopyEntryCreatedBeforeOpen: { created in
        guard gate.claim() else { return }
        try? FileManager.default.removeItem(at: created)
        try? FileManager.default.moveItem(at: external, to: created)
    })

    let result = await FileOperationService(fileSystem: fileSystem).transfer(
        [source], to: destination, mode: .copy,
        resolveConflict: { _ in .cancel }, progress: { _ in }
    )

    #expect(result.hasFailures)
    #expect(FileManager.default.fileExists(atPath: destination.appending(path: "source-link").path) == false)
    let payloads = allDescendants(of: destination).filter { $0.lastPathComponent == "payload" }
    #expect(payloads.count == 1)
    let payload = try #require(payloads.first)
    switch replacement {
    case .regularFile:
        #expect(try fileType(at: payload) == S_IFREG)
        #expect(try Data(contentsOf: payload) == Data("external".utf8))
        #expect(try filePermissions(at: payload) == 0o640)
    case .directory:
        #expect(try fileType(at: payload) == S_IFDIR)
        #expect(try Data(contentsOf: payload.appending(path: "attacker.txt")) == Data("external".utf8))
        #expect(try filePermissions(at: payload) == 0o750)
    case .fifo:
        #expect(try fileType(at: payload) == S_IFIFO)
        #expect(try filePermissions(at: payload) == 0o600)
    }
    #expect(allDescendants(of: destination).contains {
        (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    } == false)
}

private func fileType(at url: URL) throws -> mode_t {
    var information = stat()
    let status = url.withUnsafeFileSystemRepresentation { path in
        guard let path else { return Int32(-1) }
        return Darwin.lstat(path, &information)
    }
    guard status == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    return information.st_mode & S_IFMT
}

private func filePermissions(at url: URL) throws -> mode_t {
    var information = stat()
    let status = url.withUnsafeFileSystemRepresentation { path in
        guard let path else { return Int32(-1) }
        return Darwin.lstat(path, &information)
    }
    guard status == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    return information.st_mode & 0o7777
}

private func runIsolatedTestIfNeeded(
    named testName: String,
    environmentKey: String,
    timeout: TimeInterval = 4
) throws -> Bool {
    guard ProcessInfo.processInfo.environment[environmentKey] != "1" else { return false }
    let buildDirectory = URL(filePath: FileManager.default.currentDirectoryPath)
        .appending(path: ".build/debug", directoryHint: .isDirectory)
    let testExecutable = buildDirectory.appending(
        path: "BloomFileManagerPackageTests.xctest/Contents/MacOS/BloomFileManagerPackageTests"
    )
    let process = Process()
    process.executableURL = URL(filePath: try swiftPMTestingHelperPath())
    process.arguments = [
        "--test-bundle-path", testExecutable.path,
        "--filter", testName,
        testExecutable.path,
        "--testing-library", "swift-testing"
    ]
    process.currentDirectoryURL = URL(filePath: FileManager.default.currentDirectoryPath)
    var environment = ProcessInfo.processInfo.environment
    environment[environmentKey] = "1"
    process.environment = environment
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning, Date() < deadline {
        usleep(10_000)
    }
    let timedOut = process.isRunning
    if timedOut { process.terminate() }
    process.waitUntilExit()
    let outputText = String(
        decoding: output.fileHandleForReading.readDataToEndOfFile(),
        as: UTF8.self
    )
    #expect(!timedOut, Comment(rawValue: "Timed out after \(timeout)s\n\(outputText)"))
    #expect(process.terminationStatus == 0, Comment(rawValue: outputText))
    return true
}

private func swiftPMTestingHelperPath() throws -> String {
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

private func swiftTestingFrameworkSearchPath() throws -> String {
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
    if let inherited { return inherited }

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
