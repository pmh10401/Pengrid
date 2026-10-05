import SwiftUI
import AppKit

struct ShelfView: View {
    let controller: ShelfPanelController
    var body: some View {
        VStack(spacing: 10) {
            if controller.isExpanded {
                ShelfContentsView(controller: controller)
            } else {
                Button {
                    controller.show()
                } label: {
                    Label("Top Shelf · \(controller.store.entries.count)", systemImage: "tray.full")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("Open Top Shelf. Drop files, text, or images here to keep them.")
            }
        }
        .padding(controller.isExpanded ? 16 : 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
        .compositingGroup()
        .clipShape(.rect(cornerRadius: controller.isExpanded ? 24 : 16))
        .preferredColorScheme(.dark)
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
        VStack(spacing: 10) {
            HStack {
                Label("Top Shelf", systemImage: "tray.full").font(.headline)
                Text("\(store.entries.count)/50").foregroundStyle(.secondary)
                Spacer()
                Button("Open Pengrid", systemImage: "rectangle.on.rectangle") {
                    if controller.interactionAllowed { controller.openMain() }
                }
                .labelStyle(.iconOnly)
                .help("Open Pengrid")
                Button("Collapse Shelf", systemImage: "chevron.up") { controller.show(expanded: false) }
                    .labelStyle(.iconOnly)
                    .help("Collapse Shelf")
                Button("Hide Shelf", systemImage: "xmark") { controller.hide() }
                    .labelStyle(.iconOnly)
                    .help("Hide Shelf; reopen from the Shelf menu")
            }
            HStack {
                TextField("Search shelf (including Korean initials)", text: $store.query)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("topShelf.search")
                Picker("Kind", selection: $store.kind) {
                    Text("All").tag(Optional<ShelfContentKind>.none)
                    Text("Files").tag(Optional(ShelfContentKind.file))
                    Text("Text").tag(Optional(ShelfContentKind.text))
                    Text("Images").tag(Optional(ShelfContentKind.image))
                }
                .labelsHidden()
                .frame(width: 90)
            }
            List(selection: $store.selectedID) {
                ForEach(store.filteredEntries) { item in
                    ShelfItemRow(item: item, controller: controller)
                        .tag(item.id)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .overlay {
                if store.filteredEntries.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "tray.and.arrow.down").font(.title)
                        Text(store.isRestoring ? "Restoring shelf…" : store.query.isEmpty ? "Drop files, text, or images here" : "No matching items")
                        Text("Clipboard is read only when you choose Import.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .allowsHitTesting(false)
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
                Button("Clear…") { confirmingClear = true }
                    .disabled(store.entries.isEmpty || store.isPreparingTermination)
            }
            HStack {
                Text(store.retention == .clearOnQuit ? "Cleared on quit · originals stay untouched" : "Kept on this Mac · originals stay untouched")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                if store.isImporting || store.isSearching || store.isSaving {
                    ProgressView().controlSize(.mini).accessibilityLabel("Updating shelf")
                }
            }
            if let operations = controller.operationController {
                ShelfProgressView(controller: operations)
            }
        }
        .confirmationDialog("Clear all shelf items? Original files and the system clipboard will not be changed.", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("Clear Shelf", role: .destructive) { store.clear() }
        }
    }
}

private struct ShelfItemRow: View {
    let item: ShelfItem
    let controller: ShelfPanelController
    @State private var thumbnail: CGImage?
    var body: some View {
        HStack(spacing: 10) {
            if let thumbnail {
                Image(decorative: thumbnail, scale: 1).resizable().scaledToFit().frame(width: 36, height: 36)
            } else {
                Image(systemName: item.kind == .file ? "doc" : item.kind == .text ? "text.alignleft" : "photo")
                    .font(.title2).frame(width: 36, height: 36).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(item.displayName.isEmpty ? "Empty text" : item.displayName).lineLimit(1)
                Text(item.kind == .file ? "File reference · copy only" : "\(item.byteCount.formatted()) bytes")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            ShelfDragHandle(item: item, controller: controller).frame(width: 26, height: 30)
            Button("Remove from Shelf", systemImage: "minus.circle") {
                if controller.interactionAllowed { controller.store.remove(item.id) }
            }
            .labelStyle(.iconOnly).buttonStyle(.borderless).help("Remove from shelf (keep original)")
        }
        .task(id: item.id) {
            guard item.kind == .image else { return }
            let value = await ShelfThumbnailRenderer.shared.image(for: item)
            if !Task.isCancelled { thumbnail = value }
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
                    ProgressView(value: fraction).accessibilityLabel("Operation progress")
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
        .padding(.top, 5)
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
    override func mouseDown(with event: NSEvent) { controller?.store.selectedID = item?.id }
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
