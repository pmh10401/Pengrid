import AppKit
import Foundation
import Testing
@testable import BloomFileManager

@Suite("FolderPreviewPresentationTests")
@MainActor
struct FolderPreviewPresentationTests {
    @Test func escapeClosesPanelThroughCoordinator() {
        let close = CloseRecorder()
        let model = FolderPreviewModel(listing: EmptyFolderPreviewListing())
        let controller = FolderPreviewController(model: model, onClose: close.record)

        controller.handleEscape()

        #expect(close.count == 1)
    }

    @Test func userCloseNotifiesCoordinatorOnceWhenItClosesThePanel() {
        let close = CloseRecorder()
        let model = FolderPreviewModel(listing: EmptyFolderPreviewListing())
        let callback = CloseThenRunRecorder(close: close)
        let controller = FolderPreviewController(model: model, onClose: callback.recordAndRun)
        callback.afterRecording = controller.close
        let panel = controller.panel

        controller.present(request: previewRequest(named: "Projects"))
        panel.close()

        #expect(close.count == 1)
        #expect(!panel.isVisible)
    }

    @Test func panelIsReusedAndProgrammaticCloseDoesNotNotifyCoordinator() {
        let close = CloseRecorder()
        let model = FolderPreviewModel(listing: EmptyFolderPreviewListing())
        let controller = FolderPreviewController(model: model, onClose: close.record)
        let panel = controller.panel

        controller.present(request: previewRequest(named: "First"))
        controller.close()
        controller.present(request: previewRequest(named: "Second"))

        #expect(controller.panel === panel)
        #expect(panel.contentMinSize == NSSize(width: 640, height: 420))
        #expect(close.count == 0)
        controller.close()
    }

    @Test func folderPreviewHasRequiredAccessibleColumnsAndReadOnlySurface() throws {
        let implementation = try source(named: "Views/FolderPreviewView.swift")
        #expect(implementation.contains("AccessibilityIdentifiers.folderPreviewTable"))
        #expect(implementation.contains("Name"))
        #expect(implementation.contains("Kind"))
        #expect(implementation.contains("Size"))
        #expect(implementation.contains("Modified"))
        #expect(!implementation.contains("onOpen"))
        #expect(!implementation.contains("onTrash"))
        #expect(!implementation.contains("contextMenu"))
        #expect(!implementation.contains("onDrop"))
    }

    @Test func parentPresentationDoesNotExposeFullPath() {
        let url = URL(fileURLWithPath: "/Users/example/Private/Projects")
        let label = FolderPreviewPresentation.parentLabel(for: url)

        #expect(label == "In Private")
        #expect(!label.contains("/Users/example/Private"))
    }
}

private struct EmptyFolderPreviewListing: FolderPreviewListing {
    func snapshot(
        _ request: FolderPreviewRequest,
        progress: @escaping @Sendable (Int) -> Void
    ) async throws -> FolderPreviewSnapshot {
        FolderPreviewSnapshot(request: request, entries: [])
    }
}

@MainActor
private final class CloseRecorder {
    private(set) var count = 0

    func record() {
        count += 1
    }
}

@MainActor
private final class CloseThenRunRecorder {
    private let close: CloseRecorder
    var afterRecording: (@MainActor () -> Void)?

    init(close: CloseRecorder) {
        self.close = close
    }

    func recordAndRun() {
        close.record()
        afterRecording?()
    }
}

private func previewRequest(named name: String) -> FolderPreviewRequest {
    FolderPreviewRequest(
        paneID: .left,
        url: URL(fileURLWithPath: "/tmp/PreviewTests/\(name)"),
        identity: FileIdentity(entryIdentifier: name, resolvedIdentifier: name),
        kind: .ordinaryDirectory
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
