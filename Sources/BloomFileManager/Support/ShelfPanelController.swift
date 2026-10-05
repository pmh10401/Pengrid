import AppKit
import SwiftUI
import Observation

enum ShelfPanelPlacement {
    static func frame(visibleFrame: CGRect, screenFrame: CGRect, safeTop: CGFloat, expanded: Bool) -> CGRect {
        let top = max(visibleFrame.minY, min(visibleFrame.maxY, screenFrame.maxY - safeTop))
        let width = min(expanded ? 560 : 240, visibleFrame.width)
        let height = min(expanded ? 440 : 82, top - visibleFrame.minY)
        return CGRect(x: visibleFrame.midX - width / 2, y: top - height, width: width, height: height)
    }
}

@MainActor
final class ShelfPanel: NSPanel {
    var onCloseShelf: (() -> Void)?
    var onCopyShelf: (() -> Void)?
    var onImportShelf: (() -> Void)?
    var onRemoveShelf: (() -> Void)?
    var interactionAllowed: () -> Bool = { true }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func handleKey(_ event: NSEvent) -> Bool {
        guard interactionAllowed() else { return true }
        let command = event.modifierFlags.contains(.command)
        let characters = event.charactersIgnoringModifiers?.lowercased() ?? ""
        // Korean input sources can report Hangul for Command-W/C/V. Preserve
        // the usual physical shortcuts when no Latin command character is supplied.
        let physicalCommand: [UInt16: String] = [13: "w", 9: "v", 8: "c", 7: "x", 0: "a", 6: "z", 12: "q", 4: "h", 43: ","]
        let isLatinCommand = characters.count == 1 && "abcdefghijklmnopqrstuvwxyz,".contains(characters)
        let text = command && !isLatinCommand ? physicalCommand[event.keyCode] ?? characters : characters
        if event.keyCode == 53 || (command && text == "w") { onCloseShelf?(); return true }
        let editor = firstResponder as? NSTextView
        if let editor, editor.isEditable {
            if command {
                switch text {
                case "v": editor.paste(nil); return true
                case "c": editor.copy(nil); return true
                case "x": editor.cut(nil); return true
                case "a": editor.selectAll(nil); return true
                case "z":
                    if event.modifierFlags.contains(.shift) { editor.undoManager?.redo() }
                    else { editor.undoManager?.undo() }
                    return true
                default: break
                }
            }
            if event.keyCode == 51 || event.keyCode == 117 {
                editor.deleteBackward(nil)
                return true
            }
        } else {
            if event.keyCode == 51 || event.keyCode == 117 { onRemoveShelf?(); return true }
            if command && text == "v" { onImportShelf?(); return true }
            if command && text == "c" { onCopyShelf?(); return true }
        }
        // File/workspace accelerators must not fall through to a stale focused scene.
        return command && !["q", "h", ","].contains(text)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        handleKey(event) || super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if !handleKey(event) { super.keyDown(with: event) }
    }

    static func allowsWorkspaceCommands(keyWindow: NSWindow?) -> Bool { !(keyWindow is ShelfPanel) }
}

@MainActor @Observable
final class ShelfPanelController {
    let store: ShelfStore
    let panel: ShelfPanel
    let operationController: FileOperationController?
    var openMain: () -> Void
    private(set) var isExpanded = false
    @ObservationIgnored private var screenObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var keyMonitor: Any?
    init(store: ShelfStore, operationController: FileOperationController? = nil, openMain: @escaping () -> Void = {}) {
        self.store = store
        self.operationController = operationController
        self.openMain = openMain
        panel = ShelfPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.worksWhenModal = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.title = "Pengrid Top Shelf"
        panel.identifier = NSUserInterfaceItemIdentifier("pengrid.topShelf")
        panel.onCloseShelf = { [weak self] in self?.hide() }
        panel.onImportShelf = { [weak self] in self?.importClipboard() }
        panel.onCopyShelf = { [weak self] in self?.copySelection() }
        panel.onRemoveShelf = { [weak self] in self?.removeSelection() }
        panel.interactionAllowed = { [weak self] in self?.interactionAllowed == true }
        let host = ShelfHostingView(rootView: ShelfView(controller: self))
        host.controller = self
        host.registerForDraggedTypes([.fileURL, .string, .png, .tiff])
        panel.contentView = host
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reposition() }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self, NSApp.keyWindow === self.panel else { return false }
                return self.panel.handleKey(event)
            }
            return consumed ? nil : event
        }
    }

    func show(expanded: Bool = true) {
        guard store.isEnabled, interactionAllowed else { return }
        isExpanded = expanded
        reposition()
        panel.orderFront(nil)
        if expanded { panel.makeKey() }
    }

    func hide() { panel.orderOut(nil) }

    func setEnabled(_ value: Bool) {
        guard interactionAllowed else { return }
        store.setEnabled(value)
        if value { show(expanded: false) } else { hide() }
    }

    func canInteract(modalWindow: NSWindow?, windows: [NSWindow]) -> Bool {
        modalWindow == nil && !windows.contains { $0.attachedSheet != nil }
    }

    var interactionAllowed: Bool { canInteract(modalWindow: NSApp.modalWindow, windows: NSApp.windows) }

    func importClipboard() {
        guard interactionAllowed else { return }
        importContents(from: .general)
    }

    @discardableResult
    func importContents(from board: NSPasteboard) -> Bool {
        guard interactionAllowed, let token = store.beginImport() else { return false }
        let count = board.changeCount
        Task {
            do {
                let items = try await ShelfClipboard.read(from: board, expectedChangeCount: count)
                await store.completeImport(items, token: token)
            } catch { store.failImport(error, token: token) }
        }
        return true
    }

    func copySelection() {
        guard interactionAllowed, let item = store.entries.first(where: { $0.id == store.selectedID }) else { return }
        do { try ShelfClipboard.write(item, to: .general); store.errorMessage = nil }
        catch { store.errorMessage = "Could not copy this item. A referenced file may no longer be available." }
    }

    func removeSelection() {
        guard interactionAllowed, let id = store.selectedID else { return }
        store.remove(id)
    }

    private func reposition() {
        let mainScreen = NSApp.mainWindow.flatMap { $0 is ShelfPanel ? nil : $0.screen }
        guard let screen = mainScreen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        panel.setFrame(ShelfPanelPlacement.frame(visibleFrame: screen.visibleFrame, screenFrame: screen.frame, safeTop: screen.safeAreaInsets.top, expanded: isExpanded), display: true)
    }

    func tearDown() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        keyMonitor = nil
        screenObserver = nil
        panel.contentView = nil
        panel.close()
    }
}

@MainActor
private final class ShelfHostingView: NSHostingView<ShelfView> {
    weak var controller: ShelfPanelController?
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard controller?.interactionAllowed == true, controller?.store.isEnabled == true,
              !sender.draggingSourceOperationMask.intersection(.copy).isEmpty,
              sender.draggingPasteboard.availableType(from: [.fileURL, .png, .tiff, .string]) != nil else { return [] }
        return .copy
    }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard draggingEntered(sender) == .copy else { return false }
        return controller?.importContents(from: sender.draggingPasteboard) == true
    }
}
