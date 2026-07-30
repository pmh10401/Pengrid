import Foundation
import SwiftUI
import Testing
@testable import BloomFileManager

@Test func selectedURLsMapStableIndexesOnly() {
    let urls = [URL(filePath: "/a"), URL(filePath: "/b")]

    #expect(FileTableSelection.urls(for: IndexSet([0, 4]), items: urls) == Set([urls[0]]))
}

@Test func splitRatioClampsToBalancedBounds() {
    #expect(WorkspaceSplitRatio.clamped(0.1) == 0.25)
    #expect(WorkspaceSplitRatio.clamped(0.5) == 0.5)
    #expect(WorkspaceSplitRatio.clamped(0.9) == 0.75)
}

@MainActor
@Test func splitRatioNormalizationUpdatesBindingAsynchronously() async {
    var ratio = 0.9
    let binding = Binding(get: { ratio }, set: { ratio = $0 })
    let coordinator = WorkspaceSplitView<Text, Text>.Coordinator(ratio: binding)

    let normalization = coordinator.normalizeBinding(from: ratio, to: WorkspaceSplitRatio.clamped(ratio))

    #expect(ratio == 0.9)
    await normalization?.value
    #expect(ratio == 0.75)
}

@Test func emptyPathDraftIsRejectedBeforeURLResolution() {
    #expect(FilePanePath.expandedPath(for: " \t\n") == nil)
}

@MainActor
@Test func focusingPresentedFilterActivatesInactivePaneBeforeEditingSession() {
    let workspace = WorkspaceState(
        leftURL: URL(filePath: "/left"),
        rightURL: URL(filePath: "/right"),
        listingService: StubDirectoryListingService(values: [:])
    )
    workspace.activate(.right)
    workspace.left.beginFiltering()
    var activePaneWhenEditingBegan: PaneID?

    PaneFilterFocusRouting.handle(
        isFocused: true,
        onActivate: { workspace.activate(.left) },
        onBeginEditing: { activePaneWhenEditingBegan = workspace.activePaneID },
        onEndEditing: {}
    )

    #expect(workspace.activePaneID == .left)
    #expect(activePaneWhenEditingBegan == .left)
    #expect(workspace.left.isFilterPresented)
}

@MainActor
@Test func escapeFromPathEditorDismissesFilterBeforeCancellingPathEditing() {
    let pane = FilePaneState(
        directory: URL(filePath: "/left"),
        listingService: StubDirectoryListingService(values: [:])
    )
    pane.beginFiltering()
    var pathCancellationCount = 0

    let dismissedFilter = PaneEscapeRouting.handle(
        isFilterPresented: pane.isFilterPresented,
        dismissFilter: pane.dismissFiltering,
        otherwise: { pathCancellationCount += 1 }
    )

    #expect(dismissedFilter)
    #expect(!pane.isFilterPresented)
    #expect(pathCancellationCount == 0)

    let dismissedFilterAgain = PaneEscapeRouting.handle(
        isFilterPresented: pane.isFilterPresented,
        dismissFilter: pane.dismissFiltering,
        otherwise: { pathCancellationCount += 1 }
    )

    #expect(!dismissedFilterAgain)
    #expect(pathCancellationCount == 1)
}

@MainActor
@Test func dismissingFilterDefersTableFocusUntilAfterFieldTeardown() async {
    let pane = FilePaneState(
        directory: URL(filePath: "/left"),
        listingService: StubDirectoryListingService(values: [:])
    )
    pane.beginFiltering()
    var events: [String] = []

    let focusTask = PaneFilterDismissalRouting.handle(
        clearFieldFocus: { events.append("clear") },
        endEditing: { events.append("end") },
        dismissFilter: {
            pane.dismissFiltering()
            events.append("dismiss")
        },
        requestTableFocus: {
            pane.requestTableFocus()
            events.append("focus")
        }
    )

    #expect(events == ["clear", "end", "dismiss"])
    #expect(pane.focusRequestID == nil)

    await focusTask.value

    #expect(events == ["clear", "end", "dismiss", "focus"])
    #expect(pane.focusRequestID != nil)
}
