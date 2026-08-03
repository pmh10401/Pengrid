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

    @Test func overlappingParentAndDescendantRootsDoNotDuplicateAResultURL() async throws {
        let fixture = try TemporaryDirectory()
        defer { fixture.remove() }
        let descendant = fixture.url.appending(path: "nested", directoryHint: .isDirectory)
        try write("report", to: descendant.appending(path: "report.txt"))

        let results = try await service().search(query(
            "report",
            roots: [descendant, fixture.url],
            includeDirectories: false
        ))

        #expect(results.map(\.item.url) == [descendant.appending(path: "report.txt").standardizedFileURL])
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

    @Test func searchesKoreanInitialsWithBothJamoRepresentations() async throws {
        let fixture = try TemporaryDirectory()
        defer { fixture.remove() }
        try write("report", to: fixture.url.appending(path: "한국 보고서.pdf"))
        try write("notes", to: fixture.url.appending(path: "한글 노트.txt"))

        let compatibility = try await service().search(query(
            "ㅎㄱ",
            roots: [fixture.url],
            includeDirectories: false
        ))
        let choseong = try await service().search(query(
            "ᄒᄀ",
            roots: [fixture.url],
            includeDirectories: false
        ))

        #expect(compatibility.map(\.item.name) == choseong.map(\.item.name))
        #expect(Set(compatibility.map(\.item.name)) == ["한국 보고서.pdf", "한글 노트.txt"])
    }

    @Test func mixedInitialAndLiteralQueryUsesAndSemantics() async throws {
        let fixture = try TemporaryDirectory()
        defer { fixture.remove() }
        for name in ["한국 report.pdf", "한국 notes.pdf", "영문 report.pdf"] {
            try write(name, to: fixture.url.appending(path: name))
        }

        let results = try await service().search(query(
            "ㅎㄱ report",
            roots: [fixture.url],
            includeDirectories: false
        ))

        #expect(results.map(\.item.name) == ["한국 report.pdf"])
    }

    @Test func runHeadSearchRejectsAnUnrelatedIntermediateInitial() async throws {
        let fixture = try TemporaryDirectory()
        defer { fixture.remove() }
        try write("plan", to: fixture.url.appending(path: "구글 드라이브/계획.txt"))
        try write("memo", to: fixture.url.appending(path: "개인 사진 다운로드/메모.txt"))

        let results = try await service().search(query(
            "ㄱㄷ",
            roots: [fixture.url],
            includeDirectories: false
        ))

        #expect(results.contains { $0.relativePath == "구글 드라이브/계획.txt" })
        #expect(results.contains { $0.relativePath == "개인 사진 다운로드/메모.txt" } == false)
    }

    @Test func legacyComplexQueryIsRejectedBeforeFilesystemTraversal() async throws {
        let fixture = try TemporaryDirectory()
        defer { fixture.remove() }
        try write("report", to: fixture.url.appending(path: "report.txt"))
        let legacyText = Array(
            repeating: "ㄱ",
            count: SmartSearchQuery.maximumClauseCount + 1
        ).joined(separator: " ")
        let legacyQuery = try JSONDecoder().decode(
            SmartSearchQuery.self,
            from: JSONEncoder().encode(LegacyServiceQueryPayload(
                text: legacyText,
                roots: [fixture.url],
                includeHidden: false,
                includePackages: false,
                includeDirectories: true,
                maximumResults: 500
            ))
        )
        let traversalCount = LockedCounter()

        await #expect(throws: SmartSearchValidationError.queryTooComplex) {
            try await service(traversalHook: { _ in
                traversalCount.increment()
            }).search(legacyQuery)
        }
        #expect(traversalCount.value == 0)
    }

    @Test func matchingCandidateCollectionStopsAtTheDocumentedHardBudget() async throws {
        let fixture = try TemporaryDirectory()
        defer { fixture.remove() }
        for index in 0...2_000 {
            try write("report", to: fixture.url.appending(path: "report-\(index).txt"))
        }
        let traversalCount = LockedCounter()

        let results = try await service(traversalHook: { _ in
            traversalCount.increment()
        }).search(query(
            "report",
            roots: [fixture.url],
            includeDirectories: false,
            maximumResults: 1
        ))

        #expect(results.count == 1)
        #expect(traversalCount.value == 2_000)
    }

    @Test func excludesHiddenPackageAndSymlinkDescendantsByDefaultButIncludesThemWhenEnabled() async throws {
        let fixture = try TemporaryDirectory()
        defer { fixture.remove() }
        let symlinkTarget = try TemporaryDirectory()
        defer { symlinkTarget.remove() }
        try write("hidden", to: fixture.url.appending(path: ".private/report-hidden.txt"))
        try write("package", to: fixture.url.appending(path: "Reports.app/report-package.txt"))
        let linkedFile = symlinkTarget.url.appending(path: "report-linked.txt")
        try write("linked", to: linkedFile)
        try FileManager.default.createSymbolicLink(
            at: fixture.url.appending(path: "linked", directoryHint: .isDirectory),
            withDestinationURL: symlinkTarget.url
        )
        try FileManager.default.createSymbolicLink(
            at: fixture.url.appending(path: "report-zz-linked.txt"),
            withDestinationURL: linkedFile
        )
        try write("regular", to: fixture.url.appending(path: "report-regular.txt"))

        let defaults = try await service().search(query("report", roots: [fixture.url]))
        let optedIn = try await service().search(query("report", roots: [fixture.url], includeHidden: true, includePackages: true))

        #expect(defaults.map(\.item.name) == ["report-regular.txt"])
        #expect(Set(optedIn.map(\.item.name)) == ["report-hidden.txt", "report-package.txt", "report-regular.txt"])
    }

    @Test func reportsExaminedEntryProgressDuringTraversal() async throws {
        let fixture = try TemporaryDirectory()
        defer { fixture.remove() }
        try write("report", to: fixture.url.appending(path: "nested/report.txt"))
        let progress = LockedValues<Int>()

        let results = try await service().search(
            query("report", roots: [fixture.url], includeDirectories: false),
            progress: { progress.append($0) }
        )

        #expect(results.map(\.item.name) == ["report.txt"])
        #expect(progress.values == [1, 2])
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

    @Test func metadataFailureFallsBackWithoutReadingAvailabilityForNonmatches() async throws {
        let fixture = try TemporaryDirectory()
        defer { fixture.remove() }
        let matchingFile = fixture.url.appending(path: "한국.txt")
        let matchingFolder = fixture.url.appending(path: "한글 폴더")
        let nonmatch = fixture.url.appending(path: "notes.txt")
        try write("match", to: matchingFile)
        try FileManager.default.createDirectory(
            at: matchingFolder,
            withIntermediateDirectories: true
        )
        try write("nonmatch", to: nonmatch)
        let reader = RecordingAvailabilityReader()

        let results = try await service(
            availabilityReader: reader,
            typeDescriptionReader: { _ in throw MetadataProbeError.unavailable }
        ).search(query("ㅎㄱ", roots: [fixture.url]))

        let descriptions = Dictionary(uniqueKeysWithValues: results.map {
            ($0.item.name, $0.item.typeDescription)
        })
        #expect(descriptions["한국.txt"] == "File")
        #expect(descriptions["한글 폴더"] == "Folder")
        #expect(Set(await reader.requestedURLs()) == Set([
            matchingFile.standardizedFileURL,
            matchingFolder.standardizedFileURL
        ]))
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

    @Test func cancellationAfterEnumerationHasCompletedStopsRanking() async throws {
        let fixture = try TemporaryDirectory()
        defer { fixture.remove() }
        for index in 0..<250 {
            try write("report", to: fixture.url.appending(path: "report-\(index).txt"))
        }
        let rankingProbe = RankingCancellationProbe()
        let search = service(rankingHook: rankingProbe.checkCancellation)
        let task = Task {
            try await search.search(query("report", roots: [fixture.url], includeDirectories: false))
        }
        await rankingProbe.waitUntilStarted()

        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

private func service(
    availabilityReader: any CloudItemAvailabilityReading = StubAvailabilityReader(),
    traversalHook: @escaping LocalSmartSearchService.TraversalHook = { _ in },
    rankingHook: @escaping LocalSmartSearchService.RankingHook = {},
    typeDescriptionReader: @escaping @Sendable (URL) throws -> String? = {
        try $0.resourceValues(forKeys: [.localizedTypeDescriptionKey]).localizedTypeDescription
    }
) -> LocalSmartSearchService {
    LocalSmartSearchService(
        fileManager: .default,
        availabilityReader: availabilityReader,
        traversalHook: traversalHook,
        rankingHook: rankingHook,
        typeDescriptionReader: typeDescriptionReader
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

private struct LegacyServiceQueryPayload: Codable {
    let text: String
    let roots: [URL]
    let includeHidden: Bool
    let includePackages: Bool
    let includeDirectories: Bool
    let maximumResults: Int
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

private enum MetadataProbeError: Error {
    case unavailable
}

private actor RecordingAvailabilityReader: CloudItemAvailabilityReading {
    private var urls: [URL] = []

    func availability(of url: URL) -> CloudItemAvailability {
        urls.append(url.standardizedFileURL)
        return .availableLocally
    }

    func requestedURLs() -> [URL] {
        urls
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock { count += 1 }
    }
}

private final class LockedValues<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    var values: [Value] {
        lock.withLock { storage }
    }

    func append(_ value: Value) {
        lock.withLock { storage.append(value) }
    }
}

private final class RankingCancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false

    func checkCancellation() throws {
        lock.withLock { started = true }
        while !Task.isCancelled {
            usleep(100)
        }
        try Task.checkCancellation()
    }

    func waitUntilStarted() async {
        while !lock.withLock({ started }) {
            await Task.yield()
        }
    }
}
