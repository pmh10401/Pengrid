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
        inspectorPanel.setAccessibilityElement(true)
        inspectorPanel.setAccessibilityIdentifier(GetInfoAccessibilityIdentifiers.panel)
        inspectorPanel.setAccessibilityLabel("Get Info inspector")
        inspectorPanel.setAccessibilityValue("Read-only file metadata")
        inspectorPanel.setAccessibilityHelp("Displays read-only metadata for the inspected selection.")
        let inspectorHostingView = NSHostingView(rootView: GetInfoInspectorView(model: model))
        inspectorHostingView.setAccessibilityElement(true)
        inspectorHostingView.setAccessibilityIdentifier(GetInfoAccessibilityIdentifiers.inspectorHost)
        inspectorPanel.contentView = GetInfoInspectorContainerView(hosting: inspectorHostingView, model: model)
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
private final class GetInfoInspectorContainerView: NSView {
    private let model: GetInfoInspectorModel

    init(hosting: NSView, model: GetInfoInspectorModel) {
        self.model = model
        super.init(frame: .zero)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosting.topAnchor.constraint(equalTo: topAnchor),
            hosting.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        setAccessibilityElement(true)
        setAccessibilityIdentifier(GetInfoAccessibilityIdentifiers.inspector)
        setAccessibilityLabel("Get Info inspector")
        setAccessibilityHelp("Displays read-only metadata for the inspected selection.")
    }

    override func accessibilityValue() -> Any? {
        switch model.phase {
        case .idle: "No selection inspected"
        case .loading: "Inspecting selection"
        case .failed: "Information unavailable"
        case .loaded: model.report.map { GetInfoInspectorPresentation.details(for: $0).summary } ?? "Loaded"
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

@MainActor
private final class GetInfoInspectorPanel: NSPanel {
    var onEscape: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}
