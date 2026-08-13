import Foundation
import Testing
@testable import BloomFileManager

@MainActor
@Suite("WorkspaceTabPresentationTests")
struct WorkspaceTabPresentationTests {
    @Test func tabTitlesAndAccessibilityLabelsExposeOnlyTheFolderBasename() {
        let left = URL(filePath: "/private/users/example/Projects/Release", directoryHint: .isDirectory)
        let right = URL(filePath: "/private/users/example/Builds/Artifacts", directoryHint: .isDirectory)

        #expect(WorkspaceTabPresentation.title(left: left, right: right) == "Release ⇄ Artifacts")
        #expect(
            WorkspaceTabPresentation.accessibilityLabel(
                index: 2,
                leftDirectory: left,
                rightDirectory: right,
                isActive: true
            ) == "Workspace tab 2, Release and Artifacts, selected"
        )
        #expect(!WorkspaceTabPresentation.accessibilityLabel(
            index: 2,
            leftDirectory: left,
            rightDirectory: right,
            isActive: true
        ).contains("/private"))
    }

    @Test func nextAndPreviousTabSelectionTeardownBeforeChangingTheActiveRuntime() throws {
        let fixture = WorkspaceTabPresentationFixture()
        let first = try fixture.tab(left: "/One/Left", right: "/One/Right")
        let second = try fixture.tab(left: "/Two/Left", right: "/Two/Right")
        let third = try fixture.tab(left: "/Three/Left", right: "/Three/Right")
        let session = fixture.session(tabs: [first, second, third], active: second.id)
        var teardownCount = 0

        #expect(WorkspaceTabCommandActions.selectNext(
            in: session,
            isModalPresented: false,
            isTextEditing: false
        ) {
            teardownCount += 1
        })
        #expect(session.activeTabID == third.id)
        #expect(teardownCount == 1)

        #expect(WorkspaceTabCommandActions.selectPrevious(
            in: session,
            isModalPresented: false,
            isTextEditing: false
        ) {
            teardownCount += 1
        })
        #expect(session.activeTabID == second.id)
        #expect(teardownCount == 2)
    }

    @Test func tabActionsFailClosedWhileAModalOrTextEditorOwnsTheWorkspace() throws {
        let fixture = WorkspaceTabPresentationFixture()
        let first = try fixture.tab(left: "/One/Left", right: "/One/Right")
        let second = try fixture.tab(left: "/Two/Left", right: "/Two/Right")
        let session = fixture.session(tabs: [first, second], active: first.id)
        let profileID = try session.saveActiveProfile(named: "Release")
        var teardownCount = 0

        for ownership in [(true, false), (false, true)] {
            #expect(!WorkspaceTabCommandActions.newTab(
                in: session,
                isModalPresented: ownership.0,
                isTextEditing: ownership.1,
                teardown: { teardownCount += 1 }
            ))
            #expect(!WorkspaceTabCommandActions.selectNext(
                in: session,
                isModalPresented: ownership.0,
                isTextEditing: ownership.1,
                teardown: { teardownCount += 1 }
            ))
            #expect(!WorkspaceTabCommandActions.select(
                second.id,
                in: session,
                isModalPresented: ownership.0,
                isTextEditing: ownership.1,
                teardown: { teardownCount += 1 }
            ))
            #expect(!WorkspaceTabCommandActions.selectPrevious(
                in: session,
                isModalPresented: ownership.0,
                isTextEditing: ownership.1,
                teardown: { teardownCount += 1 }
            ))
            #expect(!WorkspaceTabCommandActions.openProfile(
                profileID,
                in: session,
                isModalPresented: ownership.0,
                isTextEditing: ownership.1,
                allowsCurrentModalOwner: false,
                teardown: { teardownCount += 1 }
            ))
            #expect(!WorkspaceTabCommandActions.close(
                second.id,
                in: session,
                isModalPresented: ownership.0,
                isTextEditing: ownership.1,
                canClose: { _ in true },
                teardown: { teardownCount += 1 }
            ))
        }

        #expect(session.tabs.map(\.id) == [first.id, second.id])
        #expect(session.activeTabID == first.id)
        #expect(teardownCount == 0)
    }

    @Test func currentProfileSheetOwnerMayOpenAProfileWithoutBypassingTextEditingOwnership() throws {
        let fixture = WorkspaceTabPresentationFixture()
        let first = try fixture.tab(left: "/One/Left", right: "/One/Right")
        let session = fixture.session(tabs: [first], active: first.id)
        let profileID = try session.saveActiveProfile(named: "Release")
        var teardownCount = 0

        #expect(WorkspaceTabCommandActions.openProfile(
            profileID,
            in: session,
            isModalPresented: true,
            isTextEditing: false,
            allowsCurrentModalOwner: true,
            teardown: { teardownCount += 1 }
        ))
        #expect(session.tabs.count == 2)
        #expect(teardownCount == 1)

        #expect(!WorkspaceTabCommandActions.openProfile(
            profileID,
            in: session,
            isModalPresented: true,
            isTextEditing: true,
            allowsCurrentModalOwner: true,
            teardown: { teardownCount += 1 }
        ))
        #expect(session.tabs.count == 2)
        #expect(teardownCount == 1)
    }

    @Test func closeCommandRefusesBoundWorkAndRespectsModalAndTextEditingOwnership() throws {
        let fixture = WorkspaceTabPresentationFixture()
        let first = try fixture.tab(left: "/One/Left", right: "/One/Right")
        let second = try fixture.tab(left: "/Two/Left", right: "/Two/Right")
        let session = fixture.session(tabs: [first, second], active: first.id)
        var teardownCount = 0

        #expect(!WorkspaceTabCommandActions.closeActiveTab(
            in: session,
            isModalPresented: false,
            isTextEditing: false,
            canClose: { _ in false },
            teardown: { teardownCount += 1 }
        ))
        #expect(!WorkspaceTabCommandActions.closeActiveTab(
            in: session,
            isModalPresented: true,
            isTextEditing: false,
            canClose: { _ in true },
            teardown: { teardownCount += 1 }
        ))
        #expect(!WorkspaceTabCommandActions.closeActiveTab(
            in: session,
            isModalPresented: false,
            isTextEditing: true,
            canClose: { _ in true },
            teardown: { teardownCount += 1 }
        ))
        #expect(teardownCount == 0)

        #expect(WorkspaceTabCommandActions.closeActiveTab(
            in: session,
            isModalPresented: false,
            isTextEditing: false,
            canClose: { $0 == first.id },
            teardown: { teardownCount += 1 }
        ))
        #expect(session.tabs.map(\.id) == [second.id])
        #expect(session.activeTabID == second.id)
        #expect(teardownCount == 1)
    }

    @Test func selectingTheAlreadyActiveTabDoesNotTearDownItsRuntime() throws {
        let fixture = WorkspaceTabPresentationFixture()
        let first = try fixture.tab(left: "/One/Left", right: "/One/Right")
        let session = fixture.session(tabs: [first], active: first.id)
        var teardownCount = 0

        #expect(WorkspaceTabCommandActions.select(
            first.id,
            in: session,
            isModalPresented: false,
            isTextEditing: false
        ) {
            teardownCount += 1
        })
        #expect(teardownCount == 0)
        #expect(session.activeTabID == first.id)
    }

    @Test func cancelledInitialLoadCanBeRetriedWhenReturningToItsTab() async {
        let state = WorkspaceTabInitialLoadState()
        let firstStarted = ManagedAtomicCounter()
        let tabID = WorkspaceTabID(rawValue: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!)
        let first = Task { @MainActor in
            await state.load(tabID: tabID) {
                firstStarted.increment()
                try? await Task.sleep(for: .seconds(30))
            }
        }
        await Task.yield()
        state.cancel(tabID: tabID)
        first.cancel()

        var retryCount = 0
        await state.load(tabID: tabID) { retryCount += 1 }
        await first.value
        await state.load(tabID: tabID) { retryCount += 1 }

        #expect(firstStarted.value == 1)
        #expect(retryCount == 1)
        #expect(state.isCompleted(tabID: tabID))
    }

    @Test func profilesSheetIsAModalCloseGate() throws {
        let fixture = WorkspaceTabPresentationFixture()
        let first = try fixture.tab(left: "/One/Left", right: "/One/Right")
        let second = try fixture.tab(left: "/Two/Left", right: "/Two/Right")
        let session = fixture.session(tabs: [first, second], active: first.id)
        let policy = WorkspaceTabModalPolicy(profilesPresented: true)
        var teardownCount = 0

        #expect(policy.isPresented)
        #expect(!WorkspaceTabCommandActions.closeActiveTab(
            in: session,
            isModalPresented: policy.isPresented,
            isTextEditing: false,
            canClose: { _ in true },
            teardown: { teardownCount += 1 }
        ))
        #expect(session.tabs.count == 2)
        #expect(teardownCount == 0)
    }

    @Test func closingInvalidatesTheClosingRuntimeBeforeRemovingIt() throws {
        let fixture = WorkspaceTabPresentationFixture()
        let first = try fixture.tab(left: "/One/Left", right: "/One/Right")
        let second = try fixture.tab(left: "/Two/Left", right: "/Two/Right")
        let session = fixture.session(tabs: [first, second], active: first.id)
        var invalidated: WorkspaceState?

        #expect(WorkspaceTabCommandActions.closeActiveTab(
            in: session,
            isModalPresented: false,
            isTextEditing: false,
            canClose: { _ in true },
            beforeClose: { invalidated = $0 },
            teardown: {}
        ))
        #expect(session.tabs.map(\.id) == [second.id])
        #expect(invalidated?.left.currentDirectory.path == "/One/Left")
    }

    @Test func teardownClearsTabScopedPresentationWithoutClosingGetInfo() {
        var events: [String] = []
        WorkspaceTabTeardownActions.perform(
            stopComparison: { events.append("comparison") },
            exitStorage: { events.append("storage") },
            closePreview: { events.append("preview") },
            dismissSmartSearch: { events.append("search") },
            dismissBatchRename: { events.append("rename") },
            dismissSelectionFolder: { events.append("selection") },
            dismissSynchronizationReview: { events.append("sync") },
            dismissPendingTrash: { events.append("trash") },
            endTextEditing: { events.append("editing") },
            cancelPassword: { events.append("password") }
        )

        #expect(events == ["comparison", "storage", "preview", "search", "rename", "selection", "sync", "trash", "editing", "password"])
        #expect(!events.contains("getInfo"))
    }

    @Test func profilePresentationShowsBothFolderBasenamesWithoutAccessiblePaths() throws {
        let descriptor = try WorkspaceDescriptor(
            leftPath: "/private/example/Source",
            rightPath: "/private/example/Build",
            leftSort: FileSort(),
            rightSort: FileSort(),
            splitRatio: 0.5,
            activePane: .left
        )
        let profile = try WorkspaceProfileRecord(name: "Release", descriptor: descriptor)

        #expect(WorkspaceProfilePresentation.folderNames(for: descriptor) == "Source ⇄ Build")
        #expect(WorkspaceProfilePresentation.pathText(for: descriptor) == "/private/example/Source ⇄ /private/example/Build")
        #expect(WorkspaceProfilePresentation.accessibilityLabel(for: profile) == "Workspace profile Release. Folders: Source ⇄ Build.")
        #expect(!WorkspaceProfilePresentation.accessibilityLabel(for: profile).contains("/private"))
        #expect(WorkspaceSessionAccessibilityIdentifiers.renameProfile(profile.id).hasPrefix("workspaceProfiles.rename."))
        #expect(WorkspaceSessionAccessibilityIdentifiers.openProfile(profile.id).hasPrefix("workspaceProfiles.open."))
        #expect(WorkspaceSessionAccessibilityIdentifiers.deleteProfile(profile.id).hasPrefix("workspaceProfiles.delete."))
        #expect(WorkspaceSessionAccessibilityIdentifiers.done == "workspaceProfiles.done")
    }
}

@MainActor
private final class ManagedAtomicCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

@MainActor
private final class WorkspaceTabPresentationFixture {
    private let defaults: UserDefaults
    private let persistence: WorkspaceSessionPersistence

    init() {
        let suite = "BloomFileManagerTests.WorkspaceTabPresentation.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        persistence = WorkspaceSessionPersistence(defaults: defaults)
    }

    func tab(left: String, right: String) throws -> WorkspaceTabRecord {
        WorkspaceTabRecord(descriptor: try WorkspaceDescriptor(
            leftPath: left,
            rightPath: right,
            leftSort: FileSort(),
            rightSort: FileSort(),
            splitRatio: 0.5,
            activePane: .left
        ))
    }

    func session(
        tabs: [WorkspaceTabRecord],
        active: WorkspaceTabID
    ) -> WorkspaceSessionState {
        WorkspaceSessionState(
            restored: RestoredWorkspaceSession(tabs: tabs, activeTabID: active, profiles: []),
            persistence: persistence,
            runtimeFactory: WorkspaceTabPresentationRuntimeFactory()
        )
    }
}

@MainActor
private final class WorkspaceTabPresentationRuntimeFactory: WorkspaceRuntimeCreating {
    func makeRuntime(
        id: WorkspaceTabID,
        descriptor: WorkspaceDescriptor,
        descriptorDidChange: @escaping @MainActor @Sendable (WorkspaceSnapshot, PaneID) -> Void
    ) -> WorkspaceState {
        WorkspaceState(
            leftURL: URL(filePath: descriptor.leftPath, directoryHint: .isDirectory),
            rightURL: URL(filePath: descriptor.rightPath, directoryHint: .isDirectory),
            leftSort: descriptor.leftSort,
            rightSort: descriptor.rightSort,
            splitRatio: descriptor.splitRatio,
            listingService: StubDirectoryListingService(values: [:]),
            descriptorDidChange: descriptorDidChange
        )
    }
}
