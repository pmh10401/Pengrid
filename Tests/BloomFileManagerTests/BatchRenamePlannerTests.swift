import Foundation
import Testing
@testable import BloomFileManager

@Suite struct BatchRenamePlannerTests {
    @Test func prefixPreservesOrdinaryAndExactCompoundArchiveSuffixes() throws {
        let request = request(sources: [
            source("notes.txt"),
            source("logs.TAR.GZ")
        ])

        let preview = try BatchRenamePlanner.preview(
            request: request,
            rule: .prefix("old-"),
            occupiedNames: ["notes.txt", "logs.TAR.GZ"],
            comparisonPolicy: .caseInsensitiveCanonical
        )

        #expect(preview.entries.map(\.proposedName) == ["old-notes.txt", "old-logs.TAR.GZ"])
        #expect(preview.isExecutable)
    }

    @Test func suffixTreatsDirectoriesAsWholeNamesButPreservesPackageExtension() throws {
        let request = request(sources: [
            source("Folder.v1", isDirectory: true),
            source("Pengrid.app", isDirectory: true, isPackage: true)
        ])

        let preview = try BatchRenamePlanner.preview(
            request: request,
            rule: .suffix("-old"),
            occupiedNames: ["Folder.v1", "Pengrid.app"],
            comparisonPolicy: .caseInsensitiveCanonical
        )

        #expect(preview.entries.map(\.proposedName) == ["Folder.v1-old", "Pengrid-old.app"])
    }

    @Test func prefixTreatsLeadingDotFileAsAWholeName() throws {
        let request = request(sources: [source(".gitignore"), source("notes")])

        let preview = try BatchRenamePlanner.preview(
            request: request,
            rule: .prefix("archived-"),
            occupiedNames: [".gitignore", "notes"],
            comparisonPolicy: .caseInsensitiveCanonical
        )

        #expect(preview.entries.map(\.proposedName) == ["archived-.gitignore", "archived-notes"])
    }

    @Test func caseInsensitiveFindReplaceUsesLocalizedMatchingAndReplacesEveryOccurrence() throws {
        let request = request(sources: [source("보고서FinalFINAL.txt"), source("Final 메모.md")])

        let preview = try BatchRenamePlanner.preview(
            request: request,
            rule: .findReplace(find: "final", replacement: "완료", caseSensitive: false),
            occupiedNames: ["보고서FinalFINAL.txt", "Final 메모.md"],
            comparisonPolicy: .caseInsensitiveCanonical,
            locale: Locale(identifier: "ko_KR")
        )

        #expect(preview.entries.map(\.proposedName) == ["보고서완료완료.txt", "완료 메모.md"])
    }

    @Test func caseSensitiveFindReplaceLeavesDifferentCaseUnchanged() throws {
        let request = request(sources: [source("Final.txt"), source("final.txt")])

        let preview = try BatchRenamePlanner.preview(
            request: request,
            rule: .findReplace(find: "final", replacement: "done", caseSensitive: true),
            occupiedNames: ["Final.txt", "final.txt"],
            comparisonPolicy: .caseSensitiveCanonical
        )

        #expect(preview.entries.map(\.status) == [.unchanged, .ready])
        #expect(preview.plan?.entries.map(\.proposedName) == ["done.txt"])
    }

    @Test func sequenceUsesStableInputOrderPaddingAndPreservedSuffixes() throws {
        let request = request(sources: [source("z.jpg"), source("a.png"), source("clip.tar.xz")])

        let preview = try BatchRenamePlanner.preview(
            request: request,
            rule: .sequence(baseName: "여행", start: 8, digits: 3),
            occupiedNames: ["z.jpg", "a.png", "clip.tar.xz"],
            comparisonPolicy: .caseInsensitiveCanonical
        )

        #expect(preview.entries.map(\.proposedName) == ["여행 008.jpg", "여행 009.png", "여행 010.tar.xz"])
    }

    @Test func sequenceRejectsBlankBaseAndWidthsOutsideTheSharedOneToNineBound() {
        let request = request(sources: [source("A.txt"), source("B.txt")])

        #expect(throws: BatchRenamePlanningError.invalidSequence) {
            try BatchRenamePlanner.preview(
                request: request,
                rule: .sequence(baseName: "  \n", start: 1, digits: 2),
                occupiedNames: ["A.txt", "B.txt"],
                comparisonPolicy: .caseSensitiveCanonical
            )
        }
        #expect(throws: BatchRenamePlanningError.invalidSequence) {
            try BatchRenamePlanner.preview(
                request: request,
                rule: .sequence(baseName: "Item", start: 1, digits: 10),
                occupiedNames: ["A.txt", "B.txt"],
                comparisonPolicy: .caseSensitiveCanonical
            )
        }
    }

    @Test func generatedDuplicatesAreRejectedUsingEffectiveFilenameSemantics() throws {
        let request = request(sources: [source("A.txt"), source("a.TXT")])

        let preview = try BatchRenamePlanner.preview(
            request: request,
            rule: .findReplace(find: "A", replacement: "same", caseSensitive: false),
            occupiedNames: ["A.txt", "a.TXT"],
            comparisonPolicy: .caseInsensitiveCanonical
        )

        #expect(preview.entries.map(\.status) == [.duplicate, .duplicate])
        #expect(!preview.isExecutable)
        #expect(preview.plan == nil)
    }

    @Test func unselectedSiblingCollisionIsRejectedButSelectedSourceNamesAreAvailable() throws {
        let request = request(sources: [source("A.txt"), source("B.txt")])

        let swap = try BatchRenamePlanner.preview(
            request: request,
            proposedNames: ["B.txt", "A.txt"],
            occupiedNames: ["A.txt", "B.txt"],
            comparisonPolicy: .caseInsensitiveCanonical
        )
        let collision = try BatchRenamePlanner.preview(
            request: request,
            proposedNames: ["C.txt", "D.txt"],
            occupiedNames: ["A.txt", "B.txt", "c.TXT"],
            comparisonPolicy: .caseInsensitiveCanonical
        )

        #expect(swap.isExecutable)
        #expect(swap.plan?.entries.map(\.proposedName) == ["B.txt", "A.txt"])
        #expect(collision.entries.map(\.status) == [.occupied, .ready])
        #expect(!collision.isExecutable)
    }

    @Test func invalidGeneratedNameAndEmptyFindAreReportedWithoutAPlan() throws {
        let request = request(sources: [source("one.txt"), source("two.txt")])

        let invalidName = try BatchRenamePlanner.preview(
            request: request,
            rule: .prefix("bad/name-"),
            occupiedNames: ["one.txt", "two.txt"],
            comparisonPolicy: .caseInsensitiveCanonical
        )

        #expect(invalidName.entries.map(\.status) == [
            .invalidName(.containsPathSeparator),
            .invalidName(.containsPathSeparator)
        ])
        #expect(invalidName.plan == nil)
        #expect(throws: BatchRenamePlanningError.emptyFindText) {
            try BatchRenamePlanner.preview(
                request: request,
                rule: .findReplace(find: "", replacement: "done", caseSensitive: true),
                occupiedNames: ["one.txt", "two.txt"],
                comparisonPolicy: .caseInsensitiveCanonical
            )
        }
    }

    @Test func fewerThanTwoSourcesAndMixedParentsFailClosed() throws {
        #expect(throws: BatchRenamePlanningError.selectionTooSmall) {
            try BatchRenamePlanner.preview(
                request: request(sources: [source("one.txt")]),
                rule: .prefix("old-"),
                occupiedNames: ["one.txt"],
                comparisonPolicy: .caseInsensitiveCanonical
            )
        }

        let mixed = BatchRenamePlanningRequest(
            parentURL: parent,
            parentIdentity: identity("parent"),
            sources: [
                source("one.txt"),
                BatchRenameSource(
                    url: URL(filePath: "/other/two.txt"),
                    identity: identity("two.txt"),
                    name: "two.txt",
                    isDirectory: false,
                    isPackage: false
                )
            ]
        )
        #expect(throws: BatchRenamePlanningError.mixedParents) {
            try BatchRenamePlanner.preview(
                request: mixed,
                rule: .prefix("old-"),
                occupiedNames: ["one.txt", "two.txt"],
                comparisonPolicy: .caseInsensitiveCanonical
            )
        }
    }

    private var parent: URL {
        URL(filePath: "/tmp/batch-rename", directoryHint: .isDirectory)
    }

    private func request(sources: [BatchRenameSource]) -> BatchRenamePlanningRequest {
        BatchRenamePlanningRequest(
            parentURL: parent,
            parentIdentity: identity("parent"),
            sources: sources
        )
    }

    private func source(
        _ name: String,
        isDirectory: Bool = false,
        isPackage: Bool = false
    ) -> BatchRenameSource {
        BatchRenameSource(
            url: parent.appending(path: name, directoryHint: isDirectory ? .isDirectory : .notDirectory),
            identity: identity(name),
            name: name,
            isDirectory: isDirectory,
            isPackage: isPackage
        )
    }

    private func identity(_ value: String) -> FileIdentity {
        FileIdentity(entryIdentifier: "entry-\(value)", resolvedIdentifier: "resolved-\(value)")
    }
}
