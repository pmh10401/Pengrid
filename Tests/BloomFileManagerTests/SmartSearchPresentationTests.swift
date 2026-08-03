import AppKit
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

    @Test func rootSummaryUsesPrivacySafeFolderNamesInsteadOfAbsolutePaths() {
        let home = URL(filePath: "/Users/alice", directoryHint: .isDirectory)
        let privateRoot = home.appending(path: "Private/Projects", directoryHint: .isDirectory)

        let summary = SmartSearchPresentation.rootSummary(for: [privateRoot], home: home)

        #expect(summary == "Searching in Projects")
        #expect(summary.contains("alice") == false)
        #expect(summary.contains(privateRoot.path) == false)
        #expect(SmartSearchPresentation.rootSummary(for: [home], home: home) == "Searching in Home")
    }

    @Test func searchStatesProvideDistinctEmptyLoadingErrorAndCompletePresentation() {
        #expect(SmartSearchPresentation.state(for: .idle, resultCount: 0, errorMessage: nil).title == "Ready to search")
        #expect(SmartSearchPresentation.state(for: .searching, resultCount: 0, errorMessage: nil).title == "Searching files")
        #expect(SmartSearchPresentation.state(for: .failed, resultCount: 0, errorMessage: "Search failed.").title == "Search failed.")
        #expect(SmartSearchPresentation.state(for: .results, resultCount: 2, errorMessage: nil).title == "2 results")
    }

    @Test func searchGuidanceExplainsAutomaticKoreanInitialMatching() {
        #expect(SmartSearchPresentation.queryPrompt == "Search names, paths, or Korean initials")
        #expect(SmartSearchPresentation.idleSearchDetail == "Try Korean initials such as ㅎㄱ for 한국 or 한글.")
        #expect(
            SmartSearchPresentation.queryAccessibilityHint
                == "Korean initial searches are supported, for example ㅎㄱ."
        )
    }

    @Test func smartSearchProgressHasAStableAccessibilityIdentifier() {
        #expect(AccessibilityIdentifiers.smartSearchProgress == "smartSearch.progress")
    }

    @Test func smartSearchEditingRootAndResultControlsHaveStableAccessibilityIdentifiers() {
        let resultURL = URL(filePath: "/search/report.txt")
        let savedSearchID = UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!

        #expect(AccessibilityIdentifiers.smartSearchSavedName == "smartSearch.savedName")
        #expect(AccessibilityIdentifiers.smartSearchRoots == "smartSearch.roots")
        #expect(AccessibilityIdentifiers.smartSearchAddRoots == "smartSearch.addRoots")
        #expect(AccessibilityIdentifiers.smartSearchMaximumResults == "smartSearch.maximumResults")
        #expect(
            AccessibilityIdentifiers.smartSearchResultRow(resultURL)
                == "smartSearch.result.L3NlYXJjaC9yZXBvcnQudHh0"
        )
        #expect(
            AccessibilityIdentifiers.smartSearchSavedSearchRow(savedSearchID)
                == "smartSearch.savedSearch.01234567-89ab-cdef-0123-456789abcdef"
        )
    }

    @Test func searchSubmissionRequiresQueryRootsAndAnIdleSearchState() {
        let root = URL(filePath: "/search", directoryHint: .isDirectory)

        #expect(!SmartSearchPresentation.canSubmitSearch(queryText: "report", roots: [], state: .idle))
        #expect(!SmartSearchPresentation.canSubmitSearch(queryText: "   ", roots: [root], state: .idle))
        #expect(!SmartSearchPresentation.canSubmitSearch(queryText: "report", roots: [root], state: .searching))
        #expect(SmartSearchPresentation.canSubmitSearch(queryText: "report", roots: [root], state: .idle))
    }

    @Test func rootChooserAcceptsMultipleDirectoriesOnly() {
        let panel = NSOpenPanel()

        SmartSearchRootPanelConfiguration.apply(to: panel)

        #expect(panel.canChooseDirectories)
        #expect(!panel.canChooseFiles)
        #expect(panel.allowsMultipleSelection)
        #expect(!panel.canCreateDirectories)
        #expect(panel.prompt == "Add")
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
        #expect(workspace.right.selection == [file.standardizedFileURL])
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
