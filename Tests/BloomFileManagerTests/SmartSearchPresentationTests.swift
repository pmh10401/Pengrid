import Foundation
import Testing
@testable import BloomFileManager

@MainActor
struct SmartSearchPresentationTests {
    @Test func resultAccessibilityLabelsIncludeRelativePathAndAvailability() {
        let localResult = SmartSearchResult(
            item: fileItem(
                named: "Budget.xlsx",
                availability: .availableLocally
            ),
            relativePath: "Finance/2026/Budget.xlsx",
            score: 1
        )
        let onlineResult = SmartSearchResult(
            item: fileItem(
                named: "Roadmap.pdf",
                availability: .onlineOnly
            ),
            relativePath: "Planning/Roadmap.pdf",
            score: 1
        )

        #expect(
            SmartSearchPresentation.resultAccessibilityLabel(for: localResult)
                == "Budget.xlsx, Finance/2026/Budget.xlsx, Available locally"
        )
        #expect(
            SmartSearchPresentation.resultAccessibilityLabel(for: onlineResult)
                == "Roadmap.pdf, Planning/Roadmap.pdf, Available online"
        )
    }

    @Test func savedSearchRowsDescribeTheQueryAndDeleteAffordance() throws {
        let record = SmartSearchRecord(
            displayName: "Quarterly reports",
            query: try SmartSearchQuery(
                text: "report",
                roots: [URL(filePath: "/search", directoryHint: .isDirectory)]
            )
        )

        #expect(
            SmartSearchPresentation.savedSearchAccessibilityLabel(for: record)
                == "Saved search, Quarterly reports, query report"
        )
        #expect(SmartSearchPresentation.deleteSavedSearchLabel == "Delete saved search")
    }

    @Test func searchStatesProvideDistinctEmptyLoadingErrorAndCompletePresentation() {
        #expect(SmartSearchPresentation.state(for: .idle, resultCount: 0, errorMessage: nil).title == "Ready to search")
        #expect(SmartSearchPresentation.state(for: .searching, resultCount: 0, errorMessage: nil).title == "Searching files")
        #expect(SmartSearchPresentation.state(for: .failed, resultCount: 0, errorMessage: "Search failed.").title == "Search failed.")
        #expect(SmartSearchPresentation.state(for: .results, resultCount: 2, errorMessage: nil).title == "2 results")
    }

    @Test func smartSearchProgressHasAStableAccessibilityIdentifier() {
        #expect(AccessibilityIdentifiers.smartSearchProgress == "smartSearch.progress")
    }

    @Test func openingResultsNavigatesTheActivePaneToDirectoryOrContainingFolder() async throws {
        let root = try TemporaryDirectory()
        defer { root.remove() }
        let left = root.url.appending(path: "left", directoryHint: .isDirectory)
        let right = root.url.appending(path: "right", directoryHint: .isDirectory)
        let folder = root.url.appending(path: "folder", directoryHint: .isDirectory)
        let file = folder.appending(path: "notes.txt")
        try FileManager.default.createDirectory(at: left, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: right, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("notes".utf8).write(to: file)

        let workspace = WorkspaceState(
            leftURL: left,
            rightURL: right,
            listingService: LiveDirectoryListingService(batchSize: 16)
        )
        let fileResult = SmartSearchResult(
            item: FileItem(
                url: file,
                name: "notes.txt",
                isDirectory: false,
                isPackage: false,
                modifiedAt: nil,
                byteSize: nil,
                typeDescription: "Text",
                availability: .onlineOnly
            ),
            relativePath: "folder/notes.txt",
            score: 1
        )
        let folderResult = SmartSearchResult(
            item: FileItem(
                url: folder,
                name: "folder",
                isDirectory: true,
                isPackage: false,
                modifiedAt: nil,
                byteSize: nil,
                typeDescription: "Folder"
            ),
            relativePath: "folder",
            score: 1
        )

        workspace.activate(.right)
        await SmartSearchResultNavigationRouter.open(fileResult, in: workspace)
        #expect(workspace.right.currentDirectory.standardizedFileURL == folder.standardizedFileURL)
        #expect(workspace.left.currentDirectory.standardizedFileURL == left.standardizedFileURL)

        workspace.activate(.left)
        await SmartSearchResultNavigationRouter.open(folderResult, in: workspace)
        #expect(workspace.left.currentDirectory.standardizedFileURL == folder.standardizedFileURL)
    }
}

private func fileItem(named name: String, availability: CloudItemAvailability) -> FileItem {
    FileItem(
        url: URL(filePath: "/search/\(name)"),
        name: name,
        isDirectory: false,
        isPackage: false,
        modifiedAt: nil,
        byteSize: nil,
        typeDescription: "Text",
        availability: availability
    )
}
