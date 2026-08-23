import Foundation

struct CommandPaletteFavoriteCandidate: Sendable {
    let record: FavoriteRecord
    let resolution: FavoriteResolution

    init(record: FavoriteRecord, resolution: FavoriteResolution) {
        self.record = record
        self.resolution = resolution
    }
}

enum CommandPaletteBuilder {
    static func build(
        currentDirectory: URL,
        backHistory: [URL],
        forwardHistory: [URL],
        favorites: [CommandPaletteFavoriteCandidate],
        profiles: [WorkspaceProfileRecord],
        savedSearches: [SmartSearchRecord]
    ) -> [CommandPaletteItem] {
        var items = fixedCommands
        var seenNavigationPaths = Set<String>()

        appendNavigation(
            currentDirectory,
            title: displayName(for: currentDirectory),
            subtitle: "Current Directory",
            source: .currentDirectory,
            to: &items,
            seenNavigationPaths: &seenNavigationPaths
        )
        for url in backHistory {
            appendNavigation(
                url,
                title: displayName(for: url),
                subtitle: "Back History",
                source: .backHistory,
                to: &items,
                seenNavigationPaths: &seenNavigationPaths
            )
        }
        for url in forwardHistory {
            appendNavigation(
                url,
                title: displayName(for: url),
                subtitle: "Forward History",
                source: .forwardHistory,
                to: &items,
                seenNavigationPaths: &seenNavigationPaths
            )
        }
        for favorite in favorites {
            guard case let .available(url) = favorite.resolution else { continue }
            appendNavigation(
                url,
                title: favorite.record.displayName,
                subtitle: "Favorite",
                source: .favorite,
                to: &items,
                seenNavigationPaths: &seenNavigationPaths
            )
        }
        items.append(contentsOf: profiles.map {
            CommandPaletteItem(
                title: $0.name,
                subtitle: "Workspace Profile",
                keywords: [$0.descriptor.leftPath, $0.descriptor.rightPath],
                action: .openProfile($0.id),
                source: .workspaceProfile
            )
        })
        items.append(contentsOf: savedSearches.map {
            CommandPaletteItem(
                title: $0.displayName,
                subtitle: "Saved Search",
                keywords: [$0.query.text] + $0.query.roots.map(\.path),
                action: .openSavedSearch($0.id),
                source: .savedSearch
            )
        })
        return deduplicatingStableIDs(in: items)
    }

    private static let fixedCommands = [
        CommandPaletteItem(title: "Create Folder", subtitle: "Safe Command", keywords: ["new folder"], action: .createFolder),
        CommandPaletteItem(title: "Create File", subtitle: "Safe Command", keywords: ["new file"], action: .createFile),
        CommandPaletteItem(title: "Show Filter", subtitle: "Safe Command", keywords: ["filter"], action: .showFilter),
        CommandPaletteItem(title: "Smart Search", subtitle: "Safe Command", keywords: ["search"], action: .showSmartSearch)
    ]

    private static func appendNavigation(
        _ url: URL,
        title: String,
        subtitle: String,
        source: CommandPaletteItemSource,
        to items: inout [CommandPaletteItem],
        seenNavigationPaths: inout Set<String>
    ) {
        let standardized = url.standardizedFileURL
        let path = standardized.path(percentEncoded: false)
        guard seenNavigationPaths.insert(path).inserted else { return }
        items.append(CommandPaletteItem(
            title: title,
            subtitle: subtitle,
            keywords: [path],
            action: .navigate(standardized),
            source: source
        ))
    }

    private static func displayName(for url: URL) -> String {
        let standardized = url.standardizedFileURL
        let name = standardized.lastPathComponent
        return name.isEmpty ? standardized.path : name
    }

    private static func deduplicatingStableIDs(in items: [CommandPaletteItem]) -> [CommandPaletteItem] {
        var seenIDs = Set<String>()
        return items.filter { seenIDs.insert($0.id).inserted }
    }
}
