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
    #expect(implementation.contains("let sourcePane = workspace.activePane"))
    #expect(implementation.contains("let destinationPane ="))
    #expect(implementation.contains("if operationController.runIdentifiedTransfer("))
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
