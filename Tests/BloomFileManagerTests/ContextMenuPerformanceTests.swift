import Foundation
import Testing
@testable import BloomFileManager

@Suite("ContextMenuPerformanceTests", .serialized)
struct ContextMenuPerformanceTests {
    @Test @MainActor func tenThousandRowsBuildMenuPolicyFromMetadataWithoutIORequests() throws {
        // This source inspection is deliberately outside the measured interval.
        // It proves the policy's value input cannot receive the normal identity,
        // byte-content, or File Provider materialization dependencies.
        let dependencies = try ContextMenuPolicyDependencyEvidence.read()
        let measurement = measureContextMenuPolicy(rowCount: 10_000, dependencies: dependencies)

        #expect(measurement.itemCount == 10_000)
        #expect(measurement.identityRequestCount == 0)
        #expect(dependencies.contentRequestCount == 0)
        #expect(measurement.materializationRequestCount == 0)
        #expect(measurement.elapsed >= .zero) // evidence only; intentionally no time ceiling
    }
}

struct ContextMenuPerformanceMeasurement: Sendable, Equatable {
    let itemCount: Int
    let elapsed: Duration
    let identityRequestCount: Int
    let materializationRequestCount: Int
}

/// `FileContextMenuPolicy` has no service dependency: its input is a value
/// snapshot of `FileItem` metadata. This synchronous, main-actor measurement
/// therefore completes before an `await` or a new main-run-loop turn is possible.
@MainActor
private func measureContextMenuPolicy(
    rowCount: Int,
    dependencies: ContextMenuPolicyDependencyEvidence,
    clock: ContinuousClock = .init()
) -> ContextMenuPerformanceMeasurement {
    let sourceDirectory = URL(filePath: "/performance/source", directoryHint: .isDirectory)
    let oppositeDirectory = URL(filePath: "/performance/opposite", directoryHint: .isDirectory)
    let items = (0 ..< rowCount).map { index in
        FileItem(
            url: sourceDirectory.appending(path: "item-\(index).txt", directoryHint: .notDirectory),
            name: "item-\(index).txt",
            isDirectory: false,
            isPackage: false,
            modifiedAt: Date(timeIntervalSinceReferenceDate: TimeInterval(index)),
            byteSize: Int64(index),
            typeDescription: "Document"
        )
    }
    let started = clock.now
    let policy = FileContextMenuPolicy(.init(
        workspaceCommandPolicy: WorkspaceCommandPolicy(
            selectionCount: items.count,
            isOperationRunning: false,
            pasteboardHasFileURLs: false,
            selectedItems: [],
            isTextEditing: false
        ),
        selectedItems: items,
        sourceDirectory: sourceDirectory,
        oppositeDirectory: oppositeDirectory,
        sourceCapability: .writable,
        oppositeCapability: .writable,
        isExclusiveOperationActive: false
    ))
    let elapsed = started.duration(to: clock.now)

    #expect(policy.quickLook.isEnabled)
    #expect(policy.copyToOtherPane.isEnabled)
    #expect(policy.moveToOtherPane.isEnabled)
    #expect(policy.showInFinder.isEnabled)
    #expect(policy.copyPath.isEnabled)
    #expect(policy.duplicate.isEnabled)
    #expect(policy.encloseSelection.isEnabled)

    return .init(
        itemCount: items.count,
        elapsed: elapsed,
        identityRequestCount: dependencies.identityRequestCount,
        materializationRequestCount: dependencies.materializationRequestCount
    )
}

private struct ContextMenuPolicyDependencyEvidence {
    let identityRequestCount: Int
    let contentRequestCount: Int
    let materializationRequestCount: Int

    static func read() throws -> Self {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/BloomFileManager/Support/FileContextMenuPolicy.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        return .init(
            identityRequestCount: occurrenceCount(
                in: source,
                of: ["FileSystemAccess", "FileIdentity", "identity("]
            ),
            contentRequestCount: occurrenceCount(
                in: source,
                of: ["Data(contentsOf:", "FileHandle", "InputStream"]
            ),
            materializationRequestCount: occurrenceCount(
                in: source,
                of: ["CloudMaterializer", "materialize(", "prepareForReading("]
            )
        )
    }

    private static func occurrenceCount(in source: String, of tokens: [String]) -> Int {
        tokens.reduce(into: 0) { count, token in
            count += source.components(separatedBy: token).count - 1
        }
    }
}
