import Foundation

enum ContextActionKind: Sendable, Equatable {
    case quickLook
    case openWith(applicationURL: URL)
    case openInOtherPane
    case transferToOtherPane(TransferMode)
    case showInFinder
    case copyPath(PathCopyRepresentation)
    case duplicate
    case encloseSelection
}

enum PathCopyRepresentation: Sendable, Equatable {
    case fullPath
    case name
    case parentPath
    case fileURL
}

struct OpenWithApplication: Sendable, Equatable, Identifiable {
    let applicationURL: URL
    let displayName: String

    var id: URL { applicationURL }
}

struct ContextActionSource: Sendable, Equatable {
    let item: FileItem
    let identity: FileIdentity
}

struct ContextActionDraft: Sendable, Equatable {
    let requestID: UUID
    let sources: [FileItem]
    let sourcePaneID: PaneID
    let oppositePaneID: PaneID
    let sourceDirectory: URL
    let oppositeDirectory: URL
    let sourceCapability: LocalFileOperationCapability
    let oppositeCapability: LocalFileOperationCapability

    init?(
        requestID: UUID = UUID(),
        sources: [FileItem],
        sourcePaneID: PaneID,
        oppositePaneID: PaneID,
        sourceDirectory: URL,
        oppositeDirectory: URL,
        sourceCapability: LocalFileOperationCapability,
        oppositeCapability: LocalFileOperationCapability
    ) {
        guard sourcePaneID != oppositePaneID else { return nil }
        self.requestID = requestID
        self.sources = sources
        self.sourcePaneID = sourcePaneID
        self.oppositePaneID = oppositePaneID
        self.sourceDirectory = sourceDirectory.standardizedFileURL
        self.oppositeDirectory = oppositeDirectory.standardizedFileURL
        self.sourceCapability = sourceCapability
        self.oppositeCapability = oppositeCapability
    }
}

struct ContextActionSnapshot: Sendable, Equatable {
    let requestID: UUID
    let sources: [ContextActionSource]
    let sourcePaneID: PaneID
    let oppositePaneID: PaneID
    let sourceDirectory: IdentifiedFileRequest
    let oppositeDirectory: IdentifiedFileRequest
    let sourceCapability: LocalFileOperationCapability
    let oppositeCapability: LocalFileOperationCapability

    init?(
        draft: ContextActionDraft,
        sources: [ContextActionSource],
        sourceDirectory: IdentifiedFileRequest,
        oppositeDirectory: IdentifiedFileRequest
    ) {
        let normalizedSourceDirectoryURL = sourceDirectory.url.standardizedFileURL
        let normalizedOppositeDirectoryURL = oppositeDirectory.url.standardizedFileURL
        guard !sources.isEmpty,
              draft.sourcePaneID != draft.oppositePaneID,
              sources.count == draft.sources.count,
              zip(sources, draft.sources).allSatisfy({
                  Self.matchesCapturedItem($0.item, draftItem: $1)
              }),
              normalizedSourceDirectoryURL == draft.sourceDirectory,
              normalizedOppositeDirectoryURL == draft.oppositeDirectory,
              sources.allSatisfy({
                  $0.item.url.deletingLastPathComponent().standardizedFileURL == draft.sourceDirectory
              })
        else { return nil }

        self.requestID = draft.requestID
        self.sources = sources
        self.sourcePaneID = draft.sourcePaneID
        self.oppositePaneID = draft.oppositePaneID
        self.sourceDirectory = IdentifiedFileRequest(
            url: normalizedSourceDirectoryURL,
            identity: sourceDirectory.identity
        )
        self.oppositeDirectory = IdentifiedFileRequest(
            url: normalizedOppositeDirectoryURL,
            identity: oppositeDirectory.identity
        )
        self.sourceCapability = draft.sourceCapability
        self.oppositeCapability = draft.oppositeCapability
    }

    private static func matchesCapturedItem(
        _ captured: FileItem,
        draftItem: FileItem
    ) -> Bool {
        captured.url.standardizedFileURL == draftItem.url.standardizedFileURL
            && captured.name == draftItem.name
            && captured.isDirectory == draftItem.isDirectory
            && captured.isPackage == draftItem.isPackage
            && captured.isSymbolicLink == draftItem.isSymbolicLink
            && captured.modifiedAt == draftItem.modifiedAt
            && captured.byteSize == draftItem.byteSize
            && captured.typeDescription == draftItem.typeDescription
            && captured.availability == draftItem.availability
    }
}

struct ContextActionAvailability: Sendable, Equatable {
    let isVisible: Bool
    let isEnabled: Bool
    let disabledReason: String?

    static let hidden = ContextActionAvailability(
        isVisible: false,
        isEnabled: false,
        disabledReason: nil
    )
    static let enabled = ContextActionAvailability(
        isVisible: true,
        isEnabled: true,
        disabledReason: nil
    )

    static func disabled(reason: String) -> ContextActionAvailability {
        precondition(!reason.isEmpty, "Disabled context actions require a reason")
        return ContextActionAvailability(isVisible: true, isEnabled: false, disabledReason: reason)
    }
}
