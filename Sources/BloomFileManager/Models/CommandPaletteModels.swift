import Foundation

enum CommandPaletteAction: Hashable, Sendable {
    case createFolder
    case createFile
    case showFilter
    case showSmartSearch
    case navigate(URL)
    case openProfile(WorkspaceProfileID)
    case openSavedSearch(UUID)
}

enum CommandPaletteItemSource: Equatable, Sendable {
    case command
    case currentDirectory
    case backHistory
    case forwardHistory
    case favorite
    case workspaceProfile
    case savedSearch
}

extension CommandPaletteItemSource {
    var accessibilityCategory: String {
        switch self {
        case .command: "Command"
        case .currentDirectory: "Current directory"
        case .backHistory: "Back history"
        case .forwardHistory: "Forward history"
        case .favorite: "Favorite"
        case .workspaceProfile: "Workspace profile"
        case .savedSearch: "Saved search"
        }
    }
}

struct CommandPaletteItem: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let subtitle: String?
    let keywords: [String]
    let action: CommandPaletteAction
    let source: CommandPaletteItemSource

    init(
        title: String,
        subtitle: String? = nil,
        keywords: [String] = [],
        action: CommandPaletteAction,
        source: CommandPaletteItemSource = .command
    ) {
        let normalizedAction = Self.normalized(action)
        self.id = Self.stableID(for: normalizedAction)
        self.title = title
        self.subtitle = subtitle
        self.keywords = keywords
        self.action = normalizedAction
        self.source = source
    }

    private static func stableID(for action: CommandPaletteAction) -> String {
        switch action {
        case .createFolder:
            "command:create-folder"
        case .createFile:
            "command:create-file"
        case .showFilter:
            "command:show-filter"
        case .showSmartSearch:
            "command:show-smart-search"
        case let .navigate(url):
            "navigate:\(navigationPath(for: url))"
        case let .openProfile(id):
            "profile:\(id.rawValue.uuidString.lowercased())"
        case let .openSavedSearch(id):
            "saved-search:\(id.uuidString.lowercased())"
        }
    }

    private static func normalized(_ action: CommandPaletteAction) -> CommandPaletteAction {
        guard case let .navigate(url) = action else { return action }
        return .navigate(url.standardizedFileURL)
    }

    private static func navigationPath(for url: URL) -> String {
        let standardized = url.standardizedFileURL
        return standardized.isFileURL ? standardized.path(percentEncoded: false) : standardized.absoluteString
    }
}

enum CommandPaletteMatcher {
    static func ranked(_ items: [CommandPaletteItem], query: String) -> [CommandPaletteItem] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return items }

        let foldedQuery = folded(trimmedQuery)
        let smartSearchPlan = SmartSearchTextAnalyzer.queryPlan(for: trimmedQuery)
        let rankedItems: [RankedItem] = items.enumerated().compactMap { index, item in
            guard let rank = rank(
                item,
                foldedQuery: foldedQuery,
                smartSearchPlan: smartSearchPlan
            ) else { return nil }
            return RankedItem(item: item, rank: rank, originalIndex: index)
        }
        return rankedItems.sorted { lhs, rhs in
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            if lhs.originalIndex != rhs.originalIndex { return lhs.originalIndex < rhs.originalIndex }
            return lhs.item.id < rhs.item.id
        }
        .map(\.item)
    }

    private static func rank(
        _ item: CommandPaletteItem,
        foldedQuery: String,
        smartSearchPlan: SmartSearchQueryPlan
    ) -> Int? {
        let foldedTitle = folded(item.title)
        if foldedTitle == foldedQuery { return 0 }
        if foldedTitle.hasPrefix(foldedQuery) { return 1 }
        if foldedTitle.contains(foldedQuery) { return 2 }
        if SmartSearchTextAnalyzer.match(
            plan: smartSearchPlan,
            filename: item.title,
            relativePath: item.title
        ) != nil { return 3 }

        let auxiliaryText = item.keywords + (item.subtitle.map { [$0] } ?? [])
        if auxiliaryText.contains(where: { folded($0).contains(foldedQuery) }) { return 4 }
        if isOrderedSubsequence(foldedQuery, of: foldedTitle) { return 5 }
        return nil
    }

    private static func folded(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    private static func isOrderedSubsequence(_ query: String, of candidate: String) -> Bool {
        guard !query.isEmpty else { return true }
        var queryIndex = query.startIndex
        for character in candidate where character == query[queryIndex] {
            queryIndex = query.index(after: queryIndex)
            if queryIndex == query.endIndex { return true }
        }
        return false
    }

    private struct RankedItem {
        let item: CommandPaletteItem
        let rank: Int
        let originalIndex: Int
    }
}
