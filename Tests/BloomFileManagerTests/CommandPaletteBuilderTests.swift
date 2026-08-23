import Foundation
import Testing
@testable import BloomFileManager

@Suite struct CommandPaletteBuilderTests {
    @Test func buildsFixedCommandsBeforeNavigationAndOtherSources() throws {
        let profile = try profile(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "Design")
        let search = try savedSearch(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, name: "Images")
        let favorite = FavoriteRecord(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            displayName: "Documents",
            bookmarkData: Data(),
            lastKnownPath: "/Users/test/Documents"
        )
        let items = CommandPaletteBuilder.build(
            currentDirectory: URL(filePath: "/Users/test/Current"),
            backHistory: [URL(filePath: "/Users/test/Back")],
            forwardHistory: [URL(filePath: "/Users/test/Forward")],
            favorites: [.init(record: favorite, resolution: .available(URL(filePath: "/Users/test/Documents")))],
            profiles: [profile],
            savedSearches: [search]
        )

        #expect(items.map(\.action) == [
            .createFolder, .createFile, .showFilter, .showSmartSearch,
            .navigate(URL(filePath: "/Users/test/Current")),
            .navigate(URL(filePath: "/Users/test/Back")),
            .navigate(URL(filePath: "/Users/test/Forward")),
            .navigate(URL(filePath: "/Users/test/Documents")),
            .openProfile(profile.id), .openSavedSearch(search.id)
        ])
    }

    @Test func navigationUsesStandardizedPathsAndKeepsFirstSource() {
        let current = URL(filePath: "/Users/test/Current")
        let duplicate = URL(filePath: "/Users/test/Current/../Current")
        let favorite = FavoriteRecord(id: UUID(), displayName: "Current", bookmarkData: Data(), lastKnownPath: duplicate.path)

        let items = CommandPaletteBuilder.build(
            currentDirectory: current,
            backHistory: [duplicate],
            forwardHistory: [duplicate],
            favorites: [.init(record: favorite, resolution: .available(duplicate))],
            profiles: [],
            savedSearches: []
        )
        let navigationItems = items.filter { if case .navigate = $0.action { true } else { false } }

        #expect(navigationItems.count == 1)
        #expect(navigationItems[0].source == .currentDirectory)
        #expect(navigationItems[0].action == .navigate(current.standardizedFileURL))
    }

    @Test func unavailableFavoritesAreOmittedWithoutAccessingTheFileSystem() {
        let unavailable = FavoriteRecord(id: UUID(), displayName: "Offline", bookmarkData: Data(), lastKnownPath: "/offline")
        let available = FavoriteRecord(id: UUID(), displayName: "Online", bookmarkData: Data(), lastKnownPath: "/online")

        let items = CommandPaletteBuilder.build(
            currentDirectory: URL(filePath: "/current"),
            backHistory: [],
            forwardHistory: [],
            favorites: [
                .init(record: unavailable, resolution: .unavailable(lastKnownPath: "/offline")),
                .init(record: available, resolution: .available(URL(filePath: "/online")))
            ],
            profiles: [],
            savedSearches: []
        )

        #expect(items.contains { $0.action == .navigate(URL(filePath: "/online")) })
        #expect(!items.contains { $0.action == .navigate(URL(filePath: "/offline")) })
    }

    @Test func itemIDsAreStableAcrossEquivalentPresentations() throws {
        let profile = try profile(id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!, name: "Design")
        let search = try savedSearch(id: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!, name: "Images")
        let input = CommandPaletteBuilder.build(
            currentDirectory: URL(filePath: "/current/../current"),
            backHistory: [],
            forwardHistory: [],
            favorites: [],
            profiles: [profile],
            savedSearches: [search]
        )
        let sameInput = CommandPaletteBuilder.build(
            currentDirectory: URL(filePath: "/current"),
            backHistory: [],
            forwardHistory: [],
            favorites: [],
            profiles: [profile],
            savedSearches: [search]
        )

        #expect(input.map(\.id) == sameInput.map(\.id))
        #expect(Set(input.map(\.id)).count == input.count)
    }

    @Test func duplicateProfileAndSavedSearchIDsKeepTheFirstSourceItem() throws {
        let profileID = UUID(uuidString: "00000000-0000-0000-0000-000000000006")!
        let searchID = UUID(uuidString: "00000000-0000-0000-0000-000000000007")!
        let firstProfile = try profile(id: profileID, name: "First Profile")
        let secondProfile = try profile(id: profileID, name: "Second Profile")
        let firstSearch = try savedSearch(id: searchID, name: "First Search")
        let secondSearch = try savedSearch(id: searchID, name: "Second Search")

        let items = CommandPaletteBuilder.build(
            currentDirectory: URL(filePath: "/current"),
            backHistory: [],
            forwardHistory: [],
            favorites: [],
            profiles: [firstProfile, secondProfile],
            savedSearches: [firstSearch, secondSearch]
        )

        #expect(items.filter { $0.action == .openProfile(firstProfile.id) }.map(\.title) == ["First Profile"])
        #expect(items.filter { $0.action == .openSavedSearch(firstSearch.id) }.map(\.title) == ["First Search"])
        #expect(Set(items.map(\.id)).count == items.count)
    }

    private func profile(id: UUID, name: String) throws -> WorkspaceProfileRecord {
        try WorkspaceProfileRecord(
            id: WorkspaceProfileID(rawValue: id),
            name: name,
            descriptor: WorkspaceDescriptor(
                leftPath: "/left", rightPath: "/right", leftSort: FileSort(), rightSort: FileSort(),
                splitRatio: 0.5, activePane: .left
            )
        )
    }

    private func savedSearch(id: UUID, name: String) throws -> SmartSearchRecord {
        SmartSearchRecord(
            id: id,
            displayName: name,
            query: try SmartSearchQuery(text: "image", roots: [URL(filePath: "/search")])
        )
    }
}
