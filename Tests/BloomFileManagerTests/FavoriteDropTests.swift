import AppKit
import Foundation
import Testing
@testable import BloomFileManager

@Test func favoriteDropAcceptsDirectoriesAndRejectsFiles() {
    let folder = FileItem(
        url: URL(filePath: "/Folder", directoryHint: .isDirectory),
        name: "Folder",
        isDirectory: true,
        isPackage: false,
        modifiedAt: nil,
        byteSize: nil,
        typeDescription: "Folder"
    )
    let file = FileItem(
        url: URL(filePath: "/a.txt"),
        name: "a.txt",
        isDirectory: false,
        isPackage: false,
        modifiedAt: nil,
        byteSize: 1,
        typeDescription: "Text"
    )

    #expect(FavoriteDropPolicy.accepts(folder))
    #expect(FavoriteDropPolicy.accepts(file) == false)
}

@Test func favoriteDropRejectsNonFileURLsPackagesAndMixedPayloads() throws {
    let temporaryDirectory = try TemporaryDirectory()
    defer { temporaryDirectory.remove() }
    let folder = temporaryDirectory.url.appending(path: "Folder", directoryHint: .isDirectory)
    let secondFolder = temporaryDirectory.url.appending(path: "Second", directoryHint: .isDirectory)
    let file = temporaryDirectory.url.appending(path: "note.txt", directoryHint: .notDirectory)
    let package = temporaryDirectory.url.appending(path: "Sample.app", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    try FileManager.default.createDirectory(at: secondFolder, withIntermediateDirectories: false)
    try Data().write(to: file)
    try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)

    #expect(FavoriteDropPolicy.accepts(urls: [folder, secondFolder]))
    #expect(FavoriteDropPolicy.accepts(urls: [file]) == false)
    #expect(FavoriteDropPolicy.accepts(urls: [package]) == false)
    #expect(FavoriteDropPolicy.accepts(urls: [URL(string: "https://example.com/folder")!]) == false)
    #expect(FavoriteDropPolicy.accepts(urls: [folder, file]) == false)
    #expect(FavoriteDropPolicy.accepts(urls: []) == false)
}

@Test func validFavoriteDropUsesCopyIntentAndAddsEveryFolder() throws {
    let temporaryDirectory = try TemporaryDirectory()
    defer { temporaryDirectory.remove() }
    let urls = ["A", "B"].map {
        temporaryDirectory.url.appending(path: $0, directoryHint: .isDirectory)
    }
    for url in urls {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }
    var added: [URL] = []

    #expect(FavoriteDropPolicy.operation(for: urls) == .copy)
    #expect(FavoriteDropPolicy.perform(urls: urls) { added.append($0) })
    #expect(added == urls)
}

@Test func invalidFavoriteDropDoesNotPartiallyInvokeAddCallback() throws {
    let temporaryDirectory = try TemporaryDirectory()
    defer { temporaryDirectory.remove() }
    let folder = temporaryDirectory.url.appending(path: "Folder", directoryHint: .isDirectory)
    let file = temporaryDirectory.url.appending(path: "note.txt")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    try Data().write(to: file)
    var added: [URL] = []

    #expect(FavoriteDropPolicy.operation(for: [folder, file]).isEmpty)
    #expect(FavoriteDropPolicy.perform(urls: [folder, file]) { added.append($0) } == false)
    #expect(added.isEmpty)
}

@MainActor
@Test func resolvedExactFavoriteIsReportedAsDuplicate() throws {
    let temporaryDirectory = try TemporaryDirectory()
    defer { temporaryDirectory.remove() }
    let alias = URL(filePath: "/favorites/Alias")
    let target = URL(filePath: "/favorites/Target")
    let store = FavoritesStore(
        storageURL: temporaryDirectory.url.appending(path: "favorites.json"),
        bookmarking: InMemoryFavoriteBookmarking(resolvedPaths: [alias.path: target.path])
    )
    try store.add(alias)

    #expect(store.containsExactURL(target))
    #expect(store.containsExactURL(alias))
    #expect(store.containsExactURL(URL(filePath: "/other/Target")) == false)
}

@MainActor
@Test func unavailableFavoriteNeverNavigatesEitherPane() async {
    let left = URL(filePath: "/left")
    let right = URL(filePath: "/right")
    let workspace = WorkspaceState(
        leftURL: left,
        rightURL: right,
        listingService: StubDirectoryListingService(values: [:])
    )
    workspace.activate(.right)

    let result = await FavoriteNavigationRouter.open(
        .unavailable(lastKnownPath: "/missing"),
        in: workspace.activePane
    )

    #expect(result == .unavailable(lastKnownPath: "/missing"))
    #expect(workspace.left.currentDirectory == left)
    #expect(workspace.right.currentDirectory == right)
}

@MainActor
@Test func availableFavoriteNavigatesOnlyTheActivePane() async {
    let left = URL(filePath: "/left")
    let right = URL(filePath: "/right")
    let favorite = URL(filePath: "/favorite")
    let workspace = WorkspaceState(
        leftURL: left,
        rightURL: right,
        listingService: StubDirectoryListingService(values: [:])
    )
    workspace.activate(.right)

    let result = await FavoriteNavigationRouter.open(.available(favorite), in: workspace.activePane)

    #expect(result == .navigated(favorite))
    #expect(workspace.left.currentDirectory == left)
    #expect(workspace.right.currentDirectory == favorite)
}

@Test func favoriteAccessibilityLabelsDescribeAvailability() {
    #expect(
        FavoriteRowPresentation.accessibilityLabel(
            name: "Projects",
            resolution: .available(URL(filePath: "/Projects"))
        ) == "Favorite, Projects"
    )
    #expect(
        FavoriteRowPresentation.accessibilityLabel(
            name: "Archive",
            resolution: .unavailable(lastKnownPath: "/Archive")
        ) == "Unavailable favorite, Archive"
    )
}

@Test func favoriteAddPolicyAllowsOnlyNonDuplicateFolders() {
    let directory = FileItem(
        url: URL(filePath: "/Folder", directoryHint: .isDirectory),
        name: "Folder",
        isDirectory: true,
        isPackage: false,
        modifiedAt: nil,
        byteSize: nil,
        typeDescription: "Folder"
    )
    let package = FileItem(
        url: URL(filePath: "/Example.app", directoryHint: .isDirectory),
        name: "Example.app",
        isDirectory: true,
        isPackage: true,
        modifiedAt: nil,
        byteSize: nil,
        typeDescription: "Application"
    )

    #expect(FavoriteAddPolicy.canAdd(directory, containsExactURL: { _ in false }))
    #expect(FavoriteAddPolicy.canAdd(directory, containsExactURL: { _ in true }) == false)
    #expect(FavoriteAddPolicy.canAdd(package, containsExactURL: { _ in false }) == false)
}

@MainActor
@Test func railDropTargetReturnsCopyAndInvokesCallbackOnlyForValidPayload() throws {
    let temporaryDirectory = try TemporaryDirectory()
    defer { temporaryDirectory.remove() }
    let folder = temporaryDirectory.url.appending(path: "Folder", directoryHint: .isDirectory)
    let file = temporaryDirectory.url.appending(path: "note.txt")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    try Data().write(to: file)
    var callbacks: [[URL]] = []
    let target = FavoriteDropTargetNSView { callbacks.append($0) }

    let validPasteboard = NSPasteboard(name: NSPasteboard.Name("FavoriteDrop-\(UUID())"))
    FileURLPasteboard.write([folder], to: validPasteboard)
    let validDrop = FavoriteDraggingInfoStub(pasteboard: validPasteboard)
    #expect(target.draggingEntered(validDrop) == .copy)
    #expect(target.prepareForDragOperation(validDrop))
    #expect(target.performDragOperation(validDrop))
    #expect(callbacks == [[folder]])

    let invalidPasteboard = NSPasteboard(name: NSPasteboard.Name("FavoriteDrop-\(UUID())"))
    FileURLPasteboard.write([folder, file], to: invalidPasteboard)
    let invalidDrop = FavoriteDraggingInfoStub(pasteboard: invalidPasteboard)
    #expect(target.draggingEntered(invalidDrop).isEmpty)
    #expect(target.prepareForDragOperation(invalidDrop) == false)
    #expect(target.performDragOperation(invalidDrop) == false)
    #expect(callbacks == [[folder]])
}

@MainActor
@Test func railDropTargetRejectsActualMixedFolderAndHTTPSPasteboard() throws {
    let temporaryDirectory = try TemporaryDirectory()
    defer { temporaryDirectory.remove() }
    let folder = temporaryDirectory.url.appending(path: "Folder", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    let webURL = try #require(URL(string: "https://example.com/folder"))
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("FavoriteMixedDrop-\(UUID())"))
    pasteboard.clearContents()
    #expect(pasteboard.writeObjects([folder as NSURL, webURL as NSURL]))
    #expect(pasteboard.pasteboardItems?.count == 2)
    var callbacks: [[URL]] = []
    let target = FavoriteDropTargetNSView { callbacks.append($0) }
    let drop = FavoriteDraggingInfoStub(pasteboard: pasteboard)

    #expect(target.draggingEntered(drop).isEmpty)
    #expect(target.prepareForDragOperation(drop) == false)
    #expect(target.performDragOperation(drop) == false)
    #expect(callbacks.isEmpty)
}

@MainActor
@Test func railDropTargetRejectsMalformedFileURLAndPlainTextItems() {
    let malformedItem = NSPasteboardItem()
    malformedItem.setString("not a URL", forType: .fileURL)
    let malformedPasteboard = NSPasteboard(name: NSPasteboard.Name("FavoriteMalformedDrop-\(UUID())"))
    malformedPasteboard.clearContents()
    #expect(malformedPasteboard.writeObjects([malformedItem]))

    let textItem = NSPasteboardItem()
    textItem.setString("plain text", forType: .string)
    let textPasteboard = NSPasteboard(name: NSPasteboard.Name("FavoriteTextDrop-\(UUID())"))
    textPasteboard.clearContents()
    #expect(textPasteboard.writeObjects([textItem]))

    var callbackCount = 0
    let target = FavoriteDropTargetNSView { _ in callbackCount += 1 }
    for pasteboard in [malformedPasteboard, textPasteboard] {
        let drop = FavoriteDraggingInfoStub(pasteboard: pasteboard)
        #expect(target.draggingEntered(drop).isEmpty)
        #expect(target.prepareForDragOperation(drop) == false)
        #expect(target.performDragOperation(drop) == false)
    }
    #expect(callbackCount == 0)
}

@MainActor
private final class FavoriteDraggingInfoStub: NSObject, @preconcurrency NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingDestinationWindow: NSWindow? = nil
    let draggingSourceOperationMask: NSDragOperation = [.copy, .move]
    let draggingLocation: NSPoint = .zero
    let draggedImageLocation: NSPoint = .zero
    let draggedImage: NSImage? = nil
    let draggingSource: Any? = nil
    let draggingSequenceNumber = 1
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    let springLoadingHighlight: NSSpringLoadingHighlight = .none

    init(pasteboard: NSPasteboard) {
        draggingPasteboard = pasteboard
    }

    func slideDraggedImage(to screenPoint: NSPoint) {}

    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions,
        for view: NSView?,
        classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any],
        using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}

    func resetSpringLoading() {}
}
