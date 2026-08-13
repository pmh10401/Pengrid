import Foundation
import Testing
@testable import BloomFileManager

@Suite struct FolderSynchronizationModelsTests {
    @Test func readyDraftRetainsGenerationRootsAndDeterministicActions() throws {
        let session = try makeSession()
        let directory = try entry("Reports", root: session.leftRoot, identity: "left-reports", kind: .directory)
        let file = try entry("Reports/summary.txt", root: session.leftRoot, identity: "left-summary", size: 42)
        let actions = try [
            FolderSynchronizationAction(
                relativePath: file.relativePath,
                kind: .copy,
                source: file,
                destination: nil
            ),
            FolderSynchronizationAction(
                relativePath: directory.relativePath,
                kind: .copy,
                source: directory,
                destination: nil
            )
        ]

        let draft = try FolderSynchronizationPlanDraft(
            direction: .leftToRight,
            comparisonGeneration: session.generation,
            sourceRoot: session.leftRoot,
            destinationRoot: session.rightRoot,
            sourceRootIdentity: session.leftRootIdentity,
            destinationRootIdentity: session.rightRootIdentity,
            actions: actions.sorted(by: FolderSynchronizationAction.deterministicOrder),
            skipCount: 3,
            estimatedRegularFileCopyBytes: 42
        )

        #expect(draft.comparisonGeneration == session.generation)
        #expect(draft.sourceRoot == session.leftRoot)
        #expect(draft.destinationRoot == session.rightRoot)
        #expect(draft.actions.map(\.relativePath.string) == ["Reports", "Reports/summary.txt"])
        #expect(draft.skipCount == 3)
        #expect(draft.estimatedRegularFileCopyBytes == 42)
    }

    @Test func blockerPresentationDoesNotExposeAbsolutePaths() throws {
        let blocker = FolderSynchronizationBlocker(
            relativePath: try path("Private/report.txt"),
            reason: .comparisonError
        )

        #expect(blocker.presentation.contains("Private/report.txt"))
        #expect(!blocker.presentation.contains("/Users/alice/Secret"))
        #expect(!blocker.presentation.contains("permission denied at /Users/alice/Secret"))
    }

    @Test func actionKindDefinesCopyReplaceAndTrashOnly() {
        #expect(FolderSynchronizationActionKind.allCases == [.copy, .replace, .moveDestinationToTrash])
        #expect(FolderSynchronizationActionKind.copy.rawValue == "copy")
        #expect(FolderSynchronizationActionKind.replace.rawValue == "replace")
        #expect(FolderSynchronizationActionKind.moveDestinationToTrash.rawValue == "moveDestinationToTrash")
    }

    @Test func modelsRejectMalformedActionsAndDrafts() throws {
        let session = try makeSession()
        let file = try entry("report.txt", root: session.leftRoot, identity: "report", size: 42)
        let directory = try entry("Folder", root: session.leftRoot, identity: "folder", kind: .directory)
        let wrongRootFile = try entry("report.txt", root: URL(filePath: "/outside"), identity: "outside", size: 42)
        let copy = try FolderSynchronizationAction(
            relativePath: file.relativePath,
            kind: .copy,
            source: file,
            destination: nil
        )

        #expect(throws: FolderSynchronizationModelValidationError.self) {
            try FolderSynchronizationAction(
                relativePath: directory.relativePath,
                kind: .replace,
                source: directory,
                destination: directory
            )
        }
        #expect(throws: FolderSynchronizationModelValidationError.self) {
            try FolderSynchronizationAction(
                relativePath: try path("other.txt"),
                kind: .copy,
                source: file,
                destination: nil
            )
        }
        #expect(throws: FolderSynchronizationModelValidationError.self) {
            _ = try FolderSynchronizationPlanDraft(
                direction: .leftToRight,
                comparisonGeneration: session.generation,
                sourceRoot: session.leftRoot,
                destinationRoot: session.rightRoot,
                sourceRootIdentity: session.leftRootIdentity,
                destinationRootIdentity: session.rightRootIdentity,
                actions: [],
                skipCount: 0,
                estimatedRegularFileCopyBytes: 0
            )
        }
        #expect(throws: FolderSynchronizationModelValidationError.self) {
            _ = try FolderSynchronizationPlanDraft(
                direction: .leftToRight,
                comparisonGeneration: session.generation,
                sourceRoot: session.leftRoot,
                destinationRoot: session.rightRoot,
                sourceRootIdentity: session.leftRootIdentity,
                destinationRootIdentity: session.rightRootIdentity,
                actions: [copy, copy],
                skipCount: 0,
                estimatedRegularFileCopyBytes: 42
            )
        }
        let later = try entry("z-last.txt", root: session.leftRoot, identity: "later")
        let earlier = try entry("a-first.txt", root: session.leftRoot, identity: "earlier")
        let unordered = try [
            FolderSynchronizationAction(relativePath: later.relativePath, kind: .copy, source: later, destination: nil),
            FolderSynchronizationAction(relativePath: earlier.relativePath, kind: .copy, source: earlier, destination: nil)
        ]
        #expect(throws: FolderSynchronizationModelValidationError.self) {
            _ = try FolderSynchronizationPlanDraft(
                direction: .leftToRight,
                comparisonGeneration: session.generation,
                sourceRoot: session.leftRoot,
                destinationRoot: session.rightRoot,
                sourceRootIdentity: session.leftRootIdentity,
                destinationRootIdentity: session.rightRootIdentity,
                actions: unordered,
                skipCount: 0,
                estimatedRegularFileCopyBytes: 2
            )
        }
        #expect(throws: FolderSynchronizationModelValidationError.self) {
            let wrongRootAction = try FolderSynchronizationAction(
                relativePath: wrongRootFile.relativePath,
                kind: .copy,
                source: wrongRootFile,
                destination: nil
            )
            _ = try FolderSynchronizationPlanDraft(
                direction: .leftToRight,
                comparisonGeneration: session.generation,
                sourceRoot: session.leftRoot,
                destinationRoot: session.rightRoot,
                sourceRootIdentity: session.leftRootIdentity,
                destinationRootIdentity: session.rightRootIdentity,
                actions: [wrongRootAction],
                skipCount: 0,
                estimatedRegularFileCopyBytes: 42
            )
        }
        #expect(throws: FolderSynchronizationModelValidationError.self) {
            _ = try FolderSynchronizationPlanDraft(
                direction: .leftToRight,
                comparisonGeneration: session.generation,
                sourceRoot: session.leftRoot,
                destinationRoot: session.rightRoot,
                sourceRootIdentity: session.leftRootIdentity,
                destinationRootIdentity: session.rightRootIdentity,
                actions: [copy],
                skipCount: 0,
                estimatedRegularFileCopyBytes: 41
            )
        }
    }
}

private func makeSession() throws -> ComparisonSession {
    ComparisonSession(
        generation: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        leftRoot: URL(filePath: "/Users/alice/Source"),
        rightRoot: URL(filePath: "/Users/alice/Destination"),
        leftRootIdentity: .init(entryIdentifier: "source-root", resolvedIdentifier: "source-root"),
        rightRootIdentity: .init(entryIdentifier: "destination-root", resolvedIdentifier: "destination-root")
    )
}

private func entry(
    _ relative: String,
    root: URL,
    identity: String,
    kind: ComparisonEntryKind = .regularFile,
    size: Int64 = 1
) throws -> ComparisonEntry {
    let relativePath = try path(relative)
    return ComparisonEntry(
        relativePath: relativePath,
        url: root.appending(path: relativePath.string),
        kind: kind,
        fingerprint: .init(
            identity: .init(entryIdentifier: identity, resolvedIdentifier: identity),
            byteSize: kind == .regularFile ? size : nil,
            modifiedAt: Date(timeIntervalSince1970: 1)
        ),
        symbolicLinkTarget: nil,
        typeDescription: kind.rawValue
    )
}

private func path(_ value: String) throws -> ComparisonRelativePath {
    try ComparisonRelativePath(components: value.split(separator: "/").map(String.init))
}
