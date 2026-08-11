import Foundation
import Testing
@testable import BloomFileManager

@MainActor
struct FileContextActionRouterTests {
    @Test func capturePreservesOrderedSourcesAndIdentities() async {
        let directory = URL(filePath: "/capture", directoryHint: .isDirectory)
        let opposite = URL(filePath: "/opposite", directoryHint: .isDirectory)
        let first = directory.appending(path: "first.txt")
        let second = directory.appending(path: "second.txt")
        let firstIdentity = identity("first")
        let secondIdentity = identity("second")
        let directoryIdentity = identity("directory")
        let oppositeIdentity = identity("opposite")
        let fileSystem = RecordingFileSystem(identities: [
            first: firstIdentity,
            second: secondIdentity,
            directory: directoryIdentity,
            opposite: oppositeIdentity
        ])
        let router = FileContextActionRouter(fileSystem: fileSystem)
        var selection = [item(at: second), item(at: first)]

        let snapshot = await router.capture(draft(
            sources: selection,
            directory: directory,
            oppositeDirectory: opposite
        ))
        selection = [item(at: directory.appending(path: "later-selection.txt"))]

        #expect(snapshot?.sources.map(\.item.url) == [second, first])
        #expect(snapshot?.sources.map(\.identity) == [secondIdentity, firstIdentity])
        #expect(snapshot?.sourceDirectory.identity == directoryIdentity)
        #expect(snapshot?.oppositeDirectory.identity == oppositeIdentity)
        #expect(await fileSystem.events == [
            "identity:/capture/second.txt",
            "identity:/capture/first.txt",
            "identity:/capture",
            "identity:/opposite"
        ])
    }

    @Test func captureUsesOneBalancedScopeForSourcesAndDirectories() async {
        let root = URL(filePath: "/cloud", directoryHint: .isDirectory)
        let directory = root.appending(path: "source", directoryHint: .isDirectory)
        let opposite = root.appending(path: "opposite", directoryHint: .isDirectory)
        let source = directory.appending(path: "report.txt")
        let driver = ContextActionSecurityScopeDriver(permitsAccess: true)
        let coordinator = CloudLocationScopedAccessCoordinator(driver: driver)
        coordinator.replaceManualRoots([root])
        let router = FileContextActionRouter(
            fileSystem: RecordingFileSystem(identities: identities(for: [source, directory, opposite])),
            accessCoordinator: coordinator
        )

        #expect(await router.capture(draft(
            sources: [item(at: source)], directory: directory, oppositeDirectory: opposite
        )) != nil)
        #expect(driver.startedURLs == [root])
        #expect(driver.stoppedURLs == [root])
    }

    @Test func captureRejectsDeniedScopeWithoutReadingAnIdentity() async {
        let root = URL(filePath: "/denied", directoryHint: .isDirectory)
        let source = root.appending(path: "report.txt")
        let opposite = URL(filePath: "/opposite", directoryHint: .isDirectory)
        let driver = ContextActionSecurityScopeDriver(permitsAccess: false)
        let coordinator = CloudLocationScopedAccessCoordinator(driver: driver)
        coordinator.replaceManualRoots([root])
        let fileSystem = RecordingFileSystem(identities: identities(for: [source, root, opposite]))
        let router = FileContextActionRouter(fileSystem: fileSystem, accessCoordinator: coordinator)

        #expect(await router.capture(draft(
            sources: [item(at: source)], directory: root, oppositeDirectory: opposite
        )) == nil)
        #expect(router.error == .accessDenied)
        #expect(await fileSystem.events.isEmpty)
        #expect(driver.startedURLs == [root])
        #expect(driver.stoppedURLs.isEmpty)
    }

    @Test func captureRejectsMissingIdentityAndDoesNotConstructASnapshot() async {
        let directory = URL(filePath: "/capture", directoryHint: .isDirectory)
        let opposite = URL(filePath: "/opposite", directoryHint: .isDirectory)
        let missing = directory.appending(path: "missing.txt")
        let fileSystem = RecordingFileSystem(identities: identities(for: [directory, opposite]))
        let router = FileContextActionRouter(fileSystem: fileSystem)

        #expect(await router.capture(draft(
            sources: [item(at: missing)], directory: directory, oppositeDirectory: opposite
        )) == nil)
        #expect(router.error == .itemChanged)
        #expect(await fileSystem.events == ["identity:/capture/missing.txt"])
    }

    @Test func captureCancellationDoesNotReportAnErrorOrCreateExternalEffects() async {
        let directory = URL(filePath: "/capture", directoryHint: .isDirectory)
        let opposite = URL(filePath: "/opposite", directoryHint: .isDirectory)
        let source = directory.appending(path: "report.txt")
        let router = FileContextActionRouter(fileSystem: RecordingFileSystem(
            identities: identities(for: [source, directory, opposite]),
            cancelAfterIdentityOf: source
        ))

        let operation = Task {
            await router.capture(draft(
                sources: [item(at: source)], directory: directory, oppositeDirectory: opposite
            ))
        }

        #expect(await operation.value == nil)
        #expect(router.error == nil)
    }

    @Test func finderRevealRevalidatesEveryCapturedSourceInOrderWithOneAdapterCall() async {
        let directory = URL(filePath: "/finder", directoryHint: .isDirectory)
        let opposite = URL(filePath: "/opposite", directoryHint: .isDirectory)
        let first = directory.appending(path: "first.txt")
        let second = directory.appending(path: "second.txt")
        let finder = FinderRecorder()
        let fileSystem = RecordingFileSystem(identities: [
            first: identity("first"),
            second: identity("second")
        ])
        let router = FileContextActionRouter(fileSystem: fileSystem, finderRevealer: finder)

        #expect(await router.showInFinder(snapshot(
            sources: [item(at: second), item(at: first)],
            directory: directory,
            oppositeDirectory: opposite,
            identities: [identity("second"), identity("first")]
        )))
        #expect(finder.reveals == [[second, first]])
        #expect(await fileSystem.events == [
            "identity:/finder/second.txt",
            "identity:/finder/first.txt"
        ])
    }

    @Test func finderRevealOmitsChangedEntriesAndStillSucceeds() async {
        let directory = URL(filePath: "/finder", directoryHint: .isDirectory)
        let opposite = URL(filePath: "/opposite", directoryHint: .isDirectory)
        let unchanged = directory.appending(path: "unchanged.txt")
        let changed = directory.appending(path: "changed.txt")
        let finder = FinderRecorder()
        let router = FileContextActionRouter(
            fileSystem: RecordingFileSystem(identities: [
                unchanged: identity("unchanged"),
                changed: identity("replacement")
            ]),
            finderRevealer: finder
        )

        #expect(await router.showInFinder(snapshot(
            sources: [item(at: unchanged), item(at: changed)],
            directory: directory,
            oppositeDirectory: opposite,
            identities: [identity("unchanged"), identity("changed")]
        )))
        #expect(finder.reveals == [[unchanged]])
        #expect(router.error == nil)
    }

    @Test func finderRevealRejectsWhenNoCapturedIdentityRemains() async {
        let directory = URL(filePath: "/finder", directoryHint: .isDirectory)
        let opposite = URL(filePath: "/opposite", directoryHint: .isDirectory)
        let source = directory.appending(path: "changed.txt")
        let finder = FinderRecorder()
        let router = FileContextActionRouter(
            fileSystem: RecordingFileSystem(identities: [source: identity("replacement")]),
            finderRevealer: finder
        )

        #expect(!(await router.showInFinder(snapshot(
            sources: [item(at: source)],
            directory: directory,
            oppositeDirectory: opposite,
            identities: [identity("original")]
        ))))
        #expect(router.error == .itemChanged)
        #expect(finder.reveals.isEmpty)
    }

    @Test func finderRevealDenialDoesNotRevealOrReadTheFileSystem() async {
        let root = URL(filePath: "/denied", directoryHint: .isDirectory)
        let source = root.appending(path: "report.txt")
        let driver = ContextActionSecurityScopeDriver(permitsAccess: false)
        let coordinator = CloudLocationScopedAccessCoordinator(driver: driver)
        coordinator.replaceManualRoots([root])
        let finder = FinderRecorder()
        let fileSystem = RecordingFileSystem(identities: [source: identity("source")])
        let router = FileContextActionRouter(
            fileSystem: fileSystem,
            accessCoordinator: coordinator,
            finderRevealer: finder
        )

        #expect(!(await router.showInFinder(snapshot(
            sources: [item(at: source)], directory: root, oppositeDirectory: URL(filePath: "/opposite"),
            identities: [identity("source")]
        ))))
        #expect(router.error == .accessDenied)
        #expect(finder.reveals.isEmpty)
        #expect(await fileSystem.events.isEmpty)
    }

    @Test func finderRevealCancellationDoesNotRevealOrAnnounce() async {
        let directory = URL(filePath: "/finder", directoryHint: .isDirectory)
        let opposite = URL(filePath: "/opposite", directoryHint: .isDirectory)
        let source = directory.appending(path: "report.txt")
        let finder = FinderRecorder()
        let announcements = AnnouncementRecorder()
        let router = FileContextActionRouter(
            fileSystem: RecordingFileSystem(
                identities: [source: identity("source")],
                cancelAfterIdentityOf: source
            ),
            finderRevealer: finder,
            announcementPoster: announcements
        )

        let operation = Task {
            await router.showInFinder(snapshot(
                sources: [item(at: source)],
                directory: directory,
                oppositeDirectory: opposite,
                identities: [identity("source")]
            ))
        }

        #expect(!(await operation.value))
        #expect(finder.reveals.isEmpty)
        #expect(announcements.messages.isEmpty)
        #expect(router.error == nil)
    }

    @Test func copyPathWritesEveryApprovedRepresentationAsPlainTextWithoutFileSystemReads() async {
        let directory = URL(filePath: "/private folder", directoryHint: .isDirectory)
        let opposite = URL(filePath: "/other", directoryHint: .isDirectory)
        let first = directory.appending(path: "first report.txt")
        let second = directory.appending(path: "second.txt")
        let writer = PasteboardRecorder()
        let announcements = AnnouncementRecorder()
        let fileSystem = RecordingFileSystem()
        let router = FileContextActionRouter(
            fileSystem: fileSystem,
            pasteboardWriter: writer,
            announcementPoster: announcements
        )
        let actionSnapshot = snapshot(
            sources: [item(at: first, name: "Display First"), item(at: second, name: "Display Second")],
            directory: directory,
            oppositeDirectory: opposite,
            identities: [identity("first"), identity("second")]
        )

        #expect(router.copyPath(.fullPath, from: actionSnapshot) == 2)
        #expect(router.copyPath(.name, from: actionSnapshot) == 2)
        #expect(router.copyPath(.parentPath, from: actionSnapshot) == 1)
        #expect(router.copyPath(.fileURL, from: actionSnapshot) == 2)
        #expect(writer.values == [
            first.standardizedFileURL.path + "\n" + second.standardizedFileURL.path,
            "Display First\nDisplay Second",
            directory.path,
            first.standardizedFileURL.absoluteString + "\n" + second.standardizedFileURL.absoluteString
        ])
        #expect(announcements.messages == [
            "Copied full paths for 2 items.",
            "Copied names for 2 items.",
            "Copied parent path.",
            "Copied file URLs for 2 items."
        ])
        #expect(announcements.messages.allSatisfy {
            !$0.contains(directory.path) && !$0.contains(first.absoluteString)
        })
        #expect(await fileSystem.events.isEmpty)
    }
}

private func identity(_ name: String) -> FileIdentity {
    FileIdentity(entryIdentifier: "entry-\(name)", resolvedIdentifier: "resolved-\(name)")
}

private func item(at url: URL, name: String? = nil) -> FileItem {
    FileItem(
        url: url,
        name: name ?? url.lastPathComponent,
        isDirectory: false,
        isPackage: false,
        modifiedAt: .distantPast,
        byteSize: 12,
        typeDescription: "Text"
    )
}

private func draft(
    sources: [FileItem],
    directory: URL,
    oppositeDirectory: URL
) -> ContextActionDraft {
    ContextActionDraft(
        sources: sources,
        sourcePaneID: .left,
        oppositePaneID: .right,
        sourceDirectory: directory,
        oppositeDirectory: oppositeDirectory,
        sourceCapability: .writable,
        oppositeCapability: .readOnly
    )!
}

private func snapshot(
    sources: [FileItem],
    directory: URL,
    oppositeDirectory: URL,
    identities: [FileIdentity]
) -> ContextActionSnapshot {
    let actionDraft = draft(
        sources: sources,
        directory: directory,
        oppositeDirectory: oppositeDirectory
    )
    return ContextActionSnapshot(
        draft: actionDraft,
        sources: zip(sources, identities).map { ContextActionSource(item: $0.0, identity: $0.1) },
        sourceDirectory: IdentifiedFileRequest(url: directory, identity: identity("directory")),
        oppositeDirectory: IdentifiedFileRequest(url: oppositeDirectory, identity: identity("opposite"))
    )!
}

private func identities(for urls: [URL]) -> [URL: FileIdentity] {
    Dictionary(uniqueKeysWithValues: urls.map { ($0, identity($0.lastPathComponent)) })
}

@MainActor
private final class FinderRecorder: FinderRevealing {
    private(set) var reveals: [[URL]] = []

    func reveal(_ urls: [URL]) {
        reveals.append(urls)
    }
}

@MainActor
private final class PasteboardRecorder: TextPasteboardWriting {
    private(set) var values: [String] = []

    func writePlainText(_ value: String) {
        values.append(value)
    }
}

@MainActor
private final class AnnouncementRecorder: ContextActionAnnouncementPosting {
    private(set) var messages: [String] = []

    func post(_ message: String) {
        messages.append(message)
    }
}

private final class ContextActionSecurityScopeDriver: SecurityScopedResourceAccessing, @unchecked Sendable {
    let permitsAccess: Bool
    private(set) var startedURLs: [URL] = []
    private(set) var stoppedURLs: [URL] = []

    init(permitsAccess: Bool) {
        self.permitsAccess = permitsAccess
    }

    func startAccessing(_ url: URL) -> Bool {
        startedURLs.append(url)
        return permitsAccess
    }

    func stopAccessing(_ url: URL) {
        stoppedURLs.append(url)
    }
}
