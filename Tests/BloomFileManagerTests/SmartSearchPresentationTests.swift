import Foundation
import Testing
@testable import BloomFileManager

@Test func smartSearchPresentationProvidesDateFiltersAndSafeAnnouncements() throws {
    let implementation = try smartSearchSource(named: "Views/SmartSearchView.swift")

    #expect(implementation.contains("DatePicker"))
    #expect(implementation.contains("modifiedAfter"))
    #expect(implementation.contains("modifiedBefore"))
    #expect(implementation.contains("LiveSmartSearchAnnouncementPoster"))
    #expect(implementation.contains("announcementRequested"))
    #expect(implementation.contains("router.transferRequests("))
    #expect(implementation.contains("operationController.runIdentifiedTransfer("))
    #expect(implementation.contains("SmartSearchInvocationCapture"))
    #expect(implementation.contains("SmartSearchMutationHandoff"))
    #expect(implementation.contains("Picker(\"Sort\""))
    #expect(!implementation.contains("selectedColumn"))
    #expect(implementation.contains("AccessibilityIdentifiers.smartSearchRename"))
    #expect(implementation.contains("AccessibilityIdentifiers.smartSearchDelete"))
    #expect(implementation.contains("SmartSearchAnnouncementPosting"))
    #expect(implementation.contains("onChange(of: store.progressMessage)"))
    #expect(implementation.contains("Search cancelled"))
    #expect(implementation.contains("loadFilterDrafts()"))
    #expect(implementation.contains("sizeDescription(result.item.byteSize)"))
    #expect(implementation.contains("dateDescription(result.item.modifiedAt)"))
    #expect(!implementation.contains("url.path)"))
}

@MainActor
@Test func invocationCaptureRetainsPaneObjectsAndDestinationAfterActivePaneChanges() {
    let workspace = WorkspaceState(
        leftURL: URL(filePath: "/left"), rightURL: URL(filePath: "/right"),
        listingService: StubDirectoryListingService(values: [:])
    )
    let capture = SmartSearchInvocationCapture(workspace: workspace, results: [])
    workspace.activate(.right)
    #expect(capture.sourcePane === workspace.left)
    #expect(capture.targetPane === workspace.right)
    #expect(capture.destinationURL == URL(filePath: "/right"))
}

@Test func mutationHandoffDismissesOnlyWhenQueueAccepts() {
    var handoff = SmartSearchMutationHandoff()
    var dismisses = 0
    #expect(!handoff.complete(accepted: false) { dismisses += 1 })
    #expect(dismisses == 0)
    #expect(handoff.errorMessage == "Could not queue operation. Search remains open.")
    #expect(handoff.complete(accepted: true) { dismisses += 1 })
    #expect(dismisses == 1)
    #expect(handoff.errorMessage == nil)
}

@Test func filterDraftRestoresCurrentMetadataAndLegacyDirectoryIntent() throws {
    let metadata = try SmartSearchMetadataFilter(kind: .folders, extensionText: "pdf", minimumBytes: 4)
    let current = SmartSearchFilterDraft(metadata: metadata, includeHidden: true, includePackages: true)
    #expect(current.kind == .folders)
    #expect(current.extensionText == "pdf")
    #expect(current.includeHidden && current.includePackages)

    let legacy = SmartSearchFilterDraft.legacy(includeDirectories: false)
    #expect(legacy.kind == .files)
}

@MainActor
@Test func announcementCoordinatorCoalescesProgressAndAnnouncesTerminalStates() {
    let recorder = SearchAnnouncementRecorder()
    let coordinator = SmartSearchAnnouncementCoordinator(poster: recorder, progressStride: 100)
    coordinator.progress("Examined 1 entries…", count: 1)
    coordinator.progress("Examined 2 entries…", count: 2)
    coordinator.progress("Examined 100 entries…", count: 100)
    coordinator.phase(.cancelled, resultCount: 0, error: nil)
    coordinator.phase(.failed, resultCount: 0, error: "Search failed.")
    coordinator.phase(.results, resultCount: 2, error: nil)
    #expect(recorder.messages == ["Examined 1 entries…", "Examined 100 entries…", "Search cancelled", "Search failed.", "Found 2 search results"])
}

@MainActor
private final class SearchAnnouncementRecorder: SmartSearchAnnouncementPosting {
    var messages: [String] = []
    func post(_ message: String) { messages.append(message) }
}

private func smartSearchSource(named relativePath: String) throws -> String {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    return try String(
        contentsOf: packageRoot.appending(path: "Sources/BloomFileManager").appending(path: relativePath),
        encoding: .utf8
    )
}
