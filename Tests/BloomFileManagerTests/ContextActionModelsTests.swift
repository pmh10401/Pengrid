import Foundation
import Testing
@testable import BloomFileManager

@Test func contextActionDraftNormalizesDirectoriesAndPreservesSourceOrder() {
    let first = contextActionItem(named: "first.txt")
    let second = contextActionItem(named: "second.txt")
    let sourceDirectory = URL(filePath: "/workspace/source/../source", directoryHint: .isDirectory)
    let oppositeDirectory = URL(filePath: "/workspace/opposite/./", directoryHint: .isDirectory)

    let draft = ContextActionDraft(
        requestID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
        sources: [first, second],
        sourcePaneID: .left,
        oppositePaneID: .right,
        sourceDirectory: sourceDirectory,
        oppositeDirectory: oppositeDirectory,
        sourceCapability: .writable,
        oppositeCapability: .readOnly
    )

    #expect(draft?.sources.map(\.name) == ["first.txt", "second.txt"])
    #expect(draft?.sourceDirectory == URL(filePath: "/workspace/source", directoryHint: .isDirectory))
    #expect(draft?.oppositeDirectory == URL(filePath: "/workspace/opposite", directoryHint: .isDirectory))
}

@Test func contextActionDraftRejectsIdenticalPaneIDs() {
    #expect(ContextActionDraft(
        sources: [contextActionItem(named: "document.txt")],
        sourcePaneID: .left,
        oppositePaneID: .left,
        sourceDirectory: URL(filePath: "/workspace/source", directoryHint: .isDirectory),
        oppositeDirectory: URL(filePath: "/workspace/opposite", directoryHint: .isDirectory),
        sourceCapability: .writable,
        oppositeCapability: .writable
    ) == nil)
}

@Test func contextActionSnapshotRejectsUnrelatedSourcesAndMismatchedDirectoryRequests() {
    let draft = ContextActionDraft(
        sources: [contextActionItem(named: "document.txt")],
        sourcePaneID: .left,
        oppositePaneID: .right,
        sourceDirectory: URL(filePath: "/workspace/source", directoryHint: .isDirectory),
        oppositeDirectory: URL(filePath: "/workspace/opposite", directoryHint: .isDirectory),
        sourceCapability: .writable,
        oppositeCapability: .writable
    )!
    let unrelatedSource = ContextActionSource(
        item: contextActionItem(named: "other.txt", in: "/workspace/other"),
        identity: contextActionIdentity("other")
    )
    let matchingSource = ContextActionSource(
        item: contextActionItem(named: "document.txt"),
        identity: contextActionIdentity("document")
    )
    let sourceRequest = IdentifiedFileRequest(
        url: URL(filePath: "/workspace/source", directoryHint: .isDirectory),
        identity: contextActionIdentity("source")
    )
    let oppositeRequest = IdentifiedFileRequest(
        url: URL(filePath: "/workspace/opposite", directoryHint: .isDirectory),
        identity: contextActionIdentity("opposite")
    )

    #expect(ContextActionSnapshot(
        draft: draft,
        sources: [unrelatedSource],
        sourceDirectory: sourceRequest,
        oppositeDirectory: oppositeRequest
    ) == nil)
    #expect(ContextActionSnapshot(
        draft: draft,
        sources: [matchingSource],
        sourceDirectory: IdentifiedFileRequest(
            url: URL(filePath: "/workspace/source/../other", directoryHint: .isDirectory),
            identity: contextActionIdentity("wrong-source")
        ),
        oppositeDirectory: oppositeRequest
    ) == nil)
}

@Test func contextActionSnapshotAcceptsExactOrderedDraftSources() {
    let draft = contextActionDraft(sources: [
        contextActionItem(named: "first.txt"),
        contextActionItem(named: "second.txt")
    ])
    let sources = [
        ContextActionSource(item: contextActionItem(named: "first.txt"), identity: contextActionIdentity("first")),
        ContextActionSource(item: contextActionItem(named: "second.txt"), identity: contextActionIdentity("second"))
    ]

    let snapshot = ContextActionSnapshot(
        draft: draft,
        sources: sources,
        sourceDirectory: contextActionDirectoryRequest("source"),
        oppositeDirectory: contextActionDirectoryRequest("opposite")
    )

    #expect(snapshot?.sources == sources)
    #expect(snapshot?.requestID == draft.requestID)
}

@Test func contextActionSnapshotRejectsReorderedDraftSources() {
    let first = contextActionItem(named: "first.txt")
    let second = contextActionItem(named: "second.txt")
    let draft = contextActionDraft(sources: [first, second])

    #expect(ContextActionSnapshot(
        draft: draft,
        sources: [
            ContextActionSource(item: second, identity: contextActionIdentity("second")),
            ContextActionSource(item: first, identity: contextActionIdentity("first"))
        ],
        sourceDirectory: contextActionDirectoryRequest("source"),
        oppositeDirectory: contextActionDirectoryRequest("opposite")
    ) == nil)
}

@Test func contextActionSnapshotRejectsSameParentSubstitution() {
    let draft = contextActionDraft(sources: [contextActionItem(named: "expected.txt")])

    #expect(ContextActionSnapshot(
        draft: draft,
        sources: [ContextActionSource(
            item: contextActionItem(named: "substituted.txt"),
            identity: contextActionIdentity("substituted")
        )],
        sourceDirectory: contextActionDirectoryRequest("source"),
        oppositeDirectory: contextActionDirectoryRequest("opposite")
    ) == nil)
}

@Test func contextActionSnapshotNormalizesCapturedDirectoryRequests() {
    let sourceRequest = IdentifiedFileRequest(
        url: URL(filePath: "/workspace/source/./", directoryHint: .isDirectory),
        identity: contextActionIdentity("source")
    )
    let oppositeRequest = IdentifiedFileRequest(
        url: URL(filePath: "/workspace/opposite/../opposite", directoryHint: .isDirectory),
        identity: contextActionIdentity("opposite")
    )
    let snapshot = ContextActionSnapshot(
        draft: contextActionDraft(sources: [contextActionItem(named: "document.txt")]),
        sources: [ContextActionSource(
            item: contextActionItem(named: "document.txt"),
            identity: contextActionIdentity("document")
        )],
        sourceDirectory: sourceRequest,
        oppositeDirectory: oppositeRequest
    )

    #expect(snapshot?.sourceDirectory.url == URL(filePath: "/workspace/source", directoryHint: .isDirectory))
    #expect(snapshot?.sourceDirectory.identity == sourceRequest.identity)
    #expect(snapshot?.oppositeDirectory.url == URL(filePath: "/workspace/opposite", directoryHint: .isDirectory))
    #expect(snapshot?.oppositeDirectory.identity == oppositeRequest.identity)
}

@Test func openWithApplicationsUseTheirApplicationURLAsIdentity() {
    let applicationURL = URL(filePath: "/Applications/Preview.app", directoryHint: .isDirectory)
    let application = OpenWithApplication(applicationURL: applicationURL, displayName: "Preview")

    #expect(application.id == applicationURL)
    #expect(ContextActionKind.openWith(applicationURL: applicationURL) == .openWith(applicationURL: applicationURL))
}

private func contextActionItem(named name: String, in directory: String = "/workspace/source") -> FileItem {
    FileItem(
        url: URL(filePath: directory, directoryHint: .isDirectory).appending(path: name),
        name: name,
        isDirectory: false,
        isPackage: false,
        modifiedAt: nil,
        byteSize: nil,
        typeDescription: "Document"
    )
}

private func contextActionIdentity(_ name: String) -> FileIdentity {
    FileIdentity(entryIdentifier: "entry-\(name)", resolvedIdentifier: "resolved-\(name)")
}

private func contextActionDraft(sources: [FileItem]) -> ContextActionDraft {
    ContextActionDraft(
        requestID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
        sources: sources,
        sourcePaneID: .left,
        oppositePaneID: .right,
        sourceDirectory: URL(filePath: "/workspace/source", directoryHint: .isDirectory),
        oppositeDirectory: URL(filePath: "/workspace/opposite", directoryHint: .isDirectory),
        sourceCapability: .writable,
        oppositeCapability: .writable
    )!
}

private func contextActionDirectoryRequest(_ name: String) -> IdentifiedFileRequest {
    IdentifiedFileRequest(
        url: URL(filePath: "/workspace/\(name)", directoryHint: .isDirectory),
        identity: contextActionIdentity(name)
    )
}
