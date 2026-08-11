import Foundation
import Testing
@testable import BloomFileManager

@Suite("ContextMenuPerformanceTests", .serialized)
struct ContextMenuPerformanceTests {
    @Test @MainActor func tenThousandRowsFilterInTableOrderAndBuildSynchronousPolicyDescriptor() {
        let descriptor = buildCapturedContextMenuPolicyDescriptor(rowCount: 10_000)

        #expect(descriptor.itemCount == 10_000)
        #expect(descriptor.selectedCount == 10_000)
        #expect(descriptor.firstName == "item-0.txt")
        #expect(descriptor.lastName == "item-9999.txt")
    }
}

private struct ContextMenuDescriptorMeasurement: Sendable, Equatable {
    let itemCount: Int
    let selectedCount: Int
    let firstName: String?
    let lastName: String?
}

/// Exercises the synchronous, AppKit-independent selection and policy descriptor
/// boundary. Its inputs are captured value data; it accepts no I/O collaborator.
@MainActor
private func buildCapturedContextMenuPolicyDescriptor(
    rowCount: Int
) -> ContextMenuDescriptorMeasurement {
    let sourceDirectory = URL(filePath: "/performance/source", directoryHint: .isDirectory)
    let oppositeDirectory = URL(filePath: "/performance/opposite", directoryHint: .isDirectory)
    let items = (0 ..< rowCount).map { index in
        FileItem(
            url: sourceDirectory.appending(path: "item-\(index).txt", directoryHint: .notDirectory),
            name: "item-\(index).txt", isDirectory: false, isPackage: false,
            modifiedAt: nil, byteSize: Int64(index), typeDescription: "Document"
        )
    }
    // Deliberately reverse insertion: output must still follow table order.
    let selectedURLs = Set(items.reversed().map(\.url))
    let selectedItems = FileTableContextMenuSelection.orderedItems(
        from: items,
        selectedURLs: selectedURLs
    )
    let policy = FileContextMenuPolicy(.init(
        workspaceCommandPolicy: WorkspaceCommandPolicy(
            selectionCount: selectedItems.count,
            isOperationRunning: false,
            pasteboardHasFileURLs: false,
            selectedItems: [],
            isTextEditing: false
        ),
        selectedItems: selectedItems,
        sourceDirectory: sourceDirectory,
        oppositeDirectory: oppositeDirectory,
        sourceCapability: .writable,
        oppositeCapability: .writable,
        isExclusiveOperationActive: false
    ))

    #expect(policy.duplicate.isEnabled)
    #expect(policy.encloseSelection.isEnabled)
    return .init(
        itemCount: items.count,
        selectedCount: selectedItems.count,
        firstName: selectedItems.first?.name,
        lastName: selectedItems.last?.name
    )
}
