import AppKit
import Testing
@testable import BloomFileManager

@Suite("Shelf window boundary", .serialized)
@MainActor
struct ShelfPanelTests {
    @Test func glassStylePersistsAndHonorsAccessibility() throws {
        let suite = "shelf-style-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let store = ShelfStore(defaults: defaults,
            persistence: ShelfPersistence(root: FileManager.default.temporaryDirectory.appendingPathComponent(suite)))
        let controller = ShelfPanelController(store: store, defaults: defaults)
        defer { controller.tearDown(); defaults.removePersistentDomain(forName: suite) }
        #expect(controller.surfaceStyle == .glass)
        controller.setSurfaceStyle(.darkGlass)
        #expect(defaults.string(forKey: ShelfPanelController.surfaceStyleKey) == "darkGlass")
        let restored = ShelfPanelController(store: store, defaults: defaults)
        defer { restored.tearDown() }
        #expect(restored.surfaceStyle == .darkGlass)
        #expect(restored.panel.appearance?.name == .darkAqua)
        controller.setSurfaceStyle(.solid)
        #expect(controller.surfaceStyle == .solid)
        #expect(store.entries.isEmpty)
        controller.tearDown()
        controller.setSurfaceStyle(.glass)
        #expect(controller.surfaceStyle == .solid)
        for style in ShelfSurfaceStyle.allCases {
            #expect(style.resolved(reduceTransparency: true) == .solid)
            if #available(macOS 26, *) {
                #expect(style.resolved(reduceTransparency: false) == style)
            } else {
                #expect(style.resolved(reduceTransparency: false) == .solid)
            }
        }
    }

    @Test func sideShelfUsesPortraitDimensionsAndKeepsItsCompactAnchor() {
        let screen = CGRect(x: -1440, y: 200, width: 1440, height: 900)
        let visible = CGRect(x: -1440, y: 225, width: 1440, height: 850)
        for edge in [ShelfEdge.left, .right] {
            let expanded = ShelfPanelPlacement.frame(visibleFrame: visible, screenFrame: screen, safeTop: 25,
                expanded: true, anchor: CGPoint(x: 0.5, y: 0.8), edge: edge)
            let compact = ShelfPanelPlacement.frame(visibleFrame: visible, screenFrame: screen, safeTop: 25,
                expanded: false, anchor: CGPoint(x: 0.5, y: 0.8), edge: edge)
            #expect(expanded.width <= 420)
            #expect(expanded.height > expanded.width)
            #expect(screen.contains(expanded))
            #expect(abs(compact.midY - expanded.midY) < 0.001)
        }
        let small = CGRect(x: 0, y: 0, width: 320, height: 500)
        let frame = ShelfPanelPlacement.frame(visibleFrame: small, screenFrame: small, safeTop: 0, expanded: true, edge: .left)
        #expect(small.contains(frame))
    }

    @Test func sideGalleryUsesUpDownAndRetainsSearchAcrossEdges() async throws {
        try await withHoverShelf { controller in
            let first = ShelfItem(content: .text("memo first"))
            let second = ShelfItem(content: .text("memo second"))
            await controller.store.add([first, second, ShelfItem(content: .text("unrelated"))])
            controller.store.kind = .text
            controller.store.query = "memo"
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while controller.store.isSearching && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            try #require(controller.store.filteredEntries.map(\.id) == [first.id, second.id])
            controller.setEdge(.left)
            controller.show()
            controller.selectItem(first.id)
            @MainActor func arrow(_ key: UInt16) throws -> NSEvent {
                try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: controller.panel.windowNumber, context: nil, characters: "",
                    charactersIgnoringModifiers: "", isARepeat: false, keyCode: key))
            }
            #expect(controller.panel.handleKey(try arrow(125)))
            #expect(controller.store.selectedID == second.id)
            #expect(controller.panel.handleKey(try arrow(126)))
            #expect(controller.store.selectedID == first.id)
            #expect(!controller.panel.handleKey(try arrow(124)))
            controller.setEdge(.top)
            #expect(controller.store.query == "memo")
            #expect(controller.store.kind == .text)
            #expect(controller.store.selectedID == first.id)
            #expect(controller.panel.handleKey(try arrow(124)))
            #expect(controller.store.selectedID == second.id)
            controller.setEdge(.right)
            let editor = NSTextView(frame: CGRect(x: 0, y: 0, width: 100, height: 30))
            controller.panel.contentView?.addSubview(editor)
            try #require(controller.panel.makeFirstResponder(editor))
            #expect(!controller.panel.handleKey(try arrow(126)))
            #expect(!controller.panel.handleKey(try arrow(125)))
            #expect(controller.store.selectedID == second.id)
        }
    }

    @Test func movementKeepsTheShelfAttachedToTheScreenBorder() async throws {
        try await withHoverShelf { controller in
            controller.show()
            let screen = try #require(controller.panel.screen)
            let before = controller.panel.frame
            controller.move(by: CGPoint(x: 24, y: -48))
            #expect(abs(controller.panel.frame.midX - before.midX - 24) < 1)
            #expect(controller.panel.frame.maxY == screen.frame.maxY)
            controller.show(expanded: false)
            #expect(controller.panel.frame.maxY == screen.frame.maxY)
        }
    }

    @Test func borderTrackWrapsAndCarriesContinuouslyAroundCorners() {
        let frame = CGRect(x: -2400, y: -200, width: 2400, height: 1500)
        let track = ShelfBorderTrack(frame: frame)
        for edge in ShelfEdge.allCases {
            let point: CGPoint
            switch edge {
            case .top: point = CGPoint(x: frame.midX, y: frame.maxY)
            case .right: point = CGPoint(x: frame.maxX, y: frame.midY)
            case .bottom: point = CGPoint(x: frame.midX, y: frame.minY)
            case .left: point = CGPoint(x: frame.minX, y: frame.midY)
            }
            let location = track.location(at: track.coordinate(of: point, on: edge))
            #expect(location.edge == edge)
            #expect(location.point == point)
        }
        #expect(track.gap(from: track.perimeter - 5, to: 5) == 10)
        #expect(track.gap(from: 5, to: track.perimeter - 5) == -10)
        var motion = ShelfCarryMotion(track: track, screenID: 1, position: 1200, target: 1200,
                                      grip: 0, reading: .edge(.top), pointerEdge: .top)
        var previous = motion.target
        // Follow the top-right corner in small pointer steps; changing the reading cannot teleport the grip.
        let points = stride(from: frame.midX, through: frame.maxX - 20, by: 20).map { CGPoint(x: $0, y: frame.maxY - 20) }
            + stride(from: frame.maxY - 20, through: frame.midY, by: -20).map { CGPoint(x: frame.maxX - 20, y: $0) }
        for point in points {
            motion.follow(point)
            #expect(abs(track.gap(from: previous, to: motion.target)) <= 40)
            previous = motion.target
        }
        #expect(track.location(at: motion.target).edge == .right)
        let target = motion.target
        motion.follow(CGPoint(x: CGFloat.nan, y: 0))
        #expect(motion.target == target)
        #expect(track.nearest(to: CGPoint(x: frame.maxX - 10, y: frame.maxY - 15), keeping: .top) == .top)
    }

    @Test func borderSpringSettlesAtDifferentRefreshRatesAndHonorsReduceMotion() {
        let track = ShelfBorderTrack(frame: CGRect(x: 0, y: 0, width: 2400, height: 1500))
        for rate in [30, 60, 120] {
            var motion = ShelfCarryMotion(track: track, screenID: 1, position: track.perimeter - 30, target: 100,
                                          grip: 0, reading: .edge(.top), pointerEdge: .top, isSettling: true)
            var finished = false
            for _ in 0..<(rate * 2) { finished = motion.advance(elapsed: 1 / Double(rate), reduceMotion: false) }
            #expect(finished)
            #expect(motion.position == 100)
        }
        var motion = ShelfCarryMotion(track: track, screenID: 1, position: 300, target: 100,
                                      grip: 0, reading: .edge(.top), pointerEdge: .top, isSettling: true)
        let reducedMotionFinished = motion.advance(elapsed: 1 / 60, reduceMotion: true)
        #expect(reducedMotionFinished)
        #expect(motion.position == 100)
        let notch = CGRect(x: 1110, y: 1470, width: 180, height: 30)
        #expect(track.notchLanding(at: 1300, notch: notch) == 1200)
        #expect(track.notchLanding(at: 1450, notch: notch) == nil)
        #expect(track.notchLanding(at: 2600, notch: notch) == nil)
        #expect(track.notchLanding(at: 1200, notch: nil) == nil)
    }

    @Test func borderCarryCancelsWithoutSavingAndCannotSurviveDisableOrTermination() async throws {
        try await withHoverShelf { controller in
            controller.show()
            let before = controller.panel.frame
            let point = CGPoint(x: before.midX, y: before.maxY - 50)
            #expect(controller.beginMove(at: point))
            controller.updateMove(to: CGPoint(x: point.x + 100, y: point.y - 100))
            #expect(!controller.hasCustomPosition)
            #expect(controller.panel.alphaValue == 0)
            controller.panel.onCloseShelf?() // Escape cancels the carry, not the shelf.
            #expect(controller.carry == nil)
            #expect(controller.panel.isVisible)
            #expect(controller.panel.alphaValue == 1)
            #expect(controller.panel.frame == before)
            #expect(!controller.hasCustomPosition)
            #expect(controller.beginMove(at: point))
            controller.setEnabled(false)
            controller.endMove()
            controller.advanceMove(elapsed: 1 / 60)
            #expect(controller.carry == nil)
            #expect(!controller.panel.isVisible)
            controller.setEnabled(true)
            controller.show()
            #expect(controller.beginMove(at: point))
            #expect(await controller.store.prepareForTermination())
            controller.endMove()
            #expect(controller.carry == nil)
            #expect(!controller.hasCustomPosition)
        }
    }

    @Test func physicalNotchUsesReportedGapOnAnOffsetDisplay() throws {
        let screen = CGRect(x: -1512, y: 300, width: 1512, height: 982)
        let visible = CGRect(x: -1512, y: 300, width: 1512, height: 944)
        let notch = try #require(ShelfPanelPlacement.hardwareNotch(screenFrame: screen, safeTop: 38,
            leftArea: CGRect(x: -1512, y: 1244, width: 640, height: 38),
            rightArea: CGRect(x: -680, y: 1244, width: 680, height: 38)))
        #expect(notch == CGRect(x: -872, y: 1244, width: 192, height: 38))
        #expect(ShelfPanelPlacement.frame(visibleFrame: visible, screenFrame: screen, safeTop: 38,
            expanded: false, hardwareNotch: notch) == notch)
        // The gallery begins below the camera, not at the top of the menu bar.
        #expect(ShelfPanelPlacement.frame(visibleFrame: visible, screenFrame: screen, safeTop: 38,
            expanded: true, hardwareNotch: notch) == CGRect(x: -1376, y: 844, width: 1200, height: 400))
    }

    @Test func hardwareLayoutIgnoresAutoHiddenMenuBarAndFitsASmallScreen() {
        let screen = CGRect(x: 10, y: -100, width: 300, height: 200)
        let notch = CGRect(x: 110, y: 80, width: 100, height: 20)
        #expect(ShelfPanelPlacement.frame(visibleFrame: screen, screenFrame: screen, safeTop: 20,
            expanded: true, hardwareNotch: notch) == CGRect(x: 10, y: -100, width: 300, height: 180))
        #expect(ShelfPanelPlacement.frame(visibleFrame: screen, screenFrame: screen, safeTop: 20,
            expanded: false, hardwareNotch: notch) == notch)
    }

    @Test func missingOrInvalidHardwareGeometryDoesNotInventANotch() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let left = CGRect(x: 0, y: 868, width: 620, height: 32)
        let right = CGRect(x: 820, y: 868, width: 620, height: 32)
        for (top, leftArea, rightArea) in [(CGFloat(0), Optional<CGRect>.none, Optional<CGRect>.none),
            (32, nil, Optional(right)), (32, Optional(left), nil),
            (CGFloat.nan, Optional(left), Optional(right)),
            (32, Optional(CGRect(x: 0, y: 868, width: 900, height: 32)), Optional(right))] {
            #expect(ShelfPanelPlacement.hardwareNotch(screenFrame: screen, safeTop: top,
                leftArea: leftArea, rightArea: rightArea) == nil)
        }
        #expect(ShelfPanelPlacement.hardwareNotch(screenFrame: screen, safeTop: 0,
            leftArea: left, rightArea: right) == CGRect(x: 620, y: 868, width: 200, height: 32))
    }

    @Test func hardwareHoverIncludesTheTopEdgeButNotAdjacentMenuItems() {
        let notch = CGRect(x: 650, y: 868, width: 140, height: 32)
        let gallery = CGRect(x: 120, y: 468, width: 1200, height: 400)
        #expect(ShelfPanelPlacement.hardwareHover(at: CGPoint(x: 720, y: 900), notch: notch,
            panelFrame: gallery, expanded: false))
        #expect(!ShelfPanelPlacement.hardwareHover(at: CGPoint(x: 400, y: 890), notch: notch,
            panelFrame: gallery, expanded: true))
        #expect(!ShelfPanelPlacement.hardwareHover(at: CGPoint(x: 720, y: 800), notch: notch,
            panelFrame: gallery, expanded: false))
        #expect(ShelfPanelPlacement.hardwareHover(at: CGPoint(x: 720, y: 800), notch: notch,
            panelFrame: gallery, expanded: true))
        #expect(!ShelfPanelPlacement.hardwareHover(at: CGPoint(x: 720, y: 450), notch: notch,
            panelFrame: gallery, expanded: true))
    }

    @Test func hardwareDockingChoicePersistsWithoutDiscardingMovablePosition() async throws {
        let suite = "shelf-hardware-choice-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: ShelfStore.enabledKey)
        let store = ShelfStore(defaults: defaults, persistence: ShelfPersistence(root: FileManager.default.temporaryDirectory.appendingPathComponent(suite)))
        let controller = ShelfPanelController(store: store, defaults: defaults)
        defer { controller.tearDown(); defaults.removePersistentDomain(forName: suite) }
        #expect(controller.prefersHardwareNotch)
        controller.show()
        controller.move(by: CGPoint(x: 24, y: -48))
        let position = try #require(defaults.dictionary(forKey: ShelfPanelController.positionKey))
        controller.setHardwareDocking(true)
        #expect(controller.prefersHardwareNotch)
        #expect(controller.hasCustomPosition)
        #expect(defaults.dictionary(forKey: ShelfPanelController.positionKey)?["x"] as? Double == position["x"] as? Double)
        controller.setHardwareDocking(false)
        let reloaded = ShelfPanelController(store: store, defaults: defaults)
        defer { reloaded.tearDown() }
        #expect(!reloaded.prefersHardwareNotch)
        #expect(reloaded.hasCustomPosition)
        #expect(await store.flushPersistence())
    }

    @Test func returningDuringTheFoldCancelsThePendingWindowShrink() async throws {
        try await withHoverShelf { controller in
            // Test native hover re-entry on an exposed edge. The camera cutout polls
            // the real system pointer, which is not the synthetic hover used here.
            controller.setEdge(.left)
            controller.show(expanded: false)
            controller.setHovering(true)
            controller.setHovering(false)
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while controller.isExpanded && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(!controller.isExpanded)
            controller.setHovering(true)
            try await Task.sleep(for: .milliseconds(950))
            #expect(controller.isExpanded)
            #expect(!controller.isFolding)
            #expect(controller.panel.frame.height > 100)
            controller.hide()
            #expect(!controller.isFolding)
            #expect(!controller.panel.isVisible)
        }
    }

    @Test func topEdgeRemainsReachableWhenHardwareDockingIsDisabled() async throws {
        try await withHoverShelf { controller in
            controller.setEdge(.top)
            controller.show(expanded: false)
            let frame = controller.panel.frame
            controller.trackPointer(at: CGPoint(x: frame.midX, y: frame.maxY))
            #expect(controller.isExpanded)
            #expect(!controller.prefersHardwareNotch)
        }
    }

    @Test func foldingCanvasDoesNotBecomeAnInvisibleHoverTarget() async throws {
        try await withHoverShelf { controller in
            controller.show(expanded: false)
            controller.setHovering(true)
            controller.show(expanded: false)
            controller.setHovering(false)
            let frame = controller.panel.frame
            controller.trackPointer(at: CGPoint(x: frame.midX, y: frame.minY + 50))
            #expect(!controller.isExpanded)
            controller.trackPointer(at: CGPoint(x: frame.midX, y: frame.maxY - 5))
            #expect(controller.isExpanded)
        }
    }

    @Test func foldingReleasesTheHiddenSearchEditor() async throws {
        try await withHoverShelf { controller in
            controller.show()
            let editor = NSTextView(frame: CGRect(x: 0, y: 0, width: 100, height: 30))
            controller.panel.contentView?.addSubview(editor)
            try #require(controller.panel.makeFirstResponder(editor))
            controller.show(expanded: false)
            #expect(controller.panel.firstResponder !== editor)
        }
    }

    @Test func collapsedShelfDoesNotLeaveAWindowShadow() async throws {
        try await withHoverShelf { controller in
            controller.show(expanded: false)
            #expect(!controller.panel.hasShadow)
            controller.show()
            #expect(controller.panel.hasShadow)
            controller.show(expanded: false)
            #expect(!controller.panel.hasShadow)
        }
    }

    @Test func nativeMoveHandleRespondsToLocalPointerDragging() async throws {
        try await withHoverShelf { controller in
            controller.show()
            let root = try #require(controller.panel.contentView)
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            var handle: NSView?
            while handle == nil && ContinuousClock.now < deadline {
                root.layoutSubtreeIfNeeded()
                handle = shelfMoveHandle(in: root)
                if handle == nil { try await Task.sleep(for: .milliseconds(5)) }
            }
            let view = try #require(handle)
            let before = controller.panel.frame
            let start = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
            for (type, point) in [(NSEvent.EventType.leftMouseDown, start),
                                  (.leftMouseDragged, CGPoint(x: start.x + 32, y: start.y - 24)),
                                  (.leftMouseUp, CGPoint(x: start.x + 32, y: start.y - 24))] {
                let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                                           windowNumber: controller.panel.windowNumber, context: nil,
                                                           eventNumber: 0, clickCount: 1, pressure: 1))
                switch type {
                case .leftMouseDown:
                    view.mouseDown(with: event)
                    #expect(controller.carry == nil) // A press alone must not move or change docking.
                case .leftMouseDragged: view.mouseDragged(with: event)
                default: view.mouseUp(with: event)
                }
            }
            #expect(controller.carry?.isSettling == true)
            #expect(controller.panel.frame == before)
            for _ in 0..<180 { controller.advanceMove(elapsed: 1 / 60) }
            try await Task.sleep(for: .milliseconds(80))
            #expect(controller.carry == nil)
            if let notch = controller.hardwareNotchFrame {
                #expect(controller.panel.frame.midX == notch.midX)
                #expect(controller.panel.frame.maxY == notch.minY)
            } else {
                #expect(abs(controller.panel.frame.minX - before.minX - 32) < 1)
                #expect(controller.panel.frame.maxY == before.maxY)
            }
            #expect(controller.hasCustomPosition)
        }
    }

    @Test func movingTheWindowKeepsTheHandleAtTheSameAnchorWhenFolded() async throws {
        try await withHoverShelf { controller in
            controller.show()
            let screen = try #require(controller.panel.screen)
            let moved = controller.panel.frame.offsetBy(dx: 24, dy: -40)
            try #require(screen.visibleFrame.contains(moved))
            controller.panel.setFrameOrigin(moved.origin)
            controller.show(expanded: false)
            #expect(abs(controller.panel.frame.midX - moved.midX) < 1)
            #expect(controller.panel.frame.maxY == screen.frame.maxY)
            controller.show()
            #expect(abs(controller.panel.frame.midX - moved.midX) < 1)
            #expect(controller.panel.frame.maxY == screen.frame.maxY)
        }
    }

    @Test func savedPositionSurvivesANewControllerAndResetDoesNotTouchItems() async throws {
        let suite = "shelf-panel-position-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: ShelfStore.enabledKey)
        defaults.set(false, forKey: ShelfPanelController.hardwareNotchKey)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let store = ShelfStore(defaults: defaults, persistence: ShelfPersistence(root: root))
        let controller = ShelfPanelController(store: store, defaults: defaults)
        defer {
            controller.tearDown()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let item = ShelfItem(content: .text("movement must not clear shelf items"))
        await store.add([item])
        controller.show()
        controller.setEdge(.right)
        controller.move(by: CGPoint(x: 24, y: -48))
        let moved = controller.panel.frame
        #expect(controller.hasCustomPosition)
        controller.hide()
        // Re-read the saved preference rather than sharing the first controller's state.
        let reloaded = ShelfPanelController(store: store, defaults: defaults)
        defer { reloaded.tearDown() }
        reloaded.show(expanded: false)
        #expect(reloaded.edge == .right)
        #expect(abs(reloaded.panel.frame.maxX - moved.maxX) < 1)
        #expect(abs(reloaded.panel.frame.midY - moved.midY) < 1)
        reloaded.resetPosition()
        #expect(!reloaded.hasCustomPosition)
        #expect(defaults.object(forKey: ShelfPanelController.positionKey) == nil)
        let screen = try #require(reloaded.panel.screen)
        #expect(abs(reloaded.panel.frame.midX - screen.visibleFrame.midX) < 1)
        #expect(reloaded.panel.frame.maxY == screen.frame.maxY)
        #expect(store.entries == [item])
        #expect(await store.flushPersistence())
    }

    @Test func movingToAnEdgeStaysInsideTheUsableDisplay() {
        let screen = CGRect(x: -1512, y: 300, width: 1512, height: 982)
        let visible = CGRect(x: -1512, y: 300, width: 1512, height: 944)
        let left = ShelfPanelPlacement.frame(visibleFrame: visible, screenFrame: screen, safeTop: 38,
                                             expanded: true, anchor: CGPoint(x: -1, y: 2))
        #expect(left == CGRect(x: -1512, y: 850, width: 1200, height: 432))
        let right = ShelfPanelPlacement.frame(visibleFrame: visible, screenFrame: screen, safeTop: 38,
                                              expanded: true, anchor: CGPoint(x: 2, y: -1))
        #expect(right == CGRect(x: -1200, y: 850, width: 1200, height: 432))
        for edge in ShelfEdge.allCases {
            let insets = ShelfPanelPlacement.insets(visibleFrame: visible, screenFrame: screen, edge: edge)
            if edge.isVertical { #expect(insets.top >= 52 && insets.bottom >= 52) }
            let expanded = ShelfPanelPlacement.frame(visibleFrame: visible, screenFrame: screen, safeTop: 38,
                                                      expanded: true, anchor: CGPoint(x: 0.4, y: 0.6), edge: edge)
            let compact = ShelfPanelPlacement.frame(visibleFrame: visible, screenFrame: screen, safeTop: 38,
                                                     expanded: false, anchor: CGPoint(x: 0.4, y: 0.6), edge: edge)
            #expect(screen.contains(expanded))
            #expect(screen.contains(compact))
            switch edge {
            case .top: #expect(expanded.maxY == screen.maxY && compact.maxY == screen.maxY && abs(compact.midX - expanded.midX) < 0.001)
            case .bottom: #expect(expanded.minY == screen.minY && compact.minY == screen.minY && abs(compact.midX - expanded.midX) < 0.001)
            case .left: #expect(expanded.minX == screen.minX && compact.minX == screen.minX && abs(compact.midY - expanded.midY) < 0.001)
            case .right: #expect(expanded.maxX == screen.maxX && compact.maxX == screen.maxX && abs(compact.midY - expanded.midY) < 0.001)
            }
        }
        let small = CGRect(x: 10, y: -100, width: 300, height: 200)
        #expect(ShelfPanelPlacement.frame(visibleFrame: small, screenFrame: small, safeTop: 0,
                                          expanded: true, anchor: CGPoint(x: 0, y: 0)) == small)
    }

    @Test func foldingAfterADisplayResizeKeepsTheClampedAnchor() {
        let screen = CGRect(x: 0, y: 0, width: 1280, height: 800)
        let visible = CGRect(x: 0, y: 50, width: 1280, height: 720)
        // A valid saved anchor on a larger display no longer fits the expanded panel.
        for expanded in [true, false] {
            let frame = ShelfPanelPlacement.frame(visibleFrame: visible, screenFrame: screen, safeTop: 30,
                                                  expanded: expanded, anchor: CGPoint(x: 0.7, y: 0.4))
            #expect(frame.midX == 680)
            #expect(frame.maxY == screen.maxY)
        }
    }

    @Test func optionArrowsMoveShelfButLeaveSearchWordNavigationAlone() throws {
        let panel = ShelfPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        var moves: [CGPoint] = []
        panel.onMoveShelf = { moves.append($0) }
        let right = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .option,
                                                 timestamp: 0, windowNumber: panel.windowNumber, context: nil,
                                                 characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 124))
        #expect(panel.handleKey(right))
        #expect(moves == [CGPoint(x: 24, y: 0)])
        let editor = NSTextView(frame: CGRect(x: 0, y: 0, width: 100, height: 30))
        panel.contentView = editor
        try #require(panel.makeFirstResponder(editor))
        #expect(!panel.handleKey(right))
        #expect(moves.count == 1)
    }

    @Test func invalidSavedPositionFallsBackToTheTopCenter() throws {
        let suite = "shelf-panel-invalid-position-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: ShelfStore.enabledKey)
        defaults.set(["screenID": 1, "x": Double.nan, "y": 0.5], forKey: ShelfPanelController.positionKey)
        let store = ShelfStore(defaults: defaults, persistence: ShelfPersistence(root: FileManager.default.temporaryDirectory.appendingPathComponent(suite)))
        let controller = ShelfPanelController(store: store, defaults: defaults)
        defer { controller.tearDown(); defaults.removePersistentDomain(forName: suite) }
        controller.show(expanded: false)
        #expect(!controller.hasCustomPosition)
        let screen = try #require(controller.panel.screen)
        #expect(abs(controller.panel.frame.midX - screen.visibleFrame.midX) < 1)
    }

    @Test func terminationPreventsMovementAndPositionReset() async throws {
        try await withHoverShelf { controller in
            controller.show()
            controller.move(by: CGPoint(x: 24, y: -48))
            let moved = controller.panel.frame
            #expect(controller.hasCustomPosition)
            #expect(await controller.store.prepareForTermination())
            controller.move(by: CGPoint(x: 24, y: -48))
            controller.resetPosition()
            #expect(controller.panel.frame == moved)
            #expect(controller.hasCustomPosition)
        }
    }

    @Test func leavingHoverReturnsToASmallHandleWithoutLosingShelfItems() async throws {
        try await withHoverShelf { controller in
            let item = ShelfItem(content: .text("keep this item when folded"))
            await controller.store.add([item])
            controller.show(expanded: false)
            #expect(controller.panel.frame.width <= 160)
            #expect(controller.panel.frame.height <= 24)
            let host = try #require(controller.panel.contentView)
            host.mouseEntered(with: try hoverEvent(.mouseEntered, controller))
            #expect(controller.isExpanded)
            #expect(controller.panel.frame.height > 100)
            host.mouseExited(with: try hoverEvent(.mouseExited, controller))
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while (controller.isExpanded || controller.isFolding) && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(!controller.isExpanded)
            #expect(controller.panel.isVisible)
            #expect(controller.panel.frame.width <= 160)
            #expect(controller.panel.frame.height <= 24)
            #expect(controller.store.entries == [item])
        }
    }

    @Test func nativeHoverOpensWithoutTakingFocusAndFoldsAfterLeaving() async throws {
        try await withHoverShelf { controller in
            controller.show(expanded: false)
            let previousKeyWindow = NSApp.keyWindow
            let host = try #require(controller.panel.contentView)
            host.mouseEntered(with: try hoverEvent(.mouseEntered, controller))
            #expect(controller.isExpanded)
            #expect(NSApp.keyWindow === previousKeyWindow)
            #expect(!controller.panel.isKeyWindow)
            host.mouseExited(with: try hoverEvent(.mouseExited, controller))
            #expect(controller.isExpanded)
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while controller.isExpanded && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(!controller.isExpanded)
            #expect(controller.panel.isVisible)
        }
    }

    @Test func hoverReentryCancelsFoldAndExplicitOpenStaysOpen() async throws {
        try await withHoverShelf { controller in
            controller.show(expanded: false)
            let host = try #require(controller.panel.contentView)
            host.mouseEntered(with: try hoverEvent(.mouseEntered, controller))
            host.mouseExited(with: try hoverEvent(.mouseExited, controller))
            try await Task.sleep(for: .milliseconds(300))
            host.mouseEntered(with: try hoverEvent(.mouseEntered, controller))
            try await Task.sleep(for: .milliseconds(300))
            #expect(controller.isExpanded)

            controller.show()
            host.mouseExited(with: try hoverEvent(.mouseExited, controller))
            try await Task.sleep(for: .milliseconds(550))
            #expect(controller.isExpanded)
            controller.show(expanded: false)
            #expect(!controller.isExpanded)
        }
    }

    @Test func hiddenDisabledAndDisposedShelfIgnoreStaleHoverEvents() async throws {
        try await withHoverShelf { controller in
            controller.show(expanded: false)
            let host = try #require(controller.panel.contentView)
            host.mouseEntered(with: try hoverEvent(.mouseEntered, controller))
            host.mouseExited(with: try hoverEvent(.mouseExited, controller))
            controller.hide()
            host.mouseEntered(with: try hoverEvent(.mouseEntered, controller))
            #expect(!controller.panel.isVisible)
            #expect(!controller.isExpanded)

            controller.setEnabled(true)
            host.mouseEntered(with: try hoverEvent(.mouseEntered, controller))
            host.mouseExited(with: try hoverEvent(.mouseExited, controller))
            controller.setEnabled(false)
            host.mouseEntered(with: try hoverEvent(.mouseEntered, controller))
            #expect(!controller.panel.isVisible)
            controller.setEnabled(true)
            try await Task.sleep(for: .milliseconds(550))
            #expect(controller.panel.isVisible)
            #expect(!controller.isExpanded)

            controller.tearDown()
            controller.show()
            host.mouseEntered(with: try hoverEvent(.mouseEntered, controller))
            #expect(!controller.panel.isVisible)
        }
    }

    @Test func takingKeyboardFocusKeepsHoverPreviewOpen() async throws {
        try await withHoverShelf { controller in
            controller.show(expanded: false)
            let host = try #require(controller.panel.contentView)
            host.mouseEntered(with: try hoverEvent(.mouseEntered, controller))
            host.mouseExited(with: try hoverEvent(.mouseExited, controller))
            controller.panel.makeKey()
            #expect(controller.panel.isKeyWindow)
            try await Task.sleep(for: .milliseconds(550))
            #expect(controller.isExpanded)
        }
    }

    @Test func clickingPreviewKeepsItOpenWhenShelfAlreadyHasFocus() async throws {
        try await withHoverShelf { controller in
            controller.show()
            try #require(controller.panel.isKeyWindow)
            controller.show(expanded: false)
            let host = try #require(controller.panel.contentView)
            host.mouseEntered(with: try hoverEvent(.mouseEntered, controller))
            host.mouseExited(with: try hoverEvent(.mouseExited, controller))
            let click = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 20, y: 180),
                                                       modifierFlags: [], timestamp: 0,
                                                       windowNumber: controller.panel.windowNumber, context: nil,
                                                       eventNumber: 0, clickCount: 1, pressure: 1))
            controller.panel.sendEvent(click)
            try await Task.sleep(for: .milliseconds(550))
            #expect(controller.isExpanded)
        }
    }

    @Test func sheetAndTerminationPreventHoverPresentationChanges() async throws {
        try await withHoverShelf { controller in
            controller.show(expanded: false)
            let host = try #require(controller.panel.contentView)
            let sheet = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
            sheet.isReleasedWhenClosed = false
            defer { sheet.close() }
            controller.panel.beginSheet(sheet, completionHandler: nil)
            #expect(!controller.interactionAllowed)
            host.mouseEntered(with: try hoverEvent(.mouseEntered, controller))
            #expect(!controller.isExpanded)
            controller.panel.endSheet(sheet)
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while !controller.interactionAllowed && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            try #require(controller.interactionAllowed)
            host.mouseEntered(with: try hoverEvent(.mouseEntered, controller))
            #expect(controller.isExpanded)
            host.mouseExited(with: try hoverEvent(.mouseExited, controller))
            #expect(await controller.store.prepareForTermination())
            try await Task.sleep(for: .milliseconds(550))
            #expect(controller.isExpanded)
            controller.hide()
            controller.show()
            host.mouseEntered(with: try hoverEvent(.mouseEntered, controller))
            #expect(!controller.panel.isVisible)
        }
    }

    @Test func placementRespectsMenuBarNotchAndNegativeDisplayOrigin() {
        let screen = CGRect(x: -1512, y: 300, width: 1512, height: 982)
        let visible = CGRect(x: -1512, y: 300, width: 1512, height: 944)
        let frame = ShelfPanelPlacement.frame(visibleFrame: visible, screenFrame: screen, safeTop: 38, expanded: true)
        #expect(frame.midX == -756)
        #expect(frame.maxY == screen.maxY)
        #expect(frame.maxY - ShelfPanelPlacement.insets(visibleFrame: visible, screenFrame: screen, edge: .top).top < visible.maxY)
        #expect(screen.contains(frame))
        #expect(frame.width > 400)
        let small = CGRect(x: 10, y: -100, width: 300, height: 200)
        let clamped = ShelfPanelPlacement.frame(visibleFrame: small, screenFrame: small, safeTop: 0, expanded: true)
        #expect(small.contains(clamped))
        #expect(clamped.width <= 300)
    }

    @Test func expandedShelfFitsFourPreviewCardsWithoutCoveringTheMenuBar() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let visible = CGRect(x: 0, y: 25, width: 1440, height: 850)
        let expanded = ShelfPanelPlacement.frame(visibleFrame: visible, screenFrame: screen, safeTop: 25, expanded: true)
        // Four 210-point cards, their spacing, and the notch shoulders must fit.
        let requiredWidth: CGFloat = 4 * 210 + 3 * 16 + 104
        #expect(expanded.width >= requiredWidth)
        #expect(expanded.height < expanded.width / 2)
        #expect(expanded.maxY == screen.maxY)
        #expect(expanded.maxY - ShelfPanelPlacement.insets(visibleFrame: visible, screenFrame: screen, edge: .top).top < visible.maxY)
        #expect(screen.contains(expanded))
        let compact = ShelfPanelPlacement.frame(visibleFrame: visible, screenFrame: screen, safeTop: 25, expanded: false)
        #expect(compact.width < expanded.width)
        #expect(compact.midX == expanded.midX)
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

    @Test func galleryArrowNavigationUsesVisibleItemsAndPreservesSearchEditing() async throws {
        try await withHoverShelf { controller in
            let text = ShelfItem(content: .text("visible text"))
            let second = ShelfItem(content: .text("second text"))
            await controller.store.add([text, second])
            controller.store.selectedID = nil
            let right = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                     windowNumber: controller.panel.windowNumber, context: nil,
                                                     characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 124))
            #expect(controller.panel.handleKey(right))
            #expect(controller.store.selectedID == text.id)
            #expect(controller.panel.handleKey(right))
            #expect(controller.store.selectedID == second.id)
            #expect(controller.panel.handleKey(right))
            #expect(controller.store.selectedID == second.id)
            controller.store.kind = .image
            #expect(controller.panel.handleKey(right))
            #expect(controller.store.selectedID == nil)
            let editor = NSTextView(frame: CGRect(x: 0, y: 0, width: 100, height: 30))
            controller.panel.contentView?.addSubview(editor)
            try #require(controller.panel.makeFirstResponder(editor))
            #expect(!controller.panel.handleKey(right))
            controller.store.kind = nil
            controller.selectItem(text.id)
            #expect(controller.panel.handleKey(right))
            #expect(controller.store.selectedID == second.id)
        }
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
        let controller = ShelfPanelController(store: store, defaults: defaults)
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
        let controller = ShelfPanelController(store: store, defaults: defaults)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ShelfPanelDrop-\(UUID())"))
        defer {
            pasteboard.releaseGlobally()
            controller.tearDown()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }

        await store.start()
        store.setEnabled(true)
        controller.show(expanded: false)

        let pasteboardItem = NSPasteboardItem()
        #expect(pasteboardItem.setString(fixture.absoluteString, forType: .fileURL))
        pasteboard.clearContents()
        #expect(pasteboard.writeObjects([pasteboardItem]))

        let target = try #require(controller.panel.contentView)
        let moveOnlyDrop = ShelfPanelDraggingInfoStub(pasteboard: pasteboard, sourceMask: .move)
        #expect(target.draggingEntered(moveOnlyDrop).isEmpty)
        #expect(target.performDragOperation(moveOnlyDrop) == false)
        #expect(store.entries.isEmpty)
        #expect(!controller.isExpanded)

        let copyDrop = ShelfPanelDraggingInfoStub(pasteboard: pasteboard, sourceMask: .copy)
        #expect(target.draggingEntered(copyDrop) == .copy)
        #expect(controller.isExpanded)
        #expect(target.performDragOperation(copyDrop))
        target.concludeDragOperation(copyDrop)
        let importDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while store.isImporting && ContinuousClock.now < importDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(store.isImporting == false)
        #expect(store.entries.map(\.content) == [.file(fixture)])
        #expect(try Data(contentsOf: fixture) == original)
        try await Task.sleep(for: .milliseconds(550))
        #expect(controller.isExpanded)

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
private func hoverEvent(_ type: NSEvent.EventType, _ controller: ShelfPanelController) throws -> NSEvent {
    try #require(NSEvent.enterExitEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                                      windowNumber: controller.panel.windowNumber, context: nil,
                                      eventNumber: 0, trackingNumber: 0, userData: nil))
}

@MainActor
private func shelfMoveHandle(in view: NSView) -> NSView? {
    if view.accessibilityIdentifier() == "topShelf.move" { return view }
    for child in view.subviews {
        if let found = shelfMoveHandle(in: child) { return found }
    }
    return nil
}

@MainActor
private func withHoverShelf(_ test: (ShelfPanelController) async throws -> Void) async throws {
    let suite = "shelf-panel-hover-\(UUID())"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.set(true, forKey: ShelfStore.enabledKey)
    defaults.set(false, forKey: "topShelf.hardwareNotch.v1")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("shelf-panel-hover-\(UUID())")
    let store = ShelfStore(defaults: defaults, persistence: ShelfPersistence(root: root))
    let controller = ShelfPanelController(store: store, defaults: defaults)
    defer {
        controller.tearDown()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
    do { try await test(controller) }
    catch { _ = await store.flushPersistence(); throw error }
    #expect(await store.flushPersistence())
}

@MainActor
// The macOS 15 SDK exposes nonisolated NSDraggingInfo requirements. This
// main-actor-only fixture needs the compatibility conformance on Xcode 16.4.
private final class ShelfPanelDraggingInfoStub: NSObject, @preconcurrency NSDraggingInfo {
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
