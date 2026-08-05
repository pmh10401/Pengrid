import AppKit
import Observation
import SwiftUI

/// Pure presentation helpers keep the header and cell copy compact without
/// exposing a folder's full path to the UI or assistive technologies.
enum FolderPreviewPresentation {
    static func folderName(for request: FolderPreviewRequest?) -> String {
        request?.url.lastPathComponent ?? "Folder"
    }

    static func parentLabel(for url: URL?) -> String {
        guard let url else { return "" }
        let parentName = url.deletingLastPathComponent().lastPathComponent
        return parentName.isEmpty ? "In enclosing folder" : "In \(parentName)"
    }

    static func kind(for entry: FolderPreviewEntry) -> String {
        entry.isDirectory ? "Folder" : "File"
    }

    static func size(for entry: FolderPreviewEntry) -> String {
        guard let byteSize = entry.byteSize else { return "—" }
        return ByteCountFormatter.string(fromByteCount: byteSize, countStyle: .file)
    }

    static func modified(for entry: FolderPreviewEntry) -> String {
        entry.modifiedAt?.formatted(date: .abbreviated, time: .shortened) ?? "—"
    }
}

struct FolderPreviewView: View {
    @Bindable var model: FolderPreviewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            Text(model.statusText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(AccessibilityIdentifiers.folderPreviewStatus)
                .accessibilityLabel("Folder preview status")
                .accessibilityValue(model.statusText)

            Table(model.entries) {
                TableColumn("Name") { entry in
                    Text(entry.name)
                        .accessibilityLabel("Name")
                        .accessibilityValue(entry.name)
                }
                TableColumn("Kind") { entry in
                    let kind = FolderPreviewPresentation.kind(for: entry)
                    Text(kind)
                        .accessibilityLabel("Kind")
                        .accessibilityValue(kind)
                }
                TableColumn("Size") { entry in
                    let size = FolderPreviewPresentation.size(for: entry)
                    Text(size)
                        .accessibilityLabel("Size")
                        .accessibilityValue(size)
                }
                TableColumn("Modified") { entry in
                    let modified = FolderPreviewPresentation.modified(for: entry)
                    Text(modified)
                        .accessibilityLabel("Modified")
                        .accessibilityValue(modified)
                }
            }
            .accessibilityIdentifier(AccessibilityIdentifiers.folderPreviewTable)
            .accessibilityLabel("Folder contents")
            .accessibilityValue(model.statusText)
        }
        .padding(16)
        .frame(minWidth: 640, minHeight: 420)
        .accessibilityIdentifier(AccessibilityIdentifiers.folderPreviewPanel)
        .accessibilityLabel("Folder contents preview")
        .onChange(of: model.statusText) { _, status in
            announce(status: status)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(FolderPreviewPresentation.folderName(for: model.request))
                .font(.headline)
                .accessibilityIdentifier(AccessibilityIdentifiers.folderPreviewTitle)
                .accessibilityLabel("Folder name")
                .accessibilityValue(FolderPreviewPresentation.folderName(for: model.request))

            Text(FolderPreviewPresentation.parentLabel(for: model.request?.url))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(AccessibilityIdentifiers.folderPreviewParent)
                .accessibilityLabel("Folder location")
                .accessibilityValue(FolderPreviewPresentation.parentLabel(for: model.request?.url))
        }
    }

    private func announce(status: String) {
        guard !status.isEmpty else { return }
        let application = NSApplication.shared
        NSAccessibility.post(
            element: application.mainWindow ?? application,
            notification: .announcementRequested,
            userInfo: [
                .announcement: status,
                .priority: NSAccessibilityPriorityLevel.low.rawValue
            ]
        )
    }
}
