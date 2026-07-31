import Foundation
import Testing
@testable import BloomFileManager

@MainActor
struct WorkspacePersistenceTests {
    @Test func restoreUsesOnlyTheInjectedCheapDirectoryProbe() {
        let fixture = DefaultsFixture()
        defer { fixture.remove() }
        let persistence = WorkspacePersistence(defaults: fixture.defaults)
        persistence.save(WorkspaceSnapshot(
            leftPath: "/saved/left",
            rightPath: "/saved/right",
            leftSort: FileSort(),
            rightSort: FileSort(),
            splitRatio: 0.5
        ))
        var probed: [String] = []

        let restored = persistence.restore(
            home: URL(filePath: "/home", directoryHint: .isDirectory),
            downloads: URL(filePath: "/downloads", directoryHint: .isDirectory),
            isDirectory: { url in
                probed.append(url.path)
                return true
            }
        )

        #expect(probed == ["/saved/left", "/saved/right"])
        #expect(restored.leftURL.path == "/saved/left")
        #expect(restored.rightURL.path == "/saved/right")
    }

    @Test func restorationFallsBackOnlyForInvalidPane() {
        let fixture = DefaultsFixture()
        defer { fixture.remove() }
        let persistence = WorkspacePersistence(defaults: fixture.defaults)
        let home = URL(filePath: "/valid/home", directoryHint: .isDirectory)
        let downloads = URL(filePath: "/valid/downloads", directoryHint: .isDirectory)
        persistence.save(WorkspaceSnapshot(
            leftPath: "/missing",
            rightPath: downloads.path,
            leftSort: FileSort(key: .size, direction: .descending),
            rightSort: FileSort(key: .modifiedAt, direction: .descending),
            splitRatio: 0.42
        ))

        let restored = persistence.restore(
            home: home,
            downloads: downloads,
            isDirectory: { $0.path != "/missing" }
        )

        #expect(restored.leftURL == home)
        #expect(restored.rightURL == downloads)
        #expect(restored.leftSort == FileSort(key: .size, direction: .descending))
        #expect(restored.rightSort == FileSort(key: .modifiedAt, direction: .descending))
        #expect(restored.splitRatio == 0.42)

        persistence.save(WorkspaceSnapshot(
            leftPath: home.path,
            rightPath: "/missing",
            leftSort: FileSort(key: .kind, direction: .ascending),
            rightSort: FileSort(key: .size, direction: .descending),
            splitRatio: 0.58
        ))
        let oppositeRestoration = persistence.restore(
            home: home,
            downloads: downloads,
            isDirectory: { $0.path != "/missing" }
        )

        #expect(oppositeRestoration.leftURL == home)
        #expect(oppositeRestoration.rightURL == downloads)
        #expect(oppositeRestoration.leftSort == FileSort(key: .kind, direction: .ascending))
        #expect(oppositeRestoration.rightSort == FileSort(key: .size, direction: .descending))
        #expect(oppositeRestoration.splitRatio == 0.58)
    }

    @Test func malformedAndPartialJSONRestoreCompleteDefaults() {
        let fixture = DefaultsFixture()
        defer { fixture.remove() }
        let persistence = WorkspacePersistence(defaults: fixture.defaults)
        let home = URL(filePath: "/fallback/home", directoryHint: .isDirectory)
        let downloads = URL(filePath: "/fallback/downloads", directoryHint: .isDirectory)

        for data in [
            Data("not-json".utf8),
            Data(#"{"leftPath":"/saved/left","rightPath":"/saved/right","splitRatio":0.6}"#.utf8)
        ] {
            fixture.defaults.set(data, forKey: WorkspacePersistence.storageKey)

            let restored = persistence.restore(
                home: home,
                downloads: downloads,
                isDirectory: { _ in true }
            )

            #expect(restored == RestoredWorkspace(
                leftURL: home,
                rightURL: downloads,
                leftSort: FileSort(),
                rightSort: FileSort(),
                splitRatio: 0.5
            ))
        }
    }

    @Test func fileSortCodableRoundTripsEveryCase() throws {
        for key in FileSortKey.allCases {
            for direction in [SortDirection.ascending, .descending] {
                let sort = FileSort(key: key, direction: direction)
                let data = try JSONEncoder().encode(sort)
                #expect(try JSONDecoder().decode(FileSort.self, from: data) == sort)
            }
        }
    }

    @Test func restoredRatioIsFiniteAndClamped() {
        let fixture = DefaultsFixture()
        defer { fixture.remove() }
        let persistence = WorkspacePersistence(defaults: fixture.defaults)
        let home = URL(filePath: "/home", directoryHint: .isDirectory)
        let downloads = URL(filePath: "/downloads", directoryHint: .isDirectory)
        let cases: [(Double, Double)] = [
            (0.1, 0.25),
            (0.9, 0.75),
            (.nan, 0.5),
            (.infinity, 0.75),
            (-.infinity, 0.25)
        ]

        for (stored, expected) in cases {
            persistence.save(WorkspaceSnapshot(
                leftPath: home.path,
                rightPath: downloads.path,
                leftSort: FileSort(),
                rightSort: FileSort(),
                splitRatio: stored
            ))

            let restored = persistence.restore(
                home: home,
                downloads: downloads,
                isDirectory: { _ in true }
            )

            #expect(restored.splitRatio == expected)
            #expect(restored.splitRatio.isFinite)
        }
    }

    @Test func successfulNavigationPersistsButFailedAndCancelledNavigationDoNot() async {
        let fixture = DefaultsFixture()
        defer { fixture.remove() }
        let persistence = WorkspacePersistence(defaults: fixture.defaults)
        let home = URL(filePath: "/home", directoryHint: .isDirectory)
        let downloads = URL(filePath: "/downloads", directoryHint: .isDirectory)
        let documents = URL(filePath: "/home/Documents", directoryHint: .isDirectory)
        let blocked = URL(filePath: "/blocked", directoryHint: .isDirectory)
        let slow = URL(filePath: "/slow", directoryHint: .isDirectory)
        let service = PersistenceListingService(failing: [blocked], delayed: [slow])
        let workspace = WorkspaceState(
            leftURL: home,
            rightURL: downloads,
            listingService: service,
            persistence: persistence
        )

        await workspace.left.navigate(to: documents)
        #expect(persistence.load()?.leftPath == documents.path)

        await workspace.left.navigate(to: blocked)
        #expect(workspace.left.currentDirectory == documents)
        #expect(persistence.load()?.leftPath == documents.path)

        let cancelled = Task { await workspace.left.navigate(to: slow) }
        await waitUntil { workspace.left.isLoading }
        cancelled.cancel()
        await cancelled.value

        #expect(workspace.left.currentDirectory == documents)
        #expect(persistence.load()?.leftPath == documents.path)
    }

    @Test func sortChangeDuringLoadingPersistsSortAgainstLastCommittedDirectory() async {
        let fixture = DefaultsFixture()
        defer { fixture.remove() }
        let persistence = WorkspacePersistence(defaults: fixture.defaults)
        let home = URL(filePath: "/home", directoryHint: .isDirectory)
        let downloads = URL(filePath: "/downloads", directoryHint: .isDirectory)
        let inaccessible = URL(filePath: "/not-yet-committed", directoryHint: .isDirectory)
        let workspace = WorkspaceState(
            leftURL: home,
            rightURL: downloads,
            listingService: PersistenceListingService(delayed: [inaccessible]),
            persistence: persistence
        )

        let navigation = Task { await workspace.left.navigate(to: inaccessible) }
        await waitUntil { workspace.left.isLoading }
        workspace.left.sort = FileSort(key: .size, direction: .descending)

        #expect(persistence.load()?.leftPath == home.path)
        #expect(persistence.load()?.leftSort == FileSort(key: .size, direction: .descending))

        navigation.cancel()
        await navigation.value
        #expect(persistence.load()?.leftPath == home.path)
    }

    @Test func paneSortsPersistIndependently() {
        let fixture = DefaultsFixture()
        defer { fixture.remove() }
        let persistence = WorkspacePersistence(defaults: fixture.defaults)
        let workspace = WorkspaceState(
            leftURL: URL(filePath: "/left", directoryHint: .isDirectory),
            rightURL: URL(filePath: "/right", directoryHint: .isDirectory),
            listingService: StubDirectoryListingService(values: [:]),
            persistence: persistence
        )

        workspace.left.sort = FileSort(key: .kind, direction: .descending)
        workspace.right.sort = FileSort(key: .modifiedAt, direction: .ascending)

        #expect(persistence.load()?.leftSort == FileSort(key: .kind, direction: .descending))
        #expect(persistence.load()?.rightSort == FileSort(key: .modifiedAt, direction: .ascending))
    }

    @Test func dividerPersistenceDebouncesAndKeepsLatestValue() async {
        let fixture = DefaultsFixture()
        defer { fixture.remove() }
        let persistence = WorkspacePersistence(defaults: fixture.defaults)
        let workspace = WorkspaceState(
            leftURL: URL(filePath: "/left", directoryHint: .isDirectory),
            rightURL: URL(filePath: "/right", directoryHint: .isDirectory),
            listingService: StubDirectoryListingService(values: [:]),
            persistence: persistence
        )

        workspace.splitRatio = 0.31
        workspace.splitRatio = 0.68

        #expect(persistence.load() == nil)

        await waitUntil {
            persistence.load()?.splitRatio == 0.68
        }
        #expect(persistence.load()?.splitRatio == 0.68)
    }

    @Test func flushingDividerPersistenceSavesImmediatelyAndCancelledDebounceCannotOverwriteIt() async {
        let fixture = DefaultsFixture()
        defer { fixture.remove() }
        let persistence = WorkspacePersistence(defaults: fixture.defaults)
        let workspace = WorkspaceState(
            leftURL: URL(filePath: "/left", directoryHint: .isDirectory),
            rightURL: URL(filePath: "/right", directoryHint: .isDirectory),
            listingService: StubDirectoryListingService(values: [:]),
            persistence: persistence
        )

        workspace.splitRatio = 0.63
        workspace.flushPendingPersistence()

        #expect(persistence.load()?.splitRatio == 0.63)
        try? await Task.sleep(for: .milliseconds(350))
        #expect(persistence.load()?.splitRatio == 0.63)
    }

    @Test func restoredValuesInitializeAReplacementWorkspaceLikeRelaunch() {
        let fixture = DefaultsFixture()
        defer { fixture.remove() }
        let persistence = WorkspacePersistence(defaults: fixture.defaults)
        let leftSort = FileSort(key: .size, direction: .descending)
        let rightSort = FileSort(key: .kind, direction: .ascending)
        persistence.save(WorkspaceSnapshot(
            leftPath: "/restored/left",
            rightPath: "/restored/right",
            leftSort: leftSort,
            rightSort: rightSort,
            splitRatio: 0.64
        ))
        let restored = persistence.restore(
            home: URL(filePath: "/home", directoryHint: .isDirectory),
            downloads: URL(filePath: "/downloads", directoryHint: .isDirectory),
            isDirectory: { _ in true }
        )

        let relaunched = WorkspaceState(
            restored: restored,
            listingService: StubDirectoryListingService(values: [:]),
            persistence: persistence
        )

        #expect(relaunched.left.currentDirectory.path == "/restored/left")
        #expect(relaunched.right.currentDirectory.path == "/restored/right")
        #expect(relaunched.left.sort == leftSort)
        #expect(relaunched.right.sort == rightSort)
        #expect(relaunched.splitRatio == 0.64)
    }
}

private final class DefaultsFixture {
    let name = "BloomFileManagerTests.\(UUID().uuidString)"
    let defaults: UserDefaults

    init() {
        defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
    }

    func remove() {
        defaults.removePersistentDomain(forName: name)
    }
}

private struct PersistenceListingService: DirectoryListingService {
    var failing: Set<URL> = []
    var delayed: Set<URL> = []

    func batches(in directory: URL) -> AsyncThrowingStream<[FileItem], Error> {
        AsyncThrowingStream { continuation in
            if failing.contains(directory) {
                continuation.finish(throwing: TestListingError.unavailable)
                return
            }
            if delayed.contains(directory) {
                let producer = Task {
                    do {
                        try await Task.sleep(for: .seconds(30))
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: CancellationError())
                    }
                }
                continuation.onTermination = { _ in producer.cancel() }
                return
            }
            continuation.finish()
        }
    }

    private enum TestListingError: Error {
        case unavailable
    }
}

@MainActor
private func waitUntil(
    timeout: Duration = .seconds(1),
    condition: @escaping @MainActor () -> Bool
) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition(), clock.now < deadline {
        await Task.yield()
    }
}
