import Foundation
import Testing
@testable import BloomFileManager

@Suite struct CommandPaletteModelsTests {
    @Test func emptyQueryPreservesCandidateOrder() {
        let items = [
            CommandPaletteItem(title: "Zulu", action: .createFolder),
            CommandPaletteItem(title: "Alpha", action: .createFile)
        ]

        #expect(CommandPaletteMatcher.ranked(items, query: "") == items)
    }

    @Test func whitespaceOnlyQueryPreservesCandidateOrder() {
        let items = [
            CommandPaletteItem(title: "Zulu", action: .createFolder),
            CommandPaletteItem(title: "Alpha", action: .createFile)
        ]

        #expect(CommandPaletteMatcher.ranked(items, query: " \n\t ") == items)
    }

    @Test func exactPrefixAndSubstringTitleMatchesRankInThatOrder() {
        let items = [
            CommandPaletteItem(title: "Reopen Folder", action: .createFolder),
            CommandPaletteItem(title: "Open", action: .createFile),
            CommandPaletteItem(title: "Open Recent", action: .showFilter)
        ]

        #expect(CommandPaletteMatcher.ranked(items, query: "open").map(\.action) == [
            .createFile, .showFilter, .createFolder
        ])
    }

    @Test func matcherFoldsCaseDiacriticsAndWidth() {
        let item = CommandPaletteItem(title: "Caf\u{00E9}", action: .createFolder)
        let widthItem = CommandPaletteItem(title: "\u{FF26}\u{FF4F}\u{FF4C}\u{FF44}\u{FF45}\u{FF52}", action: .createFile)

        #expect(CommandPaletteMatcher.ranked([item], query: "CAFE") == [item])
        #expect(CommandPaletteMatcher.ranked([widthItem], query: "folder") == [widthItem])
    }

    @Test func orderedSubsequenceMatchesAfterStrongerStrategies() {
        let subsequence = CommandPaletteItem(title: "Create New Folder", action: .createFolder)
        let substring = CommandPaletteItem(title: "Folder", action: .createFile)

        #expect(CommandPaletteMatcher.ranked([subsequence, substring], query: "fdr") == [subsequence, substring])
        #expect(CommandPaletteMatcher.ranked([subsequence, substring], query: "folder") == [substring, subsequence])
    }

    @Test func hangulInitialsUseSmartSearchTextAnalyzer() {
        let korean = CommandPaletteItem(title: "\u{D30C}\u{C77C}\u{AD00}\u{B9AC}", action: .createFolder)
        let other = CommandPaletteItem(title: "\u{D30C}\u{C77C} \u{C5F4}\u{AE30}", action: .createFile)

        #expect(CommandPaletteMatcher.ranked([other, korean], query: "\u{314D}\u{3131}") == [korean])
    }

    @Test func keywordAndSubtitleMatchesFollowSmartSearchMatches() {
        let initialMatch = CommandPaletteItem(title: "\u{D30C}\u{C77C}\u{AD00}\u{B9AC}", action: .createFolder)
        let keywordMatch = CommandPaletteItem(title: "Create Folder", subtitle: "Safe command", keywords: ["\u{D30C}\u{C77C}"], action: .createFile)

        #expect(CommandPaletteMatcher.ranked([keywordMatch, initialMatch], query: "\u{314D}\u{3131}") == [initialMatch])
        #expect(CommandPaletteMatcher.ranked([keywordMatch, initialMatch], query: "safe") == [keywordMatch])
    }

    @Test func equalRankPreservesInputOrderThenUsesStableID() {
        let first = CommandPaletteItem(title: "Alpha One", action: .createFolder)
        let second = CommandPaletteItem(title: "Alpha Two", action: .createFile)

        #expect(CommandPaletteMatcher.ranked([second, first], query: "alpha") == [second, first])
        #expect(first.id == CommandPaletteItem(title: "Renamed", action: .createFolder).id)
    }
}
