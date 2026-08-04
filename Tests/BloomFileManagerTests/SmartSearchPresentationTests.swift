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
