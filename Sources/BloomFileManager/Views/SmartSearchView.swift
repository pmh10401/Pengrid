import SwiftUI

struct SmartSearchStatePresentation: Equatable {
    let title: String
    let detail: String
}

enum SmartSearchPresentation {
    static let deleteSavedSearchLabel = "Delete saved search"

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

    static func state(
        for state: SmartSearchStoreState,
        resultCount: Int,
        errorMessage: String?
    ) -> SmartSearchStatePresentation {
        switch state {
        case .idle:
            SmartSearchStatePresentation(
                title: "Ready to search",
                detail: "Enter a filename or folder name."
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
enum SmartSearchResultNavigationRouter {
    static func destination(for result: SmartSearchResult) -> URL {
        result.item.isDirectory
            ? result.item.url.standardizedFileURL
            : result.item.url.deletingLastPathComponent().standardizedFileURL
    }

    static func open(_ result: SmartSearchResult, in workspace: WorkspaceState) async {
        await workspace.activePane.navigate(to: destination(for: result))
    }
}

struct SmartSearchView: View {
    let workspace: WorkspaceState
    let store: SmartSearchStore

    @Bindable private var bindableStore: SmartSearchStore
    @FocusState private var queryIsFocused: Bool
    @State private var savedSearchName = ""

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

            TextField("Search filenames and folders", text: $bindableStore.queryText)
                .textFieldStyle(.roundedBorder)
                .focused($queryIsFocused)
                .onSubmit(store.search)
                .accessibilityIdentifier(AccessibilityIdentifiers.smartSearchQuery)
                .accessibilityLabel("Search filenames and folders")

            VStack(alignment: .leading, spacing: 8) {
                Text(rootSummary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Search root, \(rootSummary)")

                Toggle("Include hidden items", isOn: $bindableStore.includeHidden)
                    .accessibilityIdentifier(AccessibilityIdentifiers.smartSearchIncludeHidden)
                Toggle("Include packages", isOn: $bindableStore.includePackages)
                    .accessibilityIdentifier(AccessibilityIdentifiers.smartSearchIncludePackages)
                Toggle("Include folders", isOn: $bindableStore.includeDirectories)
                    .accessibilityIdentifier(AccessibilityIdentifiers.smartSearchIncludeDirectories)
            }

            HStack(spacing: 12) {
                Button("Search", action: store.search)
                    .keyboardShortcut(.defaultAction)
                    .disabled(store.queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.state == .searching)
                    .accessibilityIdentifier(AccessibilityIdentifiers.smartSearchSubmit)

                if store.state == .searching {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(store.progressMessage ?? "Searching files")
                        .accessibilityIdentifier(AccessibilityIdentifiers.smartSearchProgress)
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
                List(store.results.prefix(SmartSearchQuery.defaultMaximumResults)) { result in
                    Button {
                        Task {
                            await SmartSearchResultNavigationRouter.open(result, in: workspace)
                            store.dismiss()
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(result.item.name)
                            Text(result.relativePath)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(SmartSearchPresentation.availabilityDescription(result.item.availability))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(SmartSearchPresentation.resultAccessibilityLabel(for: result))
                }
                .listStyle(.inset)
                .frame(minHeight: 180)
                .accessibilityIdentifier(AccessibilityIdentifiers.smartSearchResults)
                .accessibilityLabel("Search results")
            }
        }
    }

    private var rootSummary: String {
        let roots = store.roots.map { $0.path }.joined(separator: ", ")
        return roots.isEmpty ? "No search folder selected" : "Searching in \(roots)"
    }

    private func saveCurrentSearch() {
        let name = savedSearchName.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = store.saveCurrentSearch(named: name.isEmpty ? store.queryText : name)
        savedSearchName = ""
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
