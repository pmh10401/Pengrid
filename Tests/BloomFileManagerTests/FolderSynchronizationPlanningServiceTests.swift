import Foundation
import Testing
@testable import BloomFileManager

@Suite struct FolderSynchronizationPlanningServiceTests {
    private let planner = FolderSynchronizationPlanningService()

    @Test func sourceOnlyRegularFileBecomesCopy() throws {
        let fixture = try Fixture()
        let row = fixture.row("only.txt", left: fixture.left("only.txt"), status: .leftOnly)
        let reverseRow = fixture.row("reverse-only.txt", right: fixture.right("reverse-only.txt"), status: .rightOnly)

        let result = planner.plan(phase: .upToDate, session: fixture.session, rows: [row], direction: .leftToRight)
        let reverseResult = planner.plan(phase: .upToDate, session: fixture.session, rows: [reverseRow], direction: .rightToLeft)

        #expect(try readyDraft(result).actions.map(\.kind) == [.copy])
        #expect(try readyDraft(result).actions.map(\.relativePath.string) == ["only.txt"])
        #expect(try readyDraft(result).estimatedRegularFileCopyBytes == 10)
        #expect(try readyDraft(reverseResult).actions.map(\.kind) == [.copy])
        #expect(try readyDraft(reverseResult).sourceRoot == fixture.session.rightRoot)
        #expect(try readyDraft(reverseResult).destinationRoot == fixture.session.leftRoot)
    }

    @Test func supportedChangedSameKindBecomesReplace() throws {
        let fixture = try Fixture()
        let row = fixture.row(
            "changed.txt",
            left: fixture.left("changed.txt", identity: "left-changed", size: 44),
            right: fixture.right("changed.txt", identity: "right-changed", size: 9),
            status: .contentChanged
        )

        let result = planner.plan(phase: .upToDate, session: fixture.session, rows: [row], direction: .leftToRight)

        #expect(try readyDraft(result).actions.map(\.kind) == [.replace])
        #expect(try readyDraft(result).estimatedRegularFileCopyBytes == 44)
    }

    @Test func changedDirectoryIsSkippedAsAContainerWhileChangedFileDescendantIsReplaced() throws {
        let fixture = try Fixture()
        let rows = [
            fixture.row(
                "Folder",
                left: fixture.left("Folder", kind: .directory),
                right: fixture.right("Folder", kind: .directory),
                status: .metadataChanged
            ),
            fixture.row(
                "Folder/report.txt",
                left: fixture.left("Folder/report.txt", size: 42),
                right: fixture.right("Folder/report.txt", size: 9),
                status: .contentChanged
            )
        ]

        let result = planner.plan(phase: .upToDate, session: fixture.session, rows: rows, direction: .leftToRight)

        #expect(try readyDraft(result).actions.map(\.relativePath.string) == ["Folder/report.txt"])
        #expect(try readyDraft(result).actions.map(\.kind) == [.replace])
        #expect(try readyDraft(result).skipCount == 1)
    }

    @Test func destinationOnlyEntryBecomesTrash() throws {
        let fixture = try Fixture()
        let row = fixture.row("obsolete.txt", right: fixture.right("obsolete.txt"), status: .rightOnly)

        let result = planner.plan(phase: .upToDate, session: fixture.session, rows: [row], direction: .leftToRight)

        #expect(try readyDraft(result).actions.map(\.kind) == [.moveDestinationToTrash])
        #expect(try readyDraft(result).estimatedRegularFileCopyBytes == 0)
    }

    @Test func identicalEntriesAreSkippedAndEmptyPlanIsAlreadySynchronized() throws {
        let fixture = try Fixture()
        let entry = fixture.left("same.txt", identity: "same")
        let row = fixture.row("same.txt", left: entry, right: fixture.right("same.txt", identity: "same"), status: .identical(.checksum))

        let result = planner.plan(phase: .upToDate, session: fixture.session, rows: [row], direction: .leftToRight)

        guard case let .alreadySynchronized(summary) = result else {
            Issue.record("Expected already synchronized result")
            return
        }
        #expect(summary.skipCount == 1)
        #expect(summary.comparisonGeneration == fixture.session.generation)
    }

    @Test func topLevelDirectoryActionSuppressesDescendantActions() throws {
        let fixture = try Fixture()
        let rows = [
            fixture.row("Reports", left: fixture.left("Reports", kind: .directory), status: .leftOnly),
            fixture.row("Reports/2026.txt", left: fixture.left("Reports/2026.txt"), status: .leftOnly),
            fixture.row("obsolete", right: fixture.right("obsolete", kind: .directory), status: .rightOnly),
            fixture.row("obsolete/old.txt", right: fixture.right("obsolete/old.txt"), status: .rightOnly)
        ]

        let result = planner.plan(phase: .upToDate, session: fixture.session, rows: rows, direction: .leftToRight)

        #expect(try readyDraft(result).actions.map(\.relativePath.string) == ["obsolete", "Reports"])
        #expect(try readyDraft(result).actions.map(\.kind) == [.moveDestinationToTrash, .copy])
        #expect(try readyDraft(result).estimatedRegularFileCopyBytes == 0)
    }

    @Test func inconsistentStatusSidePathsAndURLsBlockBeforeDirectionMapping() throws {
        let fixture = try Fixture()
        let mismatchedPath = fixture.left("different.txt")
        let wrongURL = fixture.entry(
            "wrong-url.txt",
            root: URL(filePath: "/outside"),
            identity: "wrong-url",
            kind: .regularFile,
            size: 10
        )
        let rows = [
            fixture.row("left-with-both.txt", left: fixture.left("left-with-both.txt"), right: fixture.right("left-with-both.txt"), status: .leftOnly),
            fixture.row("right-with-none.txt", status: .rightOnly),
            fixture.row("identical-missing.txt", left: fixture.left("identical-missing.txt"), status: .identical(.quick)),
            fixture.row("row-path.txt", left: mismatchedPath, status: .leftOnly),
            fixture.row("wrong-url.txt", left: wrongURL, status: .leftOnly)
        ]

        let result = planner.plan(phase: .upToDate, session: fixture.session, rows: rows, direction: .rightToLeft)

        #expect(blockerReasons(result) == [
            .invalidComparisonRow, .invalidComparisonRow, .invalidComparisonRow,
            .invalidComparisonRow, .invalidComparisonRow
        ])
        #expect(blockers(result).map(\.id) == Array(Set(blockers(result).map(\.id))).sorted())
    }

    @Test func mixedDirectoryDescendantSemanticsBlockInsteadOfOverlappingActions() throws {
        let fixture = try Fixture()
        let rows = [
            fixture.row("Folder", left: fixture.left("Folder", kind: .directory), status: .leftOnly),
            fixture.row(
                "Folder/report.txt",
                left: fixture.left("Folder/report.txt", size: 42),
                right: fixture.right("Folder/report.txt", size: 9),
                status: .contentChanged
            )
        ]

        let result = planner.plan(phase: .upToDate, session: fixture.session, rows: rows, direction: .leftToRight)

        #expect(blockerReasons(result) == [.unsafeAncestorRelationship])
        #expect(blockers(result).map(\.relativePath?.string) == ["Folder/report.txt"])
    }

    @Test func repeatedBlockersAreDeduplicatedAfterStableOrdering() throws {
        let fixture = try Fixture()
        let duplicate = fixture.row("same.txt", left: fixture.left("same.txt"), status: .leftOnly)

        let result = planner.plan(
            phase: .upToDate,
            session: fixture.session,
            rows: [duplicate, duplicate, duplicate],
            direction: .leftToRight
        )

        #expect(blockers(result).map(\.id) == ["same.txt:duplicateComparisonPath"])
    }

    @Test func actionsSortParentsBeforeChildrenAndUseStableRelativePathOrder() throws {
        let fixture = try Fixture()
        let rows = [
            fixture.row("zeta.txt", left: fixture.left("zeta.txt"), status: .leftOnly),
            fixture.row("Alpha/child.txt", left: fixture.left("Alpha/child.txt"), status: .leftOnly),
            fixture.row("Beta", left: fixture.left("Beta", kind: .directory), status: .leftOnly),
            fixture.row("Alpha", left: fixture.left("Alpha", kind: .directory), right: fixture.right("Alpha", kind: .directory), status: .contentChanged),
            fixture.row("apple.txt", left: fixture.left("apple.txt"), status: .leftOnly)
        ]

        let result = planner.plan(phase: .upToDate, session: fixture.session, rows: rows, direction: .leftToRight)

        #expect(try readyDraft(result).actions.map(\.relativePath.string) == ["apple.txt", "Beta", "zeta.txt", "Alpha/child.txt"])
    }

    @Test func nonCurrentPhaseAndMissingSessionAreBlocked() throws {
        let fixture = try Fixture()
        let row = fixture.row("only.txt", left: fixture.left("only.txt"), status: .leftOnly)

        let stale = planner.plan(phase: .comparing, session: fixture.session, rows: [row], direction: .leftToRight)
        let missing = planner.plan(phase: .upToDate, session: nil, rows: [row], direction: .leftToRight)

        #expect(blockerReasons(stale) == [.comparisonNotCurrent])
        #expect(blockerReasons(missing) == [.missingComparisonSession])
    }

    @Test func conflictsCheckingUnstableErrorsAndUnsupportedKindsAreBlocked() throws {
        let fixture = try Fixture()
        let rows = [
            fixture.row("type", left: fixture.left("type"), right: fixture.right("type", kind: .directory), status: .typeConflict),
            fixture.row("name", left: fixture.left("name"), right: fixture.right("name"), status: .nameConflict),
            fixture.row("checking", left: fixture.left("checking"), right: fixture.right("checking"), status: .checking(nil)),
            fixture.row("unstable", left: fixture.left("unstable"), right: fixture.right("unstable"), status: .unstable),
            fixture.row("error", left: fixture.left("error"), right: fixture.right("error"), status: .error("/Users/alice/Secret/raw error")),
            fixture.row("link", left: fixture.left("link", kind: .symbolicLink), status: .leftOnly),
            fixture.row("package", left: fixture.left("package", kind: .package), status: .leftOnly),
            fixture.row("special", right: fixture.right("special", kind: .special), status: .rightOnly)
        ]

        let result = planner.plan(phase: .upToDate, session: fixture.session, rows: rows, direction: .leftToRight)
        let reasons = blockerReasons(result)

        #expect(reasons == [
            .checking, .comparisonError, .unsupportedEntryKind, .nameConflict,
            .unsupportedEntryKind, .unsupportedEntryKind, .typeConflict, .unstable
        ])
        #expect(blockers(result).allSatisfy { !$0.presentation.contains("/Users/alice/Secret/raw error") })
    }

    @Test func equalOrNestedRootsAreBlocked() throws {
        let fixture = try Fixture()
        let row = fixture.row("only.txt", left: fixture.left("only.txt"), status: .leftOnly)
        let equal = ComparisonSession(
            generation: fixture.session.generation,
            leftRoot: fixture.session.leftRoot,
            rightRoot: fixture.session.leftRoot,
            leftRootIdentity: fixture.session.leftRootIdentity,
            rightRootIdentity: fixture.session.leftRootIdentity
        )
        let nested = ComparisonSession(
            generation: fixture.session.generation,
            leftRoot: fixture.session.leftRoot,
            rightRoot: fixture.session.leftRoot.appending(path: "Child"),
            leftRootIdentity: fixture.session.leftRootIdentity,
            rightRootIdentity: .init(entryIdentifier: "child", resolvedIdentifier: "child")
        )

        #expect(blockerReasons(planner.plan(phase: .upToDate, session: equal, rows: [row], direction: .leftToRight)) == [.equalRoots])
        #expect(blockerReasons(planner.plan(phase: .upToDate, session: nested, rows: [row], direction: .leftToRight)) == [.nestedRoots])
    }
}

private struct Fixture {
    let session: ComparisonSession

    init() throws {
        session = ComparisonSession(
            generation: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            leftRoot: URL(filePath: "/fixtures/left"),
            rightRoot: URL(filePath: "/fixtures/right"),
            leftRootIdentity: .init(entryIdentifier: "left-root", resolvedIdentifier: "left-root"),
            rightRootIdentity: .init(entryIdentifier: "right-root", resolvedIdentifier: "right-root")
        )
    }

    func left(_ relative: String, identity: String? = nil, kind: ComparisonEntryKind = .regularFile, size: Int64 = 10) -> ComparisonEntry {
        entry(relative, root: session.leftRoot, identity: identity ?? "left-\(relative)", kind: kind, size: size)
    }

    func right(_ relative: String, identity: String? = nil, kind: ComparisonEntryKind = .regularFile, size: Int64 = 10) -> ComparisonEntry {
        entry(relative, root: session.rightRoot, identity: identity ?? "right-\(relative)", kind: kind, size: size)
    }

    func row(_ relative: String, left: ComparisonEntry? = nil, right: ComparisonEntry? = nil, status: ComparisonStatus) -> ComparisonRow {
        ComparisonRow(relativePath: try! path(relative), left: left, right: right, status: status)
    }

    func entry(_ relative: String, root: URL, identity: String, kind: ComparisonEntryKind, size: Int64) -> ComparisonEntry {
        let relativePath = try! path(relative)
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
}

private func path(_ value: String) throws -> ComparisonRelativePath {
    try ComparisonRelativePath(components: value.split(separator: "/").map(String.init))
}

private func readyDraft(_ result: FolderSynchronizationPlanningResult) throws -> FolderSynchronizationPlanDraft {
    guard case let .ready(draft) = result else { throw PlanningTestError.expectedReady }
    return draft
}

private func blockers(_ result: FolderSynchronizationPlanningResult) -> [FolderSynchronizationBlocker] {
    guard case let .blocked(blockers) = result else { return [] }
    return blockers
}

private func blockerReasons(_ result: FolderSynchronizationPlanningResult) -> [FolderSynchronizationBlocker.Reason] {
    blockers(result).map(\.reason)
}

private enum PlanningTestError: Error { case expectedReady }
