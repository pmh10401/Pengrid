import AppKit
import SwiftUI

enum FavoriteDropPolicy {
    static func accepts(_ item: FileItem) -> Bool {
        item.url.isFileURL && item.isDirectory && !item.isPackage
    }

    static func accepts(urls: [URL]) -> Bool {
        guard !urls.isEmpty else { return false }
        return urls.allSatisfy { url in
            guard url.isFileURL,
                  let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            else { return false }
            return values.isDirectory == true && values.isPackage != true
        }
    }

    static func operation(for urls: [URL]) -> NSDragOperation {
        accepts(urls: urls) ? .copy : []
    }

    @discardableResult
    static func perform(urls: [URL], add: (URL) -> Void) -> Bool {
        guard accepts(urls: urls) else { return false }
        urls.forEach(add)
        return true
    }
}

struct FavoritePasteboardDropSnapshot: Equatable {
    let urls: [URL]

    @MainActor
    static func validated(from pasteboard: NSPasteboard) -> FavoritePasteboardDropSnapshot? {
        guard let items = pasteboard.pasteboardItems, !items.isEmpty else { return nil }

        var urls: [URL] = []
        urls.reserveCapacity(items.count)
        for item in items {
            guard item.types.contains(.fileURL),
                  let value = item.string(forType: .fileURL),
                  let url = URL(string: value),
                  url.isFileURL,
                  url.path.hasPrefix("/")
            else { return nil }
            urls.append(url)
        }

        guard urls.count == items.count,
              FavoriteDropPolicy.accepts(urls: urls)
        else { return nil }
        return FavoritePasteboardDropSnapshot(urls: urls)
    }
}

enum FavoriteAddPolicy {
    static func canAdd(
        _ item: FileItem,
        containsExactURL: (URL) -> Bool
    ) -> Bool {
        FavoriteDropPolicy.accepts(item) && !containsExactURL(item.url)
    }
}

enum FavoriteNavigationResult: Equatable {
    case navigated(URL)
    case unavailable(lastKnownPath: String)
}

@MainActor
enum FavoriteNavigationRouter {
    static func open(
        _ resolution: FavoriteResolution,
        in pane: FilePaneState
    ) async -> FavoriteNavigationResult {
        switch resolution {
        case let .available(url):
            await pane.navigate(to: url)
            return .navigated(url)
        case let .unavailable(lastKnownPath):
            return .unavailable(lastKnownPath: lastKnownPath)
        }
    }
}

enum FavoriteRowPresentation {
    static func accessibilityLabel(name: String, resolution: FavoriteResolution) -> String {
        switch resolution {
        case .available:
            "Favorite, \(name)"
        case .unavailable:
            "Unavailable favorite, \(name)"
        }
    }
}

enum PlacesRailSection: CaseIterable {
    case places
    case cloud
    case favorites

    static let ordered: [PlacesRailSection] = [.places, .cloud, .favorites]
}

enum CloudLocationRowPresentation {
    struct Values: Equatable {
        let providerName: String
        let locationName: String
        let availabilityDescription: String
        let accessibilityLabel: String
        let systemImage: String
        let canNavigate: Bool
        let providerApplicationBundleIdentifier: String?
    }

    static func values(for location: StorageLocation) -> Values {
        let availabilityDescription = location.isAvailable ? "Available" : "Unavailable"
        return Values(
            providerName: location.provider.displayName,
            locationName: location.displayName,
            availabilityDescription: availabilityDescription,
            accessibilityLabel: [
                location.provider.displayName,
                location.displayName,
                availabilityDescription
            ].joined(separator: ", "),
            systemImage: location.provider.systemImage,
            canNavigate: location.isAvailable,
            providerApplicationBundleIdentifier: providerApplicationBundleIdentifier(
                for: location.provider
            )
        )
    }

    private static func providerApplicationBundleIdentifier(
        for provider: CloudProviderKind
    ) -> String? {
        switch provider {
        case .googleDrive: "com.google.drivefs"
        case .oneDrive: "com.microsoft.OneDrive"
        case .dropbox: "com.getdropbox.dropbox"
        case .iCloudDrive, .other: nil
        }
    }
}

@MainActor
enum CloudLocationNavigationRouter {
    @discardableResult
    static func open(
        _ location: StorageLocation,
        in pane: FilePaneState,
        accessCoordinator: CloudLocationScopedAccessCoordinator
    ) async -> Bool {
        guard location.isAvailable else { return false }
        let lease: CloudLocationScopedAccessLease?
        do {
            lease = try accessCoordinator.acquireAccess(for: location.rootURL)
        } catch {
            return false
        }
        defer { lease?.finish() }
        await pane.navigate(to: location.rootURL)
        return true
    }
}

@MainActor
enum CloudFolderPanelConfiguration {
    static func apply(to panel: NSOpenPanel) {
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Add"
        panel.message = "Choose a cloud-backed folder to show in the sidebar."
    }
}

@MainActor
protocol CloudLocationWorkspaceActions {
    func revealInFinder(_ url: URL)
    func applicationURL(forBundleIdentifier bundleIdentifier: String) -> URL?
    func openApplication(at url: URL)
}

@MainActor
struct LiveCloudLocationWorkspaceActions: CloudLocationWorkspaceActions {
    private let workspace: NSWorkspace

    init(workspace: NSWorkspace = .shared) {
        self.workspace = workspace
    }

    func revealInFinder(_ url: URL) {
        workspace.activateFileViewerSelecting([url])
    }

    func applicationURL(forBundleIdentifier bundleIdentifier: String) -> URL? {
        workspace.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }

    func openApplication(at url: URL) {
        workspace.openApplication(
            at: url,
            configuration: NSWorkspace.OpenConfiguration()
        ) { _, _ in }
    }
}

@MainActor
enum CloudLocationContextActions {
    @discardableResult
    static func revealInFinder(
        _ location: StorageLocation,
        workspaceActions: any CloudLocationWorkspaceActions,
        accessCoordinator: CloudLocationScopedAccessCoordinator
    ) -> Bool {
        guard location.isAvailable else { return false }
        let lease: CloudLocationScopedAccessLease?
        do {
            lease = try accessCoordinator.acquireAccess(for: location.rootURL)
        } catch {
            return false
        }
        defer { lease?.finish() }
        workspaceActions.revealInFinder(location.rootURL)
        return true
    }

    @discardableResult
    static func openProviderApplication(
        for location: StorageLocation,
        workspaceActions: any CloudLocationWorkspaceActions
    ) -> Bool {
        let presentation = CloudLocationRowPresentation.values(for: location)
        guard let bundleIdentifier = presentation.providerApplicationBundleIdentifier,
              let applicationURL = workspaceActions.applicationURL(
                  forBundleIdentifier: bundleIdentifier
              ) else {
            return false
        }
        workspaceActions.openApplication(at: applicationURL)
        return true
    }
}

struct PlacesRailView: View {
    let favorites: FavoritesStore
    let cloudLocations: CloudLocationsStore
    let smartSearch: SmartSearchStore
    let activePane: FilePaneState
    let cloudWorkspaceActions: any CloudLocationWorkspaceActions
    let cloudAccessCoordinator: CloudLocationScopedAccessCoordinator

    @State private var favoriteResolutions: [UUID: FavoriteResolution] = [:]
    @State private var alert: FavoriteRailAlert?

    private let places = Place.defaultPlaces

    var body: some View {
        List {
            ForEach(PlacesRailSection.ordered, id: \.self) { section in
                switch section {
                case .places:
                    Section("Places") {
                        ForEach(places) { place in
                            Button {
                                Task { await activePane.navigate(to: place.url) }
                            } label: {
                                Label(place.title, systemImage: place.systemImage)
                            }
                            .buttonStyle(.plain)
                            .help(place.title)
                            .accessibilityLabel(place.title)
                        }
                    }

                case .cloud:
                    CloudLocationsSection(
                        cloudLocations: cloudLocations,
                        activePane: activePane,
                        workspaceActions: cloudWorkspaceActions,
                        accessCoordinator: cloudAccessCoordinator
                    )

                case .favorites:
                    Section("Favorites") {
                        FavoriteDropTargetView(onDrop: addDroppedFavorites)
                            .frame(height: 28)

                        ForEach(favorites.records) { record in
                            let resolution = resolution(for: record)
                            Button {
                                open(record)
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: favoriteImage(for: resolution))
                                        .foregroundStyle(favoriteImageStyle(for: resolution))
                                        .accessibilityHidden(true)
                                    Text(record.displayName)
                                        .lineLimit(1)
                                }
                            }
                            .buttonStyle(.plain)
                            .help(record.lastKnownPath)
                            .accessibilityLabel(FavoriteRowPresentation.accessibilityLabel(
                                name: record.displayName,
                                resolution: resolution
                            ))
                            .contextMenu {
                                Button("Remove from Favorites", role: .destructive) {
                                    favorites.remove(id: record.id)
                                }
                            }
                        }
                        .onMove(perform: favorites.move)
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier(AccessibilityIdentifiers.favoritesSection)
                    .accessibilityLabel("Favorites")
                }
            }

            Section("Smart Searches") {
                if smartSearch.savedSearches.isEmpty {
                    Text("No saved searches")
                        .foregroundStyle(.secondary)
                }

                ForEach(smartSearch.savedSearches) { record in
                    Button {
                        open(record)
                    } label: {
                        Label(record.displayName, systemImage: "magnifyingglass")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(SmartSearchPresentation.savedSearchAccessibilityLabel(for: record))
                    .contextMenu {
                        Button(SmartSearchPresentation.deleteSavedSearchLabel, role: .destructive) {
                            _ = smartSearch.deleteSavedSearch(id: record.id)
                        }
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(AccessibilityIdentifiers.smartSearchSavedSearches)
            .accessibilityLabel("Saved searches")
        }
        .listStyle(.sidebar)
        .frame(width: 184)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityIdentifiers.placesRail)
        .accessibilityLabel("Places, Cloud, Favorites, and Smart Searches")
        .task(id: favorites.records) {
            refreshResolutions()
        }
        .alert(item: $alert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                primaryButton: alert.recordID.map { id in
                    .destructive(Text("Remove")) {
                        favorites.remove(id: id)
                    }
                } ?? .default(Text("OK")),
                secondaryButton: .cancel()
            )
        }
    }

    private func resolution(for record: FavoriteRecord) -> FavoriteResolution {
        favoriteResolutions[record.id] ?? .unavailable(lastKnownPath: record.lastKnownPath)
    }

    private func refreshResolutions() {
        var updated: [UUID: FavoriteResolution] = [:]
        for record in favorites.records {
            updated[record.id] = favorites.resolution(for: record)
        }
        favoriteResolutions = updated
    }

    private func open(_ record: FavoriteRecord) {
        let currentResolution = favorites.resolution(for: record)
        favoriteResolutions[record.id] = currentResolution
        Task {
            let result = await FavoriteNavigationRouter.open(currentResolution, in: activePane)
            if case let .unavailable(lastKnownPath) = result {
                alert = FavoriteRailAlert(
                    title: "Favorite Unavailable",
                    message: "This favorite could not be opened:\n\(lastKnownPath)",
                    recordID: record.id
                )
            }
        }
    }

    private func open(_ record: SmartSearchRecord) {
        smartSearch.openSavedSearch(record)
    }

    private func addDroppedFavorites(_ urls: [URL]) {
        guard FavoriteDropPolicy.accepts(urls: urls) else { return }
        for url in urls {
            do {
                try favorites.add(url)
            } catch {
                alert = FavoriteRailAlert(
                    title: "Could Not Add Favorite",
                    message: error.localizedDescription,
                    recordID: nil
                )
                return
            }
        }
        refreshResolutions()
    }

    private func favoriteImage(for resolution: FavoriteResolution) -> String {
        switch resolution {
        case .available: "folder"
        case .unavailable: "exclamationmark.triangle"
        }
    }

    private func favoriteImageStyle(for resolution: FavoriteResolution) -> AnyShapeStyle {
        switch resolution {
        case .available: AnyShapeStyle(.secondary)
        case .unavailable: AnyShapeStyle(.orange)
        }
    }
}

private struct CloudLocationsSection: View {
    let cloudLocations: CloudLocationsStore
    let activePane: FilePaneState
    let workspaceActions: any CloudLocationWorkspaceActions
    let accessCoordinator: CloudLocationScopedAccessCoordinator

    @State private var isRescanning = false
    @State private var alert: CloudRailAlert?

    var body: some View {
        Section {
            ForEach(cloudLocations.visibleLocations) { location in
                CloudLocationRow(
                    location: location,
                    activePane: activePane,
                    workspaceActions: workspaceActions,
                    accessCoordinator: accessCoordinator,
                    onRescan: rescan,
                    onHide: hide
                )
            }
        } header: {
            HStack(spacing: 6) {
                Text("Cloud")
                Spacer()
                if isRescanning {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Rescanning Cloud Locations")
                }
                Button(action: rescan) {
                    Image(systemName: "arrow.clockwise")
                        .accessibilityHidden(true)
                }
                .buttonStyle(.borderless)
                .disabled(isRescanning)
                .help("Rescan Cloud Locations")
                .accessibilityLabel("Rescan Cloud Locations")
                .accessibilityIdentifier(AccessibilityIdentifiers.cloudRescan)

                Button(action: addCloudFolder) {
                    Image(systemName: "plus")
                        .accessibilityHidden(true)
                }
                .buttonStyle(.borderless)
                .help("Add Cloud Folder")
                .accessibilityLabel("Add Cloud Folder")
                .accessibilityIdentifier(AccessibilityIdentifiers.cloudAddFolder)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityIdentifiers.cloudSection)
        .accessibilityLabel("Cloud")
        .alert(item: $alert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private func rescan() {
        guard !isRescanning else { return }
        isRescanning = true
        Task {
            defer { isRescanning = false }
            do {
                try await cloudLocations.rescan()
            } catch {
                alert = CloudRailAlert(
                    title: "Could Not Rescan Cloud Locations",
                    message: error.localizedDescription
                )
            }
        }
    }

    private func addCloudFolder() {
        let panel = NSOpenPanel()
        CloudFolderPanelConfiguration.apply(to: panel)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try cloudLocations.addManualLocation(url)
        } catch {
            alert = CloudRailAlert(
                title: "Could Not Add Cloud Folder",
                message: error.localizedDescription
            )
        }
    }

    private func hide(_ location: StorageLocation) {
        do {
            try cloudLocations.hide(location.id)
        } catch {
            alert = CloudRailAlert(
                title: "Could Not Hide Cloud Location",
                message: error.localizedDescription
            )
        }
    }
}

private struct CloudLocationRow: View {
    let location: StorageLocation
    let activePane: FilePaneState
    let workspaceActions: any CloudLocationWorkspaceActions
    let accessCoordinator: CloudLocationScopedAccessCoordinator
    let onRescan: () -> Void
    let onHide: (StorageLocation) -> Void

    private var presentation: CloudLocationRowPresentation.Values {
        CloudLocationRowPresentation.values(for: location)
    }

    var body: some View {
        Group {
            if presentation.canNavigate {
                Button {
                    Task {
                        await CloudLocationNavigationRouter.open(
                            location,
                            in: activePane,
                            accessCoordinator: accessCoordinator
                        )
                    }
                } label: {
                    rowLabel
                }
                .buttonStyle(.plain)
            } else {
                rowLabel
            }
        }
        .help(location.rootURL.path)
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier(AccessibilityIdentifiers.cloudLocationRow(location.id))
        .accessibilityLabel(presentation.accessibilityLabel)
        .contextMenu {
            if presentation.canNavigate {
                Button("Show in Finder") {
                    CloudLocationContextActions.revealInFinder(
                        location,
                        workspaceActions: workspaceActions,
                        accessCoordinator: accessCoordinator
                    )
                }
            }

            if let bundleIdentifier = presentation.providerApplicationBundleIdentifier,
               workspaceActions.applicationURL(
                   forBundleIdentifier: bundleIdentifier
               ) != nil {
                Button("Open Provider App") {
                    CloudLocationContextActions.openProviderApplication(
                        for: location,
                        workspaceActions: workspaceActions
                    )
                }
            }

            Button("Rescan Cloud Locations") {
                onRescan()
            }

            Divider()

            Button("Hide from Sidebar", role: .destructive) {
                onHide(location)
            }
        }
    }

    private var rowLabel: some View {
        HStack(spacing: 8) {
            Image(systemName: presentation.systemImage)
                .foregroundStyle(presentation.canNavigate ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                .frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(presentation.locationName)
                    .lineLimit(1)
                Text("\(presentation.providerName) · \(presentation.availabilityDescription)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

private struct FavoriteRailAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let recordID: UUID?
}

private struct CloudRailAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

private struct FavoriteDropTargetView: NSViewRepresentable {
    let onDrop: ([URL]) -> Void

    func makeNSView(context: Context) -> FavoriteDropTargetNSView {
        FavoriteDropTargetNSView(onDrop: onDrop)
    }

    func updateNSView(_ nsView: FavoriteDropTargetNSView, context: Context) {
        nsView.onDrop = onDrop
    }
}

final class FavoriteDropTargetNSView: NSView {
    var onDrop: ([URL]) -> Void
    private let label = NSTextField(labelWithString: "Drop folders to add")

    init(onDrop: @escaping ([URL]) -> Void) {
        self.onDrop = onDrop
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL])
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        setAccessibilityElement(true)
        setAccessibilityLabel("Add folders to Favorites")
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        FavoritePasteboardDropSnapshot.validated(from: sender.draggingPasteboard) == nil ? [] : .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        FavoritePasteboardDropSnapshot.validated(from: sender.draggingPasteboard) != nil
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let snapshot = FavoritePasteboardDropSnapshot.validated(
            from: sender.draggingPasteboard
        ) else { return false }
        onDrop(snapshot.urls)
        return true
    }
}

private struct Place: Identifiable {
    let title: String
    let systemImage: String
    let url: URL

    var id: URL { url }

    @MainActor
    static var defaultPlaces: [Place] {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        var places = [Place(title: "Home", systemImage: "house", url: home)]

        if let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            places.append(Place(title: "Documents", systemImage: "doc", url: documents))
        }
        if let downloads = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first {
            places.append(Place(title: "Downloads", systemImage: "arrow.down.circle", url: downloads))
        }

        let volumeKeys: [URLResourceKey] = [.volumeIsLocalKey]
        let volumes = fileManager.mountedVolumeURLs(
            includingResourceValuesForKeys: volumeKeys,
            options: [.skipHiddenVolumes]
        ) ?? []
        for volume in volumes where (try? volume.resourceValues(forKeys: Set(volumeKeys)).volumeIsLocal) == true {
            places.append(Place(
                title: volume.lastPathComponent.isEmpty ? "Macintosh HD" : volume.lastPathComponent,
                systemImage: "externaldrive",
                url: volume
            ))
        }

        if let iCloudDrive = iCloudDriveURL(fileManager: fileManager) {
            places.append(Place(title: "iCloud Drive", systemImage: "icloud", url: iCloudDrive))
        }

        var seen = Set<URL>()
        return places.filter { seen.insert($0.url.standardizedFileURL).inserted }
    }

    @MainActor
    private static func iCloudDriveURL(fileManager: FileManager) -> URL? {
        if let container = fileManager.url(forUbiquityContainerIdentifier: nil) {
            let documents = container.appending(path: "Documents", directoryHint: .isDirectory)
            if fileManager.fileExists(atPath: documents.path) {
                return documents
            }
        }

        let cloudDocs = fileManager.homeDirectoryForCurrentUser
            .appending(path: "Library/Mobile Documents/com~apple~CloudDocs", directoryHint: .isDirectory)
        return fileManager.fileExists(atPath: cloudDocs.path) ? cloudDocs : nil
    }
}
