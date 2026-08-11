import Foundation
import Testing
@testable import BloomFileManager

@MainActor
@Suite struct SelectionFolderModelTests {
    @Test func presentCapturesIdentitiesAndTrimsTheDefaultSubmissionName() async throws {
        let fixture = SelectionFolderFixture(names: ["A.txt", "B.txt"])
        let model = fixture.model()

        await model.present(fixture.snapshot)
        let plan = try #require(model.beginSubmission())

        #expect(plan.parentURL == fixture.parent)
        #expect(plan.parentIdentity == fixture.parentIdentity)
        #expect(plan.folderName == "New Folder with Items")
        #expect(plan.folderURL == fixture.parent.appending(path: "New Folder with Items"))
        #expect(plan.sources.map(\.identity) == fixture.sourceIdentities)
        #expect(plan.sources.map(\.item.url) == fixture.items.map(\.url))

        let trimmed = fixture.model()
        await trimmed.present(fixture.snapshot)
        trimmed.updateName("  Collected Items  \n")
        #expect(trimmed.beginSubmission()?.folderName == "Collected Items")
    }

    @Test func eachPresentationRestoresTheDocumentedDefaultName() async {
        let fixture = SelectionFolderFixture(names: ["A.txt", "B.txt"])
        let model = fixture.model()
        await model.present(fixture.snapshot)
        model.updateName("Draft From Earlier Selection")
        model.dismiss()

        await model.present(fixture.snapshot)

        #expect(model.folderName == "New Folder with Items")
        #expect(model.canSubmit)
    }

    @Test func pathBearingFilesystemFailuresBecomePrivacySafeValidation() async {
        let fixture = SelectionFolderFixture(
            names: ["A.txt", "B.txt"],
            parentIdentityFailure: SelectionFolderPathBearingError()
        )
        let model = fixture.model()

        await model.present(fixture.snapshot)

        #expect(model.validationMessage == "The selected folder is not currently accessible.")
        #expect(!model.validationMessage!.contains("/private/secret-folder"))
        #expect(!model.canSubmit)
    }

    @Test(arguments: ["   ", ".", "..", "bad/name", "bad\0name"])
    func invalidFolderNamesBlockSubmission(_ name: String) async {
        let fixture = SelectionFolderFixture(names: ["A.txt", "B.txt"])
        let model = fixture.model()
        await model.present(fixture.snapshot)

        model.updateName(name)

        #expect(!model.canSubmit)
        #expect(model.validationMessage != nil)
        #expect(model.beginSubmission() == nil)
    }

    @Test func canonicalAndCaseInsensitiveSiblingCollisionsBlockSubmission() async {
        let fixture = SelectionFolderFixture(
            names: ["A.txt", "B.txt"],
            siblingNames: ["Caf\u{00E9}", "Existing Folder"],
            caseInsensitive: true
        )
        let model = fixture.model()
        await model.present(fixture.snapshot)

        model.updateName("Cafe\u{301}")
        #expect(!model.canSubmit)

        model.updateName("existing folder")
        #expect(!model.canSubmit)
    }

    @Test func rejectsChangedParentAndMissingCapturedSource() async throws {
        let fixture = SelectionFolderFixture(names: ["A.txt", "B.txt"])
        await fixture.fileSystem.replaceIdentity(
            at: fixture.parent,
            with: FileIdentity(entryIdentifier: "new-parent", resolvedIdentifier: "new-parent")
        )
        let changedParent = fixture.model()
        await changedParent.present(fixture.snapshot)
        #expect(!changedParent.canSubmit)
        #expect(changedParent.validationMessage == "The containing folder has changed.")

        let missing = SelectionFolderFixture(names: ["A.txt", "B.txt"])
        try await missing.fileSystem.remove(missing.items[0].url)
        let missingModel = missing.model()
        await missingModel.present(missing.snapshot)
        #expect(!missingModel.canSubmit)
        #expect(missingModel.validationMessage == "A.txt is no longer available.")
    }

    @Test func selectionAndCapabilityMustAllowAnExclusiveWritableOperation() async {
        let one = SelectionFolderFixture(names: ["A.txt"])
        let tooSmall = one.model()
        await tooSmall.present(one.snapshot)
        #expect(tooSmall.validationMessage == "Select at least two items.")
        #expect(!tooSmall.canSubmit)

        let readOnly = SelectionFolderFixture(names: ["A.txt", "B.txt"], capability: .readOnly)
        let readOnlyModel = readOnly.model()
        await readOnlyModel.present(readOnly.snapshot)
        #expect(readOnlyModel.validationMessage == "This location does not allow local file operations.")
        #expect(!readOnlyModel.canSubmit)
        readOnlyModel.updateName("Still Not Allowed")
        #expect(!readOnlyModel.canSubmit)
    }

    @Test func nonSiblingSelectionCannotBecomeAnEnclosureSnapshot() {
        let parent = URL(filePath: "/selection-folder", directoryHint: .isDirectory)
        let opposite = URL(filePath: "/opposite", directoryHint: .isDirectory)
        let first = SelectionFolderFixture(names: ["A.txt", "B.txt"])
        let nonSiblingItems = [
            first.items[0],
            FileItem(
                url: URL(filePath: "/elsewhere/B.txt"),
                name: "B.txt",
                isDirectory: false,
                isPackage: false,
                modifiedAt: nil,
                byteSize: nil,
                typeDescription: "Document"
            )
        ]
        let draft = ContextActionDraft(
            sources: nonSiblingItems,
            sourcePaneID: .left,
            oppositePaneID: .right,
            sourceDirectory: parent,
            oppositeDirectory: opposite,
            sourceCapability: .writable,
            oppositeCapability: .writable
        )!

        let snapshot = ContextActionSnapshot(
            draft: draft,
            sources: [
                ContextActionSource(item: nonSiblingItems[0], identity: first.sourceIdentities[0]),
                ContextActionSource(
                    item: nonSiblingItems[1],
                    identity: FileIdentity(entryIdentifier: "elsewhere", resolvedIdentifier: "elsewhere")
                )
            ],
            sourceDirectory: IdentifiedFileRequest(url: parent, identity: first.parentIdentity),
            oppositeDirectory: IdentifiedFileRequest(
                url: opposite,
                identity: FileIdentity(entryIdentifier: "opposite", resolvedIdentifier: "opposite")
            )
        )

        #expect(snapshot == nil)
    }

    @Test func onlyTheCurrentPresentationGenerationCanPublish() async {
        let fixture = SelectionFolderFixture(
            names: ["A.txt", "B.txt"],
            suspendParentIdentity: true
        )
        let model = fixture.model()
        let task = Task { await model.present(fixture.snapshot) }
        while !(await fixture.fileSystem.hasSuspendedIdentity) {
            await Task.yield()
        }
        #expect(!model.canSubmit)

        model.dismiss()
        await fixture.fileSystem.releaseSuspendedIdentity()
        await task.value

        #expect(!model.isPresented)
        #expect(model.snapshot == nil)
        #expect(!model.canSubmit)
    }
}

private struct SelectionFolderFixture {
    let parent = URL(filePath: "/selection-folder", directoryHint: .isDirectory)
    let fileSystem: RecordingFileSystem
    let items: [FileItem]
    let parentIdentity: FileIdentity
    let sourceIdentities: [FileIdentity]
    let capability: LocalFileOperationCapability

    init(
        names: [String],
        siblingNames: [String] = [],
        caseInsensitive: Bool = false,
        capability: LocalFileOperationCapability = .writable,
        suspendParentIdentity: Bool = false,
        parentIdentityFailure: (any Error)? = nil
    ) {
        let parent = URL(filePath: "/selection-folder", directoryHint: .isDirectory)
        let parentIdentity = FileIdentity(entryIdentifier: "parent", resolvedIdentifier: "parent")
        let allNames = names + siblingNames
        var identities = [parent: parentIdentity]
        for name in allNames {
            identities[parent.appending(path: name)] = FileIdentity(
                entryIdentifier: "entry-\(name)",
                resolvedIdentifier: "resolved-\(name)"
            )
        }
        self.fileSystem = RecordingFileSystem(
            existingURLs: Set([parent] + allNames.map { parent.appending(path: $0) }),
            failures: parentIdentityFailure.map { [.identity(parent): $0] } ?? [:],
            identities: identities,
            suspendIdentityOf: suspendParentIdentity ? parent : nil,
            caseInsensitivePaths: caseInsensitive
        )
        self.items = names.map { name in
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
        self.sourceIdentities = names.map { identities[parent.appending(path: $0)]! }
        self.capability = capability
    }

    var snapshot: ContextActionSnapshot {
        let opposite = URL(filePath: "/opposite", directoryHint: .isDirectory)
        let draft = ContextActionDraft(
            sources: items,
            sourcePaneID: .left,
            oppositePaneID: .right,
            sourceDirectory: parent,
            oppositeDirectory: opposite,
            sourceCapability: capability,
            oppositeCapability: .writable
        )!
        return ContextActionSnapshot(
            draft: draft,
            sources: zip(items, sourceIdentities).map(ContextActionSource.init),
            sourceDirectory: IdentifiedFileRequest(url: parent, identity: parentIdentity),
            oppositeDirectory: IdentifiedFileRequest(
                url: opposite,
                identity: FileIdentity(entryIdentifier: "opposite", resolvedIdentifier: "opposite")
            )
        )!
    }

    @MainActor func model() -> SelectionFolderModel {
        SelectionFolderModel(fileSystem: fileSystem)
    }
}

private struct SelectionFolderPathBearingError: LocalizedError {
    var errorDescription: String? {
        "Permission denied for /private/secret-folder/Financials"
    }
}
