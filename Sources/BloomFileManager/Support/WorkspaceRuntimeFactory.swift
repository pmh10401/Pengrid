import Foundation

@MainActor
protocol WorkspaceRuntimeCreating {
    func makeRuntime(
        id: WorkspaceTabID,
        descriptor: WorkspaceDescriptor,
        descriptorDidChange: @escaping @MainActor @Sendable (WorkspaceSnapshot, PaneID) -> Void
    ) -> WorkspaceState
}

struct WorkspaceTabRuntime: Identifiable {
    let id: WorkspaceTabID
    let workspace: WorkspaceState
}

@MainActor
struct WorkspaceRuntimeFactory: WorkspaceRuntimeCreating {
    private let listingServiceFactory: @MainActor () -> any DirectoryListingService
    private let monitorFactory: @MainActor () -> any DirectoryMonitor

    init(
        listingServiceFactory: @escaping @MainActor () -> any DirectoryListingService,
        monitorFactory: @escaping @MainActor () -> any DirectoryMonitor
    ) {
        self.listingServiceFactory = listingServiceFactory
        self.monitorFactory = monitorFactory
    }

    init() {
        self.init(
            listingServiceFactory: { LiveDirectoryListingService() },
            monitorFactory: { LiveDirectoryMonitor() }
        )
    }

    func makeRuntime(
        id: WorkspaceTabID,
        descriptor: WorkspaceDescriptor,
        descriptorDidChange: @escaping @MainActor @Sendable (WorkspaceSnapshot, PaneID) -> Void
    ) -> WorkspaceState {
        let workspace = WorkspaceState(
            leftURL: URL(filePath: descriptor.leftPath, directoryHint: .isDirectory),
            rightURL: URL(filePath: descriptor.rightPath, directoryHint: .isDirectory),
            leftSort: descriptor.leftSort,
            rightSort: descriptor.rightSort,
            splitRatio: descriptor.splitRatio,
            listingService: listingServiceFactory(),
            monitor: monitorFactory(),
            descriptorDidChange: descriptorDidChange
        )
        workspace.activate(descriptor.activePane == .left ? .left : .right)
        return workspace
    }
}
