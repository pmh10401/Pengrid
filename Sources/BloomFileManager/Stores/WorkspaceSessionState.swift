import Foundation
import Observation

enum WorkspaceSessionStateError: Error, Equatable, Sendable {
    case profileNotFound(WorkspaceProfileID)
}

@MainActor @Observable
final class WorkspaceSessionState {
    private(set) var tabs: [WorkspaceTabRuntime]
    private(set) var activeTabID: WorkspaceTabID
    private(set) var profiles: [WorkspaceProfileRecord]

    @ObservationIgnored private let persistence: WorkspaceSessionPersistence
    @ObservationIgnored private let runtimeFactory: any WorkspaceRuntimeCreating
    @ObservationIgnored private var descriptors: [WorkspaceTabID: WorkspaceDescriptor]

    var activeWorkspace: WorkspaceState {
        tabs.first(where: { $0.id == activeTabID })!.workspace
    }

    init(
        restored: RestoredWorkspaceSession,
        persistence: WorkspaceSessionPersistence,
        runtimeFactory: any WorkspaceRuntimeCreating
    ) {
        precondition(!restored.tabs.isEmpty, "A workspace session requires one tab")

        self.persistence = persistence
        self.runtimeFactory = runtimeFactory
        self.activeTabID = restored.tabs.contains(where: { $0.id == restored.activeTabID })
            ? restored.activeTabID
            : restored.tabs[0].id
        self.profiles = restored.profiles
        self.descriptors = Dictionary(
            uniqueKeysWithValues: restored.tabs.map { ($0.id, $0.descriptor) }
        )
        self.tabs = []
        self.tabs = restored.tabs.map { record in
            WorkspaceTabRuntime(
                id: record.id,
                workspace: makeRuntime(id: record.id, descriptor: record.descriptor)
            )
        }
    }

    func newTab() -> WorkspaceTabID {
        let descriptor = currentDescriptor(for: activeWorkspace) ?? descriptors[activeTabID]!
        return appendTab(with: descriptor)
    }

    func openProfile(_ id: WorkspaceProfileID) -> WorkspaceTabID? {
        guard let profile = profiles.first(where: { $0.id == id }) else { return nil }
        return appendTab(with: profile.descriptor)
    }

    func closeTab(_ id: WorkspaceTabID, canClose: (WorkspaceTabID) -> Bool) -> Bool {
        guard tabs.count > 1,
              tabs.contains(where: { $0.id == id }),
              canClose(id)
        else { return false }

        let index = tabs.firstIndex(where: { $0.id == id })!
        tabs.remove(at: index)
        descriptors[id] = nil
        if activeTabID == id {
            activeTabID = tabs[min(index, tabs.count - 1)].id
        }
        saveImmediately()
        return true
    }

    func selectTab(_ id: WorkspaceTabID) -> Bool {
        guard tabs.contains(where: { $0.id == id }) else { return false }
        guard activeTabID != id else { return true }
        activeTabID = id
        saveImmediately()
        return true
    }

    func saveActiveProfile(named name: String) throws -> WorkspaceProfileID {
        let descriptor = currentDescriptor(for: activeWorkspace) ?? descriptors[activeTabID]!
        let profile = try WorkspaceProfileRecord(name: name, descriptor: descriptor)
        let normalizedName = WorkspaceProfileRecord.normalizedNameKey(profile.name)
        guard !profiles.contains(where: {
            WorkspaceProfileRecord.normalizedNameKey($0.name) == normalizedName
        }) else {
            throw WorkspaceSessionValidationError.duplicateProfileName(normalizedName)
        }
        profiles.append(profile)
        saveImmediately()
        return profile.id
    }

    func renameProfile(_ id: WorkspaceProfileID, to name: String) throws {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else {
            throw WorkspaceSessionStateError.profileNotFound(id)
        }
        let updated = try WorkspaceProfileRecord(
            id: id,
            name: name,
            descriptor: profiles[index].descriptor
        )
        let normalizedName = WorkspaceProfileRecord.normalizedNameKey(updated.name)
        guard !profiles.enumerated().contains(where: { candidateIndex, profile in
            candidateIndex != index && WorkspaceProfileRecord.normalizedNameKey(profile.name) == normalizedName
        }) else {
            throw WorkspaceSessionValidationError.duplicateProfileName(normalizedName)
        }
        profiles[index] = updated
        saveImmediately()
    }

    func deleteProfile(_ id: WorkspaceProfileID) -> Bool {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return false }
        profiles.remove(at: index)
        saveImmediately()
        return true
    }

    func flushPersistence() {
        for tab in tabs {
            tab.workspace.flushPendingPersistence()
            if let descriptor = currentDescriptor(for: tab.workspace) {
                descriptors[tab.id] = descriptor
            }
        }
        saveImmediately()
    }

    private func appendTab(with descriptor: WorkspaceDescriptor) -> WorkspaceTabID {
        let id = WorkspaceTabID()
        descriptors[id] = descriptor
        tabs.append(WorkspaceTabRuntime(id: id, workspace: makeRuntime(id: id, descriptor: descriptor)))
        activeTabID = id
        saveImmediately()
        return id
    }

    private func makeRuntime(id: WorkspaceTabID, descriptor: WorkspaceDescriptor) -> WorkspaceState {
        runtimeFactory.makeRuntime(id: id, descriptor: descriptor) { [weak self] snapshot, pane in
            self?.receiveDescriptorChange(for: id, snapshot: snapshot, activePane: pane)
        }
    }

    private func receiveDescriptorChange(
        for id: WorkspaceTabID,
        snapshot: WorkspaceSnapshot,
        activePane: PaneID
    ) {
        guard descriptors[id] != nil,
              let descriptor = try? WorkspaceDescriptor(
                snapshot: snapshot,
                activePane: activePane == .left ? .left : .right
              )
        else { return }
        descriptors[id] = descriptor
        saveEnvelope()
    }

    private func currentDescriptor(for workspace: WorkspaceState) -> WorkspaceDescriptor? {
        try? WorkspaceDescriptor(
            snapshot: workspace.currentSnapshot(),
            activePane: workspace.activePaneID == .left ? .left : .right
        )
    }

    private func saveImmediately() {
        saveEnvelope()
    }

    private func saveEnvelope() {
        let records = tabs.compactMap { tab -> WorkspaceTabRecord? in
            guard let descriptor = descriptors[tab.id] else { return nil }
            return WorkspaceTabRecord(id: tab.id, descriptor: descriptor)
        }
        guard records.count == tabs.count,
              let envelope = try? WorkspaceSessionEnvelope(
                tabs: records,
                activeTabID: activeTabID,
                profiles: profiles
              )
        else { return }
        _ = persistence.save(envelope)
    }
}
