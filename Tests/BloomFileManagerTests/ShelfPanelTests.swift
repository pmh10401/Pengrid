import AppKit
import Testing
@testable import BloomFileManager

@Suite("Shelf window boundary", .serialized)
@MainActor
struct ShelfPanelTests {
    @Test func placementRespectsMenuBarNotchAndNegativeDisplayOrigin() {
        let screen = CGRect(x: -1512, y: 300, width: 1512, height: 982)
        let visible = CGRect(x: -1512, y: 300, width: 1512, height: 944)
        let frame = ShelfPanelPlacement.frame(visibleFrame: visible, screenFrame: screen, safeTop: 38, expanded: true)
        #expect(frame.midX == -756)
        #expect(frame.maxY == 1244)
        #expect(visible.contains(frame))
        #expect(frame.width > 400)
        let small = CGRect(x: 10, y: -100, width: 300, height: 200)
        let clamped = ShelfPanelPlacement.frame(visibleFrame: small, screenFrame: small, safeTop: 0, expanded: true)
        #expect(small.contains(clamped))
        #expect(clamped.width <= 300)
    }

    @Test func shelfWindowCannotAuthorizeWorkspaceCommands() {
        let panel = ShelfPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        window.isReleasedWhenClosed = false
        defer { panel.close(); window.close() }
        #expect(!ShelfPanel.allowsWorkspaceCommands(keyWindow: panel))
        #expect(ShelfPanel.allowsWorkspaceCommands(keyWindow: window))
    }

    @Test func destructiveAndPasteShortcutsStayInsideTheShelf() throws {
        let panel = ShelfPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        var removed = 0
        var imported = 0
        var closed = 0
        panel.onRemoveShelf = { removed += 1 }
        panel.onImportShelf = { imported += 1 }
        panel.onCloseShelf = { closed += 1 }
        for (text, key) in [("\u{7f}", UInt16(51)), ("v", 9), ("w", 13)] {
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: panel.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: key))
            #expect(panel.handleKey(event))
        }
        #expect(removed == 1)
        #expect(imported == 1)
        #expect(closed == 1)
        let koreanCommandW = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: panel.windowNumber, context: nil, characters: "ㅈ", charactersIgnoringModifiers: "ㅈ", isARepeat: false, keyCode: 13))
        #expect(panel.handleKey(koreanCommandW))
        #expect(closed == 2)
    }

    @Test func panelIsNonactivatingAndModalInteractionIsBlocked() throws {
        let defaults = UserDefaults(suiteName: "shelf-panel-test-\(UUID())")!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("unused-shelf-\(UUID())")
        let store = ShelfStore(defaults: defaults, persistence: ShelfPersistence(root: root))
        let controller = ShelfPanelController(store: store)
        defer { controller.tearDown() }
        #expect(controller.panel.styleMask.contains(.nonactivatingPanel))
        #expect(controller.panel.worksWhenModal == false)
        #expect(controller.panel.hidesOnDeactivate == false)
        #expect(controller.panel.isVisible == false)
        let modal = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        modal.isReleasedWhenClosed = false
        defer { modal.close() }
        #expect(!controller.canInteract(modalWindow: modal, windows: []))
        #expect(controller.canInteract(modalWindow: nil, windows: []))
    }

    @Test func nativeDropAcceptsCopyRejectsMoveAndCannotResurrectAfterClear() async throws {
        let suite = "shelf-panel-drop-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("shelf-panel-drop-\(UUID())")
        let fixture = root.appendingPathComponent("drop-fixture.txt")
        let original = Data("native drop fixture".utf8)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try original.write(to: fixture, options: .atomic)

        let store = ShelfStore(
            defaults: defaults,
            persistence: ShelfPersistence(root: root.appendingPathComponent("state", isDirectory: true))
        )
        let controller = ShelfPanelController(store: store)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ShelfPanelDrop-\(UUID())"))
        defer {
            pasteboard.releaseGlobally()
            controller.tearDown()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }

        await store.start()
        store.setEnabled(true)

        let pasteboardItem = NSPasteboardItem()
        #expect(pasteboardItem.setString(fixture.absoluteString, forType: .fileURL))
        pasteboard.clearContents()
        #expect(pasteboard.writeObjects([pasteboardItem]))

        let target = try #require(controller.panel.contentView)
        let moveOnlyDrop = ShelfPanelDraggingInfoStub(pasteboard: pasteboard, sourceMask: .move)
        #expect(target.draggingEntered(moveOnlyDrop).isEmpty)
        #expect(target.performDragOperation(moveOnlyDrop) == false)
        #expect(store.entries.isEmpty)

        let copyDrop = ShelfPanelDraggingInfoStub(pasteboard: pasteboard, sourceMask: .copy)
        #expect(target.draggingEntered(copyDrop) == .copy)
        #expect(target.performDragOperation(copyDrop))
        let importDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while store.isImporting && ContinuousClock.now < importDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(store.isImporting == false)
        #expect(store.entries.map(\.content) == [.file(fixture)])
        #expect(try Data(contentsOf: fixture) == original)

        #expect(target.performDragOperation(copyDrop))
        store.clear()
        #expect(store.entries.isEmpty)
        store.setEnabled(false)
        try await Task.sleep(for: .milliseconds(50))
        #expect(store.isImporting == false)
        #expect(store.entries.isEmpty)
        #expect(try Data(contentsOf: fixture) == original)
        #expect(await store.flushPersistence())
    }
}

@MainActor
private final class ShelfPanelDraggingInfoStub: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingDestinationWindow: NSWindow? = nil
    let draggingSourceOperationMask: NSDragOperation
    let draggingLocation: NSPoint = .zero
    let draggedImageLocation: NSPoint = .zero
    let draggedImage: NSImage? = nil
    let draggingSource: Any? = nil
    let draggingSequenceNumber = 1
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    let springLoadingHighlight: NSSpringLoadingHighlight = .none

    init(pasteboard: NSPasteboard, sourceMask: NSDragOperation) {
        draggingPasteboard = pasteboard
        draggingSourceOperationMask = sourceMask
    }

    func slideDraggedImage(to screenPoint: NSPoint) {}

    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions,
        for view: NSView?,
        classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any],
        using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}

    func resetSpringLoading() {}
}
