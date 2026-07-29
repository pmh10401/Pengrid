import Foundation
import Testing
@testable import BloomFileManager

@Test func accessibilityIdentifiersRemainStable() {
    #expect(AccessibilityIdentifiers.placesRail == "placesRail")
    #expect(AccessibilityIdentifiers.favoritesSection == "favoritesSection")
    #expect(AccessibilityIdentifiers.leftPane == "leftPane")
    #expect(AccessibilityIdentifiers.rightPane == "rightPane")
    #expect(AccessibilityIdentifiers.operationStatus == "operationStatus")
    #expect(AccessibilityIdentifiers.conflictSheet == "conflictSheet")
}

@Test func storageInspectorIdentifiersRemainStable() {
    #expect(AccessibilityIdentifiers.storageInspectorWorkspace == "storageInspector.workspace")
    #expect(AccessibilityIdentifiers.storageInspectorToolbar == "storageInspector.toolbar")
    #expect(AccessibilityIdentifiers.storageInspectorSidebar == "storageInspector.sidebar")
    #expect(AccessibilityIdentifiers.storageInspectorResults == "storageInspector.results")
    #expect(AccessibilityIdentifiers.storageInspectorDetail == "storageInspector.detail")
    #expect(AccessibilityIdentifiers.storageInspectorReview == "storageInspector.review")
    #expect(AccessibilityIdentifiers.storageInspectorChooseLocation
        == "storageInspector.chooseLocation")
    #expect(AccessibilityIdentifiers.storageInspectorStart == "storageInspector.start")
    #expect(AccessibilityIdentifiers.storageInspectorCancel == "storageInspector.cancel")
    #expect(AccessibilityIdentifiers.storageInspectorScanAgain == "storageInspector.scanAgain")
    #expect(AccessibilityIdentifiers.storageInspectorHiddenItems
        == "storageInspector.hiddenItems")
    #expect(AccessibilityIdentifiers.storageInspectorExit == "storageInspector.exit")
    #expect(AccessibilityIdentifiers.storageInspectorProgress == "storageInspector.progress")
    #expect(AccessibilityIdentifiers.storageInspectorGroupNavigation
        == "storageInspector.groupNavigation")
    #expect(AccessibilityIdentifiers.storageInspectorGroupMembers
        == "storageInspector.groupMembers")
    #expect(Set(StorageAnalysisSection.allCases.map(
        AccessibilityIdentifiers.storageInspectorSection
    )).count == StorageAnalysisSection.allCases.count)
    #expect(Set(StorageFileCategory.allCases.map(
        AccessibilityIdentifiers.storageInspectorCategory
    )).count == StorageFileCategory.allCases.count)
}

@Test func paneAccessibilityPresentationNamesSideAndActiveState() {
    #expect(PaneAccessibilityPresentation.label(for: .left) == "Left file pane")
    #expect(PaneAccessibilityPresentation.label(for: .right) == "Right file pane")
    #expect(PaneAccessibilityPresentation.value(isActive: true) == "Active pane")
    #expect(PaneAccessibilityPresentation.value(isActive: false) == "Inactive pane")
}

@Test func reduceMotionDisablesOnlyNonessentialAnimation() {
    #expect(AccessibilityMotionPresentation.allowsNonessentialAnimation(reduceMotion: false))
    #expect(!AccessibilityMotionPresentation.allowsNonessentialAnimation(reduceMotion: true))
}

@Test func accessibilityModifiersAreStaticallyWiredIntoViews() throws {
    let filePane = try source(named: "Views/FilePaneView.swift")
    #expect(filePane.contains("AccessibilityIdentifiers.leftPane"))
    #expect(filePane.contains("AccessibilityIdentifiers.rightPane"))
    #expect(filePane.contains(".accessibilityLabel(PaneAccessibilityPresentation.label(for: paneID))"))
    #expect(filePane.contains(".accessibilityValue(PaneAccessibilityPresentation.value(isActive: isActive))"))
    #expect(filePane.occurrences(of: ".accessibilityHidden(true)") >= 3)

    let placesRail = try source(named: "Views/PlacesRailView.swift")
    #expect(placesRail.contains(".accessibilityIdentifier(AccessibilityIdentifiers.placesRail)"))
    #expect(placesRail.contains(".accessibilityIdentifier(AccessibilityIdentifiers.favoritesSection)"))
    #expect(placesRail.contains(".accessibilityHidden(true)"))

    let cloudSettings = try source(named: "Views/CloudLocationsSettingsView.swift")
    #expect(cloudSettings.contains(
        ".accessibilityIdentifier(AccessibilityIdentifiers.cloudSettings)"
    ))
    #expect(cloudSettings.contains("AccessibilityIdentifiers.cloudSettingsVisible"))
    #expect(cloudSettings.contains("AccessibilityIdentifiers.cloudSettingsHidden"))
    #expect(cloudSettings.contains(
        ".keyboardShortcut(\"r\", modifiers: .command)"
    ))
    #expect(cloudSettings.contains(".accessibilityLabel(action.accessibilityLabel)"))
    #expect(cloudSettings.contains(".help(action.help)"))

    let operationStatus = try source(named: "Views/OperationStatusView.swift")
    #expect(operationStatus.occurrences(
        of: ".accessibilityIdentifier(AccessibilityIdentifiers.operationStatus)"
    ) == 2)

    let conflictSheet = try source(named: "Views/ConflictResolutionSheet.swift")
    #expect(conflictSheet.contains(
        ".accessibilityIdentifier(AccessibilityIdentifiers.conflictSheet)"
    ))

    let workspace = try source(named: "Views/WorkspaceView.swift")
    #expect(workspace.contains("@Environment(\\.accessibilityReduceMotion) private var reduceMotion"))
    #expect(workspace.contains("AccessibilityMotionPresentation.allowsNonessentialAnimation("))
    #expect(workspace.contains("transaction.animation = nil"))

    let storageWorkspace = try source(
        named: "Views/StorageInspector/StorageInspectorView.swift"
    )
    #expect(storageWorkspace.contains(
        ".accessibilityIdentifier(AccessibilityIdentifiers.storageInspectorWorkspace)"
    ))
    #expect(storageWorkspace.contains(
        ".accessibilityIdentifier(AccessibilityIdentifiers.storageInspectorResults)"
    ))
    #expect(storageWorkspace.contains(
        "AccessibilityIdentifiers.storageInspectorProgress"
    ))
    #expect(storageWorkspace.contains(
        "AccessibilityIdentifiers.storageInspectorGroupNavigation"
    ))
    #expect(storageWorkspace.contains(
        "AccessibilityIdentifiers.storageInspectorCategory(group.category)"
    ))

    let storageToolbar = try source(
        named: "Views/StorageInspector/StorageInspectorToolbarView.swift"
    )
    #expect(storageToolbar.contains(
        ".accessibilityIdentifier(AccessibilityIdentifiers.storageInspectorToolbar)"
    ))
    #expect(storageToolbar.contains("AccessibilityIdentifiers.storageInspectorChooseLocation"))
    #expect(storageToolbar.contains("AccessibilityIdentifiers.storageInspectorStart"))
    #expect(storageToolbar.contains("AccessibilityIdentifiers.storageInspectorCancel"))
    #expect(storageToolbar.contains("AccessibilityIdentifiers.storageInspectorScanAgain"))
    #expect(storageToolbar.contains("AccessibilityIdentifiers.storageInspectorHiddenItems"))
    #expect(storageToolbar.contains("AccessibilityIdentifiers.storageInspectorExit"))

    let storageSidebar = try source(
        named: "Views/StorageInspector/StorageInspectorSidebarView.swift"
    )
    #expect(storageSidebar.contains(
        ".accessibilityIdentifier(AccessibilityIdentifiers.storageInspectorSidebar)"
    ))
    #expect(storageSidebar.contains(
        "AccessibilityIdentifiers.storageInspectorSection(section)"
    ))

    let storageResultsTable = try source(
        named: "Views/AppKit/StorageResultsTableView.swift"
    )
    #expect(storageResultsTable.contains(
        "StorageResultsAccessibilityPresentation.identifier(section: section)"
    ))
    #expect(storageResultsTable.contains(
        "StorageResultsAccessibilityPresentation.label(section: section)"
    ))
}

private func source(named relativePath: String) throws -> String {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let url = packageRoot
        .appending(path: "Sources/BloomFileManager", directoryHint: .isDirectory)
        .appending(path: relativePath)
    return try String(contentsOf: url, encoding: .utf8)
}

private extension String {
    func occurrences(of fragment: String) -> Int {
        components(separatedBy: fragment).count - 1
    }
}
