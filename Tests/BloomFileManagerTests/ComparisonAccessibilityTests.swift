import AppKit
import SwiftUI
import Testing
@testable import BloomFileManager

@Suite struct ComparisonAccessibilityTests {
    @Test func version11ChecklistContainsComparisonReleaseGates() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let checklist = repositoryRoot
            .appending(path: "docs/verification/version-1.1-checklist.md")
        let text = try String(contentsOf: checklist, encoding: .utf8)

        for required in [
            "50,000", "VoiceOver", "Full Keyboard Access", "external volume",
            "case-sensitive", "symbolic link", "package", "directional copy",
            "directional move", "Developer ID", "notarization", "staple", "Gatekeeper"
        ] {
            #expect(text.localizedCaseInsensitiveContains(required))
        }
    }

    @Test func operationDetailsUseRelativePathsOnlyToDisambiguateBasenames() throws {
        let privateRoot = URL(filePath: "/private/test-user/Private Comparison Root")
        let reports = privateRoot.appending(path: "Reports/summary.txt")
        let archive = privateRoot.appending(path: "Archive/summary.txt")
        let result = FileOperationResult(outcomes: [
            .failed(
                source: reports,
                message: "Denied"
            ),
            .skipped(source: archive),
            .cancelled(source: privateRoot.appending(path: "Drafts/notes.txt"))
        ], safeRelativePathsBySource: [
            reports: try ComparisonRelativePath(components: ["Reports", "summary.txt"]),
            archive: try ComparisonRelativePath(components: ["Archive", "summary.txt"])
        ])

        let details = OperationResultDetails(result: result)
        #expect(details.items.map(\.name) == [
            "Reports/summary.txt", "Archive/summary.txt", "notes.txt"
        ])
        #expect(details.items.allSatisfy { !$0.name.hasPrefix("/") })
        #expect(details.items.allSatisfy { !$0.name.contains("Users/minho") })
        #expect(!details.accessibilityLabel.contains("Reports/summary.txt"))
        #expect(!details.accessibilityLabel.contains("Private Comparison Root"))
    }

    @Test func operationDetailsNeverInferRelativePathsFromUnrelatedAbsoluteRoots() {
        let userSource = URL(filePath: "/private/test-user/Left/summary.txt")
        let volumeSource = URL(filePath: "/Volumes/Customer Data/Right/summary.txt")
        let details = OperationResultDetails(result: FileOperationResult(outcomes: [
            .failed(source: userSource, message: "Denied"),
            .skipped(source: volumeSource)
        ]))

        #expect(details.items.map(\.name) == ["summary.txt", "summary.txt"])
        #expect(details.items.allSatisfy { !$0.name.contains("Users") })
        #expect(details.items.allSatisfy { !$0.name.contains("Volumes") })
        #expect(details.items.allSatisfy { !$0.name.contains("Customer Data") })
    }

    @Test func everyStatusHasLabelSymbolAndVerificationDetail() {
        let statuses: [ComparisonStatus] = [
            .identical(.quick), .identical(.checksum), .metadataChanged, .contentChanged,
            .leftOnly, .rightOnly, .typeConflict, .nameConflict, .checking(nil),
            .checking(0.25), .unstable, .error("Permission denied")
        ]

        for status in statuses {
            let presentation = ComparisonAccessibility.status(status)
            #expect(!presentation.label.isEmpty)
            #expect(!presentation.symbolName.isEmpty)
            #expect(!presentation.value.isEmpty)
        }
        #expect(ComparisonAccessibility.status(.identical(.quick)).value.contains("quick"))
        #expect(ComparisonAccessibility.status(.identical(.checksum)).value.contains("checksum"))
    }

    @Test func rowSpeaksBothSidesMetadataAndVerificationDetail() throws {
        let quick = try accessibilityRow("Reports/summary.txt", status: .identical(.quick))
        let verified = try accessibilityRow("Reports/summary.txt", status: .identical(.checksum))
        let oneSided = try accessibilityRow("only.txt", status: .leftOnly, includeRight: false)

        let quickValue = ComparisonAccessibility.row(quick)
        #expect(quickValue.contains("Reports/summary.txt"))
        #expect(quickValue.contains("Left, Text Document, 12 bytes"))
        #expect(quickValue.contains("Right, Text Document, 12 bytes"))
        #expect(quickValue.contains("quick metadata comparison"))
        #expect(ComparisonAccessibility.row(verified).contains("checksum verified"))
        #expect(ComparisonAccessibility.row(oneSided).contains("Right, missing"))
    }

    @Test func rowAwareStatusReportsOnlyTheVerificationThatProducedTheResult() throws {
        let directoryPath = try ComparisonRelativePath(components: ["Archive"])
        let quickDirectory = ComparisonMatcher.rows(
            left: [accessibilityEntry(
                path: directoryPath,
                side: "left",
                kind: .directory,
                size: nil,
                modified: 1
            )],
            right: [accessibilityEntry(
                path: directoryPath,
                side: "right",
                kind: .directory,
                size: nil,
                modified: 2
            )]
        )[0]
        #expect(quickDirectory.status == .metadataChanged)
        #expect(ComparisonAccessibility.status(quickDirectory).value.contains("quick"))
        #expect(!ComparisonAccessibility.status(quickDirectory).value.contains("checksum"))
        #expect(ComparisonAccessibility.row(quickDirectory).contains("quick"))

        let packagePath = try ComparisonRelativePath(components: ["Example.app"])
        let quickPackage = ComparisonMatcher.rows(
            left: [accessibilityEntry(
                path: packagePath,
                side: "left",
                kind: .package,
                size: nil,
                modified: 1
            )],
            right: [accessibilityEntry(
                path: packagePath,
                side: "right",
                kind: .package,
                size: nil,
                modified: 2
            )]
        )[0]
        #expect(quickPackage.status == .metadataChanged)
        #expect(ComparisonAccessibility.status(quickPackage).value.contains("quick"))
        #expect(!ComparisonAccessibility.status(quickPackage).value.contains("checksum"))

        var aggregateDirectory = ComparisonMatcher.rows(
            left: [accessibilityEntry(
                path: directoryPath,
                side: "left",
                kind: .directory,
                size: nil,
                modified: 1
            )],
            right: [accessibilityEntry(
                path: directoryPath,
                side: "right",
                kind: .directory,
                size: nil,
                modified: 1
            )]
        )[0]
        aggregateDirectory.status = .metadataChanged
        aggregateDirectory.descendantDifferenceCount = 2
        let aggregateValue = ComparisonAccessibility.status(aggregateDirectory).value
        #expect(aggregateValue.contains("2 descendant differences"))
        #expect(aggregateValue.contains("quick"))
        #expect(!aggregateValue.contains("Metadata differs"))

        let regularPath = try ComparisonRelativePath(components: ["report.bin"])
        let checking = ComparisonMatcher.rows(
            left: [accessibilityEntry(
                path: regularPath,
                side: "left",
                size: 12,
                modified: 1
            )],
            right: [accessibilityEntry(
                path: regularPath,
                side: "right",
                size: 12,
                modified: 2
            )]
        )[0]
        let sameDigest = ChecksumResult(digest: Data([1]))
        let metadata = ComparisonMatcher.applying(
            left: sameDigest,
            right: sameDigest,
            to: checking
        )
        let content = ComparisonMatcher.applying(
            left: sameDigest,
            right: .init(digest: Data([2])),
            to: checking
        )
        #expect(ComparisonAccessibility.status(metadata).value.contains("checksum"))
        #expect(ComparisonAccessibility.status(content).value.contains("checksum"))
        #expect(ComparisonAccessibility.row(metadata).contains("checksum"))
        #expect(ComparisonAccessibility.row(content).contains("checksum"))

        let sizeChanged = ComparisonMatcher.rows(
            left: [accessibilityEntry(path: regularPath, side: "left", size: 12)],
            right: [accessibilityEntry(path: regularPath, side: "right", size: 13)]
        )[0]
        #expect(sizeChanged.status == .contentChanged)
        #expect(ComparisonAccessibility.status(sizeChanged).value.contains("quick"))

        let linkPath = try ComparisonRelativePath(components: ["shortcut"])
        let linkChanged = ComparisonMatcher.rows(
            left: [accessibilityEntry(
                path: linkPath,
                side: "left",
                kind: .symbolicLink,
                size: nil,
                linkTarget: "first"
            )],
            right: [accessibilityEntry(
                path: linkPath,
                side: "right",
                kind: .symbolicLink,
                size: nil,
                linkTarget: "second"
            )]
        )[0]
        #expect(linkChanged.status == .contentChanged)
        #expect(ComparisonAccessibility.status(linkChanged).value.contains("quick"))

        #expect(ComparisonAccessibility.status(.metadataChanged).value == "Difference detected")
        #expect(!ComparisonAccessibility.status(.contentChanged).value.contains("checksum"))
    }

    @MainActor @Test func statusCellUsesRowAwareVerificationProvenance() throws {
        let path = try ComparisonRelativePath(components: ["report.bin"])
        let checking = ComparisonMatcher.rows(
            left: [accessibilityEntry(path: path, side: "left", size: 12, modified: 1)],
            right: [accessibilityEntry(path: path, side: "right", size: 12, modified: 2)]
        )[0]
        let verified = ComparisonMatcher.applying(
            left: .init(digest: Data([1])),
            right: .init(digest: Data([2])),
            to: checking
        )
        let view = ComparisonTableView(rows: [verified], selection: .constant([]))
        let coordinator = view.makeCoordinator()
        let scroll = view.makeScrollView(coordinator: coordinator)
        let table = try #require(scroll.documentView as? NSTableView)
        let cell = try #require(coordinator.tableView(
            table,
            viewFor: table.tableColumns[ComparisonColumn.status.index],
            row: 0
        ))
        #expect((cell.accessibilityValue() as? String)?.contains("checksum") == true)
    }

    @Test func disabledMoveExplainsTheFirstBlockingRow() throws {
        let row = try accessibilityRow("report.txt", status: .contentChanged)
        #expect(ComparisonActionPolicy.moveBlockReason([row], .leftToRight)
            == "report.txt exists on both sides and cannot be moved in comparison mode.")
    }

    @Test func comparisonIdentifiersAreStableAndEveryFilterHasOne() {
        #expect(AccessibilityIdentifiers.comparisonWorkspace == "comparisonWorkspace")
        #expect(AccessibilityIdentifiers.comparisonToolbar == "comparisonToolbar")
        #expect(AccessibilityIdentifiers.comparisonTable == "comparisonTable")
        #expect(AccessibilityIdentifiers.comparisonStatusRail == "comparisonStatusRail")
        #expect(AccessibilityIdentifiers.comparisonActionBar == "comparisonActionBar")
        #expect(AccessibilityIdentifiers.comparisonMoveConfirmation == "comparisonMoveConfirmation")
        let filters = ComparisonFilter.allCases.map(AccessibilityIdentifiers.comparisonFilter)
        #expect(Set(filters).count == ComparisonFilter.allCases.count)
        #expect(filters.allSatisfy { $0.hasPrefix("comparisonFilter.") })
    }
}

@MainActor
@Suite struct ComparisonFocusAndAnnouncementTests {
    @Test func fileTableHandlesEachFocusRequestExactlyOnce() throws {
        let request = UUID()
        let view = FileTableView(
            items: [],
            selection: .constant([]),
            focusRequestID: request,
            onActivatePane: {},
            onOpen: { _ in },
            onSortChange: { _ in }
        )
        let coordinator = view.makeCoordinator()
        let window = FocusRecordingWindow()
        let scroll = view.makeScrollView(coordinator: coordinator)
        window.contentView = scroll
        let table = try #require(scroll.documentView as? NSTableView)

        coordinator.applyFocusRequest(to: table)
        coordinator.applyFocusRequest(to: table)
        #expect(window.makeFirstResponderCount == 1)

        coordinator.parent = FileTableView(
            items: [],
            selection: .constant([]),
            focusRequestID: UUID(),
            onActivatePane: {},
            onOpen: { _ in },
            onSortChange: { _ in }
        )
        coordinator.applyFocusRequest(to: table)
        #expect(window.makeFirstResponderCount == 2)
    }

    @Test func comparisonTableHandlesItsEntryFocusRequestOnce() throws {
        let request = UUID()
        let view = ComparisonTableView(
            rows: [],
            selection: .constant([]),
            focusRequestID: request
        )
        let coordinator = view.makeCoordinator()
        let window = FocusRecordingWindow()
        let scroll = view.makeScrollView(coordinator: coordinator)
        window.contentView = scroll
        let table = try #require(scroll.documentView as? NSTableView)

        coordinator.applyFocusRequest(to: table)
        coordinator.applyFocusRequest(to: table)
        #expect(window.makeFirstResponderCount == 1)
    }

    @Test func paneFocusRequestsUseFreshIdentifiers() {
        let pane = accessibilityWorkspace().left
        pane.requestTableFocus()
        let first = pane.focusRequestID
        pane.requestTableFocus()
        #expect(first != nil)
        #expect(pane.focusRequestID != first)
    }

    @Test func exitRestoresTheCapturedOrdinaryPaneOnNextMainActorTurn() async {
        let workspace = accessibilityWorkspace()
        workspace.activate(.right)
        let comparison = accessibilityCoordinator()
        comparison.start(workspace: workspace)
        #expect(await accessibilityWait { comparison.isActive })

        ComparisonCommandActions.toggle(workspace: workspace, comparison: comparison)
        #expect(!comparison.isActive)
        #expect(workspace.right.focusRequestID == nil)
        await Task.yield()
        #expect(workspace.right.focusRequestID != nil)
        #expect(workspace.left.focusRequestID == nil)
    }

    @Test func announcementsAreThrottledAndOnlyPhaseOrCountChangesSpeak() async throws {
        let poster = RecordingComparisonAnnouncementPoster()
        let listing = AnnouncementListingService()
        let monitor = InMemoryComparisonTreeMonitor()
        let comparison = ComparisonCoordinator(
            listings: listing,
            checksums: AnnouncementNoopChecksumService(),
            monitor: monitor,
            announcementPoster: poster,
            announcementDelay: .milliseconds(20)
        )
        let workspace = accessibilityWorkspace()
        comparison.start(workspace: workspace)
        #expect(await accessibilityWait { comparison.rows.count == 1 })
        try await Task.sleep(for: .milliseconds(30))
        let firstMessages = poster.messages
        #expect(!firstMessages.isEmpty)
        #expect(firstMessages.last?.contains("1 item") == true)

        let beforeSecondBatch = poster.messages.count
        await listing.releaseSecondBatch()
        #expect(await accessibilityWait { comparison.rows.count == 2 })
        #expect(await accessibilityWait {
            poster.messages.last?.contains("2 items") == true
        })
        #expect(poster.messages.count > beforeSecondBatch)
        #expect(zip(poster.instants, poster.instants.dropFirst()).allSatisfy {
            $0.duration(to: $1) >= .milliseconds(18)
        })

        let beforeSelection = poster.messages.count
        comparison.selection = [try ComparisonRelativePath(components: ["first.txt"])]
        try await Task.sleep(for: .milliseconds(30))
        #expect(poster.messages.count == beforeSelection)

        comparison.stop()
        try await Task.sleep(for: .milliseconds(30))
        #expect(poster.messages.count == beforeSelection)
    }

    @Test func stoppingBeforeTheThrottleDeadlineCancelsThePendingAnnouncement() async throws {
        let poster = RecordingComparisonAnnouncementPoster()
        let comparison = ComparisonCoordinator(
            listings: InMemoryComparisonListingService([:]),
            checksums: AnnouncementNoopChecksumService(),
            monitor: InMemoryComparisonTreeMonitor(),
            announcementPoster: poster,
            announcementDelay: .milliseconds(20)
        )
        comparison.start(workspace: accessibilityWorkspace())
        comparison.stop()
        try await Task.sleep(for: .milliseconds(30))
        #expect(poster.messages.isEmpty)
    }
}

private func accessibilityRow(
    _ relativePath: String,
    status: ComparisonStatus,
    includeRight: Bool = true
) throws -> ComparisonRow {
    let path = try ComparisonRelativePath(
        components: relativePath.split(separator: "/").map(String.init)
    )
    func entry(side: String) -> ComparisonEntry {
        ComparisonEntry(
            relativePath: path,
            url: URL(filePath: "/comparison/\(side)").appending(path: path.string),
            kind: .regularFile,
            fingerprint: .init(
                identity: .init(entryIdentifier: "\(side):\(path.string)", resolvedIdentifier: "\(side):\(path.string)"),
                byteSize: 12,
                modifiedAt: Date(timeIntervalSince1970: 1)
            ),
            symbolicLinkTarget: nil,
            typeDescription: "Text Document"
        )
    }
    return ComparisonRow(
        relativePath: path,
        left: entry(side: "left"),
        right: includeRight ? entry(side: "right") : nil,
        status: status
    )
}

private func accessibilityEntry(
    path: ComparisonRelativePath,
    side: String,
    kind: ComparisonEntryKind = .regularFile,
    size: Int64? = 12,
    modified: TimeInterval = 1,
    linkTarget: String? = nil
) -> ComparisonEntry {
    ComparisonEntry(
        relativePath: path,
        url: URL(filePath: "/comparison/\(side)").appending(path: path.string),
        kind: kind,
        fingerprint: .init(
            identity: .init(
                entryIdentifier: "\(side):\(path.string)",
                resolvedIdentifier: "\(side):\(path.string)"
            ),
            byteSize: size,
            modifiedAt: Date(timeIntervalSince1970: modified)
        ),
        symbolicLinkTarget: linkTarget,
        typeDescription: kind.rawValue
    )
}

@MainActor
private final class FocusRecordingWindow: NSWindow {
    private(set) var makeFirstResponderCount = 0

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        makeFirstResponderCount += 1
        return true
    }
}

@MainActor
private final class RecordingComparisonAnnouncementPoster: ComparisonAnnouncementPosting {
    private(set) var messages: [String] = []
    private(set) var instants: [ContinuousClock.Instant] = []
    func post(_ message: String) {
        messages.append(message)
        instants.append(ContinuousClock().now)
    }
}

private actor AnnouncementListingService: ComparisonListingService {
    private var secondBatchReleased = false

    func identity(of root: URL) -> FileIdentity {
        let token = "announcement:\(root.path)"
        return .init(entryIdentifier: token, resolvedIdentifier: token)
    }

    nonisolated func batches(for request: ComparisonListingRequest)
        -> AsyncThrowingStream<ComparisonListingBatch, Error> {
        let side = request.root.lastPathComponent
        guard side == "left" else { return AsyncThrowingStream { $0.finish() } }
        let producer = AnnouncementBatchProducer(owner: self, root: request.root)
        return AsyncThrowingStream(unfolding: { try await producer.next() })
    }

    func releaseSecondBatch() { secondBatchReleased = true }
    func isSecondBatchReleased() -> Bool { secondBatchReleased }
}

private actor AnnouncementBatchProducer {
    let owner: AnnouncementListingService
    let root: URL
    var index = 0

    init(owner: AnnouncementListingService, root: URL) {
        self.owner = owner
        self.root = root
    }

    func next() async throws -> ComparisonListingBatch? {
        guard index < 2 else { return nil }
        if index == 1 {
            while !(await owner.isSecondBatchReleased()) {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(2))
            }
        }
        index += 1
        let name = index == 1 ? "first.txt" : "second.txt"
        let path = try ComparisonRelativePath(components: [name])
        let entry = ComparisonEntry(
            relativePath: path,
            url: root.appending(path: name),
            kind: .regularFile,
            fingerprint: .init(
                identity: .init(entryIdentifier: name, resolvedIdentifier: name),
                byteSize: 1,
                modifiedAt: Date(timeIntervalSince1970: 1)
            ),
            symbolicLinkTarget: nil,
            typeDescription: "Text Document"
        )
        return .init(records: [.entry(entry)])
    }
}

private actor AnnouncementNoopChecksumService: ChecksumService {
    func checksum(
        for request: ChecksumRequest,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> ChecksumResult {
        .init(digest: Data(request.url.path.utf8))
    }
}

@MainActor
private func accessibilityWorkspace() -> WorkspaceState {
    WorkspaceState(
        leftURL: URL(filePath: "/comparison/left", directoryHint: .isDirectory),
        rightURL: URL(filePath: "/comparison/right", directoryHint: .isDirectory),
        listingService: StubDirectoryListingService(values: [:])
    )
}

@MainActor
private func accessibilityCoordinator() -> ComparisonCoordinator {
    ComparisonCoordinator(
        listings: InMemoryComparisonListingService([:]),
        checksums: AnnouncementNoopChecksumService(),
        monitor: InMemoryComparisonTreeMonitor()
    )
}

@MainActor
private func accessibilityWait(
    timeout: Duration = .seconds(1),
    _ condition: @escaping @MainActor () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return true }
        await Task.yield()
    }
    return await condition()
}
