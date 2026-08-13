import Foundation
import Testing
@testable import BloomFileManager

@Test func accessibilityIdentifiersRemainStable() {
    #expect(AccessibilityIdentifiers.placesRail == "placesRail")
    #expect(AccessibilityIdentifiers.favoritesSection == "favoritesSection")
    #expect(AccessibilityIdentifiers.leftPane == "leftPane")
    #expect(AccessibilityIdentifiers.rightPane == "rightPane")
    #expect(AccessibilityIdentifiers.operationStatus == "operationStatus")
    #expect(
        AccessibilityIdentifiers.workspaceCompressProtectedZIP
            == "workspace.compressProtectedZIP"
    )
    #expect(
        AccessibilityIdentifiers.fileTableCompressProtectedZIP
            == "fileTable.compressProtectedZIP"
    )
    #expect(AccessibilityIdentifiers.operationCenter == "operationCenter")
    #expect(AccessibilityIdentifiers.operationCenterActive == "operationCenter.active")
    #expect(AccessibilityIdentifiers.operationCenterQueue == "operationCenter.queue")
    #expect(
        AccessibilityIdentifiers.operationCenterMoveQueuedUp
            == "operationCenter.moveQueuedUp"
    )
    #expect(
        AccessibilityIdentifiers.operationCenterMoveQueuedDown
            == "operationCenter.moveQueuedDown"
    )
    #expect(AccessibilityIdentifiers.operationCenterDetails == "operationCenter.details")
    #expect(AccessibilityIdentifiers.operationCenterHistory == "operationCenter.history")
    #expect(AccessibilityIdentifiers.operationCenterRecovery == "operationCenter.recovery")
    #expect(
        AccessibilityIdentifiers.operationCenterContinueAfterRecovery
            == "operationCenter.continueAfterRecovery"
    )
    #expect(AccessibilityIdentifiers.conflictSheet == "conflictSheet")
    #expect(AccessibilityIdentifiers.smartSearchSheet == "smartSearch.sheet")
    #expect(AccessibilityIdentifiers.smartSearchQuery == "smartSearch.query")
    #expect(AccessibilityIdentifiers.smartSearchResults == "smartSearch.results")
    #expect(AccessibilityIdentifiers.archivePasswordSheet == "archivePasswordSheet")
    #expect(AccessibilityIdentifiers.archivePasswordField == "archivePassword.field")
    #expect(AccessibilityIdentifiers.archivePasswordCancel == "archivePassword.cancel")
    #expect(AccessibilityIdentifiers.workspaceQuickLook == "workspace.quickLook")
    #expect(AccessibilityIdentifiers.workspaceCopyFullPath == "workspace.copyFullPath")
    #expect(AccessibilityIdentifiers.workspaceDuplicate == "workspace.duplicate")
    #expect(AccessibilityIdentifiers.workspaceContextActionStatus == "workspace.contextActionStatus")
    #expect(GetInfoAccessibilityIdentifiers.command == "workspace.getInfo")
    #expect(GetInfoAccessibilityIdentifiers.contextMenu == "fileTable.getInfo")
    #expect(SpotlightSearchAccessibilityIdentifiers.indexedContents == "smartSearch.indexedContents")
    #expect(SpotlightSearchAccessibilityIdentifiers.coverage == "smartSearch.coverage")
}

@Test func workspaceSessionAccessibilityIdentifiersAreStableAndDoNotUsePaths() {
    let tabID = WorkspaceTabID(rawValue: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)
    let profileID = WorkspaceProfileID(rawValue: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!)

    #expect(WorkspaceSessionAccessibilityIdentifiers.tabBar == "workspaceTabs.bar")
    #expect(WorkspaceSessionAccessibilityIdentifiers.newTab == "workspaceTabs.new")
    #expect(WorkspaceSessionAccessibilityIdentifiers.profiles == "workspaceTabs.profiles")
    #expect(WorkspaceSessionAccessibilityIdentifiers.profilesSheet == "workspaceProfiles.sheet")
    #expect(WorkspaceSessionAccessibilityIdentifiers.tab(tabID) == "workspaceTabs.tab.11111111-1111-1111-1111-111111111111")
    #expect(WorkspaceSessionAccessibilityIdentifiers.closeTab(tabID) == "workspaceTabs.close.11111111-1111-1111-1111-111111111111")
    #expect(WorkspaceSessionAccessibilityIdentifiers.profile(profileID) == "workspaceProfiles.profile.22222222-2222-2222-2222-222222222222")
    #expect(WorkspaceSessionAccessibilityIdentifiers.renameProfile(profileID) == "workspaceProfiles.rename.22222222-2222-2222-2222-222222222222")
    #expect(WorkspaceSessionAccessibilityIdentifiers.openProfile(profileID) == "workspaceProfiles.open.22222222-2222-2222-2222-222222222222")
    #expect(WorkspaceSessionAccessibilityIdentifiers.deleteProfile(profileID) == "workspaceProfiles.delete.22222222-2222-2222-2222-222222222222")
    #expect(WorkspaceSessionAccessibilityIdentifiers.done == "workspaceProfiles.done")
}

@Test func contextActionAppWiringUsesSharedDependenciesAndAccessibleState() throws {
    let app = try source(named: "App/BloomFileManagerApp.swift")
    #expect(app.occurrences(of: "FileContextActionRouter(") == 1)
    #expect(app.occurrences(of: "OpenWithApplicationProvider()") == 1)
    #expect(app.occurrences(of: "SelectionFolderModel(") == 1)
    #expect(app.contains("fileSystem: cloudDependencies.fileSystem"))
    #expect(app.contains("accessCoordinator: cloudDependencies.accessCoordinator"))

    let workspace = try source(named: "Views/WorkspaceView.swift")
    #expect(workspace.contains("let contextActionRouter: FileContextActionRouter"))
    #expect(workspace.contains("let openWithProvider: any OpenWithApplicationProviding"))
    #expect(workspace.contains("let selectionFolder: SelectionFolderModel"))
    #expect(workspace.contains("AccessibilityIdentifiers.workspaceContextActionStatus"))

    let pane = try source(named: "Views/FilePaneView.swift")
    #expect(pane.contains("let contextActionRouter: FileContextActionRouter"))
    #expect(pane.contains("let openWithProvider: any OpenWithApplicationProviding"))
    #expect(pane.contains("let selectionFolder: SelectionFolderModel"))
    #expect(!pane.contains("@State private var openWithProvider"))
    #expect(!pane.contains("let router = FileContextActionRouter("))
}

@Test @MainActor
func passwordSheetIdentityWinsOverDeferredConflictAndSearchWithoutCancellingCoordinator() async throws {
    let request = makePasswordRequest(
        id: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
    )
    let coordinator = ArchivePasswordPromptCoordinator()
    let task = Task { try await coordinator.requestPassword(for: request) }
    await Task.yield()

    var state = WorkspaceModalPresentationState()
    state.passwordSheetDidAppear(requestID: request.id)

    #expect(state.passwordRequestToPresent(
        pending: request,
        conflictPresented: true,
        searchPresented: true
    ) == request)
    #expect(!state.allowsOtherModalPresentation)
    #expect(coordinator.pendingRequest == request)

    coordinator.cancel(requestID: request.id)
    await #expect(throws: CancellationError.self) { try await task.value }
}

@Test @MainActor
func explicitPasswordDismissalReleasesGateForDeferredModal() async throws {
    let request = makePasswordRequest(
        id: UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
    )
    let coordinator = ArchivePasswordPromptCoordinator()
    let task = Task { try await coordinator.requestPassword(for: request) }
    await Task.yield()

    var state = WorkspaceModalPresentationState()
    state.passwordSheetDidAppear(requestID: request.id)
    #expect(!state.allowsOtherModalPresentation)

    let dismissedID = state.passwordSheetDidDisappear(requestID: request.id)
    #expect(dismissedID == request.id)
    #expect(state.allowsOtherModalPresentation)
    #expect(state.passwordRequestToPresent(
        pending: nil,
        conflictPresented: true,
        searchPresented: false
    ) == nil)

    coordinator.cancel(requestID: request.id)
    await #expect(throws: CancellationError.self) { try await task.value }
}

@Test
func otherModalPresentFirstDefersPasswordRequestWithoutChangingItsIdentity() {
    let request = makePasswordRequest(
        id: UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!
    )
    let state = WorkspaceModalPresentationState()

    #expect(state.passwordRequestToPresent(
        pending: request,
        conflictPresented: true,
        searchPresented: false
    ) == nil)
    #expect(state.passwordRequestToPresent(
        pending: request,
        conflictPresented: false,
        searchPresented: true
    ) == nil)
    #expect(state.passwordRequestToPresent(
        pending: request,
        conflictPresented: false,
        searchPresented: false
    ) == request)
}

@Test @MainActor
func stalePasswordDismissalCannotCancelNewCoordinatorRequest() async throws {
    let requestA = makePasswordRequest(
        id: UUID(uuidString: "dddddddd-dddd-dddd-dddd-dddddddddddd")!
    )
    let requestB = makePasswordRequest(
        id: UUID(uuidString: "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee")!
    )
    let coordinator = ArchivePasswordPromptCoordinator()
    let taskA = Task { try await coordinator.requestPassword(for: requestA) }
    await Task.yield()

    var state = WorkspaceModalPresentationState()
    state.passwordSheetDidAppear(requestID: requestA.id)
    let dismissedA = state.passwordSheetDidDisappear(requestID: requestA.id)
    #expect(dismissedA == requestA.id)
    coordinator.cancel(requestID: requestA.id)
    await #expect(throws: CancellationError.self) { try await taskA.value }

    let taskB = Task { try await coordinator.requestPassword(for: requestB) }
    await Task.yield()
    state.passwordSheetDidAppear(requestID: requestB.id)

    #expect(state.passwordSheetDidDisappear(requestID: requestA.id) == nil)
    coordinator.cancel(requestID: requestA.id)
    #expect(coordinator.pendingRequest == requestB)

    coordinator.cancel(requestID: requestB.id)
    await #expect(throws: CancellationError.self) { try await taskB.value }
}

@Test func appWiresOneCoordinatorIdentityAcrossServiceControllerStateAndWorkspace() throws {
    let app = try source(named: "App/BloomFileManagerApp.swift")
    #expect(app.occurrences(of: "ArchivePasswordPromptCoordinator()") == 1)
    #expect(app.contains("_passwordCoordinator = State(initialValue: passwordCoordinator)"))
    #expect(app.contains("passwordProvider: passwordCoordinator"))
    #expect(app.contains("passwordCoordinator: passwordCoordinator"))
}

@Test func appComposesOneInspectorAndContentAwareSearchService() throws {
    let app = try source(named: "App/BloomFileManagerApp.swift")
    #expect(app.occurrences(of: "LiveGetInfoInspectionService(") == 1)
    #expect(app.occurrences(of: "GetInfoInspectorModel(") == 1)
    #expect(app.occurrences(of: "GetInfoInspectorController(") == 1)
    #expect(app.occurrences(of: "ContentAwareSmartSearchService(") == 1)
    #expect(app.contains("LiveSpotlightSmartSearchService("))

    let workspace = try source(named: "Views/WorkspaceView.swift")
    #expect(workspace.contains("let getInfoInspector: GetInfoInspectorController"))
    let commands = try source(named: "Support/WorkspaceCommands.swift")
    #expect(commands.contains("Button(\"Get Info\")"))
    #expect(commands.contains(".keyboardShortcut(\"i\", modifiers: .command)"))
}

@Test func folderPreviewAccessibilityIdentifiersAndAnnouncementsRemainStable() throws {
    #expect(AccessibilityIdentifiers.folderPreviewPanel == "folderPreview.panel")
    #expect(AccessibilityIdentifiers.folderPreviewTitle == "folderPreview.title")
    #expect(AccessibilityIdentifiers.folderPreviewParent == "folderPreview.parent")
    #expect(AccessibilityIdentifiers.folderPreviewStatus == "folderPreview.status")
    #expect(AccessibilityIdentifiers.folderPreviewTable == "folderPreview.table")

    let implementation = try source(named: "Views/FolderPreviewView.swift")
    #expect(implementation.contains("AccessibilityIdentifiers.folderPreviewPanel"))
    #expect(implementation.contains("AccessibilityIdentifiers.folderPreviewStatus"))
    #expect(implementation.contains(".accessibilityLabel(\"Folder preview status\")"))
    #expect(implementation.contains(".accessibilityValue(model.statusText)"))
    #expect(implementation.contains("NSAccessibility.post("))
    #expect(implementation.contains("notification: .announcementRequested"))
    #expect(implementation.contains(".announcement: status"))
    #expect(!implementation.contains("url.path"))
}

@Test func smartSearchPresentationUsesSafeColumnsAndActionAccessibility() throws {
    let implementation = try source(named: "Views/SmartSearchView.swift")
    #expect(implementation.contains("AccessibilityIdentifiers.smartSearchResults"))
    #expect(implementation.contains("Name"))
    #expect(implementation.contains("Location"))
    #expect(implementation.contains("AccessibilityIdentifiers.smartSearchCopy"))
    #expect(implementation.contains("AccessibilityIdentifiers.smartSearchMove"))
    #expect(implementation.contains("AccessibilityIdentifiers.smartSearchTrash"))
    #expect(!implementation.contains("accessibilityValue(result.item.url.path)"))
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

@Test func paneFilterAccessibilityIsStableAndReportsResults() {
    #expect(AccessibilityIdentifiers.leftPaneFilter == "leftPane.filter")
    #expect(AccessibilityIdentifiers.rightPaneFilter == "rightPane.filter")
    #expect(AccessibilityIdentifiers.leftPaneFilterResults == "leftPane.filterResults")
    #expect(AccessibilityIdentifiers.rightPaneFilterResults == "rightPane.filterResults")
    #expect(PaneFilterAccessibilityPresentation.fieldLabel(for: .left) == "Filter files in left pane")
    #expect(PaneFilterAccessibilityPresentation.fieldLabel(for: .right) == "Filter files in right pane")
    #expect(PaneFilterAccessibilityPresentation.resultCountLabel(for: .left) == "Matching files in left pane")
    #expect(PaneFilterAccessibilityPresentation.resultCountLabel(for: .right) == "Matching files in right pane")
    #expect(PaneFilterAccessibilityPresentation.closeLabel(for: .left) == "Close left pane file filter")
    #expect(PaneFilterAccessibilityPresentation.closeLabel(for: .right) == "Close right pane file filter")
    #expect(PaneFilterAccessibilityPresentation.resultCount(0) == "No matching items")
    #expect(PaneFilterAccessibilityPresentation.resultCount(1) == "1 matching item")
    #expect(PaneFilterAccessibilityPresentation.resultCount(12) == "12 matching items")
}

@Test func paneFilterPreservesAccessibilityPresentationAndUsesThePaneFilterBinding() throws {
    let implementation = try source(named: "Views/FilePaneView.swift")

    #expect(implementation.contains("AccessibilityIdentifiers.leftPaneFilter"))
    #expect(implementation.contains("AccessibilityIdentifiers.rightPaneFilter"))
    #expect(implementation.contains("AccessibilityIdentifiers.leftPaneFilterResults"))
    #expect(implementation.contains("AccessibilityIdentifiers.rightPaneFilterResults"))
    #expect(implementation.contains("PaneFilterAccessibilityPresentation.fieldLabel(for: paneID)"))
    #expect(implementation.contains("PaneFilterAccessibilityPresentation.resultCountLabel(for: paneID)"))
    #expect(implementation.contains("PaneFilterAccessibilityPresentation.closeLabel(for: paneID)"))
    #expect(implementation.contains("set: { state.updateFilterQuery($0) }"))
}

@Test func reduceMotionDisablesOnlyNonessentialAnimation() {
    #expect(AccessibilityMotionPresentation.allowsNonessentialAnimation(reduceMotion: false))
    #expect(!AccessibilityMotionPresentation.allowsNonessentialAnimation(reduceMotion: true))
}

@Test func archiveProgressAccessibilityDescribesPhasesWithoutLeakingParentPaths() {
    let displayName = "Report.txt"
    let privateParentPath = "/Users/example/Confidential"
    let preparation = ArchiveOperationStatusPresentation(progress: ArchiveOperationProgress(
        kind: .compress,
        currentDisplayName: displayName,
        format: .tarGzip,
        phase: .preparingSources(completedCount: 2, totalCount: 5)
    ))
    let encoding = ArchiveOperationStatusPresentation(progress: ArchiveOperationProgress(
        kind: .compress,
        currentDisplayName: displayName,
        format: .tarGzip,
        phase: .encoding
    ))
    let publishing = ArchiveOperationStatusPresentation(progress: ArchiveOperationProgress(
        kind: .compress,
        currentDisplayName: displayName,
        format: .tarGzip,
        phase: .publishing
    ))

    #expect(preparation.progressLabel == "Preparing files, 2 of 5")
    #expect(preparation.statusAccessibilityLabel.contains("Preparing files, 2 of 5"))
    #expect(encoding.progressLabel == "Encoding archive")
    #expect(!encoding.statusAccessibilityLabel.contains("%"))
    #expect(publishing.progressLabel == "Finishing archive")
    #expect(!preparation.statusAccessibilityLabel.contains(privateParentPath))
    #expect(!encoding.statusAccessibilityLabel.contains(privateParentPath))
    #expect(!publishing.statusAccessibilityLabel.contains(privateParentPath))
}

@Test func accessibilityModifiersAreStaticallyWiredIntoViews() throws {
    let filePane = try source(named: "Views/FilePaneView.swift")
    #expect(filePane.contains("AccessibilityIdentifiers.leftPane"))
    #expect(filePane.contains("AccessibilityIdentifiers.rightPane"))
    #expect(filePane.contains(".accessibilityLabel(PaneAccessibilityPresentation.label(for: paneID))"))
    #expect(filePane.contains(".accessibilityValue(PaneAccessibilityPresentation.value(isActive: isActive))"))
    #expect(filePane.contains("PaneFilterAccessibilityPresentation.resultCountLabel(for: paneID)"))
    #expect(filePane.contains("AccessibilityIdentifiers.leftPaneFilterResults"))
    #expect(filePane.contains("AccessibilityIdentifiers.rightPaneFilterResults"))
    #expect(!filePane.contains(
        ".accessibilityValue(\n                        PaneFilterAccessibilityPresentation.resultCount"
    ))
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

    let operationCenter = try source(named: "Views/FileOperationCenterView.swift")
    #expect(operationCenter.contains("AccessibilityIdentifiers.operationCenter"))
    #expect(operationCenter.contains("AccessibilityIdentifiers.operationCenterActive"))
    #expect(operationCenter.contains("AccessibilityIdentifiers.operationCenterQueue"))
    #expect(operationCenter.contains("AccessibilityIdentifiers.operationCenterMoveQueuedUp"))
    #expect(operationCenter.contains("AccessibilityIdentifiers.operationCenterMoveQueuedDown"))
    #expect(operationCenter.contains("AccessibilityIdentifiers.operationCenterDetails"))
    #expect(operationCenter.contains("AccessibilityIdentifiers.operationCenterHistory"))
    #expect(operationCenter.contains("controller.pauseActiveJob()"))
    #expect(operationCenter.contains("controller.resumeActiveJob()"))
    #expect(operationCenter.contains("controller.cancelActiveJob()"))
    #expect(operationCenter.contains("controller.cancelQueuedJob(job.id)"))
    #expect(operationCenter.contains("controller.retryJob(job.id)"))
    #expect(operationCenter.contains("controller.undoJob(job.id)"))
    #expect(operationCenter.contains("AccessibilityIdentifiers.operationCenterRecovery"))
    #expect(operationCenter.contains(
        "AccessibilityIdentifiers.operationCenterContinueAfterRecovery"
    ))
    #expect(operationCenter.contains("controller.continueAfterRecovery()"))
    #expect(operationCenter.contains("FileOperationCenterActiveActionPresentation(job: job)"))
    #expect(operationCenter.contains("actions.showsPause"))
    #expect(operationCenter.contains("actions.showsCancel"))

    let conflictSheet = try source(named: "Views/ConflictResolutionSheet.swift")
    #expect(conflictSheet.contains(
        ".accessibilityIdentifier(AccessibilityIdentifiers.conflictSheet)"
    ))

    let workspace = try source(named: "Views/WorkspaceView.swift")
    #expect(workspace.contains("@Environment(\\.accessibilityReduceMotion) private var reduceMotion"))
    #expect(workspace.contains("AccessibilityMotionPresentation.allowsNonessentialAnimation("))
    #expect(workspace.contains("transaction.animation = nil"))
    #expect(workspace.contains("FileOperationCenterView(controller: operationController)"))
    #expect(workspace.contains(".sheet(item: pendingPasswordRequest)"))
    #expect(workspace.contains("ArchivePasswordSheet("))
    #expect(workspace.contains("request: request"))
    #expect(workspace.contains("coordinator: passwordCoordinator"))
    #expect(workspace.contains("passwordSheetDidDisappear"))
    #expect(workspace.contains("passwordCoordinator.cancel(requestID: requestID)"))
    #expect(workspace.contains("WorkspaceModalPresentationState"))
    #expect(workspace.contains("passwordSheetDidAppear"))
    #expect(workspace.contains("passwordSheetDidDisappear"))
    #expect(workspace.contains("allowsOtherModalPresentation"))

    let app = try source(named: "App/BloomFileManagerApp.swift")
    #expect(app.contains(
        "@State private var passwordCoordinator: ArchivePasswordPromptCoordinator"
    ))
    #expect(app.contains("let passwordCoordinator = ArchivePasswordPromptCoordinator()"))
    #expect(app.contains("makeRoutingArchiveOperationService("))
    #expect(app.contains("passwordProvider: passwordCoordinator"))
    #expect(app.contains("passwordCoordinator: passwordCoordinator"))

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

private func makePasswordRequest(id: UUID) -> ArchivePasswordRequest {
    ArchivePasswordRequest(
        id: id,
        purpose: .createAES256,
        archiveBasename: "자료.zip",
        previousAttemptFailed: false
    )
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
