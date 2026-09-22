import SwiftUI

@MainActor
struct NamePatternSelectionRequest {
    let editingSession: WorkspaceTextEditingSession
    private let workspace: WorkspaceState
    private let pane: FilePaneState
    private let tabID: WorkspaceTabID
    private let directory: URL
    private let projectionToken: PaneProjectionToken?
    private let items: [FileItem]

    init(workspace: WorkspaceState, tabID: WorkspaceTabID) {
        self.workspace = workspace
        self.pane = workspace.activePane
        self.tabID = tabID
        self.directory = workspace.activePane.currentDirectory
        self.projectionToken = workspace.activePane.acceptedProjectionToken
        self.items = workspace.activePane.visibleItems
        self.editingSession = WorkspaceTextEditingSession(paneID: workspace.activePaneID, kind: .namePattern)
    }

    var itemCount: Int { items.count }

    func matchingURLs(_ pattern: String) -> Set<URL>? {
        PaneSelectionActions.matchingNamePattern(pattern, visibleItems: items)
    }

    func isCurrent(in workspace: WorkspaceState, tabID: WorkspaceTabID) -> Bool {
        self.workspace === workspace && self.tabID == tabID
            && workspace.activePane === pane
            && workspace.activeTextEditingSession == editingSession
            && !pane.isLoading && !pane.isFilterPresented
            && pane.currentDirectory == directory
            && pane.acceptedProjectionToken == projectionToken
    }

    @discardableResult
    func apply(_ pattern: String, in workspace: WorkspaceState, tabID: WorkspaceTabID) -> Bool {
        guard isCurrent(in: workspace, tabID: tabID),
              let matches = matchingURLs(pattern)
        else { return false }
        pane.selection = matches
        return true
    }

    func finish(in workspace: WorkspaceState, tabID: WorkspaceTabID) {
        self.workspace.endTextEditing(editingSession)
        guard self.workspace === workspace, self.tabID == tabID,
              workspace.activePane === pane,
              workspace.activeTextEditingSession == nil
        else { return }
        pane.requestTableFocus()
    }
}

struct NamePatternSelectionView: View {
    let request: NamePatternSelectionRequest
    let workspace: WorkspaceState
    let tabID: WorkspaceTabID
    @Environment(\.dismiss) private var dismiss
    @State private var pattern = ""
    @FocusState private var patternFocused: Bool

    var body: some View {
        let matches = request.matchingURLs(pattern)
        let isCurrent = request.isCurrent(in: workspace, tabID: tabID)

        VStack(alignment: .leading, spacing: 14) {
            Text("Select by Name")
                .font(.headline)
            Text("Match visible file and folder names in the active pane. Selection will be replaced.")
                .foregroundStyle(.secondary)
            TextField("Example: *.pdf or 보고서_?.xlsx", text: $pattern)
                .textFieldStyle(.roundedBorder)
                .focused($patternFocused)
                .accessibilityLabel("Filename pattern")
                .accessibilityIdentifier(AccessibilityIdentifiers.namePatternQuery)
            Text("* matches any number of characters; ? matches one character. Case is ignored.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Matches: \(matches?.count ?? 0) of \(request.itemCount)")
                .accessibilityIdentifier(AccessibilityIdentifiers.namePatternCount)
            if !isCurrent {
                Text("The folder listing changed. Cancel and open Select by Name again.")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier(AccessibilityIdentifiers.namePatternCancel)
                Button("Select") {
                    if request.apply(pattern, in: workspace, tabID: tabID) {
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(matches == nil || !isCurrent)
                .accessibilityIdentifier(AccessibilityIdentifiers.namePatternApply)
            }
        }
        .padding(20)
        .frame(width: 460)
        .defaultFocus($patternFocused, true)
    }
}
