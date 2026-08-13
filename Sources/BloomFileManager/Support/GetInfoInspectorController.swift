import AppKit
import SwiftUI

@MainActor
final class GetInfoInspectorController: NSObject, NSWindowDelegate {
    private let model: GetInfoInspectorModel
    private let inspectorPanel: GetInfoInspectorPanel

    var panel: NSPanel { inspectorPanel }

    init(model: GetInfoInspectorModel) {
        self.model = model
        inspectorPanel = GetInfoInspectorPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 580),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        super.init()

        inspectorPanel.title = "Get Info"
        inspectorPanel.contentMinSize = NSSize(width: 420, height: 460)
        inspectorPanel.isReleasedWhenClosed = false
        inspectorPanel.delegate = self
        inspectorPanel.setAccessibilityIdentifier(GetInfoAccessibilityIdentifiers.panel)
        inspectorPanel.contentView = NSHostingView(rootView: GetInfoInspectorView(model: model))
        inspectorPanel.onEscape = { [weak self] in
            self?.handleEscape()
        }
    }

    func present(items: [FileItem]) {
        model.inspect(items)
        inspectorPanel.makeKeyAndOrderFront(nil)
    }

    func close() {
        model.cancelAndClear()
        inspectorPanel.close()
    }

    func handleEscape() {
        model.cancelAndClear()
        inspectorPanel.close()
    }

    func windowWillClose(_ notification: Notification) {
        model.cancelAndClear()
    }
}

@MainActor
private final class GetInfoInspectorPanel: NSPanel {
    var onEscape: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}
