import AppKit
import Foundation
import Testing
@testable import BloomFileManager

@MainActor
struct CloudLocationsPresentationTests {
    @Test func sidebarSectionOrderIsPlacesCloudFavorites() {
        #expect(PlacesRailSection.ordered == [.places, .cloud, .favorites])
    }

    @Test func cloudRowsExposeProviderNameLocationAndAvailability() {
        let location = storageLocation(
            provider: .googleDrive,
            displayName: "Team Drive",
            isAvailable: true
        )

        let presentation = CloudLocationRowPresentation.values(for: location)

        #expect(presentation.providerName == "Google Drive")
        #expect(presentation.locationName == "Team Drive")
        #expect(presentation.availabilityDescription == "Available")
        #expect(presentation.accessibilityLabel == "Google Drive, Team Drive, Available")
        #expect(presentation.canNavigate)
        #expect(presentation.providerApplicationBundleIdentifier == "com.google.drivefs")
        #expect(
            CloudLocationRowPresentation.values(for: storageLocation(
                provider: .oneDrive,
                displayName: "OneDrive",
                isAvailable: true
            )).providerApplicationBundleIdentifier == "com.microsoft.OneDrive"
        )
        #expect(
            CloudLocationRowPresentation.values(for: storageLocation(
                provider: .dropbox,
                displayName: "Dropbox",
                isAvailable: true
            )).providerApplicationBundleIdentifier == "com.getdropbox.dropbox"
        )
    }

    @Test func unavailableLocationRemainsVisibleAndCannotNavigate() async throws {
        let fixture = try CloudPresentationFixture()
        defer { fixture.remove() }
        let location = storageLocation(
            provider: .oneDrive,
            displayName: "Work",
            isAvailable: true
        )
        let discovery = PresentationCloudDiscovery([location])
        let store = fixture.store(discovery: discovery)
        try await store.rescan()

        discovery.setLocations([])
        try await store.rescan()

        let unavailable = try #require(store.visibleLocations.first)
        let initialDirectory = URL(filePath: "/Initial", directoryHint: .isDirectory)
        let pane = FilePaneState(
            directory: initialDirectory,
            listingService: StubDirectoryListingService(values: [:])
        )
        let didNavigate = await CloudLocationNavigationRouter.open(
            unavailable,
            in: pane,
            accessCoordinator: .init()
        )

        #expect(store.visibleLocations.count == 1)
        #expect(unavailable.isAvailable == false)
        #expect(CloudLocationRowPresentation.values(for: unavailable).canNavigate == false)
        #expect(didNavigate == false)
        #expect(pane.currentDirectory == initialDirectory)
    }

    @Test func manualNavigationAndFinderRevealHoldBalancedScopedAccess() async {
        let driver = PresentationSecurityScopeDriver()
        let accessCoordinator = CloudLocationScopedAccessCoordinator(driver: driver)
        let root = URL(filePath: "/Cloud/Manual", directoryHint: .isDirectory)
        accessCoordinator.replaceManualRoots([root])
        let location = StorageLocation(
            id: .manualBookmark(UUID()),
            provider: .other("Manual Folder"),
            displayName: "Manual",
            rootURL: root,
            isAvailable: true,
            capabilities: [.browse, .materialize, .localFileOperations],
            source: .manualBookmark
        )
        let pane = FilePaneState(
            directory: URL(filePath: "/Initial", directoryHint: .isDirectory),
            listingService: StubDirectoryListingService(values: [root: []])
        )
        let workspace = PresentationWorkspaceActions()

        let didNavigate = await CloudLocationNavigationRouter.open(
            location,
            in: pane,
            accessCoordinator: accessCoordinator
        )
        let didReveal = CloudLocationContextActions.revealInFinder(
            location,
            workspaceActions: workspace,
            accessCoordinator: accessCoordinator
        )

        #expect(didNavigate)
        #expect(didReveal)
        #expect(pane.currentDirectory == root)
        #expect(workspace.revealedURLs == [root])
        #expect(driver.startCount == 2)
        #expect(driver.stopCount == 2)
    }

    @Test func rescanDoesNotUnhideLocations() async throws {
        let fixture = try CloudPresentationFixture()
        defer { fixture.remove() }
        let location = storageLocation(
            provider: .dropbox,
            displayName: "Dropbox",
            isAvailable: true
        )
        let discovery = PresentationCloudDiscovery([location])
        let store = fixture.store(discovery: discovery)
        try await store.rescan()
        try store.hide(location.id)

        try await store.rescan()

        #expect(store.visibleLocations.isEmpty)
        #expect(store.hiddenLocations.map(\.id) == [location.id])
    }

    @Test func manualFolderPanelAcceptsDirectoriesOnly() {
        let panel = NSOpenPanel()

        CloudFolderPanelConfiguration.apply(to: panel)

        #expect(panel.canChooseDirectories)
        #expect(panel.canChooseFiles == false)
        #expect(panel.allowsMultipleSelection == false)
    }

    @Test func unknownProviderUsesGenericCloudPresentation() {
        let location = storageLocation(
            provider: .other("Acme Cloud"),
            displayName: "Projects",
            isAvailable: true
        )

        let presentation = CloudLocationRowPresentation.values(for: location)

        #expect(presentation.providerName == "Acme Cloud")
        #expect(presentation.systemImage == "externaldrive.badge.icloud")
        #expect(presentation.providerApplicationBundleIdentifier == nil)
    }

    @Test func providerAppActionResolvesOnlyAllowlistedInstalledApplications() {
        let applicationURL = URL(
            filePath: "/Applications/Google Drive.app",
            directoryHint: .isDirectory
        )
        let workspace = PresentationWorkspaceActions(applicationURL: applicationURL)
        let known = storageLocation(
            provider: .googleDrive,
            displayName: "Google Drive",
            isAvailable: true
        )
        let unknown = storageLocation(
            provider: .other("Unknown"),
            displayName: "Unknown",
            isAvailable: true
        )

        let openedKnown = CloudLocationContextActions.openProviderApplication(
            for: known,
            workspaceActions: workspace
        )
        let openedUnknown = CloudLocationContextActions.openProviderApplication(
            for: unknown,
            workspaceActions: workspace
        )

        #expect(openedKnown)
        #expect(openedUnknown == false)
        #expect(workspace.requestedBundleIdentifiers == ["com.google.drivefs"])
        #expect(workspace.openedApplicationURLs == [applicationURL])
    }

    @Test func cloudControlsHaveStableAccessibilityIdentifiers() {
        let id = StorageLocationID.fileProvider(
            domainIdentifier: "com.example.files",
            rootIdentity: Data([0x01, 0x02])
        )

        #expect(AccessibilityIdentifiers.cloudSection == "cloudSection")
        #expect(AccessibilityIdentifiers.cloudRescan == "cloud.rescan")
        #expect(AccessibilityIdentifiers.cloudAddFolder == "cloud.addFolder")
        #expect(
            AccessibilityIdentifiers.cloudLocationRow(id)
                == "cloud.location.fileProvider.com.example.files.AQI="
        )
    }

    @Test func settingsListsVisibleAndHiddenLocationsSeparately() {
        let visible = storageLocation(
            provider: .googleDrive,
            displayName: "Visible Drive",
            isAvailable: true
        )
        let hidden = storageLocation(
            provider: .dropbox,
            displayName: "Hidden Drive",
            isAvailable: false
        )

        let sections = CloudLocationsSettingsPresentation.sections(
            visible: [visible],
            hidden: [hidden]
        )

        #expect(sections.map(\.title) == ["Visible Locations", "Hidden Locations"])
        #expect(sections[0].locations.map(\.displayName) == ["Visible Drive"])
        #expect(sections[1].locations.map(\.displayName) == ["Hidden Drive"])
    }

    @Test func unhidePersistsWithoutRunningDiscovery() async throws {
        let fixture = try CloudPresentationFixture()
        defer { fixture.remove() }
        let location = storageLocation(
            provider: .oneDrive,
            displayName: "Work",
            isAvailable: true
        )
        let discovery = PresentationCloudDiscovery([location])
        let store = fixture.store(discovery: discovery)
        try await store.rescan()
        try store.hide(location.id)
        let scansBeforeUnhide = discovery.requestCount

        try CloudLocationsSettingsActions.perform(.unhide, for: location, in: store)

        #expect(discovery.requestCount == scansBeforeUnhide)
        #expect(store.visibleLocations.map(\.displayName) == ["Work"])
        #expect(store.hiddenLocations.isEmpty)
    }

    @Test func removeManualLocationDeletesOnlyItsBookmarkRecord() throws {
        let fixture = try CloudPresentationFixture()
        defer { fixture.remove() }
        let manualRoot = fixture.directory("Manual Root")
        try FileManager.default.createDirectory(
            at: manualRoot,
            withIntermediateDirectories: false
        )
        let bookmarking = InMemoryCloudLocationBookmarking()
        let store = fixture.store(
            discovery: PresentationCloudDiscovery([]),
            bookmarking: bookmarking
        )
        try store.addManualLocation(manualRoot)
        let location = try #require(store.visibleLocations.first)

        try CloudLocationsSettingsActions.perform(
            .removeManualLocation,
            for: location,
            in: store
        )

        #expect(store.visibleLocations.isEmpty)
        #expect(FileManager.default.fileExists(atPath: manualRoot.path))
        let restored = fixture.store(
            discovery: PresentationCloudDiscovery([]),
            bookmarking: bookmarking
        )
        #expect(restored.visibleLocations.isEmpty)
    }

    @Test func removeDiscoveredLocationMeansHideNotFilesystemDelete() async throws {
        let fixture = try CloudPresentationFixture()
        defer { fixture.remove() }
        let root = fixture.directory("Discovered Root")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let discovered = StorageLocation(
            id: .fileProvider(
                domainIdentifier: "com.example.files",
                rootIdentity: Data([0x44])
            ),
            provider: .other("Example"),
            displayName: "Discovered Root",
            rootURL: root,
            isAvailable: true,
            capabilities: [.browse, .materialize, .localFileOperations],
            source: .discovered
        )
        let discovery = PresentationCloudDiscovery([discovered])
        let store = fixture.store(discovery: discovery)
        try await store.rescan()

        try CloudLocationsSettingsActions.perform(.hide, for: discovered, in: store)

        #expect(store.visibleLocations.isEmpty)
        #expect(store.hiddenLocations.map(\.id) == [discovered.id])
        #expect(FileManager.default.fileExists(atPath: root.path))
    }

    @Test func everySettingsActionHasKeyboardAndAccessibilityCopy() {
        let discovered = storageLocation(
            provider: .googleDrive,
            displayName: "Team Drive",
            isAvailable: true
        )
        let manual = StorageLocation(
            id: .manualBookmark(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!),
            provider: .other("Manual Folder"),
            displayName: "Projects",
            rootURL: URL(filePath: "/Cloud/Projects", directoryHint: .isDirectory),
            isAvailable: false,
            capabilities: [.browse, .materialize, .localFileOperations],
            source: .manualBookmark
        )

        #expect(CloudLocationsSettingsAction.rescan.title == "Rescan")
        #expect(CloudLocationsSettingsAction.rescan.accessibilityLabel == "Rescan cloud locations")
        #expect(CloudLocationsSettingsAction.rescan.keyboardShortcut == "Command-R")
        #expect(
            CloudLocationsSettingsPresentation.actions(for: discovered, isHidden: false)
                == [.hide]
        )
        #expect(
            CloudLocationsSettingsPresentation.actions(for: discovered, isHidden: true)
                == [.unhide]
        )
        #expect(
            CloudLocationsSettingsPresentation.actions(for: manual, isHidden: false)
                == [.hide, .removeManualLocation]
        )
        #expect(CloudLocationsSettingsAction.hide.accessibilityLabel == "Hide from sidebar")
        #expect(CloudLocationsSettingsAction.unhide.accessibilityLabel == "Unhide in sidebar")
        #expect(
            CloudLocationsSettingsAction.removeManualLocation.accessibilityLabel
                == "Remove manual location"
        )
        #expect(AccessibilityIdentifiers.cloudSettings == "cloud.settings")
        #expect(AccessibilityIdentifiers.cloudSettingsVisible == "cloud.settings.visible")
        #expect(AccessibilityIdentifiers.cloudSettingsHidden == "cloud.settings.hidden")
        #expect(AccessibilityIdentifiers.cloudSettingsRescan == "cloud.settings.rescan")
        #expect(
            AccessibilityIdentifiers.cloudSettingsAction(.hide, locationID: discovered.id)
                == "cloud.settings.hide.cloud.location.fileProvider.com.example.files.VGVhbSBEcml2ZQ=="
        )
        #expect(
            AccessibilityIdentifiers.cloudSettingsAction(
                .removeManualLocation,
                locationID: manual.id
            ) == "cloud.settings.removeManualLocation.cloud.location.manual.aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        )
    }

    private func storageLocation(
        provider: CloudProviderKind,
        displayName: String,
        isAvailable: Bool
    ) -> StorageLocation {
        StorageLocation(
            id: .fileProvider(
                domainIdentifier: "com.example.files",
                rootIdentity: Data(displayName.utf8)
            ),
            provider: provider,
            displayName: displayName,
            rootURL: URL(filePath: "/Cloud/\(displayName)", directoryHint: .isDirectory),
            isAvailable: isAvailable,
            capabilities: [.browse, .materialize, .localFileOperations],
            source: .discovered
        )
    }
}

@MainActor
private final class PresentationWorkspaceActions: CloudLocationWorkspaceActions {
    private(set) var revealedURLs: [URL] = []
    private(set) var requestedBundleIdentifiers: [String] = []
    private(set) var openedApplicationURLs: [URL] = []
    private let applicationURL: URL?

    init(applicationURL: URL? = nil) {
        self.applicationURL = applicationURL
    }

    func revealInFinder(_ url: URL) {
        revealedURLs.append(url)
    }

    func applicationURL(forBundleIdentifier bundleIdentifier: String) -> URL? {
        requestedBundleIdentifiers.append(bundleIdentifier)
        return applicationURL
    }

    func openApplication(at url: URL) {
        openedApplicationURLs.append(url)
    }
}

private final class PresentationSecurityScopeDriver:
    SecurityScopedResourceAccessing,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var starts = 0
    private var stops = 0

    var startCount: Int { lock.withLock { starts } }
    var stopCount: Int { lock.withLock { stops } }

    func startAccessing(_ url: URL) -> Bool {
        lock.withLock { starts += 1 }
        return true
    }

    func stopAccessing(_ url: URL) {
        lock.withLock { stops += 1 }
    }
}

private final class PresentationCloudDiscovery: CloudLocationDiscovering, @unchecked Sendable {
    private let lock = NSLock()
    private var locations: [StorageLocation]
    private var scans = 0

    init(_ locations: [StorageLocation]) {
        self.locations = locations
    }

    func setLocations(_ locations: [StorageLocation]) {
        lock.withLock { self.locations = locations }
    }

    var requestCount: Int {
        lock.withLock { scans }
    }

    func discover() async -> [StorageLocation] {
        lock.withLock {
            scans += 1
            return locations
        }
    }
}

@MainActor
private struct CloudPresentationFixture {
    let temporaryDirectory: TemporaryDirectory
    let storageURL: URL

    init() throws {
        temporaryDirectory = try TemporaryDirectory()
        storageURL = temporaryDirectory.url.appending(path: "cloud-locations.json")
    }

    func remove() {
        temporaryDirectory.remove()
    }

    func directory(_ basename: String) -> URL {
        temporaryDirectory.url.appending(path: basename, directoryHint: .isDirectory)
    }

    func store(
        discovery: any CloudLocationDiscovering,
        bookmarking: any CloudLocationBookmarking = InMemoryCloudLocationBookmarking()
    ) -> CloudLocationsStore {
        CloudLocationsStore(
            storageURL: storageURL,
            discovery: discovery,
            bookmarking: bookmarking
        )
    }
}
