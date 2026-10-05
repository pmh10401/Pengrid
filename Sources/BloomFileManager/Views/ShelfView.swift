import SwiftUI
import AppKit

struct ShelfView: View {
    let controller: ShelfPanelController
    var body: some View {
        VStack(spacing: 10) {
            if controller.isExpanded {
                ShelfContentsView(controller: controller)
            } else {
                ShelfCollapsedView(controller: controller)
            }
        }
        .padding(.horizontal, controller.isExpanded ? 52 : 10)
        .padding(.vertical, controller.isExpanded ? 18 : 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
        .compositingGroup()
        .clipShape(ShelfNotchShape(shoulder: controller.isExpanded ? 32 : 8))
        .preferredColorScheme(.dark)
    }
}

private struct ShelfNotchShape: Shape {
    var shoulder: CGFloat
    func path(in rect: CGRect) -> Path {
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
        return path
    }
}

private struct ShelfCollapsedView: View {
    let controller: ShelfPanelController

    private func count(_ kind: ShelfContentKind) -> Int {
        controller.store.entries.filter { $0.kind == kind }.count
    }

    var body: some View {
        Button { controller.show() } label: {
            HStack(spacing: 22) {
                category("doc", count: count(.file), color: .mint)
                category("text.alignleft", count: count(.text), color: .cyan)
                category("photo", count: count(.image), color: .orange)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open Top Shelf: \(count(.file)) files, \(count(.text)) text items, \(count(.image)) images")
        .accessibilityIdentifier("topShelf.open")
        .help("Open Top Shelf. Drop files, text, or images here to keep them.")
    }

    private func category(_ symbol: String, count: Int, color: Color) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .frame(width: 36, height: 36)
                .background { Circle().stroke(color, lineWidth: 2) }
            Text(count.formatted()).font(.caption.monospacedDigit())
        }
        .foregroundStyle(.white)
        .accessibilityHidden(true)
    }
}

private struct ShelfContentsView: View {
    let controller: ShelfPanelController
    @Bindable private var store: ShelfStore
    @State private var confirmingClear = false

    init(controller: ShelfPanelController) {
        self.controller = controller
        store = controller.store
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                    TextField("Search…", text: $store.query,
                              prompt: Text("Search…").foregroundStyle(.white.opacity(0.5)))
                        .textFieldStyle(.plain)
                        .font(.title3)
                        .accessibilityLabel("Search shelf (including Korean initials)")
                        .help("Search filenames and text, including Korean initials")
                        .accessibilityIdentifier("topShelf.search")
                    shelfAction("Keep Shelf Open", symbol: controller.isPinned ? "pin.fill" : "pin") { controller.show() }
                        .help(controller.isPinned ? "Shelf stays open until you collapse or hide it" : "Keep the hover preview open")
                    shelfAction("Open Pengrid", symbol: "rectangle.on.rectangle") {
                        if controller.interactionAllowed { controller.openMain() }
                    }
                    shelfAction("Collapse Shelf", symbol: "chevron.up") { controller.show(expanded: false) }
                    shelfAction("Hide Shelf", symbol: "xmark") { controller.hide() }
                }
                ScrollView(.horizontal) {
                    HStack(spacing: 10) {
                        category("All", kind: nil)
                        category("Files", kind: .file)
                        category("Text", kind: .text)
                        category("Images", kind: .image)
                    }
                }
                .scrollIndicators(.hidden)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Shelf categories")
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 16) {
                            ForEach(store.filteredEntries) { item in
                                ShelfItemCard(item: item, controller: controller).id(item.id)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(height: 190)
                    .onChange(of: store.selectedID) { _, id in
                        if let id { proxy.scrollTo(id, anchor: .center) }
                    }
                    .overlay {
                        if store.filteredEntries.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: "tray.and.arrow.down").font(.title).foregroundStyle(.mint)
                                Text(store.isRestoring ? "Restoring shelf…" : store.query.isEmpty && store.kind == nil ? "Drop files, text, or images here" : "No matching items")
                                    .font(.callout)
                                Text("Clipboard is read only when you choose Import.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .allowsHitTesting(false)
                        }
                    }
                }
                if let error = store.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.orange).lineLimit(2)
                }
                if let error = store.persistenceError {
                    HStack {
                        Text(error).font(.caption).foregroundStyle(.orange).lineLimit(3)
                        Button("Retry") { store.retryPersistence() }
                    }
                }
                HStack {
                    Button("Import Clipboard", systemImage: "clipboard") { controller.importClipboard() }
                        .disabled(store.isImporting || store.isRestoring || store.isPreparingTermination)
                        .accessibilityIdentifier("topShelf.import")
                    Button("Copy", systemImage: "doc.on.doc") { controller.copySelection() }
                        .disabled(store.selectedID == nil)
                    Spacer()
                    Text("\(store.entries.count)/\(ShelfItem.maximumItemCount)")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Button("Clear…") { confirmingClear = true }
                        .disabled(store.entries.isEmpty || store.isPreparingTermination)
                }
                .buttonStyle(.borderless)
                HStack {
                    Text(store.retention == .clearOnQuit ? "Cleared on quit · originals stay untouched" : "Kept on this Mac · originals stay untouched")
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    if store.isImporting || store.isSearching || store.isSaving {
                        ProgressView().controlSize(.mini).accessibilityLabel("Updating shelf")
                    }
                }
                if let operations = controller.operationController,
                   operations.activeJob != nil || !operations.queuedJobs.isEmpty || operations.isQueueBlockedByRecovery || operations.operationHistory.first?.state == .failed {
                    ShelfProgressView(controller: operations)
                }
            }
        }
        .confirmationDialog("Clear all shelf items? Original files and the system clipboard will not be changed.", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("Clear Shelf", role: .destructive) { store.clear() }
        }
    }

    private func shelfAction(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15, weight: .medium))
                .frame(width: 34, height: 34)
                .background(.white.opacity(0.12), in: Circle())
        }
        .buttonStyle(.plain).accessibilityLabel(title).help(title)
    }

    private func category(_ title: String, kind: ShelfContentKind?) -> some View {
        let selected = store.kind == kind
        let count = kind.map { value in store.entries.filter { $0.kind == value }.count } ?? store.entries.count
        return Button { store.kind = kind } label: {
            HStack(spacing: 8) {
                Text(title)
                Text(count.formatted()).monospacedDigit().opacity(selected ? 0.6 : 0.5)
            }
            .font(.callout)
            .padding(.horizontal, 18).padding(.vertical, 11)
            .foregroundStyle(selected ? .black : .white.opacity(0.8))
            .background(selected ? .white : .white.opacity(0.1), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(count) items")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityIdentifier("topShelf.category.\(kind?.rawValue ?? "all")")
    }
}

private struct ShelfItemCard: View {
    let item: ShelfItem
    let controller: ShelfPanelController
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
            .frame(width: 210, height: 180)
            .background(.white.opacity(0.12))
            .clipShape(.rect(cornerRadius: 20))
            .overlay {
                RoundedRectangle(cornerRadius: 20).strokeBorder(controller.store.selectedID == item.id ? .mint : .white.opacity(0.15), lineWidth: controller.store.selectedID == item.id ? 2 : 1)
            }
            .contentShape(.rect(cornerRadius: 20))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.displayName.isEmpty ? "Empty text" : item.displayName)
        .accessibilityValue(item.kind.rawValue)
        .accessibilityAddTraits(controller.store.selectedID == item.id ? [.isSelected] : [])
        .help("Select this item, then Copy (⌘C). Use the arrow handle to drag a copy.")
        .overlay(alignment: .bottomTrailing) {
            ShelfDragHandle(item: item, controller: controller).frame(width: 28, height: 30).padding(8)
        }
        .overlay(alignment: .topTrailing) {
            Button("Remove from Shelf", systemImage: "minus.circle") {
                if controller.interactionAllowed { controller.store.remove(item.id) }
            }
            .labelStyle(.iconOnly).buttonStyle(.plain)
            .padding(8).background(.black.opacity(0.65), in: Circle()).padding(8)
            .help("Remove from shelf (keep original)")
        }
        .task(id: item.id) {
            guard item.kind == .image else { return }
            let value = await ShelfThumbnailRenderer.shared.image(for: item)
            if !Task.isCancelled { thumbnail = value }
        }
    }

    private var symbol: String { item.kind == .file ? "doc" : item.kind == .text ? "text.alignleft" : "photo" }

    @ViewBuilder private var preview: some View {
        switch item.content {
        case .image:
            if let thumbnail {
                Image(decorative: thumbnail, scale: 1).resizable().scaledToFit()
                    .frame(width: 210, height: 180).clipped()
            } else { Image(systemName: "photo").font(.largeTitle).frame(maxWidth: .infinity, maxHeight: .infinity) }
        case let .text(value):
            Text(String(value.prefix(512))).font(.body).lineLimit(6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(16).padding(.top, 20).padding(.bottom, 28)
        case .file:
            VStack(spacing: 10) {
                Image(systemName: "doc.fill").font(.system(size: 42)).foregroundStyle(.mint)
                Text("File reference · copy only").font(.caption2).foregroundStyle(.secondary)
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
                Label("Recovery needs attention in Pengrid", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            } else if let job = controller.activeJob {
                Text("\(job.title) · \(job.state.label)").lineLimit(1)
                if let progress = job.progress,
                   let fraction = FileOperationCenterProgressPresentation.determinateFraction(for: progress) {
                    ProgressView(value: fraction).tint(.mint).accessibilityLabel("Operation progress")
                    Text(progress.detail).foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.mini).accessibilityLabel("Operation in progress")
                }
            } else if let recent = controller.operationHistory.first, recent.state == .failed {
                Label("Last operation failed. Open Pengrid for details.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            } else {
                Text("No active file operation").foregroundStyle(.secondary)
            }
            if !controller.queuedJobs.isEmpty { Text("\(controller.queuedJobs.count) queued") }
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.white.opacity(0.06), in: .rect(cornerRadius: 12))
    }
}

struct ShelfSettingsView: View {
    let controller: ShelfPanelController
    var body: some View {
        Form {
            Toggle("Enable Top Shelf", isOn: Binding(get: { controller.store.isEnabled }, set: { controller.setEnabled($0) }))
            Picker("When Pengrid quits", selection: Binding(get: { controller.store.retention }, set: { controller.store.setRetention($0) })) {
                ForEach(ShelfRetention.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .disabled(controller.store.isRestoring || controller.store.isPreparingTermination)
            Text("Clear on Quit is the default. Keep Between Launches stores manually added text, images, and file references locally on this Mac. This storage is not encrypted by Pengrid or synced to the cloud.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Switching to Clear on Quit removes the saved snapshot but keeps current shelf items until quit. Turning the shelf off clears its items. Original files and the system clipboard are never deleted.")
                .font(.caption).foregroundStyle(.secondary)
            if let error = controller.store.persistenceError {
                Text(error).foregroundStyle(.orange)
                Button("Retry Storage") { controller.store.retryPersistence() }
            }
            Button("Show Shelf") { controller.show() }.disabled(!controller.store.isEnabled)
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 340)
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
        image = NSImage(systemSymbolName: "arrow.up.right.square", accessibilityDescription: "Drag a copy")
        toolTip = "Drag a copy. Text and images require a destination accepting their native type."
        setAccessibilityLabel("Drag a copy; use Copy for keyboard access")
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
