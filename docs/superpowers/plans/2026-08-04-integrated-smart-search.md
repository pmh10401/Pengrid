# Integrated Smart Search Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore Command-Shift-F recursive Smart Search with Korean-initial matching, metadata filters, saved searches, and identity-safe file-manager actions while preserving the existing Command-F pane filter.

**Architecture:** Selectively hand-port the isolated analyzer, model, service, store, and view units from `codex/korean-search-final` without merging that branch. Add exact `FileIdentity` authority to every result, route mutations only through identified safe-operation controller overloads, and integrate the sheet through minimal app/workspace changes.

**Tech Stack:** Swift 6.1, SwiftUI and AppKit on macOS 15, Swift Testing, Foundation URL resource metadata, existing `FileSystemAccess`, `CloudMaterializing`, and operation-center APIs.

## Global Constraints

- On this workstation, prefix every `xcrun swift` command with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`; the selected CommandLineTools path cannot import Swift Testing.
- Work only from `codex/safe-operation-center`; never merge `codex/korean-search-final` wholesale.
- Do not replace `FileOperationController`, `FileOperationService`, `FileOperationUndoService`, `FileSystemAccess`, archive code, or operation-center files with branch versions.
- Command-F remains a pure in-memory projection over the active pane's loaded items.
- Search reads names, relative paths, and ordinary provider metadata only; it makes zero `CloudMaterializing` calls and reads no file contents.
- Every result carries the exact search-captured `FileIdentity`; revalidation uses `==`, never `refersToSameItem(as:)`.
- Copy/move call `runIdentifiedTransfer`; Trash calls `trash(_:workspace:privacySafeProgress:onCompletion:)` with identified requests.
- Missing metadata does not match an active size or date bound.
- Legacy saved searches without metadata filters map `includeDirectories == false` to files-only and `true` to all items.
- Follow RED → verify failure → GREEN → verify pass → refactor → commit for every production behavior.

---

## File Structure

- `Sources/BloomFileManager/Models/SmartSearchModels.swift`: query, metadata filters, results with identity, saved records, ranking.
- `Sources/BloomFileManager/Models/SmartSearchTextAnalyzer.swift`: literal and Korean-initial parsing/matching only.
- `Sources/BloomFileManager/Services/SmartSearchService.swift`: bounded recursive metadata enumeration and identity capture.
- `Sources/BloomFileManager/Stores/SmartSearchStore.swift`: sheet state, cancellation generations, sort, filters, roots, persistence.
- `Sources/BloomFileManager/Support/SmartSearchActionRouter.swift`: identity revalidation and delegation to existing preview/navigation/operation APIs.
- `Sources/BloomFileManager/Views/SmartSearchView.swift`: sheet, filters, results, saved searches, and action controls.
- `Sources/BloomFileManager/App/BloomFileManagerApp.swift`: create/inject the search store and present the sheet.
- `Sources/BloomFileManager/Support/WorkspaceCommands.swift`: Command-Shift-F command only; preserve Command-F behavior.
- `Sources/BloomFileManager/Views/WorkspaceView.swift`: focused search presentation binding and opposite-pane dependencies.
- `Sources/BloomFileManager/Support/AccessibilityIdentifiers.swift`: stable search identifiers.
- `Sources/BloomFileManager/Stores/WorkspacePersistence.swift`: saved-search persistence boundary only.
- `Tests/BloomFileManagerTests/SmartSearch*.swift`: analyzer, model, service, store, presentation, and action coverage.

### Task 1: Korean-initial analyzer and bounded query model

**Files:**
- Create: `Sources/BloomFileManager/Models/SmartSearchTextAnalyzer.swift`
- Create: `Sources/BloomFileManager/Models/SmartSearchModels.swift`
- Create: `Tests/BloomFileManagerTests/SmartSearchTextAnalyzerTests.swift`
- Create: `Tests/BloomFileManagerTests/SmartSearchModelTests.swift`

**Interfaces:**
- Consumes: `FileItem`, `FileIdentity`.
- Produces: `SmartSearchQuery`, `SmartSearchQueryPlan`, `SmartSearchTextAnalyzer`, `SmartSearchResult`, `SmartSearchRanker`, `SmartSearchRecord`.

- [ ] **Step 1: Write failing analyzer tests**

```swift
import Testing
@testable import BloomFileManager

@Test func koreanInitialClauseMatchesDecomposedAndPrecomposedNames() throws {
    let plan = SmartSearchTextAnalyzer.queryPlan(for: "ㅍㄱ")
    #expect(try SmartSearchTextAnalyzer.match(
        plan: plan,
        filename: "파일관리",
        relativePath: "문서/파일관리",
        analysisStep: {}
    ) != nil)
}

@Test func mixedClausesUseAndSemantics() throws {
    let plan = SmartSearchTextAnalyzer.queryPlan(for: "ㅍㄱ report")
    #expect(try SmartSearchTextAnalyzer.match(
        plan: plan,
        filename: "파일관리 report.txt",
        relativePath: "파일관리 report.txt",
        analysisStep: {}
    ) != nil)
    #expect(try SmartSearchTextAnalyzer.match(
        plan: plan,
        filename: "파일관리.txt",
        relativePath: "파일관리.txt",
        analysisStep: {}
    ) == nil)
}
```

- [ ] **Step 2: Run the analyzer tests and verify RED**

Run: `xcrun swift test --filter SmartSearchTextAnalyzerTests`

Expected: compilation fails because `SmartSearchTextAnalyzer` and its plan types do not exist.

- [ ] **Step 3: Hand-port the analyzer and core bounded model**

Start from the two files at `codex/korean-search-final:afea689`, preserving these public shapes while adding result identity:

```swift
struct SmartSearchResult: Identifiable, Equatable, Sendable {
    let item: FileItem
    let relativePath: String
    let score: Double
    let identity: FileIdentity
    var id: URL { item.url }
}

struct SmartSearchQuery: Codable, Equatable, Sendable {
    static let maximumTextScalarCount = 512
    static let maximumClauseCount = 16
    static let maximumResultRange = 1...2_000
    static let maximumCandidateBudget = 50_000
    func executablePlan() throws -> SmartSearchQueryPlan
}
```

Keep Unicode canonical normalization, Korean compatibility-jamo handling, multi-clause AND semantics, cancellation hooks, candidate budgeting, and result ranking from the source branch. Do not copy any shared baseline file.

- [ ] **Step 4: Run analyzer and model tests and verify GREEN**

Run: `xcrun swift test --filter SmartSearchTextAnalyzerTests && xcrun swift test --filter SmartSearchModelTests`

Expected: both filters pass with no warnings or crashes.

- [ ] **Step 5: Commit the analyzer/model slice**

```bash
git add Sources/BloomFileManager/Models/SmartSearchModels.swift Sources/BloomFileManager/Models/SmartSearchTextAnalyzer.swift Tests/BloomFileManagerTests/SmartSearchModelTests.swift Tests/BloomFileManagerTests/SmartSearchTextAnalyzerTests.swift
git commit -m "feat: restore Korean-aware smart search model"
```

### Task 2: Metadata filters and backward-compatible coding

**Files:**
- Modify: `Sources/BloomFileManager/Models/SmartSearchModels.swift`
- Modify: `Tests/BloomFileManagerTests/SmartSearchModelTests.swift`

**Interfaces:**
- Consumes: Task 1 `SmartSearchQuery`.
- Produces: `SmartSearchItemKind`, `SmartSearchMetadataFilter`, normalized extension and inclusive bound predicates.

- [ ] **Step 1: Write failing filter and legacy decode tests**

```swift
@Test func metadataFilterNormalizesExtensionsAndRejectsMissingBoundedMetadata() throws {
    let filter = try SmartSearchMetadataFilter(
        kind: .files,
        extensionText: ".PDF, pdf, TXT",
        minimumBytes: 10,
        maximumBytes: 20,
        modifiedAfter: nil,
        modifiedBefore: nil
    )
    #expect(filter.extensions == ["pdf", "txt"])
    #expect(!filter.matches(isDirectory: false, extension: "pdf", byteSize: nil, modifiedAt: .now))
    #expect(filter.matches(isDirectory: false, extension: "PDF", byteSize: 10, modifiedAt: .now))
    #expect(filter.matches(isDirectory: false, extension: "pdf", byteSize: 20, modifiedAt: .now))
}

@Test func legacyFilesOnlySearchStaysFilesOnly() throws {
    let data = Data(#"{"text":"문서","roots":["file:///tmp"],"includeHidden":false,"includePackages":false,"includeDirectories":false,"maximumResults":500}"#.utf8)
    let query = try JSONDecoder().decode(SmartSearchQuery.self, from: data)
    #expect(query.metadata.kind == .files)
}
```

- [ ] **Step 2: Run the model tests and verify RED**

Run: `xcrun swift test --filter SmartSearchModelTests`

Expected: compilation fails because `SmartSearchMetadataFilter`, `SmartSearchItemKind`, and `query.metadata` do not exist.

- [ ] **Step 3: Implement filter values and coding migration**

```swift
enum SmartSearchItemKind: String, Codable, CaseIterable, Sendable {
    case all, files, folders
}

struct SmartSearchMetadataFilter: Codable, Equatable, Sendable {
    let kind: SmartSearchItemKind
    let extensions: Set<String>
    let minimumBytes: Int64?
    let maximumBytes: Int64?
    let modifiedAfter: Date?
    let modifiedBefore: Date?

    func matches(
        isDirectory: Bool,
        extension: String?,
        byteSize: Int64?,
        modifiedAt: Date?
    ) -> Bool
}
```

Use `decodeIfPresent(SmartSearchMetadataFilter.self, forKey: .metadata)`. When absent, decode legacy `includeDirectories` with historical default `true`; map false to `.files` and true to `.all`. Encode the new metadata object and retain the legacy boolean for downgrade readability. Validate nonnegative size bounds, minimum ≤ maximum, and earliest date ≤ latest date with distinct `SmartSearchValidationError` cases.

- [ ] **Step 4: Run model tests and verify GREEN**

Run: `xcrun swift test --filter SmartSearchModelTests`

Expected: normalization, inclusive boundaries, invalid ranges, round trips, and legacy fixtures all pass.

- [ ] **Step 5: Commit metadata filters**

```bash
git add Sources/BloomFileManager/Models/SmartSearchModels.swift Tests/BloomFileManagerTests/SmartSearchModelTests.swift
git commit -m "feat: add smart search metadata filters"
```

### Task 3: Identity-bearing metadata-only recursive service

**Files:**
- Create: `Sources/BloomFileManager/Services/SmartSearchService.swift`
- Create: `Tests/BloomFileManagerTests/SmartSearchServiceTests.swift`

**Interfaces:**
- Consumes: `SmartSearchQuery`, `SmartSearchResult`, `FileSystemAccess.identity(of:)`, `CloudItemAvailabilityReading`, `CloudLocationScopedAccessCoordinator`.
- Produces: `SmartSearching.search(_:progress:) async throws -> [SmartSearchResult]` and `LocalSmartSearchService`.

- [ ] **Step 1: Write failing service tests**

```swift
@Test func serviceCapturesExactIdentityAndAppliesMetadataBeforeRetention() async throws {
    let root = try TemporaryDirectory()
    defer { root.remove() }
    let textURL = root.url.appending(path: "alpha.txt")
    try Data(repeating: 1, count: 12).write(to: textURL)
    try Data(repeating: 1, count: 30).write(to: root.url.appending(path: "alpha.pdf"))
    let fileSystem = LiveFileSystemAccess()
    let service = LocalSmartSearchService(fileSystem: fileSystem)
    let query = try SmartSearchQuery(
        text: "alpha",
        roots: [root.url],
        metadata: try .init(kind: .files, extensionText: "txt", minimumBytes: 10, maximumBytes: 20)
    )

    let results = try await service.search(query)
    let expectedIdentity = try await fileSystem.identity(of: textURL)

    #expect(results.map(\.item.name) == ["alpha.txt"])
    #expect(results.first?.identity == expectedIdentity)
}

@Test func itemReplacedDuringMetadataReadIsNotRetained() async throws {
    let root = try TemporaryDirectory()
    defer { root.remove() }
    let url = root.url.appending(path: "replace-me.txt")
    try Data([1]).write(to: url)
    let replacement = ReplacementOnce()
    let service = LocalSmartSearchService(
        fileSystem: LiveFileSystemAccess(),
        typeDescriptionReader: { candidate in
            try replacement.replace(candidate)
            return "File"
        }
    )
    let results = try await service.search(
        try SmartSearchQuery(text: "replace-me", roots: [root.url])
    )
    #expect(results.isEmpty)
}

private final class ReplacementOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var didReplace = false
    func replace(_ url: URL) throws {
        lock.lock()
        guard !didReplace else { lock.unlock(); return }
        didReplace = true
        lock.unlock()
        try FileManager.default.removeItem(at: url)
        try Data([2]).write(to: url)
    }
}

@Test func smartSearchServiceHasNoMaterializationOrContentReadDependency() throws {
    let implementation = try source(named: "Services/SmartSearchService.swift")
    #expect(!implementation.contains("CloudMaterializing"))
    #expect(!implementation.contains("materialize("))
    #expect(!implementation.contains("NSFileCoordinator"))
}

private func source(named relativePath: String) throws -> String {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let url = packageRoot.appending(path: "Sources/BloomFileManager").appending(path: relativePath)
    return try String(contentsOf: url, encoding: .utf8)
}
```

Keep `CloudMaterializing` outside the service initializer; the source-level regression test makes that dependency boundary explicit.

- [ ] **Step 2: Run service tests and verify RED**

Run: `xcrun swift test --filter SmartSearchServiceTests`

Expected: compilation fails because `SmartSearching` and `LocalSmartSearchService` do not exist.

- [ ] **Step 3: Hand-port and harden the service**

```swift
protocol SmartSearching: Sendable {
    func search(
        _ query: SmartSearchQuery,
        progress: @escaping @Sendable (Int) -> Void
    ) async throws -> [SmartSearchResult]
}

final class LocalSmartSearchService: SmartSearching, @unchecked Sendable {
    init(
        fileManager: FileManager = .default,
        fileSystem: any FileSystemAccess = LiveFileSystemAccess(),
        availabilityReader: any CloudItemAvailabilityReading = LiveCloudItemAvailabilityService(),
        scopedAccessCoordinator: CloudLocationScopedAccessCoordinator = .init(),
        typeDescriptionReader: @escaping @Sendable (URL) throws -> String? = {
            try $0.resourceValues(forKeys: [.localizedTypeDescriptionKey]).localizedTypeDescription
        }
    )
}
```

Port recursive traversal, root deduplication, symlink/package boundaries, progress, cancellation, candidate cap, and result cap from `afea689`. For each candidate, capture `identityBefore` before reading filter/display metadata and `identityAfter` after metadata plus availability reads; retain the item only when both are nonnil and `identityBefore == identityAfter`, then store `identityBefore` in the result. Apply `query.metadata.matches` before candidate retention. Skip inaccessible or replaced descendants, but fail invalid roots. Never call content readers, coordinated reads, or materialization.

- [ ] **Step 4: Run service and performance tests and verify GREEN**

Run: `xcrun swift test --filter SmartSearchServiceTests`

Expected: filtering, duplicate-root pruning, symlink/package/hidden boundaries, pre/post exact-identity refusal, cancellation, progress, result/candidate caps, and unavailable metadata cases pass.

- [ ] **Step 5: Commit the service slice**

```bash
git add Sources/BloomFileManager/Services/SmartSearchService.swift Tests/BloomFileManagerTests/SmartSearchServiceTests.swift
git commit -m "feat: add bounded identity-aware smart search service"
```

### Task 4: Store, saved searches, sorting, and cancellation generations

**Files:**
- Create: `Sources/BloomFileManager/Stores/SmartSearchStore.swift`
- Create: `Tests/BloomFileManagerTests/SmartSearchStoreTests.swift`
- Modify: `Sources/BloomFileManager/Stores/WorkspacePersistence.swift`
- Modify: `Tests/BloomFileManagerTests/WorkspacePersistenceTests.swift`

**Interfaces:**
- Consumes: `SmartSearching`, `SmartSearchQuery`, `SmartSearchRecord`.
- Produces: `@MainActor @Observable SmartSearchStore`, `SmartSearchSort`, `SmartSearchPresentationState`.

- [ ] **Step 1: Write failing store generation and persistence tests**

```swift
@Test @MainActor func staleSearchCannotReplaceNewerResults() async throws {
    let service = ReplacingSearchService()
    let persistence = RecordingSmartSearchPersistence(data: nil)
    let store = SmartSearchStore(service: service, persistence: persistence)
    store.present(initialRoot: URL(fileURLWithPath: "/new"))
    store.queryText = "old"
    store.submit()
    store.queryText = "new"
    store.submit()
    let oldResult = searchResult(name: "old.txt")
    let newResult = searchResult(name: "new.txt")
    await service.finish(request: 1, with: [newResult])
    await service.finish(request: 0, with: [oldResult])
    #expect(store.results == [newResult])
}

@Test func undecodableSavedSearchBytesRemainUntouched() {
    let persistence = RecordingSmartSearchPersistence(data: Data("{".utf8))
    let store = SmartSearchStore(service: ReplacingSearchService(), persistence: persistence)
    #expect(store.savedSearches.isEmpty)
    #expect(persistence.savedData == Data("{".utf8))
}

private actor ReplacingSearchService: SmartSearching {
    private var continuations: [CheckedContinuation<[SmartSearchResult], any Error>] = []

    func search(
        _ query: SmartSearchQuery,
        progress: @escaping @Sendable (Int) -> Void
    ) async throws -> [SmartSearchResult] {
        try await withCheckedThrowingContinuation { continuations.append($0) }
    }

    func finish(request index: Int, with results: [SmartSearchResult]) {
        continuations[index].resume(returning: results)
    }
}

private final class RecordingSmartSearchPersistence: SmartSearchPersisting, @unchecked Sendable {
    private(set) var savedData: Data?
    init(data: Data?) { savedData = data }
    func load() -> Data? { savedData }
    func save(_ data: Data) { savedData = data }
}

private func searchResult(name: String) -> SmartSearchResult {
    let url = URL(filePath: "/fixture/\(name)")
    return SmartSearchResult(
        item: FileItem(url: url, name: name, isDirectory: false, isPackage: false, modifiedAt: nil, byteSize: 1, typeDescription: "File"),
        relativePath: name,
        score: 1,
        identity: FileIdentity(entryIdentifier: name, resolvedIdentifier: name)
    )
}
```

- [ ] **Step 2: Run store tests and verify RED**

Run: `xcrun swift test --filter SmartSearchStoreTests`

Expected: compilation fails because the store and persistence interfaces do not exist.

- [ ] **Step 3: Implement observable state and isolated persistence**

```swift
protocol SmartSearchPersisting: Sendable {
    func load() -> Data?
    func save(_ data: Data)
}

@MainActor @Observable
final class SmartSearchStore {
    private(set) var isPresented = false
    private(set) var phase: SmartSearchPresentationState = .idle
    private(set) var results: [SmartSearchResult] = []
    var queryText = ""
    var roots: [URL] = []
    var metadata: SmartSearchMetadataFilter = .unrestricted
    var sort: SmartSearchSort = .score
    func present(initialRoot: URL)
    func submit()
    func cancel()
    func dismiss()
}
```

Port generation cancellation and newest-value progress coalescing from `afea689`. Preserve current query, roots, filter, sort, and results across dismissal. Decode saved records without overwriting corrupt bytes; save only after an explicit saved-search mutation.

- [ ] **Step 4: Run store and persistence tests and verify GREEN**

Run: `xcrun swift test --filter SmartSearchStoreTests && xcrun swift test --filter WorkspacePersistenceTests`

Expected: generation races, cancellation, progress coalescing, sorting, filter edits, legacy decoding, corrupt bytes, and restoration pass.

- [ ] **Step 5: Commit state and persistence**

```bash
git add Sources/BloomFileManager/Stores/SmartSearchStore.swift Sources/BloomFileManager/Stores/WorkspacePersistence.swift Tests/BloomFileManagerTests/SmartSearchStoreTests.swift Tests/BloomFileManagerTests/WorkspacePersistenceTests.swift
git commit -m "feat: persist smart search workspace state"
```

### Task 5: Exact-identity result actions

**Files:**
- Create: `Sources/BloomFileManager/Support/SmartSearchActionRouter.swift`
- Create: `Tests/BloomFileManagerTests/SmartSearchActionRouterTests.swift`

**Interfaces:**
- Consumes: `SmartSearchResult`, `FileSystemAccess`, `QuickLookController`, `FileOperationController`, `WorkspaceState`, identified transfer and Trash APIs.
- Produces: `SmartSearchActionRouter`, `SmartSearchActionError.itemChanged`, result-to-request conversion.

- [ ] **Step 1: Write failing replacement-refusal and identified-routing tests**

```swift
@Test @MainActor func replacementCannotBePreviewedOrTransferred() async {
    let url = URL(filePath: "/search/report.txt")
    let searchIdentity = FileIdentity(entryIdentifier: "searched", resolvedIdentifier: "searched")
    let replacementIdentity = FileIdentity(entryIdentifier: "replacement", resolvedIdentifier: "replacement")
    let fileSystem = RecordingFileSystem(identities: [url: replacementIdentity])
    let router = SmartSearchActionRouter(fileSystem: fileSystem)
    let result = actionResult(url: url, identity: searchIdentity)

    #expect(await router.revalidatedRequest(for: result) == nil)
    #expect(router.error == .itemChanged)
}

@Test @MainActor func transferCarriesSearchAndDestinationIdentities() async throws {
    let sourceURL = URL(filePath: "/search/report.txt")
    let destinationURL = URL(filePath: "/destination", directoryHint: .isDirectory)
    let sourceIdentity = FileIdentity(entryIdentifier: "source", resolvedIdentifier: "source")
    let destinationIdentity = FileIdentity(entryIdentifier: "destination", resolvedIdentifier: "destination")
    let result = actionResult(url: sourceURL, identity: sourceIdentity)
    let router = SmartSearchActionRouter(fileSystem: RecordingFileSystem(
        identities: [sourceURL: sourceIdentity, destinationURL: destinationIdentity]
    ))
    let requests = try await router.transferRequests(for: [result], destination: destinationURL)
    #expect(requests == [IdentifiedTransferRequest(
        source: result.item.url,
        sourceIdentity: result.identity,
        destinationRoot: destinationURL,
        destinationRootIdentity: destinationIdentity,
        relativeParentComponents: []
    )])
}

private func actionResult(url: URL, identity: FileIdentity) -> SmartSearchResult {
    SmartSearchResult(
        item: FileItem(url: url, name: url.lastPathComponent, isDirectory: false, isPackage: false, modifiedAt: nil, byteSize: 1, typeDescription: "File"),
        relativePath: url.lastPathComponent,
        score: 1,
        identity: identity
    )
}
```

- [ ] **Step 2: Run action tests and verify RED**

Run: `xcrun swift test --filter SmartSearchActionRouterTests`

Expected: compilation fails because `SmartSearchActionRouter` does not exist.

- [ ] **Step 3: Implement the fail-closed router**

```swift
@MainActor
final class SmartSearchActionRouter {
    private(set) var error: SmartSearchActionError?

    func revalidatedRequest(for result: SmartSearchResult) async -> IdentifiedFileRequest? {
        guard (try? await fileSystem.identity(of: result.item.url)) == result.identity else {
            error = .itemChanged
            return nil
        }
        return IdentifiedFileRequest(url: result.item.url, identity: result.identity)
    }
}
```

Quick Look passes only revalidated identified requests. Reveal navigates to the parent, then revalidates again before selection. Opposite-pane open captures and revalidates the result before navigation. Copy/move capture the opposite pane's destination identity at invocation and call only `runIdentifiedTransfer`. Trash calls only the identified `trash` overload with privacy-safe progress and binds confirmation to the captured ordered result IDs.

- [ ] **Step 4: Run action and safe-operation regression tests and verify GREEN**

Run: `xcrun swift test --filter SmartSearchActionRouterTests && xcrun swift test --filter FileOperationControllerTests && xcrun swift test --filter FileTransferTests`

Expected: replacement, missing item, destination replacement, selection change, and all identified routes pass; existing operation tests remain green.

- [ ] **Step 5: Commit action routing**

```bash
git add Sources/BloomFileManager/Support/SmartSearchActionRouter.swift Tests/BloomFileManagerTests/SmartSearchActionRouterTests.swift
git commit -m "feat: add identity-safe smart search actions"
```

### Task 6: Search sheet, commands, accessibility, and app wiring

**Files:**
- Create: `Sources/BloomFileManager/Views/SmartSearchView.swift`
- Create: `Tests/BloomFileManagerTests/SmartSearchPresentationTests.swift`
- Modify: `Sources/BloomFileManager/App/BloomFileManagerApp.swift`
- Modify: `Sources/BloomFileManager/Support/WorkspaceCommands.swift`
- Modify: `Sources/BloomFileManager/Views/WorkspaceView.swift`
- Modify: `Sources/BloomFileManager/Support/AccessibilityIdentifiers.swift`
- Modify: `Tests/BloomFileManagerTests/WorkspaceCommandTests.swift`
- Modify: `Tests/BloomFileManagerTests/WorkspaceCommandPolicyTests.swift`
- Modify: `Tests/BloomFileManagerTests/AccessibilityPresentationTests.swift`

**Interfaces:**
- Consumes: Tasks 1–5 models, store, service, and router; existing pane filter.
- Produces: Command-Shift-F sheet presentation and accessible result/filter/action UI.

- [ ] **Step 1: Write failing command and presentation tests**

```swift
@Test @MainActor func smartSearchStartsAtActivePaneRoot() {
    let store = SmartSearchStore(
        service: EmptySmartSearchService(),
        persistence: WorkspacePersistence(defaults: UserDefaults(suiteName: UUID().uuidString)!)
    )
    WorkspaceSearchCommandActions.showSmartSearch(in: workspace, store: store)
    #expect(store.isPresented)
    #expect(store.roots == [workspace.activePane.currentDirectory])
}

@Test func presentationExposesPrivacySafeColumnsAndActions() {
    let implementation = try source(named: "Views/SmartSearchView.swift")
    #expect(implementation.contains("smartSearch.results"))
    #expect(implementation.contains("Name"))
    #expect(implementation.contains("Location"))
    #expect(!implementation.contains("accessibilityValue(result.item.url.path)"))
}

private actor EmptySmartSearchService: SmartSearching {
    func search(
        _ query: SmartSearchQuery,
        progress: @escaping @Sendable (Int) -> Void
    ) async throws -> [SmartSearchResult] { [] }
}

private func source(named relativePath: String) throws -> String {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let url = packageRoot.appending(path: "Sources/BloomFileManager").appending(path: relativePath)
    return try String(contentsOf: url, encoding: .utf8)
}
```

- [ ] **Step 2: Run presentation tests and verify RED**

Run: `xcrun swift test --filter SmartSearchPresentationTests && xcrun swift test --filter WorkspaceCommandTests`

Expected: compilation or assertions fail because the view, command action, identifiers, and app wiring are absent.

- [ ] **Step 3: Hand-port the view and add minimal baseline integrations**

```swift
@MainActor
enum WorkspaceSearchCommandActions {
    static func showSmartSearch(in workspace: WorkspaceState, store: SmartSearchStore) {
        store.present(initialRoot: workspace.activePane.currentDirectory)
    }
}
```

Add a Command-Shift-F button labeled “Smart Search…” without modifying the existing Command-F pane-filter command. Present `SmartSearchView` from the app/workspace with query, roots, filter chips/popover, sortable columns (name, safe parent location, type, size, modified, availability), saved searches, and Task 5 actions. Mutations dismiss the sheet before entering the operation center. Add stable identifiers under `AccessibilityIdentifiers.smartSearch...`, explicit labels/hints, deterministic focus order, and VoiceOver-safe progress/error announcements.

- [ ] **Step 4: Run presentation, command, and accessibility tests and verify GREEN**

Run: `xcrun swift test --filter SmartSearchPresentationTests && xcrun swift test --filter WorkspaceCommand && xcrun swift test --filter AccessibilityPresentationTests`

Expected: both shortcuts coexist, initial-root routing, filters, sortable columns, actions, privacy-safe copy, and accessibility identifiers pass.

- [ ] **Step 5: Commit the UI integration**

```bash
git add Sources/BloomFileManager/App/BloomFileManagerApp.swift Sources/BloomFileManager/Support/AccessibilityIdentifiers.swift Sources/BloomFileManager/Support/WorkspaceCommands.swift Sources/BloomFileManager/Views/SmartSearchView.swift Sources/BloomFileManager/Views/WorkspaceView.swift Tests/BloomFileManagerTests/AccessibilityPresentationTests.swift Tests/BloomFileManagerTests/SmartSearchPresentationTests.swift Tests/BloomFileManagerTests/WorkspaceCommandPolicyTests.swift Tests/BloomFileManagerTests/WorkspaceCommandTests.swift
git commit -m "feat: restore integrated smart search workspace"
```

### Task 7: Search regression and release evidence

**Files:**
- Modify: `README.md`
- Create: `docs/verification/2026-08-04-smart-search.md`
- Modify only if a focused regression fails: the file responsible for that regression, paired with a failing test first.

**Interfaces:**
- Consumes: complete Tasks 1–6 feature.
- Produces: reproducible automated and manual verification record.

- [ ] **Step 1: Run focused automated verification**

```bash
xcrun swift test --filter PaneFilenameFilterTests
xcrun swift test --filter SmartSearch
xcrun swift test --filter FileOperationControllerTests
xcrun swift test --filter FileTransferTests
xcrun swift test --filter CloudOperationGateTests
```

Expected: every command exits 0; Command-F filter regressions and safe-operation suites remain green.

- [ ] **Step 2: Run the complete suite serially and release build**

```bash
xcrun swift test --no-parallel
xcrun swift build -c release
```

Expected: full test suite and release build exit 0 with no new warnings.

- [ ] **Step 3: Record local and provider manual evidence**

Create `docs/verification/2026-08-04-smart-search.md` with this checked matrix and actual observed results:

```markdown
- [ ] Command-F filters only the active pane and performs no listing.
- [ ] Command-Shift-F searches local names, paths, Korean initials, and mixed clauses.
- [ ] Kind, extension, size, and modification-date filters honor inclusive bounds.
- [ ] Google Drive search shows provider metadata without downloading online-only content.
- [ ] OneDrive search shows provider metadata without downloading online-only content.
- [ ] Replacing a result before Quick Look/copy/move/Trash fails with “Item changed. Search again.”
- [ ] Submitted copy/move/Trash appears in the operation center with progress and cancellation.
- [ ] VoiceOver reads query, filters, table columns, selection, progress, and errors without absolute paths.
```

- [ ] **Step 4: Update README and commit evidence**

Document Command-F versus Command-Shift-F, Korean-initial examples, metadata filters, saved searches, cloud search limits, and identity-safe actions.

```bash
git add README.md docs/verification/2026-08-04-smart-search.md
git commit -m "docs: verify integrated smart search"
```
