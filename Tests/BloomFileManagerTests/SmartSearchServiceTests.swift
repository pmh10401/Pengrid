import Foundation
import Testing
@testable import BloomFileManager

@Suite struct SmartSearchServiceTests {
    @Test func recursivelyFindsMatchingFilesInNestedDirectories() async throws {
        let fixture = try TemporaryDirectory()
        defer { fixture.remove() }
        try write("quarterly report", to: fixture.url.appending(path: "2026/Q1/report.txt"))

        let results = try await service().search(query("report", roots: [fixture.url]))

        #expect(results.map(\.relativePath) == ["2026/Q1/report.txt"])
    }

    @Test func deDuplicatesExplicitRoots() async throws {
        let first = try TemporaryDirectory()
        defer { first.remove() }
        let second = try TemporaryDirectory()
        defer { second.remove() }
        try write("first", to: first.url.appending(path: "report-first.txt"))
        try write("second", to: second.url.appending(path: "report-second.txt"))

        let results = try await service().search(query("report", roots: [
            first.url,
            first.url.appending(path: ".", directoryHint: .isDirectory),
            second.url
        ]))

        #expect(Set(results.map(\.item.name)) == ["report-first.txt", "report-second.txt"])
        #expect(results.count == 2)
    }

    @Test func ranksFilenameMatchesBeforePathMatchesAndEnforcesResultCap() async throws {
        let fixture = try TemporaryDirectory()
        defer { fixture.remove() }
        try write("a", to: fixture.url.appending(path: "reports/archive.txt"))
        try write("b", to: fixture.url.appending(path: "meeting-report.txt"))
        try write("c", to: fixture.url.appending(path: "report.txt"))

        let results = try await service().search(query(
            "report", roots: [fixture.url], includeDirectories: false, maximumResults: 2
        ))

        #expect(results.map(\.item.name) == ["report.txt", "meeting-report.txt"])
    }

    @Test func excludesHiddenPackageAndSymlinkDescendantsByDefaultButIncludesThemWhenEnabled() async throws {
        let fixture = try TemporaryDirectory()
        defer { fixture.remove() }
        let symlinkTarget = try TemporaryDirectory()
        defer { symlinkTarget.remove() }
        try write("hidden", to: fixture.url.appending(path: ".private/report-hidden.txt"))
        try write("package", to: fixture.url.appending(path: "Reports.app/report-package.txt"))
        try write("linked", to: symlinkTarget.url.appending(path: "report-linked.txt"))
        try FileManager.default.createSymbolicLink(at: fixture.url.appending(path: "linked", directoryHint: .isDirectory), withDestinationURL: symlinkTarget.url)
        try write("regular", to: fixture.url.appending(path: "report-regular.txt"))

        let defaults = try await service().search(query("report", roots: [fixture.url]))
        let optedIn = try await service().search(query("report", roots: [fixture.url], includeHidden: true, includePackages: true))

        #expect(defaults.map(\.item.name) == ["report-regular.txt"])
        #expect(Set(optedIn.map(\.item.name)) == ["report-hidden.txt", "report-package.txt", "report-regular.txt"])
    }

    @Test func includesDirectoryResultsOnlyWhenRequested() async throws {
        let fixture = try TemporaryDirectory()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.url.appending(path: "report-folder"), withIntermediateDirectories: true)

        let included = try await service().search(query("report", roots: [fixture.url]))
        let excluded = try await service().search(query("report", roots: [fixture.url], includeDirectories: false))

        #expect(included.map(\.item.name) == ["report-folder"])
        #expect(excluded.isEmpty)
    }

    @Test func copiesCloudAvailabilityWithoutMaterializingItem() async throws {
        let fixture = try TemporaryDirectory()
        defer { fixture.remove() }
        let report = fixture.url.appending(path: "report.txt")
        try write("report", to: report)
        let reader = StubAvailabilityReader(values: [report.standardizedFileURL: .onlineOnly])

        let results = try await service(availabilityReader: reader).search(query("report", roots: [fixture.url]))

        #expect(results.first?.item.availability == .onlineOnly)
    }

    @Test func rejectsMissingFilesAndNonDirectoryRootsWithStableError() async throws {
        let fixture = try TemporaryDirectory()
        defer { fixture.remove() }
        let file = fixture.url.appending(path: "report.txt")
        try write("report", to: file)

        await #expect(throws: SmartSearchServiceError.invalidRoot) {
            try await service().search(query("report", roots: [fixture.url.appending(path: "missing")]))
        }
        await #expect(throws: SmartSearchServiceError.invalidRoot) {
            try await service().search(query("report", roots: [file]))
        }
    }

    @Test func skipsUnreadableTraversalEntriesWhileKeepingOtherMatches() async throws {
        let fixture = try TemporaryDirectory()
        defer { fixture.remove() }
        try write("report", to: fixture.url.appending(path: "report-visible.txt"))
        try write("report", to: fixture.url.appending(path: "report-unreadable.txt"))
        let unreadable = fixture.url.appending(path: "report-unreadable.txt").standardizedFileURL

        let results = try await service(traversalHook: { url in
            if url.standardizedFileURL == unreadable { throw CocoaError(.fileReadNoPermission) }
        }).search(query("report", roots: [fixture.url]))

        #expect(results.map(\.item.name) == ["report-visible.txt"])
    }

    @Test func cancellationStopsLargeTraversalPromptly() async throws {
        let fixture = try TemporaryDirectory()
        defer { fixture.remove() }
        for index in 0..<1_000 {
            try write("report", to: fixture.url.appending(path: "report-\(index).txt"))
        }
        let search = service(traversalHook: { _ in usleep(1_000) })
        let task = Task { try await search.search(query("report", roots: [fixture.url])) }
        try await Task.sleep(for: .milliseconds(15))
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

private func service(
    availabilityReader: any CloudItemAvailabilityReading = StubAvailabilityReader(),
    traversalHook: @escaping LocalSmartSearchService.TraversalHook = { _ in }
) -> LocalSmartSearchService {
    LocalSmartSearchService(
        fileManager: .default,
        availabilityReader: availabilityReader,
        traversalHook: traversalHook
    )
}

private func query(
    _ text: String,
    roots: [URL],
    includeHidden: Bool = false,
    includePackages: Bool = false,
    includeDirectories: Bool = true,
    maximumResults: Int = SmartSearchQuery.defaultMaximumResults
) throws -> SmartSearchQuery {
    try SmartSearchQuery(text: text, roots: roots, includeHidden: includeHidden, includePackages: includePackages, includeDirectories: includeDirectories, maximumResults: maximumResults)
}

private func write(_ contents: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(contents.utf8).write(to: url)
}

private actor StubAvailabilityReader: CloudItemAvailabilityReading {
    private let values: [URL: CloudItemAvailability]

    init(values: [URL: CloudItemAvailability] = [:]) {
        self.values = values
    }

    func availability(of url: URL) -> CloudItemAvailability {
        values[url.standardizedFileURL] ?? .availableLocally
    }
}
