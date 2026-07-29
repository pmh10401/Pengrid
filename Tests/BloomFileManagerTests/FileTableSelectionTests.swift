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
