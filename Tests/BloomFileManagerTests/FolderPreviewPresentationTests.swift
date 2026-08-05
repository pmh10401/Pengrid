import AppKit
import Foundation
import Testing
@testable import BloomFileManager

@Suite("FolderPreviewPresentationTests")
@MainActor
struct FolderPreviewPresentationTests {
    @Test func escapeClosesVisiblePanelThroughCoordinatorExactlyOnce() {
        let close = CloseRecorder()
        let model = FolderPreviewModel(listing: EmptyFolderPreviewListing())
        let callback = CloseThenRunRecorder(close: close)
        let controller = FolderPreviewController(model: model, onClose: callback.recordAndRun)
        callback.afterRecording = controller.close
        let panel = controller.panel

        controller.present(request: previewRequest(named: "Escape"))
        controller.handleEscape()

        #expect(close.count == 1)
        #expect(!panel.isVisible)
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

    @Test func programmaticCloseCancelsActiveFolderLoadAndClearsModel() async {
        let close = CloseRecorder()
        let listing = CancellationObservingPresentationListing()
        let model = FolderPreviewModel(listing: listing)
        let controller = FolderPreviewController(model: model, onClose: close.record)
        defer {
            model.cancel()
            controller.close()
        }

        controller.present(request: previewRequest(named: "Programmatic"))
        #expect(await waitForPresentationCondition("listing to start") {
            await listing.hasStarted(count: 1)
        })

        controller.close()

        #expect(await waitForPresentationCondition("programmatic dismissal cancellation") {
            await listing.hasCancelled(count: 1)
        })
        #expect(model.phase == .idle)
        #expect(model.request == nil)
        #expect(model.entries.isEmpty)
        #expect(close.count == 0)
    }

    @Test func userCloseCancelsActiveFolderLoadAndClearsModel() async {
        let close = CloseRecorder()
        let listing = CancellationObservingPresentationListing()
        let model = FolderPreviewModel(listing: listing)
        let controller = FolderPreviewController(model: model, onClose: close.record)
        let panel = controller.panel
        defer {
            model.cancel()
            controller.close()
        }

        controller.present(request: previewRequest(named: "User"))
        #expect(await waitForPresentationCondition("listing to start") {
            await listing.hasStarted(count: 1)
        })

        panel.close()

        #expect(await waitForPresentationCondition("user dismissal cancellation") {
            await listing.hasCancelled(count: 1)
        })
        #expect(model.phase == .idle)
        #expect(model.request == nil)
        #expect(model.entries.isEmpty)
        #expect(close.count == 1)
        #expect(!panel.isVisible)
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

private actor CancellationObservingPresentationListing: FolderPreviewListing {
    private var startedCount = 0
    private var cancelledCount = 0
    private var continuations: [UUID: CheckedContinuation<FolderPreviewSnapshot, any Error>] = [:]

    func snapshot(
        _ request: FolderPreviewRequest,
        progress: @escaping @Sendable (Int) -> Void
    ) async throws -> FolderPreviewSnapshot {
        let requestID = UUID()
        startedCount += 1
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                continuations[requestID] = continuation
            }
        } onCancel: {
            Task { await self.cancel(requestID) }
        }
    }

    func hasStarted(count: Int) -> Bool {
        startedCount >= count
    }

    func hasCancelled(count: Int) -> Bool {
        cancelledCount >= count
    }

    private func cancel(_ requestID: UUID) {
        cancelledCount += 1
        continuations.removeValue(forKey: requestID)?.resume(throwing: CancellationError())
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

private func waitForPresentationCondition(
    _ description: String,
    timeout: Duration = .seconds(1),
    _ condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !(await condition()) {
        guard clock.now < deadline else {
            Issue.record("Timed out waiting for \(description).")
            return false
        }
        await Task.yield()
    }
    return true
}
