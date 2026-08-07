import Foundation
import Testing
@testable import BloomFileManager

struct PaneItemProjectionTests {
    @Test func paneProjectionFiltersSortsAndIndexes() {
        let items = makeProjectionItems([
            ("파일관리.txt", 20),
            ("보고서.txt", 10),
            ("파일목록.txt", 30)
        ])
        let key = PaneProjectionKey(
            itemsRevision: 7,
            normalizedQuery: "파일",
            sort: FileSort(key: .size, direction: .descending)
        )

        let result = PaneItemProjector().project(items: items, key: key)

        #expect(result.items.map(\.name) == ["파일목록.txt", "파일관리.txt"])
        #expect(result.indexByURL[items[2].url] == 0)
        #expect(result.indexByURL[items[0].url] == 1)
        #expect(result.urlByEntryPath["/projection/파일목록.txt"] == items[2].url)
    }

    @Test func projectionKeyAndFilterNormalizeWhitespaceQueries() {
        let items = makeItems([
            ("여행사진.heic", false, nil, 1, "Image", "/queries/여행사진.heic"),
            ("업무보고서.pdf", false, nil, 2, "PDF", "/queries/업무보고서.pdf"),
            ("여행계획.md", false, nil, 3, "Markdown", "/queries/여행계획.md")
        ])
        let key = PaneProjectionKey(
            itemsRevision: 9,
            normalizedQuery: " \n 여행 \t",
            sort: FileSort()
        )

        #expect(PaneFilenameFilter.normalize(" \n 여행 \t") == "여행")
        #expect(key.normalizedQuery == "여행")
        #expect(PaneItemProjector().project(items: items, key: key).items.map(\.name) == [
            "여행계획.md",
            "여행사진.heic"
        ])
    }

    @Test func projectionPreservesDirectoryFirstOrderForEverySortKeyAndDirection() {
        let items = makeItems([
            ("dir-b", true, 20, 4, "Folder", "/sort/dir-b"),
            ("dir-a", true, 10, 12, "Folder", "/sort/dir-a"),
            ("file-b", false, 30, 10, "Markdown", "/sort/file-b"),
            ("file-a", false, 40, 2, "Text", "/sort/file-a")
        ])
        let projector = PaneItemProjector()

        #expect(projector.project(items: items, key: PaneProjectionKey(
            itemsRevision: 1, normalizedQuery: "", sort: FileSort(key: .name, direction: .ascending)
        )).items.map(\.name) == ["dir-a", "dir-b", "file-a", "file-b"])
        #expect(projector.project(items: items, key: PaneProjectionKey(
            itemsRevision: 1, normalizedQuery: "", sort: FileSort(key: .name, direction: .descending)
        )).items.map(\.name) == ["dir-b", "dir-a", "file-b", "file-a"])

        #expect(projector.project(items: items, key: PaneProjectionKey(
            itemsRevision: 1, normalizedQuery: "", sort: FileSort(key: .modifiedAt, direction: .ascending)
        )).items.map(\.name) == ["dir-a", "dir-b", "file-b", "file-a"])
        #expect(projector.project(items: items, key: PaneProjectionKey(
            itemsRevision: 1, normalizedQuery: "", sort: FileSort(key: .modifiedAt, direction: .descending)
        )).items.map(\.name) == ["dir-b", "dir-a", "file-a", "file-b"])

        #expect(projector.project(items: items, key: PaneProjectionKey(
            itemsRevision: 1, normalizedQuery: "", sort: FileSort(key: .kind, direction: .ascending)
        )).items.map(\.name) == ["dir-a", "dir-b", "file-b", "file-a"])
        #expect(projector.project(items: items, key: PaneProjectionKey(
            itemsRevision: 1, normalizedQuery: "", sort: FileSort(key: .kind, direction: .descending)
        )).items.map(\.name) == ["dir-a", "dir-b", "file-a", "file-b"])

        #expect(projector.project(items: items, key: PaneProjectionKey(
            itemsRevision: 1, normalizedQuery: "", sort: FileSort(key: .size, direction: .ascending)
        )).items.map(\.name) == ["dir-b", "dir-a", "file-a", "file-b"])
        #expect(projector.project(items: items, key: PaneProjectionKey(
            itemsRevision: 1, normalizedQuery: "", sort: FileSort(key: .size, direction: .descending)
        )).items.map(\.name) == ["dir-a", "dir-b", "file-b", "file-a"])
    }

    @Test func projectionUsesURLTieBreaksAndSupportsDiacriticsAndKoreanNames() {
        let tieItems = makeItems([
            ("same.txt", false, nil, 3, "Text", "/ties/z-item.txt"),
            ("same.txt", false, nil, 3, "Text", "/ties/a-item.txt")
        ])
        let tieResult = PaneItemProjector().project(
            items: tieItems,
            key: PaneProjectionKey(itemsRevision: 2, normalizedQuery: "", sort: FileSort())
        )
        #expect(tieResult.items.map(\.url.path) == ["/ties/a-item.txt", "/ties/z-item.txt"])

        let diacriticItems = makeItems([
            ("Résumé.PDF", false, nil, 1, "PDF", "/text/Résumé.PDF"),
            ("resume-notes.txt", false, nil, 2, "Text", "/text/resume-notes.txt"),
            ("사진.jpg", false, nil, 3, "Image", "/text/사진.jpg")
        ])
        let diacriticResult = PaneItemProjector().project(
            items: diacriticItems,
            key: PaneProjectionKey(itemsRevision: 3, normalizedQuery: "RESUME", sort: FileSort())
        )
        #expect(diacriticResult.items.map(\.name) == ["resume-notes.txt", "Résumé.PDF"])
    }

    @Test func projectionLastProjectedRowWinsDuplicateStandardizedURLAndEntryPath() {
        let duplicateStandardizedURLItems = [
            makeItem(
                name: "first.txt",
                url: URL(filePath: "/dupes/one/../entry.txt"),
                isDirectory: false,
                modifiedAt: nil,
                byteSize: 1,
                typeDescription: "Text"
            ),
            makeItem(
                name: "last.txt",
                url: URL(filePath: "/dupes/entry.txt"),
                isDirectory: false,
                modifiedAt: nil,
                byteSize: 2,
                typeDescription: "Text"
            )
        ]
        let duplicateEntryPathItems = [
            makeItem(
                name: "first-folder",
                url: URL(filePath: "/dupes/folder", directoryHint: .isDirectory),
                isDirectory: true,
                modifiedAt: nil,
                byteSize: nil,
                typeDescription: "Folder"
            ),
            makeItem(
                name: "last-folder",
                url: URL(filePath: "/dupes/folder"),
                isDirectory: true,
                modifiedAt: nil,
                byteSize: nil,
                typeDescription: "Folder"
            )
        ]

        let projector = PaneItemProjector()
        let duplicateURLResult = projector.project(
            items: duplicateStandardizedURLItems,
            key: PaneProjectionKey(itemsRevision: 4, normalizedQuery: "", sort: FileSort())
        )
        let duplicateEntryResult = projector.project(
            items: duplicateEntryPathItems,
            key: PaneProjectionKey(itemsRevision: 5, normalizedQuery: "", sort: FileSort())
        )

        let standardizedURL = URL(filePath: "/dupes/entry.txt")
        #expect(duplicateURLResult.items.map(\.name) == ["first.txt", "last.txt"])
        #expect(duplicateURLResult.indexByURL[standardizedURL] == 1)
        #expect(duplicateURLResult.urlByEntryPath["/dupes/entry.txt"] == standardizedURL)

        let directoryURL = URL(filePath: "/dupes/folder")
        #expect(duplicateEntryResult.items.map(\.name) == ["first-folder", "last-folder"])
        #expect(duplicateEntryResult.indexByURL[duplicateEntryPathItems[0].url.standardizedFileURL] == 0)
        #expect(duplicateEntryResult.indexByURL[directoryURL.standardizedFileURL] == 1)
        #expect(duplicateEntryResult.urlByEntryPath["/dupes/folder"] == directoryURL.standardizedFileURL)
    }

    @Test func activeOrderSnapshotSortsOnceAndExclusivelyPartitionsPrintableASCIIFilenames() async throws {
        let items = makeActiveOrderCorpus()
        let key = PaneProjectionKey(
            itemsRevision: 42,
            normalizedQuery: "ignored by active order",
            sort: FileSort(key: .name, direction: .ascending)
        )

        guard let snapshot = try await PaneItemProjector().buildActiveOrder(
            items: items,
            directoryKey: "/active",
            key: key
        ) else {
            Issue.record("Expected unique corpus to create an active-order snapshot")
            return
        }

        #expect(snapshot.directoryKey == "/active")
        #expect(snapshot.itemsRevision == 42)
        #expect(snapshot.sort == FileSort(key: .name, direction: .ascending))
        #expect(snapshot.orderedItems.map(\.url.standardizedFileURL) == key.sort.apply(to: items).map(\.url.standardizedFileURL))
        #expect(snapshot.asciiLiteralSafePositions == [0, 8, 11, 13])
        #expect(snapshot.localizedFallbackPositions == [1, 2, 3, 4, 5, 6, 7, 9, 10, 12])
        let coveredPositions = Set(snapshot.asciiLiteralSafePositions + snapshot.localizedFallbackPositions)
        #expect(coveredPositions == Set(0..<14))
        #expect(Set(snapshot.asciiLiteralSafePositions).isDisjoint(with: Set(snapshot.localizedFallbackPositions)))
    }

    @Test func activeOrderRejectsDuplicateStandardizedURLAndEntryPathIdentities() async throws {
        let duplicateStandardizedURL = [
            makeItem(name: "first.txt", url: URL(filePath: "/active/one/../entry.txt"), isDirectory: false, modifiedAt: nil, byteSize: 1, typeDescription: "Text"),
            makeItem(name: "last.txt", url: URL(filePath: "/active/entry.txt"), isDirectory: false, modifiedAt: nil, byteSize: 2, typeDescription: "Text")
        ]
        let duplicateEntryPath = [
            makeItem(name: "first-folder", url: URL(filePath: "/active/folder", directoryHint: .isDirectory), isDirectory: true, modifiedAt: nil, byteSize: nil, typeDescription: "Folder"),
            makeItem(name: "last-folder", url: URL(filePath: "/active/folder"), isDirectory: true, modifiedAt: nil, byteSize: nil, typeDescription: "Folder")
        ]
        let key = PaneProjectionKey(itemsRevision: 43, normalizedQuery: "", sort: FileSort())

        #expect(try await PaneItemProjector().buildActiveOrder(items: duplicateStandardizedURL, directoryKey: "/active", key: key) == nil)
        #expect(try await PaneItemProjector().buildActiveOrder(items: duplicateEntryPath, directoryKey: "/active", key: key) == nil)
    }

    @Test func activeOrderFullFilteringMatchesFilterThenSortForEverySortAndQueryCorpus() async throws {
        let items = makeActiveOrderCorpus()
        let queries = [
            "", "  report  ", "RESUME", "Re\u{301}sume\u{301}", "보고", "보고", "ß", "ss", "s",
            "ﬀ", "⑫", "12", "Ｆｕｌｌ", "🎉", "  mixed ", "한글 résumé"
        ]

        for sortKey in FileSortKey.allCases {
            for direction in [SortDirection.ascending, .descending] {
                let sort = FileSort(key: sortKey, direction: direction)
                let key = PaneProjectionKey(itemsRevision: 44, normalizedQuery: "", sort: sort)
                guard let snapshot = try await PaneItemProjector().buildActiveOrder(
                    items: items,
                    directoryKey: "/active",
                    key: key
                ) else {
                    Issue.record("Expected unique corpus to create an active-order snapshot")
                    return
                }

                for query in queries {
                    let projected = PaneFilenameFilter(query: query).apply(to: snapshot.orderedItems)
                    let oracle = sort.apply(to: PaneFilenameFilter(query: query).apply(to: items))
                    #expect(projected.map { $0.url.standardizedFileURL } == oracle.map { $0.url.standardizedFileURL })
                }
            }
        }
    }

    @Test func acceptedSearchSnapshotCarriesTheNormalizedQueryAndPartitionMatches() {
        let snapshot = AcceptedSearchSnapshot(
            directoryKey: "/active",
            itemsRevision: 45,
            sort: FileSort(key: .size, direction: .descending),
            normalizedQuery: PaneFilenameFilter.normalize("  report  "),
            matchedASCIIPositions: [1],
            matchedLocalizedPositions: [5, 8]
        )

        #expect(snapshot.normalizedQuery == "report")
        #expect(snapshot.matchedASCIIPositions == [1])
        #expect(snapshot.matchedLocalizedPositions == [5, 8])
    }

    @Test func activeOrderNarrowingRechecksEveryLocalizedFallbackPosition() async throws {
        let items = makeActiveOrderCorpus()
        let projector = PaneItemProjector()
        let sort = FileSort(key: .name, direction: .ascending)
        let activeKey = PaneProjectionKey(itemsRevision: 46, normalizedQuery: "", sort: sort)
        let activeOrder = try #require(await projector.buildActiveOrder(
            items: items,
            directoryKey: "/active",
            key: activeKey
        ))
        let previousKey = PaneProjectionKey(itemsRevision: 46, normalizedQuery: "rep", sort: sort)
        let previous = try await projector.projectActiveOrder(.init(
            items: items,
            directoryKey: "/active",
            key: previousKey,
            activeOrder: activeOrder,
            previousSearch: nil
        ))
        let nextKey = PaneProjectionKey(itemsRevision: 46, normalizedQuery: "repo", sort: sort)

        let result = try await projector.projectActiveOrder(.init(
            items: items,
            directoryKey: "/active",
            key: nextKey,
            activeOrder: activeOrder,
            previousSearch: previous.search
        ))
        let oracle = sort.apply(to: PaneFilenameFilter(query: "repo").apply(to: items))

        #expect(result.diagnostics.path == .activeOrderNarrowedASCII)
        #expect(result.diagnostics.visitedASCIIPositions == previous.search?.matchedASCIIPositions.count)
        #expect(result.diagnostics.visitedLocalizedPositions == activeOrder.localizedFallbackPositions.count)
        #expect(result.items.map(\.url.standardizedFileURL) == oracle.map(\.url.standardizedFileURL))
        #expect(result.items == oracle)
    }

    @Test func activeOrderRoutesEveryDisallowedTransitionThroughAFullScan() async throws {
        let items = makeActiveOrderCorpus()
        let projector = PaneItemProjector()
        let sort = FileSort(key: .name, direction: .ascending)
        let key = PaneProjectionKey(itemsRevision: 47, normalizedQuery: "", sort: sort)
        let activeOrder = try #require(await projector.buildActiveOrder(
            items: items,
            directoryKey: "/active",
            key: key
        ))
        let cases: [(String, String, String, UInt64, FileSort)] = [
            ("report", "repo", "/active", 47, sort), // replacement
            ("report", "rep", "/active", 47, sort), // backspace
            ("rep", "", "/active", 47, sort), // empty query
            ("r", "repo", "/active", 47, sort), // multi-scalar paste
            ("rep", "rep!", "/active", 47, sort), // punctuation
            ("rep", "보고", "/active", 47, sort), // Korean IME text
            ("rep", "repo", "/other", 47, sort), // directory mismatch
            ("rep", "repo", "/active", 48, sort), // revision mismatch
            ("rep", "repo", "/active", 47, FileSort(key: .size, direction: .descending)) // sort mismatch
        ]

        for (oldQuery, newQuery, previousDirectory, previousRevision, previousSort) in cases {
            let previous = try await projector.projectActiveOrder(.init(
                items: items,
                directoryKey: "/active",
                key: PaneProjectionKey(itemsRevision: 47, normalizedQuery: oldQuery, sort: sort),
                activeOrder: activeOrder,
                previousSearch: nil
            ))
            let prior = try #require(previous.search)
            let mismatchedPrevious = AcceptedSearchSnapshot(
                directoryKey: previousDirectory,
                itemsRevision: previousRevision,
                sort: previousSort,
                normalizedQuery: prior.normalizedQuery,
                matchedASCIIPositions: prior.matchedASCIIPositions,
                matchedLocalizedPositions: prior.matchedLocalizedPositions
            )
            let nextKey = PaneProjectionKey(itemsRevision: 47, normalizedQuery: newQuery, sort: sort)
            let result = try await projector.projectActiveOrder(.init(
                items: items,
                directoryKey: "/active",
                key: nextKey,
                activeOrder: activeOrder,
                previousSearch: mismatchedPrevious
            ))
            let oracle = sort.apply(to: PaneFilenameFilter(query: newQuery).apply(to: items))

            #expect(result.diagnostics.path == .activeOrderFullScan)
            #expect(result.diagnostics.visitedASCIIPositions == activeOrder.asciiLiteralSafePositions.count)
            #expect(result.diagnostics.visitedLocalizedPositions == activeOrder.localizedFallbackPositions.count)
            #expect(result.items.map(\.url.standardizedFileURL) == oracle.map(\.url.standardizedFileURL))
            #expect(result.items == oracle)
        }
    }

    @Test func activeOrderEmptyQueryAndMissingOrderUseTheirExplicitPaths() async throws {
        let items = makeActiveOrderCorpus()
        let projector = PaneItemProjector()
        let key = PaneProjectionKey(itemsRevision: 48, normalizedQuery: "", sort: FileSort())
        let activeOrder = try #require(await projector.buildActiveOrder(
            items: items,
            directoryKey: "/active",
            key: key
        ))

        let empty = try await projector.projectActiveOrder(.init(
            items: items,
            directoryKey: "/active",
            key: key,
            activeOrder: activeOrder,
            previousSearch: nil
        ))
        let fallback = try await projector.projectActiveOrder(.init(
            items: items,
            directoryKey: "/active",
            key: key,
            activeOrder: nil,
            previousSearch: nil
        ))

        #expect(empty.diagnostics.path == .activeOrderFullScan)
        #expect(empty.items == activeOrder.orderedItems)
        #expect(empty.search?.normalizedQuery == "")
        #expect(fallback.diagnostics.path == .fallbackFilterThenSort)
        #expect(fallback.items == key.sort.apply(to: items))
    }

    @Test func emptyActiveOrderUsesTheDedicatedPath() async throws {
        let projector = PaneItemProjector()
        let key = PaneProjectionKey(itemsRevision: 49, normalizedQuery: "anything", sort: FileSort())
        let activeOrder = try #require(await projector.buildActiveOrder(
            items: [],
            directoryKey: "/empty",
            key: key
        ))

        let result = try await projector.projectActiveOrder(.init(
            items: [],
            directoryKey: "/empty",
            key: key,
            activeOrder: activeOrder,
            previousSearch: nil
        ))

        #expect(result.diagnostics == .init(
            path: .emptyActiveOrder,
            visitedASCIIPositions: 0,
            visitedLocalizedPositions: 0
        ))
        #expect(result.items.isEmpty)
    }

    @Test func sortedSubsetRejectsDuplicateTieBreakIdentitiesAndKeepsFallbackIndexesLastWins() async throws {
        let items = [
            makeItem(name: "first.txt", url: URL(filePath: "/subset/one/../entry.txt"), isDirectory: false, modifiedAt: nil, byteSize: 1, typeDescription: "Text"),
            makeItem(name: "last.txt", url: URL(filePath: "/subset/entry.txt"), isDirectory: false, modifiedAt: nil, byteSize: 2, typeDescription: "Text")
        ]
        let key = PaneProjectionKey(itemsRevision: 50, normalizedQuery: "txt", sort: FileSort())

        let result = try await PaneItemProjector().projectSortedSubset(items: items, key: key)

        #expect(result.diagnostics.path == .fallbackFilterThenSort)
        #expect(result.items == key.sort.apply(to: PaneFilenameFilter(query: "txt").apply(to: items)))
        #expect(result.indexByURL[URL(filePath: "/subset/entry.txt")] == 1)
        #expect(result.urlByEntryPath["/subset/entry.txt"] == URL(filePath: "/subset/entry.txt"))
    }

    @Test func randomizedActiveOrderProjectionMatchesTheFullOracleForOneThousandFilenameQueryCombinations() async throws {
        var generator = ProjectionTestGenerator(seed: 0xA11CE5EED)
        let projector = PaneItemProjector()

        for caseNumber in 0..<1_000 {
            let sort = FileSort(
                key: FileSortKey.allCases[generator.nextInt(upperBound: FileSortKey.allCases.count)],
                direction: generator.nextBool() ? .ascending : .descending
            )
            let oldQuery = generator.asciiQuery(length: 1 + generator.nextInt(upperBound: 5))
            let newQuery = oldQuery + generator.asciiQuery(length: 1)
            let items = generator.items(caseNumber: caseNumber, count: 1 + generator.nextInt(upperBound: 10))
            let key = PaneProjectionKey(itemsRevision: UInt64(caseNumber), normalizedQuery: "", sort: sort)
            let activeOrder = try #require(await projector.buildActiveOrder(
                items: items,
                directoryKey: "/random/\(caseNumber)",
                key: key
            ))
            let previous = try await projector.projectActiveOrder(.init(
                items: items,
                directoryKey: "/random/\(caseNumber)",
                key: PaneProjectionKey(itemsRevision: UInt64(caseNumber), normalizedQuery: oldQuery, sort: sort),
                activeOrder: activeOrder,
                previousSearch: nil
            ))
            let result = try await projector.projectActiveOrder(.init(
                items: items,
                directoryKey: "/random/\(caseNumber)",
                key: PaneProjectionKey(itemsRevision: UInt64(caseNumber), normalizedQuery: newQuery, sort: sort),
                activeOrder: activeOrder,
                previousSearch: previous.search
            ))
            let oracle = sort.apply(to: PaneFilenameFilter(query: newQuery).apply(to: items))

            #expect(result.items.map(\.url.standardizedFileURL) == oracle.map(\.url.standardizedFileURL), "case \(caseNumber)")
            #expect(result.items == oracle, "case \(caseNumber)")
        }
    }
}

private func makeActiveOrderCorpus() -> [FileItem] {
    makeItems([
        (" !~", false, 1, 1, "Text", "/active/00-ascii-punctuation"),
        ("report-1999.txt", false, 2, 2, "Text", "/active/01-ascii-report"),
        ("space report.txt", false, 3, 3, "Text", "/active/02-ascii-space"),
        ("Zebra_42.md", false, 4, 4, "Markdown", "/active/03-ascii-zebra"),
        ("Résumé.pdf", false, 5, 5, "PDF", "/active/04-accent"),
        ("Re\u{301}sume\u{301}.txt", false, 6, 6, "Text", "/active/05-decomposed-accent"),
        ("보고서.txt", false, 7, 7, "Text", "/active/06-hangul"),
        ("보고상.md", false, 8, 8, "Markdown", "/active/07-jamo"),
        ("ß.txt", false, 9, 9, "Text", "/active/08-sharp-s"),
        ("ﬀile.txt", false, 10, 10, "Text", "/active/09-ligature"),
        ("⑫-notes.txt", false, 11, 11, "Text", "/active/10-circled"),
        ("Ｆｕｌｌ.txt", false, 12, 12, "Text", "/active/11-full-width"),
        ("🎉-report.txt", false, 13, 13, "Text", "/active/12-emoji"),
        ("한글 résumé ⑫.txt", false, 14, 14, "Text", "/active/13-mixed")
    ])
}

private func makeProjectionItems(_ values: [(String, Int64)]) -> [FileItem] {
    let root = URL(filePath: "/projection", directoryHint: .isDirectory)
    return values.map { name, size in
        FileItem(
            url: root.appending(path: name), name: name,
            isDirectory: false, isPackage: false, modifiedAt: nil,
            byteSize: size, typeDescription: "Text"
        )
    }
}

private func makeItems(
    _ values: [(String, Bool, Int?, Int64?, String, String)]
) -> [FileItem] {
    values.map { name, isDirectory, timestamp, byteSize, typeDescription, path in
        makeItem(
            name: name,
            url: URL(filePath: path),
            isDirectory: isDirectory,
            modifiedAt: timestamp.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            byteSize: byteSize,
            typeDescription: typeDescription
        )
    }
}

private func makeItem(
    name: String,
    url: URL,
    isDirectory: Bool,
    modifiedAt: Date?,
    byteSize: Int64?,
    typeDescription: String
) -> FileItem {
    FileItem(
        url: url,
        name: name,
        isDirectory: isDirectory,
        isPackage: false,
        modifiedAt: modifiedAt,
        byteSize: byteSize,
        typeDescription: typeDescription
    )
}

private struct ProjectionTestGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func nextBool() -> Bool {
        next() & 1 == 0
    }

    mutating func nextInt(upperBound: Int) -> Int {
        Int(next() % UInt64(upperBound))
    }

    mutating func asciiQuery(length: Int) -> String {
        String((0..<length).map { _ in
            let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
            return alphabet[nextInt(upperBound: alphabet.count)]
        })
    }

    mutating func items(caseNumber: Int, count: Int) -> [FileItem] {
        let unsafePrefixes = ["보고서", "Re\u{301}sume\u{301}", "ß", "⑫", "🎉", "Ｆｕｌｌ"]
        return (0..<count).map { index in
            let ascii = asciiQuery(length: 1 + nextInt(upperBound: 12))
            let name = nextBool()
                ? "\(ascii).txt"
                : "\(unsafePrefixes[nextInt(upperBound: unsafePrefixes.count)])-\(ascii).txt"
            return makeItem(
                name: name,
                url: URL(filePath: "/random/\(caseNumber)/\(index)-\(name)"),
                isDirectory: nextBool(),
                modifiedAt: Date(timeIntervalSince1970: TimeInterval(nextInt(upperBound: 10_000))),
                byteSize: Int64(nextInt(upperBound: 1_000)),
                typeDescription: nextBool() ? "Text" : "Markdown"
            )
        }
    }

    private mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}
