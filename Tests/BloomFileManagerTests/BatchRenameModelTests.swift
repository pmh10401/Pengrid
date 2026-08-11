import Foundation
import Testing
@testable import BloomFileManager

@MainActor
@Suite struct BatchRenameModelTests {
    @Test func presentationCapturesOrderedSelectionIdentityParentAndSiblingNamesOnce() async throws {
        let fixture = BatchRenameModelFixture(names: ["z.jpg", "a.jpg"], siblingNames: ["kept.jpg"])
        let model = fixture.model()

        await model.present(
            items: fixture.items,
            in: fixture.parent,
            capability: .writable
        )
        model.updateRule(.sequence(baseName: "Photo", start: 1, digits: 2))
        await waitForModel { model.phase == .ready }
        let plan = try #require(model.preview.plan)

        #expect(plan.parentURL == fixture.parent)
        #expect(plan.parentIdentity == fixture.parentIdentity)
        #expect(plan.entries.map(\.source.url) == fixture.items.map(\.url))
        #expect(plan.entries.map(\.source.identity) == fixture.sourceIdentities)
        #expect(plan.entries.map(\.proposedName) == ["Photo 01.jpg", "Photo 02.jpg"])

        await fixture.fileSystem.replaceIdentity(
            at: fixture.parent.appending(path: "future.jpg"),
            with: FileIdentity(entryIdentifier: "future", resolvedIdentifier: "future")
        )
        model.updateRule(.prefix("future-"))
        await waitForModel { model.phase == .ready }
        #expect(model.preview.plan != nil)
    }

    @Test func readOnlyAndUnknownLocationsFailBeforeFilesystemCapture() async {
        let fixture = BatchRenameModelFixture(names: ["A.txt", "B.txt"])
        let readOnly = fixture.model()
        await readOnly.present(items: fixture.items, in: fixture.parent, capability: .readOnly)

        #expect(readOnly.phase == .failed("This location does not allow local file operations."))
        #expect(readOnly.validationSummary == .unavailable(
            "This location does not allow local file operations."
        ))

        let unknown = fixture.model()
        await unknown.present(items: fixture.items, in: fixture.parent, capability: .unknown)
        #expect(unknown.phase == .failed(
            "Pengrid could not verify that this location supports renaming."
        ))
        #expect(await fixture.fileSystem.events.isEmpty)
    }

    @Test func deniedSecurityScopeSurfacesOneErrorWithoutRetrying() async {
        let fixture = BatchRenameModelFixture(names: ["A.txt", "B.txt"])
        let driver = DeniedBatchRenameAccessDriver()
        let coordinator = CloudLocationScopedAccessCoordinator(driver: driver)
        coordinator.replaceManualRoots([fixture.parent])
        let model = BatchRenameModel(
            fileSystem: fixture.fileSystem,
            accessCoordinator: coordinator
        )

        await model.present(items: fixture.items, in: fixture.parent)
        await Task.yield()

        #expect(model.phase == .failed("The selected cloud folder is not currently accessible."))
        #expect(driver.startCount == 1)
        #expect(driver.stopCount == 0)
    }

    @Test func validationSummaryTracksNoChangeInvalidAndReadyDrafts() async {
        let fixture = BatchRenameModelFixture(names: ["A.txt", "B.txt"])
        let model = fixture.model()
        await model.present(items: fixture.items, in: fixture.parent)
        await waitForModel { model.phase != .planning }

        #expect(model.validationSummary == .noChanges)
        #expect(!model.canSubmit)

        model.updateRule(.prefix("bad/"))
        await waitForModel { model.validationSummary.invalidCount == 2 }
        #expect(model.validationSummary == .invalid(
            count: 2,
            message: "2 names are invalid."
        ))

        model.updateRule(.prefix("old-"))
        await waitForModel { model.phase == .ready }
        #expect(model.validationSummary == .ready(changedCount: 2, totalCount: 2))
        #expect(model.canSubmit)
    }

    @Test func onlyTheLatestPreviewGenerationCanPublish() async throws {
        let fixture = BatchRenameModelFixture(names: ["A.txt", "B.txt"])
        let generator = ControlledBatchRenamePreviewGenerator()
        let model = fixture.model(previewGenerator: generator.call)
        await model.present(items: fixture.items, in: fixture.parent)
        await generator.waitForCallCount(1)
        await generator.finish(call: 0)
        await waitForModel { model.phase != .planning }

        model.updateRule(.prefix("old-"))
        await generator.waitForCallCount(2)
        model.updateRule(.prefix("new-"))
        await generator.waitForCallCount(3)
        await generator.finish(call: 2)
        await waitForModel {
            model.preview.entries.first?.proposedName == "new-A.txt"
        }
        await generator.finish(call: 1)
        await Task.yield()

        #expect(model.preview.entries.map(\.proposedName) == ["new-A.txt", "new-B.txt"])
        #expect(model.phase == .ready)
    }

    @Test func dismissInvalidatesAnOutstandingPreview() async {
        let fixture = BatchRenameModelFixture(names: ["A.txt", "B.txt"])
        let generator = ControlledBatchRenamePreviewGenerator()
        let model = fixture.model(previewGenerator: generator.call)
        await model.present(items: fixture.items, in: fixture.parent)
        await generator.waitForCallCount(1)

        model.dismiss()
        await generator.finish(call: 0)
        await Task.yield()

        #expect(!model.isPresented)
        #expect(model.phase == .idle)
        #expect(model.preview.entries.isEmpty)
    }

    @Test func submissionReturnsImmutablePlanAndLocksEditsUntilHandoffCompletes() async throws {
        let fixture = BatchRenameModelFixture(names: ["A.txt", "B.txt"])
        let model = fixture.model()
        await model.present(items: fixture.items, in: fixture.parent)
        model.updateRule(.suffix("-done"))
        await waitForModel { model.canSubmit }

        let submitted = try #require(model.beginSubmission())
        model.updateRule(.prefix("ignored-"))

        #expect(model.phase == .executing)
        #expect(!model.canSubmit)
        #expect(model.rule == .suffix("-done"))
        #expect(submitted.entries.map(\.proposedName) == ["A-done.txt", "B-done.txt"])

        model.finishSubmission(didStart: false)
        #expect(model.phase == .failed("The rename operation could not be started."))
        #expect(model.isPresented)

        model.updateRule(.prefix("retry-"))
        await waitForModel { model.canSubmit }
        #expect(model.beginSubmission() != nil)
        model.finishSubmission(didStart: true)
        #expect(!model.isPresented)
        #expect(model.phase == .idle)
    }
}

private final class DeniedBatchRenameAccessDriver: SecurityScopedResourceAccessing,
    @unchecked Sendable {
    private let lock = NSLock()
    private var starts = 0
    private var stops = 0

    var startCount: Int { lock.withLock { starts } }
    var stopCount: Int { lock.withLock { stops } }

    func startAccessing(_ url: URL) -> Bool {
        lock.withLock { starts += 1 }
        return false
    }

    func stopAccessing(_ url: URL) {
        lock.withLock { stops += 1 }
    }
}

private struct BatchRenameModelFixture {
    let parent = URL(filePath: "/workspace", directoryHint: .isDirectory)
    let fileSystem: RecordingFileSystem
    let items: [FileItem]
    let parentIdentity: FileIdentity
    let sourceIdentities: [FileIdentity]

    init(names: [String], siblingNames: [String] = []) {
        let parent = URL(filePath: "/workspace", directoryHint: .isDirectory)
        let allNames = names + siblingNames
        let urls = allNames.map { parent.appending(path: $0) }
        let parentIdentity = FileIdentity(entryIdentifier: "parent", resolvedIdentifier: "parent")
        var identities: [URL: FileIdentity] = [parent: parentIdentity]
        for name in allNames {
            let url = parent.appending(path: name)
            identities[url] = FileIdentity(
                entryIdentifier: "entry-\(name)",
                resolvedIdentifier: "resolved-\(name)"
            )
        }
        fileSystem = RecordingFileSystem(
            existingURLs: Set([parent] + urls),
            identities: identities,
            caseInsensitivePaths: true
        )
        items = names.map { name in
            FileItem(
                url: parent.appending(path: name),
                name: name,
                isDirectory: false,
                isPackage: false,
                modifiedAt: nil,
                byteSize: nil,
                typeDescription: "Document"
            )
        }
        self.parentIdentity = parentIdentity
        sourceIdentities = names.map { identities[parent.appending(path: $0)]! }
    }

    @MainActor
    func model(
        previewGenerator: @escaping BatchRenamePreviewGenerator = BatchRenameModel.livePreview
    ) -> BatchRenameModel {
        BatchRenameModel(fileSystem: fileSystem, previewGenerator: previewGenerator)
    }
}

private actor ControlledBatchRenamePreviewGenerator {
    private struct Pending {
        let request: BatchRenamePlanningRequest
        let rule: BatchRenameRule
        let occupiedNames: Set<String>
        let comparisonPolicy: FilenameComparisonPolicy
        let continuation: CheckedContinuation<BatchRenamePreview, any Error>
    }

    private var pending: [Pending] = []
    private var callCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func call(
        _ request: BatchRenamePlanningRequest,
        _ rule: BatchRenameRule,
        _ occupiedNames: Set<String>,
        _ comparisonPolicy: FilenameComparisonPolicy
    ) async throws -> BatchRenamePreview {
        try await withCheckedThrowingContinuation { continuation in
            pending.append(Pending(
                request: request,
                rule: rule,
                occupiedNames: occupiedNames,
                comparisonPolicy: comparisonPolicy,
                continuation: continuation
            ))
            let ready = callCountWaiters.filter { pending.count >= $0.0 }
            callCountWaiters.removeAll { pending.count >= $0.0 }
            ready.forEach { $0.1.resume() }
        }
    }

    func waitForCallCount(_ count: Int) async {
        guard pending.count < count else { return }
        await withCheckedContinuation { continuation in
            callCountWaiters.append((count, continuation))
        }
    }

    func finish(call index: Int) {
        let value = pending[index]
        value.continuation.resume(returning: try! BatchRenamePlanner.preview(
            request: value.request,
            rule: value.rule,
            occupiedNames: value.occupiedNames,
            comparisonPolicy: value.comparisonPolicy
        ))
    }
}

@MainActor
private func waitForModel(
    _ predicate: @escaping @MainActor () -> Bool
) async {
    while !predicate() {
        await Task.yield()
    }
}
