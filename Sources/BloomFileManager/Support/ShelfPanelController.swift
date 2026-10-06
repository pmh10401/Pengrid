import AppKit
import SwiftUI
import Observation
import QuartzCore

enum ShelfSurfaceStyle: String, CaseIterable {
    case glass, darkGlass, solid

    var title: String {
        switch self {
        case .glass: "Liquid Glass"
        case .darkGlass: "Dark Glass"
        case .solid: "Solid Black"
        }
    }

    func resolved(reduceTransparency: Bool) -> Self {
        if #available(macOS 26, *), !reduceTransparency { return self }
        return .solid
    }
}

enum ShelfPanelPlacement {
    static func hardwareNotch(screenFrame: CGRect, safeTop: CGFloat, leftArea: CGRect?, rightArea: CGRect?) -> CGRect? {
        guard let leftArea, let rightArea,
              [screenFrame.minX, screenFrame.minY, screenFrame.width, screenFrame.height,
               safeTop, leftArea.width, leftArea.height, rightArea.width, rightArea.height].allSatisfy(\.isFinite),
              leftArea.width > 0, rightArea.width > 0 else { return nil }
        let width = screenFrame.width - leftArea.width - rightArea.width
        // Auxiliary strips still describe the cutout when the menu bar auto-hides.
        let height = max(safeTop, leftArea.height, rightArea.height)
        guard width > 0, height > 0, height <= screenFrame.height else { return nil }
        return CGRect(x: screenFrame.minX + leftArea.width, y: screenFrame.maxY - height, width: width, height: height)
    }

    @MainActor static func hardwareNotch(on screen: NSScreen) -> CGRect? {
        hardwareNotch(screenFrame: screen.frame, safeTop: screen.safeAreaInsets.top,
                      leftArea: screen.auxiliaryTopLeftArea, rightArea: screen.auxiliaryTopRightArea)
    }

    static func hardwareHover(at point: CGPoint, notch: CGRect, panelFrame: CGRect, expanded: Bool) -> Bool {
        // CGRect.contains excludes the top edge, exactly where the pointer can stop.
        let inNotch = point.x >= notch.minX && point.x <= notch.maxX && point.y >= notch.minY && point.y <= notch.maxY
        return inNotch || (expanded && panelFrame.insetBy(dx: -4, dy: -4).contains(point))
    }

    static func insets(visibleFrame: CGRect, screenFrame: CGRect, edge: ShelfEdge) -> EdgeInsets {
        EdgeInsets(top: edge == .top ? max(18, screenFrame.maxY - visibleFrame.maxY + 12) : edge.isVertical ? 52 : 18,
                   leading: edge == .left ? max(52, visibleFrame.minX - screenFrame.minX + 12) : 52,
                   bottom: edge == .bottom ? max(18, visibleFrame.minY - screenFrame.minY + 12) : edge.isVertical ? 52 : 18,
                   trailing: edge == .right ? max(52, screenFrame.maxX - visibleFrame.maxX + 12) : 52)
    }

    static func frame(visibleFrame: CGRect, screenFrame: CGRect, safeTop: CGFloat, expanded: Bool, anchor: CGPoint? = nil, hardwareNotch: CGRect? = nil, edge: ShelfEdge = .top) -> CGRect {
        if let notch = hardwareNotch {
            guard expanded else { return notch }
            let width = min(1200, visibleFrame.width)
            let height = min(400, max(0, notch.minY - visibleFrame.minY))
            let center = min(max(notch.midX, visibleFrame.minX + width / 2), visibleFrame.maxX - width / 2)
            return CGRect(x: center - width / 2, y: notch.minY - height, width: width, height: height)
        }
        let padding = insets(visibleFrame: visibleFrame, screenFrame: screenFrame, edge: edge)
        let expandedWidth = min(edge.isVertical ? 360 + padding.leading + padding.trailing - 104 : 1200, screenFrame.width)
        let expandedHeight = min(edge.isVertical ? 760 : 400 + padding.top + padding.bottom - 36, screenFrame.height)
        let width = expanded ? expandedWidth : min(edge.isVertical ? 18 : 112, screenFrame.width)
        let height = expanded ? expandedHeight : min(edge.isVertical ? 112 : 18, screenFrame.height)
        let anchor = anchor.flatMap { $0.x.isFinite && $0.y.isFinite ? $0 : nil } ?? CGPoint(x: 0.5, y: 1)
        let x = min(max(screenFrame.minX + anchor.x * screenFrame.width, screenFrame.minX + expandedWidth / 2), screenFrame.maxX - expandedWidth / 2)
        let y = min(max(screenFrame.minY + anchor.y * screenFrame.height, screenFrame.minY + expandedHeight / 2), screenFrame.maxY - expandedHeight / 2)
        // The perpendicular coordinate is always a physical edge, never a free window position.
        switch edge {
        case .top: return CGRect(x: x - width / 2, y: screenFrame.maxY - height, width: width, height: height)
        case .bottom: return CGRect(x: x - width / 2, y: screenFrame.minY, width: width, height: height)
        case .left: return CGRect(x: screenFrame.minX, y: y - height / 2, width: width, height: height)
        case .right: return CGRect(x: screenFrame.maxX - width, y: y - height / 2, width: width, height: height)
        }
    }

    static func anchor(of frame: CGRect, in bounds: CGRect, edge: ShelfEdge = .top) -> CGPoint {
        guard bounds.width > 0, bounds.height > 0 else { return CGPoint(x: 0.5, y: 1) }
        let x = (frame.midX - bounds.minX) / bounds.width
        let y = (frame.midY - bounds.minY) / bounds.height
        switch edge {
        case .top: return CGPoint(x: x, y: 1)
        case .bottom: return CGPoint(x: x, y: 0)
        case .left: return CGPoint(x: 0, y: y)
        case .right: return CGPoint(x: 1, y: y)
        }
    }
}

@MainActor
final class ShelfPanel: NSPanel {
    var onInteraction: (() -> Void)?
    var onCloseShelf: (() -> Void)?
    var onCopyShelf: (() -> Void)?
    var onImportShelf: (() -> Void)?
    var onRemoveShelf: (() -> Void)?
    var onNavigateShelf: ((Int) -> Void)?
    var onMoveShelf: ((CGPoint) -> Void)?
    var usesVerticalGallery = false
    var interactionAllowed: () -> Bool = { true }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func becomeKey() {
        super.becomeKey()
        onInteraction?()
    }

    override func sendEvent(_ event: NSEvent) {
        if interactionAllowed(), [.leftMouseDown, .rightMouseDown, .keyDown].contains(event.type) {
            onInteraction?()
        }
        super.sendEvent(event)
    }

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
            if event.modifierFlags.intersection([.command, .option, .control, .shift]) == .option {
                let offsets: [UInt16: CGPoint] = [123: CGPoint(x: -24, y: 0), 124: CGPoint(x: 24, y: 0),
                                                125: CGPoint(x: 0, y: -24), 126: CGPoint(x: 0, y: 24)]
                if let offset = offsets[event.keyCode] { onMoveShelf?(offset); return onMoveShelf != nil }
            }
            let navigationKeys: [UInt16] = usesVerticalGallery ? [126, 125] : [123, 124]
            if navigationKeys.contains(event.keyCode),
               event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
                onNavigateShelf?(event.keyCode == navigationKeys[0] ? -1 : 1)
                return onNavigateShelf != nil
            }
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
    static let positionKey = "topShelf.position.v1"
    static let hardwareNotchKey = "topShelf.hardwareNotch.v1"
    static let surfaceStyleKey = "topShelf.surfaceStyle.v1"
    let store: ShelfStore
    let panel: ShelfPanel
    let operationController: FileOperationController?
    var openMain: () -> Void
    private(set) var isExpanded = false
    private(set) var hasCustomPosition = false
    private(set) var prefersHardwareNotch = true
    private(set) var surfaceStyle: ShelfSurfaceStyle
    private(set) var hardwareNotchFrame: CGRect?
    private(set) var expandedSize = CGSize(width: 1200, height: 400)
    private(set) var collapsedSize = CGSize(width: 112, height: 18)
    private(set) var isFolding = false
    private(set) var edge: ShelfEdge = .top
    private(set) var contentInsets = EdgeInsets(top: 18, leading: 52, bottom: 18, trailing: 52)
    private(set) var carry: ShelfCarryMotion?
    var isHardwareDocked: Bool { hardwareNotchFrame != nil }
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var savedPosition: (screenID: Int, anchor: CGPoint)?
    @ObservationIgnored private var savedEdge: ShelfEdge = .top
    @ObservationIgnored private var compactFrame = CGRect.zero
    @ObservationIgnored private var compactOverlapsCutout = false
    @ObservationIgnored private var isRepositioning = false
    @ObservationIgnored private var moveObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var screenObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var appearanceObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var foldTask: Task<Void, Never>?
    @ObservationIgnored private var foldAnimationTask: Task<Void, Never>?
    @ObservationIgnored private var pointerTimer: Timer?
    @ObservationIgnored private var carryPanel: NSPanel?
    @ObservationIgnored private var carryDisplayLink: CADisplayLink?
    @ObservationIgnored private var carryTick: ShelfCarryTick?
    @ObservationIgnored private var carryTimestamp: TimeInterval = 0
    @ObservationIgnored private var revealTask: Task<Void, Never>?
    @ObservationIgnored private var isHovering = false
    private(set) var isPinned = false
    @ObservationIgnored private var isTornDown = false
    init(store: ShelfStore, operationController: FileOperationController? = nil, defaults: UserDefaults = .standard, openMain: @escaping () -> Void = {}) {
        self.store = store
        self.operationController = operationController
        self.defaults = defaults
        self.openMain = openMain
        surfaceStyle = defaults.string(forKey: Self.surfaceStyleKey).flatMap(ShelfSurfaceStyle.init(rawValue:)) ?? .glass
        prefersHardwareNotch = defaults.object(forKey: Self.hardwareNotchKey) as? Bool ?? true
        if let position = defaults.dictionary(forKey: Self.positionKey),
           let screenID = position["screenID"] as? Int,
           let x = position["x"] as? Double, let y = position["y"] as? Double,
           x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) {
            savedPosition = (screenID, CGPoint(x: x, y: y))
            savedEdge = (position["edge"] as? String).flatMap(ShelfEdge.init(rawValue:)) ?? .top
            hasCustomPosition = true
        }
        panel = ShelfPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.worksWhenModal = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        updateAppearance()
        panel.hasShadow = true
        panel.title = "Pengrid Top Shelf"
        panel.identifier = NSUserInterfaceItemIdentifier("pengrid.topShelf")
        panel.onCloseShelf = { [weak self] in
            guard let self else { return }
            if self.carry != nil { self.cancelMove() } else { self.hide() }
        }
        panel.onInteraction = { [weak self] in self?.pinOpen() }
        panel.onImportShelf = { [weak self] in self?.importClipboard() }
        panel.onCopyShelf = { [weak self] in self?.copySelection() }
        panel.onRemoveShelf = { [weak self] in self?.removeSelection() }
        panel.onNavigateShelf = { [weak self] direction in self?.navigateSelection(direction: direction) }
        panel.onMoveShelf = { [weak self] offset in self?.move(by: offset) }
        panel.interactionAllowed = { [weak self] in self?.interactionAllowed == true }
        let host = ShelfHostingView(rootView: ShelfView(controller: self))
        host.sizingOptions = []
        host.controller = self
        host.registerForDraggedTypes([.fileURL, .string, .png, .tiff])
        panel.contentView = host
        appearanceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateAppearance() }
        }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancelMove(); self?.reposition() }
        }
        moveObserver = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isRepositioning, self.carry == nil else { return }
                self.rememberPosition(self.panel.frame)
            }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self else { return false }
                if self.carry != nil {
                    if event.type == .leftMouseDragged {
                        self.updateMove(to: NSEvent.mouseLocation)
                        return true
                    }
                    if event.type == .leftMouseUp { self.endMove(); return true }
                    if event.keyCode == 53 { self.cancelMove(); return true }
                }
                guard event.type == .keyDown, NSApp.keyWindow === self.panel else { return false }
                return self.panel.handleKey(event)
            }
            return consumed ? nil : event
        }
    }

    func show(expanded: Bool = true) {
        guard !isTornDown, store.isEnabled, !store.isPreparingTermination, interactionAllowed else { return }
        cancelMove()
        revealTask?.cancel()
        revealTask = nil
        cancelFold()
        isPinned = expanded
        setExpanded(expanded)
        panel.orderFront(nil)
        updatePointerTracking()
        if expanded { panel.makeKey() }
    }

    func hide() {
        cancelMove()
        revealTask?.cancel()
        revealTask = nil
        cancelFold()
        foldAnimationTask?.cancel()
        foldAnimationTask = nil
        pointerTimer?.invalidate()
        pointerTimer = nil
        isFolding = false
        isHovering = false
        isPinned = false
        isExpanded = false
        panel.orderOut(nil)
    }

    func setHovering(_ hovering: Bool) {
        guard !isTornDown, carry == nil, panel.isVisible, store.isEnabled, !store.isPreparingTermination, interactionAllowed else { return }
        isHovering = hovering
        cancelFold()
        if hovering {
            guard !isExpanded else { return }
            setExpanded(true) // Hover previews never make the panel key.
        } else if isExpanded && !isPinned {
            foldTask = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(450)) }
                catch { return }
                guard let self else { return }
                self.foldTask = nil
                guard !self.isTornDown, !self.isHovering, !self.isPinned, self.panel.isVisible,
                      self.store.isEnabled, !self.store.isPreparingTermination, self.interactionAllowed else { return }
                self.setExpanded(false)
            }
        }
    }

    private func cancelFold() {
        foldTask?.cancel()
        foldTask = nil
    }

    private func setExpanded(_ expanded: Bool) {
        foldAnimationTask?.cancel()
        foldAnimationTask = nil
        isFolding = !expanded && (isExpanded || isFolding) && panel.isVisible
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        isExpanded = expanded
        if !expanded { panel.makeFirstResponder(nil) }
        reposition()
        guard isFolding else { return }
        // Keep the canvas while the SwiftUI spring folds; a returning pointer cancels this shrink.
        foldAnimationTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(850)) }
            catch { return }
            guard let self, !self.isTornDown, !self.isExpanded else { return }
            self.foldAnimationTask = nil
            self.isFolding = false
            self.reposition()
        }
    }

    private func pinOpen() {
        guard isExpanded, panel.isVisible else { return }
        isPinned = true
        cancelFold()
    }

    func setEnabled(_ value: Bool) {
        guard !isTornDown, !store.isPreparingTermination, interactionAllowed else { return }
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
        pinOpen()
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

    func selectItem(_ id: UUID) {
        guard interactionAllowed, !store.isPreparingTermination,
              store.filteredEntries.contains(where: { $0.id == id }) else { return }
        panel.makeFirstResponder(nil)
        store.selectedID = id
    }

    private func navigateSelection(direction: Int) {
        guard interactionAllowed, !store.isPreparingTermination else { return }
        let items = store.filteredEntries
        guard !items.isEmpty else { store.selectedID = nil; return }
        let index = items.firstIndex { $0.id == store.selectedID }
        let next = index.map { min(max($0 + direction, 0), items.count - 1) }
            ?? (direction < 0 ? items.count - 1 : 0)
        store.selectedID = items[next].id
    }

    func beginMove(at point: CGPoint = NSEvent.mouseLocation) -> Bool {
        guard canMove, point.x.isFinite, point.y.isFinite, let screen = panel.screen,
              let screenID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? Int else { return false }
        pinOpen()
        panel.makeFirstResponder(nil)
        let track = ShelfBorderTrack(frame: screen.frame)
        let position = track.coordinate(of: CGPoint(x: compactFrame.midX, y: compactFrame.midY), on: edge)
        let reading = track.reading(at: point, edge: edge)
        carry = ShelfCarryMotion(track: track, screenID: screenID, position: position, target: position,
                                 grip: track.gap(from: track.coordinate(of: point, reading: reading), to: position),
                                 reading: reading, pointerEdge: edge)
        let overlay = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        overlay.isReleasedWhenClosed = false
        overlay.level = .statusBar
        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.hasShadow = false
        overlay.ignoresMouseEvents = true
        overlay.hidesOnDeactivate = false
        overlay.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        overlay.title = "Moving Pengrid Shelf"
        let host = NSHostingView(rootView: ShelfCarryView(controller: self))
        host.sizingOptions = []
        overlay.contentView = host
        carryPanel = overlay
        overlay.orderFront(nil)
        panel.alphaValue = 0
        let tick = ShelfCarryTick(controller: self)
        let link = screen.displayLink(target: tick, selector: #selector(ShelfCarryTick.update(_:)))
        carryTick = tick
        carryDisplayLink = link
        carryTimestamp = 0
        link.add(to: .main, forMode: .common)
        return true
    }

    func updateMove(to point: CGPoint) {
        guard !isTornDown, store.isEnabled, !store.isPreparingTermination, interactionAllowed else { cancelMove(); return }
        carry?.follow(point)
    }

    func endMove() {
        guard var motion = carry, !motion.isSettling else { return }
        guard !isTornDown, store.isEnabled, !store.isPreparingTermination, interactionAllowed,
              let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? Int) == motion.screenID }) else { cancelMove(); return }
        if let landing = motion.track.notchLanding(at: motion.target, notch: ShelfPanelPlacement.hardwareNotch(on: screen)) {
            motion.target = landing
            motion.docksToHardware = true
        } else {
            let destination = motion.track.location(at: motion.target)
            let anchor = ShelfPanelPlacement.anchor(of: CGRect(origin: destination.point, size: .zero), in: screen.frame, edge: destination.edge)
            let frame = ShelfPanelPlacement.frame(visibleFrame: screen.visibleFrame, screenFrame: screen.frame,
                safeTop: screen.safeAreaInsets.top, expanded: false, anchor: anchor, edge: destination.edge)
            motion.target = motion.track.coordinate(of: CGPoint(x: frame.midX, y: frame.midY), on: destination.edge)
        }
        motion.isSettling = true
        carry = motion
    }

    func advanceMove(elapsed: TimeInterval) {
        guard var motion = carry else { return }
        guard !isTornDown, store.isEnabled, !store.isPreparingTermination, interactionAllowed else { cancelMove(); return }
        let finished = motion.advance(elapsed: elapsed, reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        carry = motion
        guard finished else { return }
        let destination = motion.track.location(at: motion.target)
        savedEdge = destination.edge
        let anchor = ShelfPanelPlacement.anchor(of: CGRect(origin: destination.point, size: .zero), in: motion.track.frame, edge: destination.edge)
        savePosition(screenID: motion.screenID, anchor: anchor, hardware: motion.docksToHardware)
        cancelMove()
        // Reuse the shelf's inward unfold; the full gallery never follows the pointer.
        isExpanded = false
        isFolding = false
        reposition()
        revealTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(40)) } catch { return }
            guard let self, !self.isTornDown, self.panel.isVisible, self.store.isEnabled,
                  !self.store.isPreparingTermination, self.interactionAllowed else { return }
            self.revealTask = nil
            self.show()
        }
    }

    fileprivate func displayCarry(at timestamp: TimeInterval) {
        let elapsed = carryTimestamp == 0 ? 1.0 / 60 : timestamp - carryTimestamp
        carryTimestamp = timestamp
        advanceMove(elapsed: elapsed)
    }

    func cancelMove() {
        carryDisplayLink?.invalidate()
        carryDisplayLink = nil
        carryTick = nil
        carryPanel?.close()
        carryPanel = nil
        carry = nil
        panel.alphaValue = 1
    }

    func setEdge(_ value: ShelfEdge) {
        guard !isTornDown, !store.isPreparingTermination, interactionAllowed, let screen = panel.screen ?? NSScreen.main,
              let screenID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? Int else { return }
        cancelMove()
        savedEdge = value
        savePosition(screenID: screenID, anchor: CGPoint(x: 0.5, y: 0.5), hardware: false)
        reposition()
    }

    func move(by offset: CGPoint) {
        guard canMove, offset.x.isFinite, offset.y.isFinite else { return }
        pinOpen()
        rememberPosition(panel.frame.offsetBy(dx: edge.isVertical ? 0 : offset.x, dy: edge.isVertical ? offset.y : 0))
    }

    private var canMove: Bool {
        !isTornDown && carry == nil && isExpanded && panel.isVisible && store.isEnabled && !store.isPreparingTermination && interactionAllowed
    }

    private func rememberPosition(_ frame: CGRect) {
        guard canMove,
              let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) }) ?? panel.screen,
              let screenID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? Int else { return }
        let proposed = ShelfPanelPlacement.anchor(of: frame, in: screen.frame, edge: edge)
        let clamped = ShelfPanelPlacement.frame(visibleFrame: screen.visibleFrame, screenFrame: screen.frame,
                                                safeTop: screen.safeAreaInsets.top, expanded: true, anchor: proposed, edge: edge)
        let anchor = ShelfPanelPlacement.anchor(of: clamped, in: screen.frame, edge: edge)
        savedEdge = edge
        savePosition(screenID: screenID, anchor: anchor, hardware: false)
        reposition()
    }

    private func savePosition(screenID: Int, anchor: CGPoint, hardware: Bool) {
        savedPosition = (screenID, anchor)
        hasCustomPosition = true
        prefersHardwareNotch = hardware
        defaults.set(hardware, forKey: Self.hardwareNotchKey)
        defaults.set(["screenID": screenID, "x": Double(anchor.x), "y": Double(anchor.y), "edge": savedEdge.rawValue], forKey: Self.positionKey)
    }

    func resetPosition() {
        guard !isTornDown, !store.isPreparingTermination, interactionAllowed else { return }
        cancelMove()
        savedPosition = nil
        savedEdge = .top
        hasCustomPosition = false
        defaults.removeObject(forKey: Self.positionKey)
        reposition()
    }

    func setHardwareDocking(_ value: Bool) {
        guard !isTornDown, !store.isPreparingTermination, interactionAllowed else { return }
        cancelMove()
        prefersHardwareNotch = value
        defaults.set(value, forKey: Self.hardwareNotchKey)
        reposition()
    }

    func setSurfaceStyle(_ value: ShelfSurfaceStyle) {
        guard !isTornDown, !store.isPreparingTermination, interactionAllowed else { return }
        surfaceStyle = value
        defaults.set(value.rawValue, forKey: Self.surfaceStyleKey)
        updateAppearance()
    }

    private func updateAppearance() {
        let style = surfaceStyle.resolved(reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency)
        panel.appearance = style == .glass ? nil : NSAppearance(named: .darkAqua)
    }

    private func reposition() {
        let mainScreen = NSApp.mainWindow.flatMap { $0 is ShelfPanel ? nil : $0.screen }
        let savedScreen = savedPosition.flatMap { position in NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? Int) == position.screenID } }
        let notchScreen = prefersHardwareNotch ? ([mainScreen].compactMap { $0 } + NSScreen.screens)
            .first(where: { ShelfPanelPlacement.hardwareNotch(on: $0) != nil }) : nil
        guard let screen = notchScreen ?? savedScreen ?? mainScreen ?? NSScreen.main ?? NSScreen.screens.first else { return }
        hardwareNotchFrame = notchScreen.flatMap { ShelfPanelPlacement.hardwareNotch(on: $0) }
        edge = isHardwareDocked ? .top : savedEdge
        panel.usesVerticalGallery = edge.isVertical
        contentInsets = isHardwareDocked ? EdgeInsets(top: 18, leading: 52, bottom: 18, trailing: 52)
            : ShelfPanelPlacement.insets(visibleFrame: screen.visibleFrame, screenFrame: screen.frame, edge: edge)
        let anchor = savedScreen == nil ? nil : savedPosition?.anchor
        let expandedFrame = ShelfPanelPlacement.frame(visibleFrame: screen.visibleFrame, screenFrame: screen.frame,
            safeTop: screen.safeAreaInsets.top, expanded: true, anchor: anchor, hardwareNotch: hardwareNotchFrame, edge: edge)
        let collapsedFrame = ShelfPanelPlacement.frame(visibleFrame: screen.visibleFrame, screenFrame: screen.frame,
            safeTop: screen.safeAreaInsets.top, expanded: false, anchor: anchor, hardwareNotch: hardwareNotchFrame, edge: edge)
        compactFrame = collapsedFrame
        compactOverlapsCutout = edge == .top && ShelfPanelPlacement.hardwareNotch(on: screen).map { $0.intersects(collapsedFrame) } == true
        expandedSize = expandedFrame.size
        collapsedSize = CGSize(width: collapsedFrame.width, height: isHardwareDocked ? 0 : collapsedFrame.height)
        isRepositioning = true
        defer { isRepositioning = false }
        panel.hasShadow = isExpanded
        panel.ignoresMouseEvents = !isExpanded && (isHardwareDocked || isFolding)
        panel.setFrame(isExpanded || isFolding ? expandedFrame : collapsedFrame, display: true)
        updatePointerTracking()
    }

    private func updatePointerTracking() {
        guard !isTornDown, panel.isVisible, store.isEnabled, !store.isPreparingTermination,
              isHardwareDocked || compactOverlapsCutout || isFolding else {
            pointerTimer?.invalidate()
            pointerTimer = nil
            return
        }
        guard pointerTimer == nil else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackPointer(at: NSEvent.mouseLocation) }
        }
        timer.tolerance = 0.02
        pointerTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func trackPointer(at point: CGPoint) {
        guard !store.isPreparingTermination else { updatePointerTracking(); return }
        let hovering = hardwareNotchFrame.map {
            ShelfPanelPlacement.hardwareHover(at: point, notch: $0, panelFrame: panel.frame, expanded: isExpanded)
        } ?? ShelfPanelPlacement.hardwareHover(at: point, notch: compactFrame, panelFrame: panel.frame, expanded: isExpanded)
        // Repeated outside readings must not restart the 450 ms fold grace.
        if hovering != isHovering { setHovering(hovering) }
    }

    func tearDown() {
        isTornDown = true
        hide()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
        if let appearanceObserver { NSWorkspace.shared.notificationCenter.removeObserver(appearanceObserver) }
        keyMonitor = nil
        screenObserver = nil
        moveObserver = nil
        appearanceObserver = nil
        panel.contentView = nil
        panel.close()
    }
}

@MainActor
private final class ShelfCarryTick: NSObject {
    weak var controller: ShelfPanelController?
    init(controller: ShelfPanelController) { self.controller = controller }
    @objc func update(_ link: CADisplayLink) { controller?.displayCarry(at: link.timestamp) }
}

@MainActor
private final class ShelfHostingView: NSHostingView<ShelfView> {
    weak var controller: ShelfPanelController?
    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .enabledDuringMouseDrag],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        controller?.setHovering(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        controller?.setHovering(false)
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard controller?.interactionAllowed == true, controller?.store.isEnabled == true,
              controller?.store.isPreparingTermination == false,
              !sender.draggingSourceOperationMask.intersection(.copy).isEmpty,
              sender.draggingPasteboard.availableType(from: [.fileURL, .png, .tiff, .string]) != nil else { return [] }
        controller?.setHovering(true)
        return .copy
    }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    override func draggingExited(_ sender: (any NSDraggingInfo)?) { controller?.setHovering(false) }
    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) { controller?.setHovering(false) }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard draggingEntered(sender) == .copy else { return false }
        return controller?.importContents(from: sender.draggingPasteboard) == true
    }
}
