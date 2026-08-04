import AppKit
import SwiftUI

@MainActor
protocol SmartSearchAnnouncementPosting: AnyObject {
    func post(_ message: String)
}

@MainActor
final class LiveSmartSearchAnnouncementPoster: SmartSearchAnnouncementPosting {
    func post(_ message: String) {
        let application = NSApplication.shared
        NSAccessibility.post(
            element: application.mainWindow ?? application,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue
            ]
        )
    }
}

private enum SmartSearchFocus: Hashable {
    case query, savedSearchName
}

private enum SmartSearchResultColumn: String, CaseIterable, Identifiable {
    case name = "Name"
    case location = "Location"
    case type = "Type"
    case size = "Size"
    case modified = "Modified"
    case availability = "Availability"

    var id: String { rawValue }
}

@MainActor
struct SmartSearchView: View {
    let store: SmartSearchStore
    let router: SmartSearchActionRouter
    let workspace: WorkspaceState
    let operationController: FileOperationController
    let quickLookController: QuickLookController
    let materializer: any CloudMaterializing

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: SmartSearchFocus?
    @State private var selectedResultIDs = Set<URL>()
    @State private var selectedColumn: SmartSearchResultColumn = .name
    @State private var itemKind: SmartSearchItemKind = .all
    @State private var hasModifiedAfter = false
    @State private var modifiedAfter = Date()
    @State private var hasModifiedBefore = false
    @State private var modifiedBefore = Date()
    @State private var filtersArePresented = false
    @State private var rootPickerIsPresented = false
    @State private var savedSearchName = ""
    @State private var selectedSavedSearchID: UUID?
    @State private var extensionText = ""
    @State private var minimumBytesText = ""
    @State private var maximumBytesText = ""
    @State private var filterError: String?
    @State private var actionError: String?
    @State private var pendingTrashResults: [SmartSearchResult] = []
    private let announcer: any SmartSearchAnnouncementPosting

    init(
        store: SmartSearchStore,
        router: SmartSearchActionRouter,
        workspace: WorkspaceState,
        operationController: FileOperationController,
        quickLookController: QuickLookController,
        materializer: any CloudMaterializing,
        announcer: any SmartSearchAnnouncementPosting = LiveSmartSearchAnnouncementPoster()
    ) {
        self.store = store
        self.router = router
        self.workspace = workspace
        self.operationController = operationController
        self.quickLookController = quickLookController
        self.materializer = materializer
        self.announcer = announcer
    }

    var body: some View {
        VStack(spacing: 12) {
            searchControls
            rootsControls
            filtersControls
            resultsTable
            savedSearchControls
            actionControls
        }
        .padding()
        .frame(minWidth: 860, minHeight: 560)
        .accessibilityIdentifier(AccessibilityIdentifiers.smartSearchSheet)
        .accessibilityLabel("Smart Search")
        .onAppear {
            loadFilterDrafts()
            focusedField = .query
        }
        .onChange(of: selectedResultIDs) { _, _ in
            pendingTrashResults = []
        }
        .onChange(of: store.phase) { _, phase in
            switch phase {
            case .searching:
                announcer.post("Searching files")
            case .results:
                announcer.post("Found \(store.results.count) search results")
            case .failed:
                announcer.post(store.errorMessage ?? "Search failed")
            case .cancelled:
                announcer.post("Search cancelled")
            case .idle:
                break
            }
        }
        .onChange(of: actionError) { _, message in
            if let message { announcer.post(message) }
        }
        .onChange(of: store.progressMessage) { _, message in
            if let message { announcer.post(message) }
        }
        .onKeyPress(.space) {
            quickLookSelectedResult()
            return .handled
        }
        .fileImporter(
            isPresented: $rootPickerIsPresented,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: true
        ) { result in
            if case let .success(urls) = result {
                store.addRoots(urls)
            }
        }
        .alert("Move to Trash?", isPresented: hasPendingTrashConfirmation) {
            Button("Cancel", role: .cancel) { pendingTrashResults = [] }
            Button("Move to Trash", role: .destructive) { trashSelectedResults() }
        } message: {
            Text(trashConfirmationMessage)
        }
    }

    private var searchControls: some View {
        HStack(spacing: 8) {
            TextField(
                "Search filenames, paths, or Korean initials",
                text: Binding(get: { store.queryText }, set: { store.queryText = $0 })
            )
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: .query)
                .onSubmit { submitSearch() }
                .accessibilityIdentifier(AccessibilityIdentifiers.smartSearchQuery)
                .accessibilityLabel("Smart Search query")
                .accessibilityHint("Searches names and relative locations without reading file contents")

            if store.phase == .searching {
                Button("Cancel") { store.cancel() }
                    .accessibilityIdentifier(AccessibilityIdentifiers.smartSearchCancel)
                    .accessibilityHint("Stops the current recursive search")
            } else {
                Button("Search") { submitSearch() }
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(!canSubmit)
                    .accessibilityIdentifier(AccessibilityIdentifiers.smartSearchSearch)
                    .accessibilityHint("Starts a recursive search in the selected roots")
            }
        }
    }

    private var rootsControls: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Search in")
                .font(.headline)
            if store.roots.isEmpty {
                Text("No folders selected")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.roots, id: \.self) { root in
                    HStack(spacing: 3) {
                        Text(safeLocation(root))
                            .lineLimit(1)
                        Button {
                            store.removeRoot(root)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .accessibilityHidden(true)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove search folder \(safeLocation(root))")
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
                }
            }
            Button("Add Folder…") { rootPickerIsPresented = true }
                .accessibilityIdentifier(AccessibilityIdentifiers.smartSearchAddRoot)
                .accessibilityHint("Adds one or more folders to search recursively")
            Spacer()
        }
        .accessibilityIdentifier(AccessibilityIdentifiers.smartSearchRoots)
        .accessibilityLabel("Smart Search folders")
    }

    private var filtersControls: some View {
        HStack(spacing: 8) {
            Button("Filters") { filtersArePresented.toggle() }
                .popover(isPresented: $filtersArePresented, arrowEdge: .bottom) {
                    filterPopover
                }
                .accessibilityIdentifier(AccessibilityIdentifiers.smartSearchFilters)
                .accessibilityHint("Choose file kind, extensions, size, dates, hidden items, and packages")
            activeFilterSummary
            Spacer()
            if let message = filterError ?? store.errorMessage ?? actionError {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier(AccessibilityIdentifiers.smartSearchError)
                    .accessibilityLabel("Smart Search error")
                    .accessibilityValue(message)
            }
            if let progress = store.progressMessage {
                Text(progress)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier(AccessibilityIdentifiers.smartSearchProgress)
                    .accessibilityLabel("Smart Search progress")
                    .accessibilityValue(progress)
            }
        }
    }

    private var filterPopover: some View {
        return VStack(alignment: .leading, spacing: 10) {
            Text("Filters").font(.headline)
            Picker("Kind", selection: $itemKind) {
                Text("Files and folders").tag(SmartSearchItemKind.all)
                Text("Files only").tag(SmartSearchItemKind.files)
                Text("Folders only").tag(SmartSearchItemKind.folders)
            }
            .accessibilityIdentifier(AccessibilityIdentifiers.smartSearchKind)
            Toggle("Include hidden items", isOn: Binding(
                get: { store.includeHidden }, set: { store.includeHidden = $0 }
            ))
            Toggle("Search inside packages", isOn: Binding(
                get: { store.includePackages }, set: { store.includePackages = $0 }
            ))
            TextField("Extensions, separated by commas", text: $extensionText)
                .accessibilityIdentifier(AccessibilityIdentifiers.smartSearchExtensions)
            HStack {
                TextField("Minimum size (bytes)", text: $minimumBytesText)
                    .accessibilityIdentifier(AccessibilityIdentifiers.smartSearchMinimumSize)
                TextField("Maximum size (bytes)", text: $maximumBytesText)
                    .accessibilityIdentifier(AccessibilityIdentifiers.smartSearchMaximumSize)
            }
            Toggle("Modified after", isOn: $hasModifiedAfter)
            if hasModifiedAfter {
                DatePicker("Earliest modification date", selection: $modifiedAfter, displayedComponents: .date)
            }
            Toggle("Modified before", isOn: $hasModifiedBefore)
            if hasModifiedBefore {
                DatePicker("Latest modification date", selection: $modifiedBefore, displayedComponents: .date)
            }
            if let filterMessage = filterError ?? filterValidationMessage {
                Text(filterMessage).foregroundStyle(.red).font(.caption)
                    .accessibilityLabel("Invalid filter")
            }
            Button("Apply Filters") { applyFilterDrafts() }
                .disabled(!filterDraftIsValid)
        }
        .padding()
        .frame(width: 340)
    }

    private var activeFilterSummary: some View {
        Text(filterSummary)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    private var resultsTable: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 0) {
                ForEach(SmartSearchResultColumn.allCases) { column in
                    Button(column.rawValue) { selectSort(column) }
                        .buttonStyle(.plain)
                        .fontWeight(selectedColumn == column ? .semibold : .regular)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel("Sort results by \(column.rawValue)")
                        .accessibilityIdentifier(AccessibilityIdentifiers.smartSearchSort + ".\(column.rawValue.lowercased())")
                }
            }
            .padding(.horizontal, 8)
            .font(.caption)
            .foregroundStyle(.secondary)

            List(selection: $selectedResultIDs) {
                ForEach(sortedResults) { result in
                    HStack(spacing: 0) {
                        Text(result.item.name).frame(maxWidth: .infinity, alignment: .leading)
                        Text(safeResultLocation(result)).frame(maxWidth: .infinity, alignment: .leading)
                        Text(result.item.typeDescription).frame(maxWidth: .infinity, alignment: .leading)
                        Text(sizeDescription(result.item.byteSize)).frame(maxWidth: .infinity, alignment: .leading)
                        Text(dateDescription(result.item.modifiedAt)).frame(maxWidth: .infinity, alignment: .leading)
                        Text(availabilityDescription(result.item.availability)).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.caption)
                    .tag(result.id)
                    .accessibilityLabel(result.item.name)
                    .accessibilityValue("\(safeResultLocation(result)), \(result.item.typeDescription), \(sizeDescription(result.item.byteSize)), \(dateDescription(result.item.modifiedAt)), \(availabilityDescription(result.item.availability))")
                }
            }
            .accessibilityIdentifier(AccessibilityIdentifiers.smartSearchResults)
            .accessibilityLabel("Smart Search results")
            .accessibilityHint("Use the action buttons below to work with selected results")
        }
        .frame(maxHeight: .infinity)
    }

    private var savedSearchControls: some View {
        HStack(spacing: 8) {
            TextField("Saved search name", text: $savedSearchName)
                .focused($focusedField, equals: .savedSearchName)
                .textFieldStyle(.roundedBorder)
            Button("Save Search") {
                if store.saveCurrentSearch(named: savedSearchName) != nil {
                    savedSearchName = ""
                }
            }
            .disabled(!store.canSaveCurrentSearch || savedSearchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier(AccessibilityIdentifiers.smartSearchSave)
            .accessibilityHint("Saves the current query and filters")

            Button("Rename Saved") {
                guard let selectedSavedSearchID else { return }
                _ = store.renameSavedSearch(id: selectedSavedSearchID, to: savedSearchName)
            }
            .disabled(selectedSavedSearchID == nil || savedSearchName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier(AccessibilityIdentifiers.smartSearchRename)

            Button("Delete Saved", role: .destructive) {
                guard let selectedSavedSearchID else { return }
                _ = store.deleteSavedSearch(id: selectedSavedSearchID)
                self.selectedSavedSearchID = nil
            }
            .disabled(selectedSavedSearchID == nil)
            .accessibilityIdentifier(AccessibilityIdentifiers.smartSearchDelete)

            Menu("Saved Searches") {
                ForEach(store.savedSearches) { record in
                    Button(record.displayName) {
                        selectedSavedSearchID = record.id
                        savedSearchName = record.displayName
                        store.openSavedSearch(record)
                        loadFilterDrafts()
                    }
                }
            }
            .accessibilityIdentifier(AccessibilityIdentifiers.smartSearchSavedSearches)
            .accessibilityLabel("Saved Smart Searches")
        }
    }

    private var actionControls: some View {
        HStack(spacing: 8) {
            Button("Quick Look") { quickLookSelectedResult() }
                .disabled(selectedResults.count != 1)
                .accessibilityIdentifier(AccessibilityIdentifiers.smartSearchQuickLook)
                .accessibilityHint("Prepares the selected result for Quick Look")
            Button("Reveal") { revealSelectedResult() }
                .disabled(selectedResults.count != 1)
                .accessibilityIdentifier(AccessibilityIdentifiers.smartSearchReveal)
                .accessibilityHint("Reveals the selected result in the active file pane")
            Button("Open in Other Pane") { openContainingFolder() }
                .disabled(selectedResults.count != 1)
                .accessibilityIdentifier(AccessibilityIdentifiers.smartSearchOpenContainingFolder)
                .accessibilityHint("Opens the selected result's folder in the other file pane")
            Spacer()
            Button("Copy to Other Pane") { transferSelectedResults(mode: .copy) }
                .disabled(selectedResults.isEmpty)
                .accessibilityIdentifier(AccessibilityIdentifiers.smartSearchCopy)
                .accessibilityHint("Queues a copy operation to the other file pane")
            Button("Move to Other Pane") { transferSelectedResults(mode: .move) }
                .disabled(selectedResults.isEmpty)
                .accessibilityIdentifier(AccessibilityIdentifiers.smartSearchMove)
                .accessibilityHint("Queues a move operation to the other file pane")
            Button("Move to Trash") { pendingTrashResults = selectedResults }
                .disabled(selectedResults.isEmpty)
                .accessibilityIdentifier(AccessibilityIdentifiers.smartSearchTrash)
                .accessibilityHint("Asks for confirmation before moving selected results to Trash")
        }
    }

    private var selectedResults: [SmartSearchResult] {
        sortedResults.filter { selectedResultIDs.contains($0.id) }
    }

    private var sortedResults: [SmartSearchResult] {
        store.results
    }

    private var canSubmit: Bool {
        !store.queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !store.roots.isEmpty
            && filterDraftIsValid
    }

    private var filterDraftIsValid: Bool {
        filterValidationMessage == nil
    }

    private var filterValidationMessage: String? {
        guard case .value = parsedByteValue(minimumBytesText),
              case .value = parsedByteValue(maximumBytesText)
        else {
            return "Sizes must be whole numbers of bytes."
        }
        guard case let .value(minimum) = parsedByteValue(minimumBytesText),
              case let .value(maximum) = parsedByteValue(maximumBytesText)
        else { return "Sizes must be whole numbers of bytes." }
        do {
            _ = try SmartSearchMetadataFilter(
                kind: itemKind,
                extensionText: extensionText,
                minimumBytes: minimum,
                maximumBytes: maximum,
                modifiedAfter: hasModifiedAfter ? modifiedAfter : nil,
                modifiedBefore: hasModifiedBefore ? modifiedBefore : nil
            )
            return nil
        } catch SmartSearchValidationError.invalidByteRange {
            return "Minimum size must not exceed maximum size."
        } catch {
            return "Enter valid metadata filters."
        }
    }

    private var filterSummary: String {
        var parts: [String] = []
        if store.metadata.kind == .files { parts.append("Files") }
        if store.metadata.kind == .folders { parts.append("Folders") }
        if !store.metadata.extensions.isEmpty { parts.append(store.metadata.extensions.sorted().joined(separator: ", ")) }
        if store.metadata.modifiedAfter != nil || store.metadata.modifiedBefore != nil { parts.append("Modified date") }
        if store.includeHidden { parts.append("Hidden") }
        if store.includePackages { parts.append("Packages") }
        return parts.isEmpty ? "No filters" : parts.joined(separator: " · ")
    }

    private var hasPendingTrashConfirmation: Binding<Bool> {
        Binding { !pendingTrashResults.isEmpty } set: { isPresented in
            if !isPresented { pendingTrashResults = [] }
        }
    }

    private var trashConfirmationMessage: String {
        switch pendingTrashResults.count {
        case 0: ""
        case 1: "\(pendingTrashResults[0].item.name) will be moved to the Trash."
        default: "\(pendingTrashResults.count) selected items will be moved to the Trash."
        }
    }

    private func submitSearch() {
        applyFilterDrafts()
        guard filterError == nil else { return }
        actionError = nil
        store.submit()
    }

    private func loadFilterDrafts() {
        itemKind = store.metadata.kind
        hasModifiedAfter = store.metadata.modifiedAfter != nil
        modifiedAfter = store.metadata.modifiedAfter ?? Date()
        hasModifiedBefore = store.metadata.modifiedBefore != nil
        modifiedBefore = store.metadata.modifiedBefore ?? Date()
        extensionText = store.metadata.extensions.sorted().joined(separator: ", ")
        minimumBytesText = store.metadata.minimumBytes.map(String.init) ?? ""
        maximumBytesText = store.metadata.maximumBytes.map(String.init) ?? ""
    }

    private func applyFilterDrafts() {
        guard let filter = validFilter() else {
            filterError = filterValidationMessage
            return
        }
        store.metadata = filter
        filterError = nil
    }

    private func validFilter() -> SmartSearchMetadataFilter? {
        guard case let .value(minimum) = parsedByteValue(minimumBytesText),
              case let .value(maximum) = parsedByteValue(maximumBytesText)
        else {
            return nil
        }
        do {
            let filter = try SmartSearchMetadataFilter(
                kind: itemKind,
                extensionText: extensionText,
                minimumBytes: minimum,
                maximumBytes: maximum,
                modifiedAfter: hasModifiedAfter ? modifiedAfter : nil,
                modifiedBefore: hasModifiedBefore ? modifiedBefore : nil
            )
            return filter
        } catch {
            return nil
        }
    }

    private enum ParsedByteValue {
        case value(Int64?), invalid
    }

    private func parsedByteValue(_ value: String) -> ParsedByteValue {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .value(nil) }
        guard let bytes = Int64(trimmed), bytes >= 0 else { return .invalid }
        return .value(bytes)
    }

    private func quickLookSelectedResult() {
        guard let result = selectedResults.only else { return }
        Task {
            guard await router.prepareQuickLook(
                for: result,
                controller: quickLookController,
                materializer: materializer
            ) else {
                actionError = "Item changed. Search again."
                return
            }
        }
    }

    private func revealSelectedResult() {
        guard let result = selectedResults.only else { return }
        let sourcePane = workspace.activePane
        Task {
            guard await router.reveal(result, in: sourcePane) else {
                actionError = "Item changed. Search again."
                return
            }
        }
    }

    private func openContainingFolder() {
        guard let result = selectedResults.only else { return }
        let destinationPane = workspace.activePaneID == .left ? workspace.right : workspace.left
        Task {
            guard await router.openContainingFolder(for: result, in: destinationPane) else {
                actionError = "Item changed. Search again."
                return
            }
        }
    }

    private func transferSelectedResults(mode: TransferMode) {
        let results = selectedResults
        guard !results.isEmpty else { return }
        let destinationPane = workspace.activePaneID == .left ? workspace.right : workspace.left
        let destination = destinationPane.currentDirectory
        Task {
            let requests: [IdentifiedTransferRequest]
            do {
                requests = try await router.transferRequests(for: results, destination: destination)
            } catch {
                actionError = "Item changed. Search again."
                return
            }
            if operationController.runIdentifiedTransfer(
                requests,
                mode: mode,
                workspace: workspace,
                includeSafeRelativePaths: false
            ) {
                store.dismiss()
                dismiss()
            } else {
                actionError = "Could not queue operation. Search remains open."
            }
        }
    }

    private func trashSelectedResults() {
        let results = pendingTrashResults
        pendingTrashResults = []
        guard !results.isEmpty else { return }
        Task {
            var requests: [IdentifiedFileRequest] = []
            for result in results {
                guard let request = await router.revalidatedRequest(for: result) else {
                    actionError = "Item changed. Search again."
                    return
                }
                requests.append(request)
            }
            if operationController.trash(requests, workspace: workspace, privacySafeProgress: true) {
                store.dismiss()
                dismiss()
            } else {
                actionError = "Could not queue operation. Search remains open."
            }
        }
    }

    private func selectSort(_ column: SmartSearchResultColumn) {
        selectedColumn = column
        switch column {
        case .name: store.sort = .name
        case .size: store.sort = .size
        case .modified: store.sort = .modifiedAt
        case .location, .type, .availability: break
        }
    }

    private func safeLocation(_ url: URL) -> String {
        url.lastPathComponent.isEmpty ? "Folder" : url.lastPathComponent
    }

    private func safeResultLocation(_ result: SmartSearchResult) -> String {
        let parent = result.relativePath.split(separator: "/").dropLast().joined(separator: "/")
        return parent.isEmpty ? "Search folder" : parent
    }

    private func sizeDescription(_ byteSize: Int64?) -> String {
        byteSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—"
    }

    private func dateDescription(_ date: Date?) -> String {
        date?.formatted(date: .abbreviated, time: .shortened) ?? "—"
    }

    private func availabilityDescription(_ availability: CloudItemAvailability) -> String {
        switch availability {
        case .availableLocally: "Local"
        case .onlineOnly: "Online only"
        case .downloading: "Downloading"
        case .unavailable: "Unavailable"
        case .unknown: "Unknown"
        }
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
