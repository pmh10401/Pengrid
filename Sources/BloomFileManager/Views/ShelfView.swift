import SwiftUI
import AppKit

struct ShelfView: View {
    let controller: ShelfPanelController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var surfaceStyle: ShelfSurfaceStyle { controller.surfaceStyle.resolved(reduceTransparency: reduceTransparency) }

    var body: some View {
        ZStack(alignment: controller.edge.alignment) {
            if controller.isExpanded || controller.isFolding {
                ShelfContentsView(controller: controller)
                    .padding(controller.contentInsets)
                    .frame(width: controller.expandedSize.width, height: controller.expandedSize.height)
                    .opacity(controller.isExpanded ? 1 : 0)
                    .offset(x: controller.isExpanded || reduceMotion ? 0 : controller.edge.outward.width * 12,
                            y: controller.isExpanded || reduceMotion ? 0 : controller.edge.outward.height * 12)
                    .animation(reduceMotion ? nil : ShelfMotion.contents, value: controller.isExpanded)
                    .transition(.opacity.animation(reduceMotion ? nil : .easeInOut(duration: 0.16)))
                    .allowsHitTesting(controller.isExpanded)
                    .accessibilityHidden(!controller.isExpanded)
            }
            if !controller.isHardwareDocked {
                ShelfCollapsedView(controller: controller)
                    .frame(width: controller.collapsedSize.width, height: controller.collapsedSize.height)
                    .opacity(controller.isExpanded || controller.isFolding ? 0 : 1)
                    .allowsHitTesting(!controller.isExpanded && !controller.isFolding)
                    .accessibilityHidden(controller.isExpanded || controller.isFolding)
            }
        }
        .frame(width: controller.isExpanded ? controller.expandedSize.width : controller.collapsedSize.width,
               height: controller.isExpanded ? controller.expandedSize.height : controller.collapsedSize.height,
               alignment: controller.edge.alignment)
        .background {
            ZStack {
                Color.black.opacity(surfaceStyle != .solid && controller.isExpanded ? 0 : 1)
                if #available(macOS 26, *), surfaceStyle != .solid, controller.isExpanded || controller.isFolding {
                    Color.clear
                        .glassEffect(surfaceStyle == .darkGlass ? .clear : .regular, in: Rectangle())
                        .background {
                            if surfaceStyle == .darkGlass { Color.black.opacity(0.6) }
                        }
                        .opacity(controller.isExpanded ? 1 : 0)
                }
            }
        }
        .clipShape(ShelfNotchShape(shoulder: controller.isExpanded ? 32 : 4, edge: controller.edge))
        .animation(reduceMotion ? nil : ShelfMotion.unfold, value: controller.isExpanded)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: controller.edge.alignment)
        .preferredColorScheme(surfaceStyle == .glass ? nil : .dark)
    }
}

private enum ShelfMotion {
    // Match PenguinNotch's soft fold and slightly quicker content arrival.
    static let unfold = Animation.spring(response: 0.62, dampingFraction: 0.72)
    static let contents = Animation.spring(response: 0.48, dampingFraction: 0.8)
}

private struct ShelfNotchShape: Shape {
    var shoulder: CGFloat
    var edge: ShelfEdge = .top
    var animatableData: CGFloat {
        get { shoulder }
        set { shoulder = newValue }
    }
    func path(in rect: CGRect) -> Path {
        let bounds = rect
        let rect = CGRect(origin: .zero, size: edge.isVertical ? CGSize(width: rect.height, height: rect.width) : rect.size)
        let inset = min(shoulder, rect.width / 4, rect.height / 4)
        let bottom = min(26, rect.height / 4)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - inset, y: rect.minY + inset),
                          control: CGPoint(x: rect.maxX - inset, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.maxY - bottom))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - inset - bottom, y: rect.maxY),
                          control: CGPoint(x: rect.maxX - inset, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + inset + bottom, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX + inset, y: rect.maxY - bottom),
                          control: CGPoint(x: rect.minX + inset, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + inset, y: rect.minY + inset))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY),
                          control: CGPoint(x: rect.minX + inset, y: rect.minY))
        path.closeSubpath()
        let transform: CGAffineTransform
        switch edge {
        case .top: transform = .identity
        case .bottom: transform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: bounds.height)
        case .left: transform = CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        case .right: transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: bounds.width, ty: 0)
        }
        return path.applying(transform).offsetBy(dx: bounds.minX, dy: bounds.minY)
    }
}

// Only this light, click-through border surface redraws during movement.
struct ShelfCarryView: View {
    let controller: ShelfPanelController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let motion = controller.carry {
            let track = motion.track
            let stretch = reduceMotion ? 0 : min(abs(motion.velocity) / 2600, 0.14)
            let length = 112 * (1 + stretch)
            let depth = 18 / (1 + stretch * 0.5)
            let place = track.location(at: motion.position)
            let inward = place.edge.outward
            let point = CGPoint(x: place.point.x - track.frame.minX - inward.width * depth / 2,
                                y: track.frame.maxY - place.point.y - inward.height * depth / 2)
            ZStack(alignment: .topLeading) {
                Path { path in
                    for step in 0...40 {
                        let point = track.location(at: motion.position - length / 2 + length * CGFloat(step) / 40).point
                        let local = CGPoint(x: point.x - track.frame.minX, y: track.frame.maxY - point.y)
                        if step == 0 { path.move(to: local) } else { path.addLine(to: local) }
                    }
                }
                .stroke(.black, style: StrokeStyle(lineWidth: depth * 2, lineCap: .round, lineJoin: .round))
                HStack(spacing: 3) {
                    ForEach(0..<3) { _ in
                        VStack(spacing: 3) {
                            Circle().frame(width: 2, height: 2)
                            Circle().frame(width: 2, height: 2)
                        }
                    }
                }
                .foregroundStyle(.white.opacity(0.8))
                .rotationEffect(.degrees(place.edge.isVertical ? 90 : 0))
                .position(point)
            }
            .frame(width: track.frame.width, height: track.frame.height)
            .clipped()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

private struct ShelfCollapsedView: View {
    let controller: ShelfPanelController

    var body: some View {
        Button { controller.show() } label: {
            Capsule()
                .fill(.white.opacity(0.65))
                .frame(width: controller.edge.isVertical ? 3 : 32, height: controller.edge.isVertical ? 32 : 3)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(AppText.format("Open Top Shelf: %ld items", controller.store.entries.count))
        .accessibilityIdentifier("topShelf.open")
        .accessibilityHint(AppText.text("Hover or click this handle to open the shelf."))
        .help(AppText.text("Hover or click to open Top Shelf. Drop files, text, or images here to keep them."))
    }
}

private struct ShelfContentsView: View {
    let controller: ShelfPanelController
    @Bindable private var store: ShelfStore
    @State private var confirmingClear = false
    @State private var galleryPosition = ScrollPosition(idType: UUID.self)

    init(controller: ShelfPanelController) {
        self.controller = controller
        store = controller.store
    }

    private var isVertical: Bool { controller.edge.isVertical }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header.fixedSize(horizontal: false, vertical: true)
            categories.fixedSize(horizontal: false, vertical: true)
            gallery
            footer.fixedSize(horizontal: false, vertical: true)
        }
        .confirmationDialog(AppText.text("Clear all shelf items? Original files and the system clipboard will not be changed."), isPresented: $confirmingClear, titleVisibility: .visible) {
            Button(AppText.text("Clear Shelf"), role: .destructive) { store.clear() }
        }
    }

    private var header: some View {
        let layout = isVertical ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField(AppText.text("Search…"), text: $store.query,
                          prompt: Text(AppText.text("Search…")).foregroundStyle(.secondary))
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .accessibilityLabel(AppText.text("Search shelf (including Korean initials)"))
                    .help(AppText.text("Search filenames and text, including Korean initials"))
                    .accessibilityIdentifier("topShelf.search")
            }
            HStack(spacing: 12) {
                ShelfMoveHandle(controller: controller)
                    .frame(width: 34, height: 34)
                    .background(.primary.opacity(0.1), in: Circle())
                    .contextMenu {
                        ForEach(ShelfEdge.allCases, id: \.self) { edge in
                            Button(AppText.format("Dock to %@ Edge", AppText.text(edge.title))) { controller.setEdge(edge) }
                        }
                        Divider()
                        Button(AppText.text("Use Hardware Notch")) { controller.setHardwareDocking(true) }
                        Button(AppText.text("Reset Shelf Position")) { controller.resetPosition() }
                    }
                shelfAction("Keep Shelf Open", symbol: controller.isPinned ? "pin.fill" : "pin") { controller.show() }
                    .help(AppText.text(controller.isPinned ? "Shelf stays open until you collapse or hide it" : "Keep the hover preview open"))
                shelfAction("Open Pengrid", symbol: "rectangle.on.rectangle") {
                    if controller.interactionAllowed { controller.openMain() }
                }
                shelfAction("Collapse Shelf", symbol: controller.edge.collapseSymbol) { controller.show(expanded: false) }
                shelfAction("Hide Shelf", symbol: "xmark") { controller.hide() }
            }
            .fixedSize()
        }
    }

    private var categories: some View {
        Group {
            if isVertical {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) { categoryButtons }
            } else {
                ScrollView(.horizontal) { HStack(spacing: 10) { categoryButtons } }
                    .scrollIndicators(.hidden)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(AppText.text("Shelf categories"))
    }

    @ViewBuilder private var categoryButtons: some View {
        category("All", kind: nil)
        category("Files", kind: .file)
        category("Text", kind: .text)
        category("Images", kind: .image)
    }

    private var gallery: some View {
        GeometryReader { geometry in
            Group {
                ScrollView(isVertical ? .vertical : .horizontal) {
                    if isVertical {
                        LazyVStack(spacing: 16) {
                            ForEach(store.filteredEntries) { item in
                                ShelfItemCard(item: item, controller: controller,
                                    size: CGSize(width: geometry.size.width, height: 180)).id(item.id)
                            }
                        }
                        .scrollTargetLayout()
                        .padding(.vertical, 4)
                    } else {
                        LazyHStack(spacing: 16) {
                            ForEach(store.filteredEntries) { item in
                                ShelfItemCard(item: item, controller: controller,
                                    size: CGSize(width: 210, height: min(180, max(0, geometry.size.height - 8)))).id(item.id)
                            }
                        }
                        .scrollTargetLayout()
                        .padding(.vertical, 4)
                    }
                }
                .scrollPosition($galleryPosition)
                .accessibilityIdentifier("topShelf.gallery")
                .onChange(of: store.selectedID, initial: true) { _, id in
                    if let id { galleryPosition.scrollTo(id: id, anchor: .center) }
                }
                .onChange(of: isVertical) {
                    if let id = store.selectedID { galleryPosition.scrollTo(id: id, anchor: .center) }
                }
                .overlay {
                    if store.filteredEntries.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "tray.and.arrow.down").font(.title).foregroundStyle(.mint)
                            Text(AppText.text(store.isRestoring ? "Restoring shelf…" : store.query.isEmpty && store.kind == nil ? "Drop files, text, or images here" : "No matching items"))
                                .font(.callout)
                            Text(AppText.text("Clipboard is read only when you choose Import."))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .multilineTextAlignment(.center)
                        .allowsHitTesting(false)
                    }
                }
            }
        }
        .frame(maxHeight: isVertical ? .infinity : 190)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let error = store.errorMessage {
                Text(error).font(.caption).foregroundStyle(.orange).lineLimit(2)
            }
            if let error = store.persistenceError {
                HStack {
                    Text(error).font(.caption).foregroundStyle(.orange).lineLimit(3)
                    Button(AppText.text("Retry")) { store.retryPersistence() }
                }
            }
            let layout = isVertical ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10)) : AnyLayout(HStackLayout())
            layout {
                HStack(spacing: 12) {
                    Button(AppText.text("Import Clipboard"), systemImage: "clipboard") { controller.importClipboard() }
                        .disabled(store.isImporting || store.isRestoring || store.isPreparingTermination)
                        .accessibilityIdentifier("topShelf.import")
                    Button(AppText.text("Copy"), systemImage: "doc.on.doc") { controller.copySelection() }
                        .disabled(store.selectedID == nil)
                }
                HStack {
                    if !isVertical { Spacer(minLength: 0) }
                    Text("\(store.entries.count)/\(ShelfItem.maximumItemCount)")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    if isVertical { Spacer(minLength: 0) }
                    Button(AppText.text("Clear…")) { confirmingClear = true }
                        .disabled(store.entries.isEmpty || store.isPreparingTermination)
                }
            }
            .buttonStyle(.borderless)
            HStack {
                Text(AppText.text(store.retention == .clearOnQuit ? "Cleared on quit · originals stay untouched" : "Kept on this Mac · originals stay untouched"))
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if store.isImporting || store.isSearching || store.isSaving {
                    ProgressView().controlSize(.mini).accessibilityLabel(AppText.text("Updating shelf"))
                }
            }
            if let operations = controller.operationController,
               operations.activeJob != nil || !operations.queuedJobs.isEmpty || operations.isQueueBlockedByRecovery || operations.operationHistory.first?.state == .failed {
                ShelfProgressView(controller: operations)
            }
        }
    }

    private func shelfAction(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15, weight: .medium))
                .frame(width: 34, height: 34)
                .background(.primary.opacity(0.1), in: Circle())
        }
        .buttonStyle(.plain).accessibilityLabel(AppText.text(title)).help(AppText.text(title))
    }

    private func category(_ title: String, kind: ShelfContentKind?) -> some View {
        let selected = store.kind == kind
        let count = kind.map { value in store.entries.filter { $0.kind == value }.count } ?? store.entries.count
        return Button { store.kind = kind } label: {
            HStack(spacing: 8) {
                Text(AppText.text(title))
                Text(count.formatted()).monospacedDigit().opacity(selected ? 0.6 : 0.5)
            }
            .font(.callout)
            .padding(.horizontal, isVertical ? 10 : 18).padding(.vertical, isVertical ? 8 : 11)
            .frame(maxWidth: isVertical ? .infinity : nil)
            .foregroundStyle(selected ? Color(nsColor: .textBackgroundColor) : .primary)
            .background(selected ? Color.primary : Color.primary.opacity(0.1), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(AppText.format("%@, %ld items", AppText.text(title), count))
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityIdentifier("topShelf.category.\(kind?.rawValue ?? "all")")
    }
}

private struct ShelfItemCard: View {
    let item: ShelfItem
    let controller: ShelfPanelController
    let size: CGSize
    @State private var thumbnail: CGImage?
    var body: some View {
        Button {
            controller.selectItem(item.id)
        } label: {
            ZStack(alignment: .bottomLeading) {
                preview
                LinearGradient(colors: [.clear, .black.opacity(0.9)], startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 5) {
                    if item.kind != .text { Text(item.displayName).font(.callout).lineLimit(1) }
                    HStack(spacing: 6) {
                        Image(systemName: symbol)
                        Text(item.createdAt, format: .relative(presentation: .numeric, unitsStyle: .abbreviated)).lineLimit(1)
                        Spacer(minLength: 0)
                        if item.kind != .file {
                            Text(ByteCountFormatter.string(fromByteCount: Int64(item.byteCount), countStyle: .file)).lineLimit(1)
                        }
                    }
                    .font(.caption2).foregroundStyle(.white.opacity(0.75))
                }
                .padding(14).padding(.trailing, 24)
            }
            .frame(width: size.width, height: size.height)
            .background(Color(white: 0.12))
            .clipShape(.rect(cornerRadius: 20))
            .overlay {
                RoundedRectangle(cornerRadius: 20).strokeBorder(controller.store.selectedID == item.id ? .mint : .white.opacity(0.15), lineWidth: controller.store.selectedID == item.id ? 2 : 1)
            }
            .contentShape(.rect(cornerRadius: 20))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.displayName.isEmpty ? AppText.text("Empty text") : item.displayName)
        .accessibilityValue(item.kind.rawValue)
        .accessibilityAddTraits(controller.store.selectedID == item.id ? [.isSelected] : [])
        .help(AppText.text("Select this item, then Copy (⌘C). Use the arrow handle to drag a copy."))
        .overlay(alignment: .bottomTrailing) {
            ShelfDragHandle(item: item, controller: controller).frame(width: 28, height: 30).padding(8)
        }
        .overlay(alignment: .topTrailing) {
            Button(AppText.text("Remove from Shelf"), systemImage: "minus.circle") {
                if controller.interactionAllowed { controller.store.remove(item.id) }
            }
            .labelStyle(.iconOnly).buttonStyle(.plain)
            .padding(8).background(.black.opacity(0.65), in: Circle()).padding(8)
            .help(AppText.text("Remove from shelf (keep original)"))
        }
        .task(id: item.id) {
            guard item.kind == .image else { return }
            let value = await ShelfThumbnailRenderer.shared.image(for: item)
            if !Task.isCancelled { thumbnail = value }
        }
        .environment(\.colorScheme, .dark)
    }

    private var symbol: String { item.kind == .file ? "doc" : item.kind == .text ? "text.alignleft" : "photo" }

    @ViewBuilder private var preview: some View {
        switch item.content {
        case .image:
            if let thumbnail {
                Image(decorative: thumbnail, scale: 1).resizable().scaledToFit()
                    .frame(width: size.width, height: size.height).clipped()
            } else { Image(systemName: "photo").font(.largeTitle).frame(maxWidth: .infinity, maxHeight: .infinity) }
        case let .text(value):
            Text(String(value.prefix(512))).font(.body).lineLimit(6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(16).padding(.top, 20).padding(.bottom, 28)
        case .file:
            VStack(spacing: 10) {
                Image(systemName: "doc.fill").font(.system(size: 42)).foregroundStyle(.mint)
                Text(AppText.text("File reference · copy only")).font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity).padding(.bottom, 30)
        }
    }
}

private struct ShelfProgressView: View {
    let controller: FileOperationController
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if controller.isQueueBlockedByRecovery {
                Label(AppText.text("Recovery needs attention in Pengrid"), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            } else if let job = controller.activeJob {
                Text("\(job.title) · \(job.state.label)").lineLimit(1)
                if let progress = job.progress,
                   let fraction = FileOperationCenterProgressPresentation.determinateFraction(for: progress) {
                    ProgressView(value: fraction).tint(.mint).accessibilityLabel(AppText.text("Operation progress"))
                    Text(progress.detail).foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.mini).accessibilityLabel(AppText.text("Operation in progress"))
                }
            } else if let recent = controller.operationHistory.first, recent.state == .failed {
                Label(AppText.text("Last operation failed. Open Pengrid for details."), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            } else {
                Text(AppText.text("No active file operation")).foregroundStyle(.secondary)
            }
            if !controller.queuedJobs.isEmpty { Text(AppText.format("%ld queued", controller.queuedJobs.count)) }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.primary.opacity(0.06), in: .rect(cornerRadius: 12))
    }
}

struct ShelfSettingsView: View {
    let controller: ShelfPanelController
    var body: some View {
        Form {
            Toggle(AppText.text("Enable Top Shelf"), isOn: Binding(get: { controller.store.isEnabled }, set: { controller.setEnabled($0) }))
            Toggle(AppText.text("Use Hardware Notch"), isOn: Binding(get: { controller.prefersHardwareNotch }, set: { controller.setHardwareDocking($0) }))
                .disabled(controller.store.isPreparingTermination)
                .accessibilityIdentifier("topShelf.hardwareNotch")
            Picker(AppText.text("Shelf Appearance"), selection: Binding(get: { controller.surfaceStyle }, set: { controller.setSurfaceStyle($0) })) {
                ForEach(ShelfSurfaceStyle.allCases, id: \.self) { Text(AppText.text($0.title)).tag($0) }
            }
            .disabled(controller.store.isPreparingTermination)
            .accessibilityIdentifier("topShelf.appearance")
            Text(AppText.text("Liquid Glass follows this Mac’s appearance. Dark Glass stays dark. The folded notch stays black; macOS versions before 26 and Reduce Transparency use solid black."))
                .font(.caption).foregroundStyle(.secondary)
            Text(AppText.text("Hover over the camera notch to reveal the shelf. Drag the six-dot grip along any screen edge; it flows around corners and docks when released. Release near the camera notch to dock there again. Escape cancels a move."))
                .font(.caption).foregroundStyle(.secondary)
            Picker(AppText.text("Dock to Screen Edge"), selection: Binding(get: { controller.edge }, set: { controller.setEdge($0) })) {
                ForEach(ShelfEdge.allCases, id: \.self) { Text(AppText.text($0.title)).tag($0) }
            }
            .disabled(controller.store.isPreparingTermination)
            Picker(AppText.text("When Pengrid quits"), selection: Binding(get: { controller.store.retention }, set: { controller.store.setRetention($0) })) {
                ForEach(ShelfRetention.allCases, id: \.self) { Text(AppText.text($0.title)).tag($0) }
            }
            .disabled(controller.store.isRestoring || controller.store.isPreparingTermination)
            Text(AppText.text("Clear on Quit is the default. Keep Between Launches stores manually added text, images, and file references locally on this Mac. This storage is not encrypted by Pengrid or synced to the cloud."))
                .font(.caption).foregroundStyle(.secondary)
            Text(AppText.text("Switching to Clear on Quit removes the saved snapshot but keeps current shelf items until quit. Turning the shelf off clears its items. Original files and the system clipboard are never deleted."))
                .font(.caption).foregroundStyle(.secondary)
            if let error = controller.store.persistenceError {
                Text(error).foregroundStyle(.orange)
                Button(AppText.text("Retry Storage")) { controller.store.retryPersistence() }
            }
            HStack {
                Button(AppText.text("Show Shelf")) { controller.show() }.disabled(!controller.store.isEnabled)
                Button(AppText.text("Reset Shelf Position")) { controller.resetPosition() }
                    .disabled(!controller.hasCustomPosition || controller.store.isPreparingTermination)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 560)
    }
}

struct ShelfStartup: ViewModifier {
    let controller: ShelfPanelController
    @Environment(\.openWindow) private var openWindow
    func body(content: Content) -> some View {
        content.task {
            controller.openMain = { NSApp.activate(ignoringOtherApps: true); openWindow(id: "pengrid-main") }
            await controller.store.start()
            controller.show(expanded: false)
        }
    }
}

private struct ShelfMoveHandle: NSViewRepresentable {
    let controller: ShelfPanelController
    func makeNSView(context: Context) -> ShelfMoveView { ShelfMoveView() }
    func updateNSView(_ view: ShelfMoveView, context: Context) { view.controller = controller }
}

@MainActor
private final class ShelfMoveView: NSView {
    weak var controller: ShelfPanelController?
    private var dragStart: CGPoint?
    override var acceptsFirstResponder: Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        toolTip = AppText.text("Drag the grip along the screen border, including around corners. Release to dock; Escape cancels. Outside search, ⌥Arrow keys adjust along the edge. Right-click to choose an edge.")
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(AppText.text("Move Shelf"))
        setAccessibilityHelp(toolTip)
        setAccessibilityIdentifier("topShelf.move")
    }
    required init?(coder: NSCoder) { nil }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.8).setFill()
        for x in [-5.0, 0, 5] {
            for y in [-2.5, 2.5] {
                NSBezierPath(ovalIn: CGRect(x: bounds.midX + x - 1, y: bounds.midY + y - 1, width: 2, height: 2)).fill()
            }
        }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        dragStart = window.convertPoint(toScreen: event.locationInWindow)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        let point = window.convertPoint(toScreen: event.locationInWindow)
        if let start = dragStart {
            guard hypot(point.x - start.x, point.y - start.y) >= 4 else { return }
            dragStart = nil
            guard controller?.beginMove(at: start) == true else { return }
        }
        controller?.updateMove(to: point)
    }
    override func mouseUp(with event: NSEvent) {
        if dragStart != nil { window?.makeFirstResponder(self) }
        dragStart = nil
        controller?.endMove()
    }
    override func accessibilityPerformPress() -> Bool {
        guard let controller, controller.interactionAllowed, !controller.store.isPreparingTermination else { return false }
        controller.show()
        return controller.panel.makeFirstResponder(self)
    }
}

private struct ShelfDragHandle: NSViewRepresentable {
    let item: ShelfItem
    let controller: ShelfPanelController
    func makeNSView(context: Context) -> ShelfDragView { ShelfDragView() }
    func updateNSView(_ view: ShelfDragView, context: Context) { view.item = item; view.controller = controller }
}

@MainActor
private final class ShelfDragView: NSImageView, NSDraggingSource {
    var item: ShelfItem?
    weak var controller: ShelfPanelController?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        image = NSImage(systemSymbolName: "arrow.up.right.square", accessibilityDescription: AppText.text("Drag a copy"))
        toolTip = AppText.text("Drag a copy. Text and images require a destination accepting their native type.")
        setAccessibilityLabel(AppText.text("Drag a copy; use Copy for keyboard access"))
    }
    required init?(coder: NSCoder) { nil }
    override func mouseDown(with event: NSEvent) {
        if let item { controller?.selectItem(item.id) }
    }
    override func mouseDragged(with event: NSEvent) {
        guard let item, let controller, controller.interactionAllowed, !controller.store.isPreparingTermination else { return }
        do {
            let dragging = NSDraggingItem(pasteboardWriter: try ShelfClipboard.writer(for: item))
            dragging.setDraggingFrame(bounds, contents: image)
            beginDraggingSession(with: [dragging], event: event, source: self)
        } catch { controller.store.errorMessage = "This item cannot be dragged. Its original file may no longer exist." }
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
}
