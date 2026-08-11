import AppKit
import Foundation

enum FileContextActionError: Sendable, Equatable {
    case itemChanged
    case accessDenied
}

@MainActor
protocol FinderRevealing {
    func reveal(_ urls: [URL])
}

@MainActor
protocol TextPasteboardWriting {
    func writePlainText(_ value: String)
}

@MainActor
protocol ContextActionAnnouncementPosting: AnyObject {
    func post(_ message: String)
}

@MainActor
struct LiveFinderRevealer: FinderRevealing {
    func reveal(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}

@MainActor
struct LiveTextPasteboardWriter: TextPasteboardWriting {
    func writePlainText(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

@MainActor
final class LiveContextActionAnnouncementPoster: ContextActionAnnouncementPosting {
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

@MainActor
final class FileContextActionRouter {
    private let fileSystem: any FileSystemAccess
    private let accessCoordinator: CloudLocationScopedAccessCoordinator
    private let finderRevealer: any FinderRevealing
    private let pasteboardWriter: any TextPasteboardWriting
    private let announcementPoster: any ContextActionAnnouncementPosting

    private(set) var error: FileContextActionError?

    init(
        fileSystem: any FileSystemAccess = LiveFileSystemAccess(),
        accessCoordinator: CloudLocationScopedAccessCoordinator = .init(),
        finderRevealer: any FinderRevealing = LiveFinderRevealer(),
        pasteboardWriter: any TextPasteboardWriting = LiveTextPasteboardWriter(),
        announcementPoster: any ContextActionAnnouncementPosting = LiveContextActionAnnouncementPoster()
    ) {
        self.fileSystem = fileSystem
        self.accessCoordinator = accessCoordinator
        self.finderRevealer = finderRevealer
        self.pasteboardWriter = pasteboardWriter
        self.announcementPoster = announcementPoster
    }

    func capture(_ draft: ContextActionDraft) async -> ContextActionSnapshot? {
        error = nil
        guard !Task.isCancelled else { return nil }

        let accessLeases: [CloudLocationScopedAccessLease]
        do {
            accessLeases = try accessCoordinator.acquireAccess(for: draft.sources.map(\.url) + [
                draft.sourceDirectory,
                draft.oppositeDirectory
            ])
        } catch {
            guard !Task.isCancelled else { return nil }
            self.error = .accessDenied
            return nil
        }
        defer { accessLeases.forEach { $0.finish() } }

        var sources: [ContextActionSource] = []
        sources.reserveCapacity(draft.sources.count)
        for item in draft.sources {
            guard let identity = await identity(at: item.url) else { return nil }
            sources.append(ContextActionSource(item: item, identity: identity))
        }
        guard let sourceDirectoryIdentity = await identity(at: draft.sourceDirectory),
              let oppositeDirectoryIdentity = await identity(at: draft.oppositeDirectory),
              !Task.isCancelled
        else {
            return nil
        }

        guard let snapshot = ContextActionSnapshot(
            draft: draft,
            sources: sources,
            sourceDirectory: IdentifiedFileRequest(
                url: draft.sourceDirectory,
                identity: sourceDirectoryIdentity
            ),
            oppositeDirectory: IdentifiedFileRequest(
                url: draft.oppositeDirectory,
                identity: oppositeDirectoryIdentity
            )
        ) else {
            error = .itemChanged
            return nil
        }
        return snapshot
    }

    func showInFinder(_ snapshot: ContextActionSnapshot) async -> Bool {
        error = nil
        guard !Task.isCancelled else { return false }

        let accessLeases: [CloudLocationScopedAccessLease]
        do {
            accessLeases = try accessCoordinator.acquireAccess(for: snapshot.sources.map { $0.item.url })
        } catch {
            guard !Task.isCancelled else { return false }
            self.error = .accessDenied
            return false
        }
        defer { accessLeases.forEach { $0.finish() } }

        var currentURLs: [URL] = []
        currentURLs.reserveCapacity(snapshot.sources.count)
        for source in snapshot.sources {
            guard !Task.isCancelled else { return false }
            guard let currentIdentity = await currentIdentity(at: source.item.url) else { continue }
            guard !Task.isCancelled else { return false }
            if currentIdentity.refersToSameItem(as: source.identity) {
                currentURLs.append(source.item.url)
            }
        }

        guard !currentURLs.isEmpty else {
            error = .itemChanged
            return false
        }
        finderRevealer.reveal(currentURLs)
        return true
    }

    @discardableResult
    func copyPath(
        _ representation: PathCopyRepresentation,
        from snapshot: ContextActionSnapshot
    ) -> Int {
        let values: [String]
        let message: String
        switch representation {
        case .fullPath:
            values = snapshot.sources.map { $0.item.url.standardizedFileURL.path }
            message = "Copied full paths for \(values.count) items."
        case .name:
            values = snapshot.sources.map { $0.item.name }
            message = "Copied names for \(values.count) items."
        case .parentPath:
            values = [snapshot.sourceDirectory.url.path]
            message = "Copied parent path."
        case .fileURL:
            values = snapshot.sources.map { $0.item.url.standardizedFileURL.absoluteString }
            message = "Copied file URLs for \(values.count) items."
        }
        guard !values.isEmpty else { return 0 }

        pasteboardWriter.writePlainText(values.joined(separator: "\n"))
        announcementPoster.post(message)
        return values.count
    }

    func quickLook(
        _ snapshot: ContextActionSnapshot,
        previewCoordinator: WorkspacePreviewCoordinator
    ) async -> Bool {
        error = nil
        guard !Task.isCancelled else { return false }

        let accessLeases: [CloudLocationScopedAccessLease]
        do {
            accessLeases = try accessCoordinator.acquireAccess(for: snapshot.sources.map(\.item.url))
        } catch {
            guard !Task.isCancelled else { return false }
            self.error = .accessDenied
            return false
        }
        defer { accessLeases.forEach { $0.finish() } }

        guard await sourcesStillMatch(snapshot.sources), !Task.isCancelled else { return false }
        await previewCoordinator.toggle(
            selection: WorkspacePreviewSelection(
                paneID: snapshot.sourcePaneID,
                items: snapshot.sources.map(\.item)
            )
        )
        return !Task.isCancelled && previewCoordinator.mode != .closed
    }

    func openInOtherPane(
        _ snapshot: ContextActionSnapshot,
        targetPane: FilePaneState
    ) async -> Bool {
        error = nil
        guard !Task.isCancelled,
              snapshot.sources.count == 1,
              let source = snapshot.sources.first
        else {
            error = .itemChanged
            return false
        }

        let accessLeases: [CloudLocationScopedAccessLease]
        do {
            accessLeases = try accessCoordinator.acquireAccess(for: [
                source.item.url,
                snapshot.sourceDirectory.url
            ])
        } catch {
            guard !Task.isCancelled else { return false }
            self.error = .accessDenied
            return false
        }
        defer { accessLeases.forEach { $0.finish() } }

        guard await sourceStillMatches(source),
              await requestStillMatches(snapshot.sourceDirectory),
              !Task.isCancelled
        else { return false }

        let isOrdinaryDirectory = source.item.isDirectory
            && !source.item.isPackage
            && !source.item.isSymbolicLink
        let destination = isOrdinaryDirectory
            ? source.item.url.standardizedFileURL
            : snapshot.sourceDirectory.url.standardizedFileURL

        await targetPane.navigate(to: destination)
        guard !Task.isCancelled,
              targetPane.currentDirectory.standardizedFileURL == destination,
              targetPane.errorMessage == nil,
              !targetPane.isLoading
        else { return false }

        guard !isOrdinaryDirectory else { return true }
        guard let listedItem = targetPane.visibleItems.first(where: {
            $0.url.standardizedFileURL == source.item.url.standardizedFileURL
        }),
        await sourceStillMatches(source),
        let listedIdentity = await currentIdentity(at: listedItem.url),
        listedIdentity.refersToSameItem(as: source.identity),
        !Task.isCancelled
        else {
            error = .itemChanged
            return false
        }

        targetPane.selection = [listedItem.url]
        return true
    }

    private func identity(at url: URL) async -> FileIdentity? {
        do {
            try Task.checkCancellation()
            guard let identity = try await fileSystem.identity(of: url) else {
                error = .itemChanged
                return nil
            }
            try Task.checkCancellation()
            return identity
        } catch is CancellationError {
            return nil
        } catch {
            self.error = .itemChanged
            return nil
        }
    }

    private func currentIdentity(at url: URL) async -> FileIdentity? {
        do {
            return try await fileSystem.identity(of: url)
        } catch {
            return nil
        }
    }

    private func sourcesStillMatch(_ sources: [ContextActionSource]) async -> Bool {
        for source in sources {
            guard await sourceStillMatches(source), !Task.isCancelled else { return false }
        }
        return true
    }

    private func sourceStillMatches(_ source: ContextActionSource) async -> Bool {
        guard let currentIdentity = await currentIdentity(at: source.item.url),
              currentIdentity.refersToSameItem(as: source.identity)
        else {
            error = .itemChanged
            return false
        }
        return true
    }

    private func requestStillMatches(_ request: IdentifiedFileRequest) async -> Bool {
        guard let currentIdentity = await currentIdentity(at: request.url),
              currentIdentity.refersToSameItem(as: request.identity)
        else {
            error = .itemChanged
            return false
        }
        return true
    }
}
