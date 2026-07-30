import Foundation
import Observation

enum PaneID: String, Sendable {
    case left
    case right
}

struct TrashRequest: Identifiable, Equatable {
    let id = UUID()
    let items: [IdentifiedFileRequest]
    var urls: [URL] { items.map(\.url) }
}

struct WorkspaceTextEditingSession: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case path
        case inlineName
        case filter
    }

    let id: UUID
    let paneID: PaneID
    let kind: Kind

    init(id: UUID = UUID(), paneID: PaneID, kind: Kind) {
        self.id = id
        self.paneID = paneID
        self.kind = kind
    }
}

@MainActor @Observable
final class WorkspaceState {
    let left: FilePaneState
    let right: FilePaneState
    var activePaneID: PaneID = .left
    var splitRatio: Double {
        didSet {
            guard splitRatio != oldValue else { return }
            scheduleSplitRatioPersistence()
        }
    }
    private(set) var pendingTrashRequest: TrashRequest?
    private(set) var activeTextEditingSession: WorkspaceTextEditingSession?
    private let persistence: WorkspacePersistence?
    let leftFallbackURL: URL
    let rightFallbackURL: URL
    private var persistedSplitRatio: Double
    private var splitRatioPersistenceTask: Task<Void, Never>?

    var activePane: FilePaneState {
        activePaneID == .left ? left : right
    }

    var selectedURLsForCommands: [URL] {
        activePane.selection.sorted { $0.path < $1.path }
    }

    init(
        leftURL: URL,
        rightURL: URL,
        leftFallbackURL: URL? = nil,
        rightFallbackURL: URL? = nil,
        leftSort: FileSort = FileSort(),
        rightSort: FileSort = FileSort(),
        splitRatio: Double = 0.5,
        listingService: any DirectoryListingService,
        monitor: any DirectoryMonitor = LiveDirectoryMonitor(),
        persistence: WorkspacePersistence? = nil
    ) {
        let normalizedRatio = WorkspaceSplitRatio.clamped(splitRatio)
        left = FilePaneState(
            directory: leftURL,
            sort: leftSort,
            listingService: listingService,
            monitor: monitor
        )
        right = FilePaneState(
            directory: rightURL,
            sort: rightSort,
            listingService: listingService,
            monitor: monitor
        )
        self.splitRatio = normalizedRatio
        persistedSplitRatio = normalizedRatio
        self.persistence = persistence
        self.leftFallbackURL = leftFallbackURL ?? leftURL
        self.rightFallbackURL = rightFallbackURL ?? rightURL

        left.setPersistenceChangeHandler { [weak self] in
            self?.saveWorkspaceSnapshot()
        }
        right.setPersistenceChangeHandler { [weak self] in
            self?.saveWorkspaceSnapshot()
        }
    }

    convenience init(
        restored: RestoredWorkspace,
        listingService: any DirectoryListingService,
        monitor: any DirectoryMonitor = LiveDirectoryMonitor(),
        persistence: WorkspacePersistence,
        leftFallbackURL: URL? = nil,
        rightFallbackURL: URL? = nil
    ) {
        self.init(
            leftURL: restored.leftURL,
            rightURL: restored.rightURL,
            leftFallbackURL: leftFallbackURL,
            rightFallbackURL: rightFallbackURL,
            leftSort: restored.leftSort,
            rightSort: restored.rightSort,
            splitRatio: restored.splitRatio,
            listingService: listingService,
            monitor: monitor,
            persistence: persistence
        )
    }

    func activate(_ pane: PaneID) {
        activePaneID = pane
    }

    func requestTrashConfirmation(for items: [IdentifiedFileRequest]) {
        guard !items.isEmpty else { return }
        pendingTrashRequest = TrashRequest(items: items)
    }

    func requestTrashConfirmation(for urls: [URL]) {
        requestTrashConfirmation(for: urls.map {
            IdentifiedFileRequest(
                url: $0,
                identity: FileIdentity(entryIdentifier: "uncaptured", resolvedIdentifier: "uncaptured")
            )
        })
    }

    func dismissTrashConfirmation() {
        pendingTrashRequest = nil
    }

    func beginTextEditing(_ session: WorkspaceTextEditingSession) {
        activeTextEditingSession = session
    }

    func endTextEditing(_ session: WorkspaceTextEditingSession) {
        guard activeTextEditingSession == session else { return }
        activeTextEditingSession = nil
    }

    func loadInitialDirectories() async {
        async let leftLoad: Void = left.navigate(to: left.currentDirectory, recordHistory: false)
        async let rightLoad: Void = right.navigate(to: right.currentDirectory, recordHistory: false)
        _ = await (leftLoad, rightLoad)
        if left.errorMessage != nil, left.currentDirectory != leftFallbackURL {
            await left.navigate(to: leftFallbackURL, recordHistory: false)
        }
        if right.errorMessage != nil, right.currentDirectory != rightFallbackURL {
            await right.navigate(to: rightFallbackURL, recordHistory: false)
        }
    }

    func fallbackURL(for paneID: PaneID) -> URL {
        paneID == .left ? leftFallbackURL : rightFallbackURL
    }

    func fallbackDisplayName(for paneID: PaneID) -> String {
        let fallback = fallbackURL(for: paneID).standardizedFileURL
        if fallback == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL {
            return "Home"
        }
        let name = fallback.lastPathComponent
        return name.isEmpty ? "Fallback Folder" : name
    }

    func flushPendingPersistence() {
        guard splitRatioPersistenceTask != nil else { return }
        splitRatioPersistenceTask?.cancel()
        splitRatioPersistenceTask = nil
        persistedSplitRatio = WorkspaceSplitRatio.clamped(splitRatio)
        saveWorkspaceSnapshot()
    }

    private func scheduleSplitRatioPersistence() {
        guard persistence != nil else { return }
        splitRatioPersistenceTask?.cancel()
        splitRatioPersistenceTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(300))
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            persistedSplitRatio = WorkspaceSplitRatio.clamped(splitRatio)
            splitRatioPersistenceTask = nil
            saveWorkspaceSnapshot()
        }
    }

    private func saveWorkspaceSnapshot() {
        persistence?.save(WorkspaceSnapshot(
            leftPath: left.committedDirectoryForPersistence.path,
            rightPath: right.committedDirectoryForPersistence.path,
            leftSort: left.sort,
            rightSort: right.sort,
            splitRatio: persistedSplitRatio
        ))
    }
}
