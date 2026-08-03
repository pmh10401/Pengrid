import AppKit
import SwiftUI

struct SmartSearchStatePresentation: Equatable {
    let title: String
    let detail: String
}

enum SmartSearchPresentation {
    static let deleteSavedSearchLabel = "Delete saved search"
    static let queryPrompt = "Search names, paths, or Korean initials"
    static let idleSearchDetail = "Try Korean initials such as ㅎㄱ for 한국 or 한글."
    static let queryAccessibilityHint = "Korean initial searches are supported, for example ㅎㄱ."

    static func canSubmitSearch(
        queryText: String,
        roots: [URL],
        state: SmartSearchStoreState
    ) -> Bool {
        !queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !roots.isEmpty
            && state != .searching
    }

    static func availabilityDescription(_ availability: CloudItemAvailability) -> String {
        return switch availability {
        case .availableLocally: "Available locally"
        case .onlineOnly: "Available online"
        case let .downloading(progress):
            progress.map {
                "Downloading, \(Int(($0.clamped(to: 0...1) * 100).rounded())) percent"
            } ?? "Downloading"
        case .unavailable: "Unavailable"
        case .unknown: "Availability unknown"
        }
    }

    static func resultAccessibilityLabel(for result: SmartSearchResult) -> String {
        [
            result.item.name,
            result.relativePath,
            availabilityDescription(result.item.availability)
        ].joined(separator: ", ")
    }

    static func savedSearchAccessibilityLabel(for record: SmartSearchRecord) -> String {
        "Saved search, \(record.displayName), query \(record.query.text)"
    }

    static func rootSummary(
        for roots: [URL],
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        guard !roots.isEmpty else { return "No search folder selected" }
        let homePath = home.standardizedFileURL.path
        let names = roots.map { root in
            let standardizedRoot = root.standardizedFileURL
            if standardizedRoot.path == homePath { return "Home" }
            let name = standardizedRoot.lastPathComponent
            return name.isEmpty ? "Root folder" : name
        }
        return "Searching in \(names.joined(separator: ", "))"
    }

    static func state(
        for state: SmartSearchStoreState,
        resultCount: Int,
        errorMessage: String?
    ) -> SmartSearchStatePresentation {
        switch state {
        case .idle:
            SmartSearchStatePresentation(
                title: "Ready to search",
                detail: idleSearchDetail
            )
        case .searching:
            SmartSearchStatePresentation(title: "Searching files", detail: "")
        case .results:
            switch resultCount {
            case 0: SmartSearchStatePresentation(title: "No results", detail: "Try a different search.")
            case 1: SmartSearchStatePresentation(title: "1 result", detail: "")
            default: SmartSearchStatePresentation(title: "\(resultCount) results", detail: "")
            }
        case .cancelled:
            SmartSearchStatePresentation(title: "Search cancelled", detail: "")
        case .failed:
            SmartSearchStatePresentation(
                title: errorMessage ?? "Search failed.",
                detail: "Check the selected folder and try again."
            )
        }
    }
}

@MainActor
enum SmartSearchRootPanelConfiguration {
    static func apply(to panel: NSOpenPanel) {
        panel.title = "Add Search Folders"
        panel.prompt = "Add"
        panel.message = "Choose one or more folders to search."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
    }
}

@MainActor
enum SmartSearchResultNavigationRouter {
    static func destination(for result: SmartSearchResult) -> URL {
        result.item.isDirectory
            ? result.item.url.standardizedFileURL
            : result.item.url.deletingLastPathComponent().standardizedFileURL
    }

    static func open(_ result: SmartSearchResult, in workspace: WorkspaceState) async {
        let pane = workspace.activePane
        await pane.navigate(to: destination(for: result))
        guard !result.item.isDirectory else { return }
        let resultPath = result.item.url.standardizedFileURL.path
        if let loadedURL = pane.items.first(where: {
            $0.url.standardizedFileURL.path == resultPath
        })?.url {
            pane.selection = [loadedURL]
        }
    }
}

struct SmartSearchView: View {
    let workspace: WorkspaceState
    let store: SmartSearchStore

    @Bindable private var bindableStore: SmartSearchStore
    @FocusState private var queryIsFocused: Bool
    @FocusState private var savedNameIsFocused: Bool
    @State private var savedSearchName = ""
    @State private var queryEditingSession: WorkspaceTextEditingSession?
    @State private var savedNameEditingSession: WorkspaceTextEditingSession?

    init(workspace: WorkspaceState, store: SmartSearchStore) {
        self.workspace = workspace
        self.store = store
        _bindableStore = Bindable(store)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Smart Search", systemImage: "magnifyingglass")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button("Close", action: store.dismiss)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier(AccessibilityIdentifiers.smartSearchClose)
            }

            TextField(SmartSearchPresentation.queryPrompt, text: $bindableStore.queryText)
                .textFieldStyle(.roundedBorder)
                .focused($queryIsFocused)
                .onSubmit(submitSearch)
                .accessibilityIdentifier(AccessibilityIdentifiers.smartSearchQuery)
                .accessibilityLabel("Search filenames and folders")
                .accessibilityHint(SmartSearchPresentation.queryAccessibilityHint)

            VStack(alignment: .leading, spacing: 8) {
                Text(rootSummary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Search root, \(rootSummary)")

                HStack {
                    Button("Add Folders…", action: chooseRoots)
                        .accessibilityIdentifier(AccessibilityIdentifiers.smartSearchAddRoots)

                    Spacer()

                    Stepper(
                        "Maximum results: \(store.maximumResults)",
                        value: $bindableStore.maximumResults,
                        in: SmartSearchQuery.maximumResultRange,
                        step: 50
                    )
                    .fixedSize()
                    .accessibilityIdentifier(AccessibilityIdentifiers.smartSearchMaximumResults)
                }

                if !store.roots.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(store.roots, id: \.self) { root in
                            HStack(spacing: 8) {
                                Image(systemName: "folder")
                                    .foregroundStyle(.secondary)
                                    .accessibilityHidden(true)
                                Text(rootDisplayName(root))
                                    .lineLimit(1)
                                Spacer()
                                Button {
                                    store.removeRoot(root)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .accessibilityHidden(true)
                                }
                                .buttonStyle(.borderless)
                                .help("Remove \(rootDisplayName(root))")
                                .accessibilityLabel("Remove \(rootDisplayName(root)) from search")
                                .accessibilityIdentifier(AccessibilityIdentifiers.smartSearchRemoveRoot(root))
                            }
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier(AccessibilityIdentifiers.smartSearchRoots)
                    .accessibilityLabel("Search folders")
                }

                Toggle("Include hidden items", isOn: $bindableStore.includeHidden)
                    .accessibilityIdentifier(AccessibilityIdentifiers.smartSearchIncludeHidden)
                Toggle("Include packages", isOn: $bindableStore.includePackages)
                    .accessibilityIdentifier(AccessibilityIdentifiers.smartSearchIncludePackages)
                Toggle("Include folders", isOn: $bindableStore.includeDirectories)
                    .accessibilityIdentifier(AccessibilityIdentifiers.smartSearchIncludeDirectories)
            }

            HStack(spacing: 12) {
                Button("Search", action: submitSearch)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!SmartSearchPresentation.canSubmitSearch(
                        queryText: store.queryText,
                        roots: store.roots,
                        state: store.state
                    ))
                    .accessibilityIdentifier(AccessibilityIdentifiers.smartSearchSubmit)

                if store.state == .searching {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(store.progressMessage ?? "Searching files")
                        .accessibilityIdentifier(AccessibilityIdentifiers.smartSearchProgress)
                    Text(store.progressMessage ?? "Searching files…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Cancel", action: store.cancelSearch)
                        .accessibilityIdentifier(AccessibilityIdentifiers.smartSearchCancel)
                }
            }

            Divider()

            resultsContent

            Divider()

            HStack {
                TextField("Saved search name", text: $savedSearchName)
                    .textFieldStyle(.roundedBorder)
                    .focused($savedNameIsFocused)
                    .accessibilityIdentifier(AccessibilityIdentifiers.smartSearchSavedName)
                Button("Save Search", action: saveCurrentSearch)
                    .disabled(store.queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.roots.isEmpty)
                    .accessibilityIdentifier(AccessibilityIdentifiers.smartSearchSave)
            }
        }
        .padding(24)
        .frame(maxWidth: 720, maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityIdentifiers.smartSearch)
        .accessibilityLabel("Smart Search")
        .onAppear {
            queryIsFocused = true
        }
        .onChange(of: queryIsFocused) { _, isFocused in
            updateQueryEditingSession(isFocused: isFocused)
        }
        .onChange(of: savedNameIsFocused) { _, isFocused in
            updateSavedNameEditingSession(isFocused: isFocused)
        }
        .onDisappear {
            endEditingSessions()
        }
    }

    @ViewBuilder
    private var resultsContent: some View {
        let presentation = SmartSearchPresentation.state(
            for: store.state,
            resultCount: store.results.count,
            errorMessage: store.errorMessage
        )

        VStack(alignment: .leading, spacing: 8) {
            Text(presentation.title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            if !presentation.detail.isEmpty {
                Text(presentation.detail)
                    .foregroundStyle(.secondary)
            }

            if !store.results.isEmpty {
                List(store.results.prefix(store.maximumResults)) { result in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(result.item.name)
                        Text(result.relativePath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(SmartSearchPresentation.availabilityDescription(result.item.availability))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        activate(result)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel(SmartSearchPresentation.resultAccessibilityLabel(for: result))
                    .accessibilityIdentifier(AccessibilityIdentifiers.smartSearchResultRow(result.item.url))
                    .accessibilityAction {
                        activate(result)
                    }
                }
                .listStyle(.inset)
                .frame(minHeight: 180)
                .accessibilityIdentifier(AccessibilityIdentifiers.smartSearchResults)
                .accessibilityLabel("Search results")
            }
        }
    }

    private var rootSummary: String {
        SmartSearchPresentation.rootSummary(for: store.roots)
    }

    private func submitSearch() {
        guard SmartSearchPresentation.canSubmitSearch(
            queryText: store.queryText,
            roots: store.roots,
            state: store.state
        ) else {
            return
        }
        store.search()
    }

    private func saveCurrentSearch() {
        let name = savedSearchName.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = store.saveCurrentSearch(named: name.isEmpty ? store.queryText : name)
        savedSearchName = ""
    }

    private func chooseRoots() {
        let panel = NSOpenPanel()
        SmartSearchRootPanelConfiguration.apply(to: panel)
        guard panel.runModal() == .OK else { return }
        store.addRoots(panel.urls)
    }

    private func rootDisplayName(_ root: URL) -> String {
        if root.standardizedFileURL == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL {
            return "Home"
        }
        let name = root.standardizedFileURL.lastPathComponent
        return name.isEmpty ? "Root folder" : name
    }

    private func activate(_ result: SmartSearchResult) {
        Task {
            await SmartSearchResultNavigationRouter.open(result, in: workspace)
            store.dismiss()
        }
    }

    private func updateQueryEditingSession(isFocused: Bool) {
        if isFocused {
            guard queryEditingSession == nil else { return }
            let session = WorkspaceTextEditingSession(
                paneID: workspace.activePaneID,
                kind: .smartSearchQuery
            )
            queryEditingSession = session
            workspace.beginTextEditing(session)
        } else if let session = queryEditingSession {
            queryEditingSession = nil
            workspace.endTextEditing(session)
        }
    }

    private func updateSavedNameEditingSession(isFocused: Bool) {
        if isFocused {
            guard savedNameEditingSession == nil else { return }
            let session = WorkspaceTextEditingSession(
                paneID: workspace.activePaneID,
                kind: .smartSearchName
            )
            savedNameEditingSession = session
            workspace.beginTextEditing(session)
        } else if let session = savedNameEditingSession {
            savedNameEditingSession = nil
            workspace.endTextEditing(session)
        }
    }

    private func endEditingSessions() {
        if let queryEditingSession {
            workspace.endTextEditing(queryEditingSession)
            self.queryEditingSession = nil
        }
        if let savedNameEditingSession {
            workspace.endTextEditing(savedNameEditingSession)
            self.savedNameEditingSession = nil
        }
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
