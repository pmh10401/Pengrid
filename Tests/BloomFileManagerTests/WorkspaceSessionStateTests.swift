import Foundation
import Testing
@testable import BloomFileManager

@MainActor
@Suite("WorkspaceSessionStateTests")
struct WorkspaceSessionStateTests {
    @Test func runtimeFactoryCreatesFreshListingAndMonitorDependenciesForEachRuntime() throws {
        var listingFactoryCalls = 0
        var monitorFactoryCalls = 0
        var listingInstanceIDs: [UUID] = []
        var monitorInstanceIDs: [UUID] = []
        let factory = WorkspaceRuntimeFactory(
            listingServiceFactory: {
                listingFactoryCalls += 1
                let service = TaggedListingService()
                listingInstanceIDs.append(service.id)
                return service
            },
            monitorFactory: {
                monitorFactoryCalls += 1
                let monitor = TaggedDirectoryMonitor()
                monitorInstanceIDs.append(monitor.id)
                return monitor
            }
        )
        let descriptor = try SessionStateFixture().descriptor(left: "/One/Left", right: "/One/Right")

        _ = factory.makeRuntime(id: WorkspaceTabID(), descriptor: descriptor, descriptorDidChange: { _, _ in })
        _ = factory.makeRuntime(id: WorkspaceTabID(), descriptor: descriptor, descriptorDidChange: { _, _ in })

        #expect(listingFactoryCalls == 2)
        #expect(monitorFactoryCalls == 2)
        #expect(Set(listingInstanceIDs).count == 2)
        #expect(Set(monitorInstanceIDs).count == 2)
    }

    @Test func newTabCopiesDescriptorButOwnsIndependentRuntimeState() throws {
        let fixture = SessionStateFixture()
        let first = try fixture.makeTab(left: "/One/Left", right: "/One/Right")
        let state = fixture.makeState(tabs: [first], active: first.id)

        let newID = state.newTab()
        let created = try #require(state.tabs.first(where: { $0.id == newID }))

        #expect(state.tabs.count == 2)
        #expect(created.workspace !== state.tabs[0].workspace)
        #expect(created.workspace.left.currentDirectory.path == "/One/Left")
        created.workspace.activate(.right)
        #expect(state.tabs[0].workspace.activePaneID == .left)
    }

    @Test func profileOpenCreatesANewTabAndLeavesCurrentRuntimeUntouched() throws {
        let fixture = SessionStateFixture()
        let first = try fixture.makeTab(left: "/Current/Left", right: "/Current/Right")
        let profile = try WorkspaceProfileRecord(
            name: "Release",
            descriptor: fixture.descriptor(left: "/Release/Left", right: "/Release/Right", activePane: .right)
        )
        let state = fixture.makeState(tabs: [first], active: first.id, profiles: [profile])

        let openedID = try #require(state.openProfile(profile.id))
        let opened = try #require(state.tabs.first(where: { $0.id == openedID }))

        #expect(state.tabs.count == 2)
        #expect(state.activeTabID == openedID)
        #expect(state.tabs[0].workspace.left.currentDirectory.path == "/Current/Left")
        #expect(opened.workspace.left.currentDirectory.path == "/Release/Left")
        #expect(opened.workspace.activePaneID == .right)
    }

    @Test func childDescriptorChangesPersistOnlyTheirOwningTab() async throws {
        let fixture = SessionStateFixture()
        let first = try fixture.makeTab(left: "/One/Left", right: "/One/Right")
        let second = try fixture.makeTab(left: "/Two/Left", right: "/Two/Right")
        let state = fixture.makeState(tabs: [first, second], active: first.id)

        let child = try #require(state.tabs.first(where: { $0.id == second.id }))
        child.workspace.activate(.right)
        try await Task.sleep(for: .milliseconds(350))

        let saved = try #require(fixture.persistence.load())
        #expect(saved.tabs.first(where: { $0.id == first.id })?.descriptor.activePane == .left)
        #expect(saved.tabs.first(where: { $0.id == second.id })?.descriptor.activePane == .right)
    }

    @Test func dividerDescriptorPersistsAfterOneDebounceBoundary() async throws {
        let fixture = SessionStateFixture()
        let first = try fixture.makeTab(left: "/One/Left", right: "/One/Right")
        let state = fixture.makeState(tabs: [first], active: first.id)

        state.activeWorkspace.splitRatio = 0.64
        try await Task.sleep(for: .milliseconds(180))
        #expect(fixture.persistence.load() == nil)

        try await Task.sleep(for: .milliseconds(220))
        let saved = try #require(fixture.persistence.load())
        #expect(saved.tabs[0].descriptor.splitRatio == 0.64)
    }

    @Test func closeSelectsNextThenPreviousAndRefusesTheLastTab() throws {
        let fixture = SessionStateFixture()
        let first = try fixture.makeTab(left: "/One/Left", right: "/One/Right")
        let second = try fixture.makeTab(left: "/Two/Left", right: "/Two/Right")
        let third = try fixture.makeTab(left: "/Three/Left", right: "/Three/Right")
        let state = fixture.makeState(tabs: [first, second, third], active: second.id)

        #expect(state.closeTab(second.id, canClose: { _ in true }))
        #expect(state.activeTabID == third.id)
        #expect(state.closeTab(third.id, canClose: { _ in true }))
        #expect(state.activeTabID == first.id)
        #expect(state.closeTab(first.id, canClose: { _ in true }) == false)
    }

    @Test func closeGateRefusesATabWithBoundActiveOrQueuedWork() throws {
        let fixture = SessionStateFixture()
        let first = try fixture.makeTab(left: "/One/Left", right: "/One/Right")
        let second = try fixture.makeTab(left: "/Two/Left", right: "/Two/Right")
        let state = fixture.makeState(tabs: [first, second], active: first.id)

        #expect(state.closeTab(first.id, canClose: { $0 != first.id }) == false)
        #expect(state.tabs.map(\.id) == [first.id, second.id])
    }

    @Test func renameAndDeleteProfilesPreserveOpenTabs() throws {
        let fixture = SessionStateFixture()
        let first = try fixture.makeTab(left: "/One/Left", right: "/One/Right")
        let profile = try WorkspaceProfileRecord(name: "Work", descriptor: first.descriptor)
        let state = fixture.makeState(tabs: [first], active: first.id, profiles: [profile])

        try state.renameProfile(profile.id, to: "  Renamed  ")
        #expect(state.profiles.map(\.name) == ["Renamed"])
        #expect(state.deleteProfile(profile.id))
        #expect(state.profiles.isEmpty)
        #expect(state.tabs.map(\.id) == [first.id])
    }

    @Test func flushPersistsEveryChildCommittedDescriptor() throws {
        let fixture = SessionStateFixture()
        let first = try fixture.makeTab(left: "/One/Left", right: "/One/Right")
        let second = try fixture.makeTab(left: "/Two/Left", right: "/Two/Right")
        let state = fixture.makeState(tabs: [first, second], active: first.id)

        state.tabs[0].workspace.activate(.right)
        state.tabs[1].workspace.activate(.right)
        state.flushPersistence()

        let saved = try #require(fixture.persistence.load())
        #expect(saved.tabs.map(\.descriptor.activePane) == [.right, .right])
    }
}

@MainActor
private final class SessionStateFixture {
    let defaults: UserDefaults
    let persistence: WorkspaceSessionPersistence
    let factory = WorkspaceStateTestRuntimeFactory()

    init() {
        let name = "BloomFileManagerTests.WorkspaceSessionState.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        persistence = WorkspaceSessionPersistence(defaults: defaults)
    }

    func descriptor(
        left: String,
        right: String,
        activePane: WorkspacePersistedPane = .left
    ) throws -> WorkspaceDescriptor {
        try WorkspaceDescriptor(
            leftPath: left,
            rightPath: right,
            leftSort: FileSort(),
            rightSort: FileSort(),
            splitRatio: 0.5,
            activePane: activePane
        )
    }

    func makeTab(left: String, right: String) throws -> WorkspaceTabRecord {
        WorkspaceTabRecord(descriptor: try descriptor(left: left, right: right))
    }

    func makeState(
        tabs: [WorkspaceTabRecord],
        active: WorkspaceTabID,
        profiles: [WorkspaceProfileRecord] = []
    ) -> WorkspaceSessionState {
        WorkspaceSessionState(
            restored: RestoredWorkspaceSession(tabs: tabs, activeTabID: active, profiles: profiles),
            persistence: persistence,
            runtimeFactory: factory
        )
    }

}

@MainActor
private final class WorkspaceStateTestRuntimeFactory: WorkspaceRuntimeCreating {
    func makeRuntime(
        id: WorkspaceTabID,
        descriptor: WorkspaceDescriptor,
        descriptorDidChange: @escaping @MainActor @Sendable (WorkspaceSnapshot, PaneID) -> Void
    ) -> WorkspaceState {
        let workspace = WorkspaceState(
            leftURL: URL(filePath: descriptor.leftPath),
            rightURL: URL(filePath: descriptor.rightPath),
            leftSort: descriptor.leftSort,
            rightSort: descriptor.rightSort,
            splitRatio: descriptor.splitRatio,
            listingService: StubDirectoryListingService(values: [:]),
            descriptorDidChange: descriptorDidChange
        )
        workspace.activate(descriptor.activePane == .left ? .left : .right)
        return workspace
    }
}

private struct TaggedListingService: DirectoryListingService {
    let id = UUID()

    func batches(in directory: URL) -> AsyncThrowingStream<[FileItem], Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private struct TaggedDirectoryMonitor: DirectoryMonitor {
    let id = UUID()

    func events(for directory: URL) -> AsyncStream<Void> {
        AsyncStream { $0.finish() }
    }
}
