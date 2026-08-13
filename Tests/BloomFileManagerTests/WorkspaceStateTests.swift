import Foundation
import Testing
@testable import BloomFileManager

@MainActor
struct WorkspaceStateTests {
    @Test func panesNavigateWithoutSharingHistory() async {
        let home = URL(filePath: "/private/test-home")
        let downloads = home.appending(path: "Downloads")
        let service = StubDirectoryListingService(values: [:])
        let workspace = WorkspaceState(leftURL: home, rightURL: downloads, listingService: service)

        await workspace.left.navigate(to: home.appending(path: "Documents"))

        #expect(workspace.left.canGoBack)
        #expect(workspace.right.currentDirectory == downloads)
        #expect(workspace.right.canGoBack == false)
    }

    @Test func activePaneTracksExplicitActivation() {
        let home = URL(filePath: "/private/test-home")
        let workspace = WorkspaceState(
            leftURL: home,
            rightURL: home.appending(path: "Downloads"),
            listingService: StubDirectoryListingService(values: [:])
        )

        workspace.activate(.right)

        #expect(workspace.activePaneID == .right)
        #expect(workspace.activePane === workspace.right)
    }

    @Test func descriptorCallbackReceivesCommittedSnapshotAndNewlyActivePane() {
        let home = URL(filePath: "/private/test-home")
        var received: [(WorkspaceSnapshot, PaneID)] = []
        let workspace = WorkspaceState(
            leftURL: home,
            rightURL: home.appending(path: "Downloads"),
            listingService: StubDirectoryListingService(values: [:]),
            descriptorDidChange: { snapshot, pane in
                received.append((snapshot, pane))
            }
        )

        workspace.activate(.right)

        #expect(received.count == 1)
        #expect(received[0].0.leftPath == "/private/test-home")
        #expect(received[0].0.rightPath == "/private/test-home/Downloads")
        #expect(received[0].1 == .right)
    }
}
