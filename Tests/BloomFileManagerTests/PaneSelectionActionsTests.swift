import Foundation
import Testing
@testable import BloomFileManager

struct PaneSelectionActionsTests {
    @Test func selectAllReturnsEveryVisibleURL() {
        let directory = URL(filePath: "/selection")
        let visibleItems = [
            makeSelectionItem(named: "one.txt", in: directory),
            makeSelectionItem(named: "two.txt", in: directory)
        ]

        #expect(
            PaneSelectionActions.selectAll(visibleItems: visibleItems)
                == Set(visibleItems.map(\.url))
        )
    }

    @Test func invertWithEmptySelectionSelectsEveryVisibleURL() {
        let directory = URL(filePath: "/selection")
        let first = makeSelectionItem(named: "one.txt", in: directory)
        let second = makeSelectionItem(named: "two.txt", in: directory)

        #expect(
            PaneSelectionActions.invert(current: [], visibleItems: [first, second])
                == Set([first.url, second.url])
        )
    }

    @Test func invertWithPartialSelectionKeepsOnlyVisibleUnselectedURLs() {
        let directory = URL(filePath: "/selection")
        let first = makeSelectionItem(named: "one.txt", in: directory)
        let second = makeSelectionItem(named: "two.txt", in: directory)
        let third = makeSelectionItem(named: "three.txt", in: directory)

        #expect(
            PaneSelectionActions.invert(
                current: [first.url],
                visibleItems: [first, second, third]
            ) == Set([second.url, third.url])
        )
    }

    @Test func invertWithFullSelectionClearsVisibleSelection() {
        let directory = URL(filePath: "/selection")
        let first = makeSelectionItem(named: "one.txt", in: directory)
        let second = makeSelectionItem(named: "two.txt", in: directory)

        #expect(
            PaneSelectionActions.invert(
                current: [first.url, second.url],
                visibleItems: [first, second]
            ).isEmpty
        )
    }

    @Test func invertDropsSelectedURLsOutsideVisibleProjection() {
        let directory = URL(filePath: "/selection")
        let visible = makeSelectionItem(named: "visible.txt", in: directory)
        let hidden = makeSelectionItem(named: "hidden.txt", in: directory)

        #expect(
            PaneSelectionActions.invert(
                current: [hidden.url],
                visibleItems: [visible]
            ) == Set([visible.url])
        )
    }

    @Test func matchingExtensionFoldsCaseAndDiacritics() throws {
        let directory = URL(filePath: "/selection")
        let anchor = makeSelectionItem(named: "anchor.Résumé", in: directory)
        let matching = makeSelectionItem(named: "copy.resume", in: directory)
        let different = makeSelectionItem(named: "notes.txt", in: directory)

        let result = try #require(
            PaneSelectionActions.matchingExtension(
                current: [anchor.url],
                visibleItems: [anchor, matching, different]
            )
        )

        #expect(result == Set([anchor.url, matching.url]))
    }

    @Test func matchingExtensionUsesTheSingleVisibleRegularFileAsAnchor() throws {
        let directory = URL(filePath: "/selection")
        let anchor = makeSelectionItem(named: "anchor.txt", in: directory)
        let matching = makeSelectionItem(named: "copy.txt", in: directory)

        let result = try #require(
            PaneSelectionActions.matchingExtension(
                current: [anchor.url],
                visibleItems: [anchor, matching]
            )
        )

        #expect(result == Set([anchor.url, matching.url]))
    }

    @Test func matchingExtensionRequiresExactlyOneSelectedAnchor() {
        let directory = URL(filePath: "/selection")
        let anchor = makeSelectionItem(named: "anchor.txt", in: directory)
        let anotherSelection = makeSelectionItem(named: "other.md", in: directory)

        #expect(
            PaneSelectionActions.matchingExtension(
                current: [anchor.url, anotherSelection.url],
                visibleItems: [anchor, anotherSelection]
            ) == nil
        )
    }

    @Test func matchingExtensionRejectsDirectoryAnchors() {
        let directory = URL(filePath: "/selection")
        let anchor = makeSelectionItem(
            named: "folder.txt",
            in: directory,
            isDirectory: true
        )

        #expect(
            PaneSelectionActions.matchingExtension(
                current: [anchor.url],
                visibleItems: [anchor]
            ) == nil
        )
    }

    @Test func matchingExtensionRejectsPackageAnchors() {
        let directory = URL(filePath: "/selection")
        let anchor = makeSelectionItem(
            named: "bundle.txt",
            in: directory,
            isDirectory: true,
            isPackage: true
        )

        #expect(
            PaneSelectionActions.matchingExtension(
                current: [anchor.url],
                visibleItems: [anchor]
            ) == nil
        )
    }

    @Test func matchingExtensionRejectsDotfilesWithoutAnActualExtension() {
        let directory = URL(filePath: "/selection")
        let anchor = makeSelectionItem(named: ".gitignore", in: directory)

        #expect(
            PaneSelectionActions.matchingExtension(
                current: [anchor.url],
                visibleItems: [anchor]
            ) == nil
        )
    }

    @Test func matchingExtensionRejectsExtensionlessAnchors() {
        let directory = URL(filePath: "/selection")
        let anchor = makeSelectionItem(named: "README", in: directory)

        #expect(
            PaneSelectionActions.matchingExtension(
                current: [anchor.url],
                visibleItems: [anchor]
            ) == nil
        )
    }

    @Test func matchingExtensionIgnoresNonRegularVisibleCandidates() throws {
        let directory = URL(filePath: "/selection")
        let anchor = makeSelectionItem(named: "anchor.txt", in: directory)
        let matching = makeSelectionItem(named: "copy.txt", in: directory)
        let folder = makeSelectionItem(
            named: "folder.txt",
            in: directory,
            isDirectory: true
        )
        let package = makeSelectionItem(
            named: "bundle.txt",
            in: directory,
            isDirectory: true,
            isPackage: true
        )
        let dotfile = makeSelectionItem(named: ".txt", in: directory)
        let extensionless = makeSelectionItem(named: "README", in: directory)

        let result = try #require(
            PaneSelectionActions.matchingExtension(
                current: [anchor.url],
                visibleItems: [anchor, matching, folder, package, dotfile, extensionless]
            )
        )

        #expect(result == Set([anchor.url, matching.url]))
    }

    @Test func matchingExtensionRejectsANonvisibleAnchor() {
        let directory = URL(filePath: "/selection")
        let visible = makeSelectionItem(named: "visible.txt", in: directory)
        let hidden = makeSelectionItem(named: "hidden.txt", in: directory)

        #expect(
            PaneSelectionActions.matchingExtension(
                current: [hidden.url],
                visibleItems: [visible]
            ) == nil
        )
    }
}

private func makeSelectionItem(
    named name: String,
    in directory: URL,
    isDirectory: Bool = false,
    isPackage: Bool = false
) -> FileItem {
    FileItem(
        url: directory.appending(path: name),
        name: name,
        isDirectory: isDirectory,
        isPackage: isPackage,
        modifiedAt: nil,
        byteSize: isDirectory ? nil : 1,
        typeDescription: isDirectory ? "Folder" : "Text"
    )
}
