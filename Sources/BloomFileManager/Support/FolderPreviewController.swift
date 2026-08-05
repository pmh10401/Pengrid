import AppKit
import SwiftUI

/// Owns the reusable AppKit shell for the read-only folder preview. Folder
/// contents and loading state remain in `FolderPreviewModel` so this boundary
/// only presents and dismisses the panel.
@MainActor
final class FolderPreviewController: NSObject, FolderPreviewPresenting, NSWindowDelegate {
    private let model: FolderPreviewModel
    private let onClose: @MainActor () -> Void
    private let previewPanel: FolderPreviewPanel
    private var isProgrammaticClose = false
    private var isNotifyingClose = false

    var panel: NSPanel { previewPanel }

    init(model: FolderPreviewModel, onClose: @escaping @MainActor () -> Void) {
        self.model = model
        self.onClose = onClose
        previewPanel = FolderPreviewPanel(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        super.init()

        previewPanel.title = "Folder Contents"
        previewPanel.contentMinSize = NSSize(width: 640, height: 420)
        previewPanel.isReleasedWhenClosed = false
        previewPanel.becomesKeyOnlyIfNeeded = false
        previewPanel.delegate = self
        previewPanel.setAccessibilityIdentifier(AccessibilityIdentifiers.folderPreviewPanel)
        previewPanel.contentView = NSHostingView(rootView: FolderPreviewView(model: model))
        previewPanel.onEscape = { [weak self] in
            self?.handleEscape()
        }
    }

    func present(request: FolderPreviewRequest) {
        model.load(request)
        previewPanel.makeKeyAndOrderFront(nil)
    }

    func close() {
        guard previewPanel.isVisible, !isNotifyingClose else { return }

        isProgrammaticClose = true
        previewPanel.close()
        isProgrammaticClose = false
    }

    func handleEscape() {
        notifyCoordinatorOfClose()
    }

    func windowWillClose(_ notification: Notification) {
        guard !isProgrammaticClose else { return }
        notifyCoordinatorOfClose()
    }

    private func notifyCoordinatorOfClose() {
        guard !isNotifyingClose else { return }
        isNotifyingClose = true
        onClose()
        isNotifyingClose = false
    }
}

@MainActor
private final class FolderPreviewPanel: NSPanel {
    var onEscape: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}
