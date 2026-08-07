import Foundation
import Testing
@testable import BloomFileManager

struct FileTableUpdatePlannerTests {
    @Test func plannerReturnsNoneForEqualRows() {
        let rows = items(["a", "b"])

        #expect(FileTableUpdatePlanner().plan(from: rows, to: rows) == .none)
    }

    @Test func plannerReloadsOnlyChangedValuesWhenIdentityOrderIsStable() {
        let old = items(["a", "b"])
        let changed = FileItem(
            url: old[1].url,
            name: "renamed-b",
            isDirectory: false,
            isPackage: false,
            modifiedAt: nil,
            byteSize: 1,
            typeDescription: "File"
        )

        #expect(FileTableUpdatePlanner().plan(from: old, to: [old[0], changed]) == .reload(IndexSet(integer: 1)))
    }

    @Test func plannerInsertsWhenOldOrderIsSubsequence() {
        #expect(
            FileTableUpdatePlanner().plan(
                from: items(["b", "d"]),
                to: items(["a", "b", "c", "d"])
            ) == .insert(IndexSet([0, 2]))
        )
    }

    @Test func plannerRemovesWhenNewOrderIsSubsequence() {
        #expect(
            FileTableUpdatePlanner().plan(
                from: items(["a", "b", "c", "d"]),
                to: items(["b", "d"])
            ) == .remove(IndexSet([0, 2]))
        )
    }

    @Test func plannerBuildsSequentialMovesForPureReorder() {
        #expect(
            FileTableUpdatePlanner().plan(
                from: items(["a", "b", "c", "d"]),
                to: items(["d", "b", "a", "c"])
            ) == .move([
                FileTableRowMove(from: 3, to: 0),
                FileTableRowMove(from: 2, to: 1)
            ])
        )
    }

    @Test func plannerFallsBackWhenReorderedRowsAlsoChangeValues() {
        let old = items(["a", "b"])
        let changedA = FileItem(
            url: old[0].url,
            name: "changed-a",
            isDirectory: false,
            isPackage: false,
            modifiedAt: nil,
            byteSize: 1,
            typeDescription: "File"
        )

        #expect(FileTableUpdatePlanner().plan(from: old, to: [old[1], changedA]) == .reloadAll)
    }

    @Test func plannerFallsBackForMixedInsertionAndRemoval() {
        #expect(
            FileTableUpdatePlanner().plan(
                from: items(["a", "b", "c"]),
                to: items(["a", "d", "c"])
            ) == .reloadAll
        )
    }

    @Test func plannerFallsBackForDuplicates() {
        #expect(FileTableUpdatePlanner().plan(from: [], to: items(["a", "a"])) == .reloadAll)
    }

    @Test func plannerRejectsDuplicatesAfterURLStandardization() {
        let duplicateRows = [
            item(name: "canonical", url: URL(filePath: "/table/a")),
            item(name: "alias", url: URL(filePath: "/table/folder/../a"))
        ]

        #expect(FileTableUpdatePlanner().plan(from: [], to: duplicateRows) == .reloadAll)
    }

    @Test func plannerUsesStandardizedURLAsRowIdentity() {
        let old = [item(name: "a", url: URL(filePath: "/table/folder/../a"))]
        let new = [item(name: "a", url: URL(filePath: "/table/a"))]

        #expect(FileTableUpdatePlanner().plan(from: old, to: new) == .reload(IndexSet(integer: 0)))
    }

    @Test func plannerAllowsChangesAtThresholdAndFallsBackAboveIt() {
        let planner = FileTableUpdatePlanner(maximumIncrementalChanges: 2)

        #expect(planner.plan(from: [], to: items(["a", "b"])) == .insert(IndexSet([0, 1])))
        #expect(planner.plan(from: [], to: items(["a", "b", "c"])) == .reloadAll)
    }

    @Test func plannerFallsBackWhenMoveCountExceedsThreshold() {
        let planner = FileTableUpdatePlanner(maximumIncrementalChanges: 1)

        #expect(
            planner.plan(
                from: items(["a", "b", "c"]),
                to: items(["c", "b", "a"])
            ) == .reloadAll
        )
    }
}

private func items(_ names: [String]) -> [FileItem] {
    names.map { name in
        item(name: name, url: URL(filePath: "/table/\(name)"))
    }
}

private func item(name: String, url: URL) -> FileItem {
    FileItem(
        url: url,
        name: name,
        isDirectory: false,
        isPackage: false,
        modifiedAt: nil,
        byteSize: 1,
        typeDescription: "File"
    )
}
