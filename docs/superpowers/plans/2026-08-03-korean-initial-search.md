# Pengrid Korean Initial Search Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add automatic Korean initial-consonant search to Pengrid Smart Search while preserving the existing literal search, safety, cancellation, and deterministic ranking contracts.

**Architecture:** Compile each query once into literal and Korean-initial clauses with a pure `SmartSearchTextAnalyzer`. Candidate filtering and ranking consume the same match evidence, while literal-only queries retain the existing tokenization, BM25 score, and path tie-break fast path. The UI adds only discoverability copy and a VoiceOver hint; persistence and search controls do not change.

**Tech Stack:** Swift 6.1, Foundation Unicode scalars and localized word boundaries, Swift Testing, SwiftUI/AppKit, Swift Package Manager on macOS 15+

## Global Constraints

- Recognize only the 19 modern Hangul initials: `ㄱ ㄲ ㄴ ㄷ ㄸ ㄹ ㅁ ㅂ ㅃ ㅅ ㅆ ㅇ ㅈ ㅉ ㅊ ㅋ ㅌ ㅍ ㅎ`.
- Treat compatibility jamo and modern choseong jamo as equivalent through an explicit mapping; do not apply global NFKC.
- Normalize document text to NFC before deriving initials.
- Initial clauses match consecutive syllable-run initials or consecutive run-head initials; arbitrary subsequences are forbidden.
- Query clauses use AND semantics, including mixed input such as `ㅎㄱ report` and adjacent input such as `2026ㅎㄱ`.
- Literal-only candidate membership, BM25 scoring, filename bonuses, and deterministic path ordering must remain unchanged.
- Keep search local and metadata-only; do not add network calls, materialization, content reads, persistent indexes, or unbounded caches.
- Preserve the 50,000 candidate hard bound, 2,000 result hard bound, progress reporting, and cancellation checks.
- Do not change `SmartSearchQuery`, `SmartSearchRecord`, or saved-search persistence schemas.
- Add no search-mode toggle and no result highlighting in this increment.

---

### Task 1: Pure query compiler and Hangul initial matcher

**Files:**
- Create: `Sources/BloomFileManager/Models/SmartSearchTextAnalyzer.swift`
- Create: `Tests/BloomFileManagerTests/SmartSearchTextAnalyzerTests.swift`
- Modify: `Sources/BloomFileManager/Models/SmartSearchModels.swift`
- Test: `Tests/BloomFileManagerTests/SmartSearchModelTests.swift`

**Interfaces:**
- Produces: `SmartSearchQueryPlan`, `SmartSearchClause`, `SmartSearchInitial`, `SmartSearchInitialEvidence`, `SmartSearchMatch`, and `SmartSearchTextAnalyzer`.
- Produces: `SmartSearchTextAnalyzer.queryPlan(for:)` and `SmartSearchTextAnalyzer.match(plan:filename:relativePath:)`.
- Preserves: `SmartSearchRanker.tokens(in:)`, implemented through the analyzer's literal tokenization so existing callers remain source-compatible.

- [ ] **Step 1: Write failing query-plan and Unicode equivalence tests**

Create `SmartSearchTextAnalyzerTests.swift` with real, table-driven expectations:

```swift
import Foundation
import Testing
@testable import BloomFileManager

@Suite struct SmartSearchTextAnalyzerTests {
    @Test func compatibilityAndChoseongQueriesCompileToTheSameInitials() {
        #expect(
            SmartSearchTextAnalyzer.queryPlan(for: "ㅎㄱ").clauses
                == SmartSearchTextAnalyzer.queryPlan(for: "ᄒᄀ").clauses
        )
    }

    @Test func mixedAndAdjacentScriptsCompileIntoOrderedAndClauses() {
        #expect(SmartSearchTextAnalyzer.queryPlan(for: "ㅎㄱ report").clauses == [
            .hangulInitials([.hieuh, .kiyeok]),
            .literal("report")
        ])
        #expect(SmartSearchTextAnalyzer.queryPlan(for: "2026ㅎㄱ").clauses == [
            .literal("2026"),
            .hangulInitials([.hieuh, .kiyeok])
        ])
    }

    @Test func unsupportedCompoundFinalRemainsLiteral() {
        #expect(SmartSearchTextAnalyzer.queryPlan(for: "ㄳ").clauses == [.literal("ㄳ")])
    }
}
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --no-parallel --filter SmartSearchTextAnalyzerTests
```

Expected: compilation fails because `SmartSearchTextAnalyzer`, `SmartSearchClause`, and `SmartSearchInitial` do not exist.

- [ ] **Step 3: Implement the minimal query-plan types and explicit 19-initial mapping**

Create focused value types in `SmartSearchTextAnalyzer.swift`:

```swift
enum SmartSearchInitial: UInt8, CaseIterable, Sendable, Equatable {
    case kiyeok, ssangKiyeok, nieun, tikeut, ssangTikeut, rieul, mieum
    case pieup, ssangPieup, siot, ssangSiot, ieung, cieuc, ssangCieuc
    case chieuch, khieukh, thieuth, phieuph, hieuh
}

enum SmartSearchClause: Sendable, Equatable {
    case literal(String)
    case hangulInitials([SmartSearchInitial])
}

struct SmartSearchQueryPlan: Sendable, Equatable {
    let clauses: [SmartSearchClause]
    var containsInitials: Bool {
        clauses.contains { if case .hangulInitials = $0 { true } else { false } }
    }
}

enum SmartSearchTextAnalyzer {
    static func queryPlan(for text: String) -> SmartSearchQueryPlan
    static func literalTokens(in text: String) -> [String]
}
```

Map compatibility jamo scalars and U+1100...U+1112 choseong scalars explicitly to the enum. Use the existing NFC, case-insensitive, diacritic-insensitive, localized `.byWords` behavior for literal runs. Split supported-initial and non-initial scalar runs inside each word so `2026ㅎㄱ` produces two clauses. Unsupported jamo must flow through literal tokenization.

Change `SmartSearchRanker.tokens(in:)` to delegate to `SmartSearchTextAnalyzer.literalTokens(in:)` without changing its public behavior.

- [ ] **Step 4: Run focused query-plan and existing tokenization tests and verify GREEN**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --no-parallel --filter SmartSearchTextAnalyzerTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --no-parallel --filter SmartSearchModelTests.tokenizationIsLocalizedCaseAndDiacriticInsensitive
```

Expected: both commands pass.

- [ ] **Step 5: Write failing document-projection and matching tests**

Add tests that name the false positives they prevent:

```swift
@Test func syllableRunsMatchKoreanWordsAcrossCanonicalForms() {
    let plan = SmartSearchTextAnalyzer.queryPlan(for: "ㅎㄱ")
    #expect(SmartSearchTextAnalyzer.match(plan: plan, filename: "한국.txt", relativePath: "한국.txt") != nil)
    #expect(SmartSearchTextAnalyzer.match(plan: plan, filename: "한글.txt", relativePath: "한글.txt") != nil)
    #expect(SmartSearchTextAnalyzer.match(
        plan: plan,
        filename: "한글".decomposedStringWithCanonicalMapping,
        relativePath: "한글".decomposedStringWithCanonicalMapping
    ) != nil)
}

@Test func runHeadsMatchWordsButDoNotAllowArbitrarySubsequences() {
    let plan = SmartSearchTextAnalyzer.queryPlan(for: "ㄱㄷ")
    #expect(SmartSearchTextAnalyzer.match(
        plan: plan, filename: "구글 드라이브", relativePath: "구글 드라이브"
    ) != nil)
    #expect(SmartSearchTextAnalyzer.match(
        plan: plan, filename: "개인 사진 다운로드", relativePath: "개인 사진 다운로드"
    ) == nil)
}

@Test func mixedClausesRequireEveryLiteralAndInitialCondition() {
    let plan = SmartSearchTextAnalyzer.queryPlan(for: "ㅎㄱ report")
    #expect(SmartSearchTextAnalyzer.match(
        plan: plan, filename: "한국 report.pdf", relativePath: "한국 report.pdf"
    ) != nil)
    #expect(SmartSearchTextAnalyzer.match(
        plan: plan, filename: "한국 notes.pdf", relativePath: "한국 notes.pdf"
    ) == nil)
}
```

- [ ] **Step 6: Run matching tests and verify RED**

Run the Task 1 suite again. Expected: compilation fails because `match(plan:filename:relativePath:)` and match-evidence types do not exist.

- [ ] **Step 7: Implement linear document projections and best-evidence selection**

Add:

```swift
enum SmartSearchInitialField: Int, Sendable, Equatable { case relativePath, filename }
enum SmartSearchInitialProjection: Int, Sendable, Equatable { case runHeads, syllableRun, literal }
enum SmartSearchInitialRelation: Int, Sendable, Equatable { case contains, prefix, exact }

struct SmartSearchInitialEvidence: Sendable, Equatable {
    let field: SmartSearchInitialField
    let projection: SmartSearchInitialProjection
    let relation: SmartSearchInitialRelation
    let start: Int
    let spanLength: Int
    var quality: Int {
        let fieldBase = field == .filename ? 1_000 : 0
        let matchRank = switch (projection, relation) {
        case (.literal, .exact): 900
        case (.literal, .prefix): 850
        case (.literal, .contains): 820
        case (.syllableRun, .exact): 800
        case (.syllableRun, .prefix): 700
        case (.runHeads, .exact): 600
        case (.runHeads, .prefix): 500
        case (.syllableRun, .contains): 400
        case (.runHeads, .contains): 300
        }
        return fieldBase + matchRank
    }
}

struct SmartSearchMatch: Sendable, Equatable {
    let initialEvidence: [SmartSearchInitialEvidence]
}
```

`match` must:

1. NFC-normalize filename and relative path.
2. Evaluate literal clauses with the current folded relative-path `contains` rule.
3. Derive syllable runs and run heads only when `plan.containsInitials` is true.
4. For every initial clause choose exactly one best evidence by field, projection, relation, shorter span, then earlier start.
5. Return `nil` if any clause fails; otherwise return one evidence per initial clause.

Use Hangul arithmetic only for U+AC00...U+D7A3. Segment heads reset on non-alphanumeric separators, including whitespace, `/`, `-`, `_`, and `.`. Check literal compatibility-jamo text before derived initials so a file literally named `ㅎㄱ` receives `.literal/.exact` evidence.

- [ ] **Step 8: Run Task 1 tests, mutation-check boundaries, and commit**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --no-parallel --filter SmartSearchTextAnalyzerTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --no-parallel --filter SmartSearchModelTests
git diff --check
```

Mentally verify these mutations fail a test: mapping `ㅎ` to the wrong initial, allowing non-consecutive subsequences, skipping NFC normalization, or treating `ㄳ` as a modern initial.

Commit:

```bash
git add Sources/BloomFileManager/Models/SmartSearchTextAnalyzer.swift Sources/BloomFileManager/Models/SmartSearchModels.swift Tests/BloomFileManagerTests/SmartSearchTextAnalyzerTests.swift Tests/BloomFileManagerTests/SmartSearchModelTests.swift
git commit -m "feat: add Korean initial search matcher"
```

### Task 2: Share match evidence between traversal and deterministic ranking

**Files:**
- Modify: `Sources/BloomFileManager/Models/SmartSearchModels.swift`
- Modify: `Sources/BloomFileManager/Services/SmartSearchService.swift`
- Modify: `Tests/BloomFileManagerTests/SmartSearchModelTests.swift`
- Modify: `Tests/BloomFileManagerTests/SmartSearchServiceTests.swift`

**Interfaces:**
- Consumes: `SmartSearchTextAnalyzer.queryPlan(for:)` and `match(plan:filename:relativePath:)` from Task 1.
- Produces: internal `PreparedSmartSearchCandidate(result:match:)` and a ranker overload that accepts prepared candidates plus a query plan.
- Preserves: non-throwing and cancellable `SmartSearchRanker.ranked(_:for:)` entry points for existing callers.

- [ ] **Step 1: Write failing service integration tests**

Add real temporary-directory cases to `SmartSearchServiceTests.swift`:

```swift
@Test func searchesKoreanInitialsWithBothJamoRepresentations() async throws {
    let root = try TemporaryDirectory()
    defer { root.remove() }
    try Data().write(to: root.url.appending(path: "한국 보고서.pdf"))
    try Data().write(to: root.url.appending(path: "한글 노트.txt"))

    let service = LocalSmartSearchService()
    let compatibility = try await service.search(try SmartSearchQuery(text: "ㅎㄱ", roots: [root.url]))
    let choseong = try await service.search(try SmartSearchQuery(text: "ᄒᄀ", roots: [root.url]))

    #expect(compatibility.map(\.item.name) == choseong.map(\.item.name))
    #expect(Set(compatibility.map(\.item.name)) == ["한국 보고서.pdf", "한글 노트.txt"])
}

@Test func mixedInitialAndLiteralQueryUsesAndSemantics() async throws {
    let root = try TemporaryDirectory()
    defer { root.remove() }
    for name in ["한국 report.pdf", "한국 notes.pdf", "영문 report.pdf"] {
        try Data().write(to: root.url.appending(path: name))
    }

    let results = try await LocalSmartSearchService().search(
        try SmartSearchQuery(text: "ㅎㄱ report", roots: [root.url])
    )

    #expect(results.map(\.item.name) == ["한국 report.pdf"])
}

@Test func runHeadSearchRejectsAnUnrelatedIntermediateInitial() async throws {
    let root = try TemporaryDirectory()
    defer { root.remove() }
    let matching = root.url.appending(path: "구글 드라이브", directoryHint: .isDirectory)
    let unrelated = root.url.appending(path: "개인 사진 다운로드", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: matching, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
    try Data().write(to: matching.appending(path: "계획.txt"))
    try Data().write(to: unrelated.appending(path: "메모.txt"))

    let results = try await LocalSmartSearchService().search(
        try SmartSearchQuery(text: "ㄱㄷ", roots: [root.url])
    )

    #expect(results.contains { $0.relativePath == "구글 드라이브/계획.txt" })
    #expect(results.contains { $0.relativePath == "개인 사진 다운로드/메모.txt" } == false)
}
```

Also add a path-head case where `ㄱㄷ` finds `구글/드라이브/계획.txt`, and a negative case proving `개인/사진/다운로드` is not returned.

- [ ] **Step 2: Run focused service tests and verify RED**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --no-parallel --filter SmartSearchServiceTests
```

Expected: Korean initial cases return zero results under the old literal-only `matches` implementation.

- [ ] **Step 3: Compile one plan per search and retain match evidence per candidate**

In `SmartSearchService.swift`, add:

```swift
struct PreparedSmartSearchCandidate: Sendable {
    let result: SmartSearchResult
    let match: SmartSearchMatch
}
```

Compile `let plan = SmartSearchTextAnalyzer.queryPlan(for: query.text)` before root traversal. Replace the private `matches(url:relativeTo:queryTokens:)` split path with a single analyzer call. Append a prepared candidate only after a non-`nil` match; request cloud availability only for matching entries. Carry prepared candidates through root deduplication and pass them to the ranker. Keep every existing traversal and ranking cancellation check.

- [ ] **Step 4: Run service tests and verify candidate matching GREEN**

Run the focused service suite. Expected: new Korean cases and every existing traversal/safety case pass.

- [ ] **Step 5: Write failing ranking-order and determinism tests**

Add tests that assert behavior rather than numeric constants:

```swift
@Test func literalJamoFilenameOutranksDerivedInitialAndPathMatches() throws {
    let query = try SmartSearchQuery(text: "ㅎㄱ", roots: [URL(filePath: "/search/root")])
    let ranked = SmartSearchRanker.ranked([
        result(name: "notes.txt", path: "한국/notes.txt"),
        result(name: "한국.txt", path: "한국.txt"),
        result(name: "ㅎㄱ", path: "ㅎㄱ")
    ], for: query)
    #expect(ranked.map(\.item.name) == ["ㅎㄱ", "한국.txt", "notes.txt"])
}

@Test func initialRankingIsIndependentOfCandidateInputOrder() throws {
    let query = try SmartSearchQuery(text: "ㅎㄱ", roots: [URL(filePath: "/search/root")])
    let candidates = [
        result(name: "한국2.txt", path: "한국2.txt"),
        result(name: "한국10.txt", path: "한국10.txt"),
        result(name: "한글.txt", path: "한글.txt")
    ]

    let forward = SmartSearchRanker.ranked(candidates, for: query).map(\.item.url)
    let reversed = SmartSearchRanker.ranked(Array(candidates.reversed()), for: query).map(\.item.url)

    #expect(forward == reversed)
}

@Test func literalOnlyRankingKeepsTheExistingExactPrefixAndContainsOrder() throws {
    let query = try SmartSearchQuery(text: "report", roots: [URL(filePath: "/search/root")])
    let ranked = SmartSearchRanker.ranked([
        result(name: "monthly-report.txt", path: "monthly-report.txt"),
        result(name: "report-draft.txt", path: "report-draft.txt"),
        result(name: "report", path: "report")
    ], for: query)

    #expect(ranked.map(\.item.name) == ["report", "report-draft.txt", "monthly-report.txt"])
    #expect(ranked.allSatisfy { $0.score > 0 })
}
```

- [ ] **Step 6: Run model tests and verify RED for initial quality ordering**

Run the model suite. Expected: the initial candidates are either absent or tied under literal BM25 and do not satisfy the required order.

- [ ] **Step 7: Implement lexicographic initial-quality ranking with literal fast-path preservation**

Rank prepared candidates with an internal scored tuple:

```swift
private struct SmartSearchRankedCandidate {
    let result: SmartSearchResult
    let weakestInitialQuality: Int
    let totalInitialQuality: Int
    let totalInitialSpan: Int
    let totalInitialStart: Int
    let literalScore: Double
}
```

For queries containing initial clauses, compare in this exact order:

1. `weakestInitialQuality` descending;
2. `totalInitialQuality` descending;
3. `totalInitialSpan` ascending;
4. `totalInitialStart` ascending;
5. existing `literalScore` descending;
6. existing localized standardized path ordering;
7. raw standardized path; and
8. relative path.

For literal-only plans, execute the current BM25 and filename bonus calculations and current tie-break without adding or comparing initial fields. Set `SmartSearchResult.score` to the non-negative literal score plus a bounded evidence bonus for initial queries, while tests use relative ordering rather than private constants.

Keep `ranked(_:for:)` source-compatible by preparing match evidence internally and dropping candidates that do not match the compiled plan. The service overload must consume its already-prepared candidates so it does not normalize each path twice.

- [ ] **Step 8: Run model, service, cancellation, and permutation tests and commit**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --no-parallel --filter SmartSearchModelTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --no-parallel --filter SmartSearchServiceTests
git diff --check
```

Verify that cancellation during traversal, feature preparation, scoring, and merge sorting still throws `CancellationError` and that reversing candidates cannot change equal-score output.

Commit:

```bash
git add Sources/BloomFileManager/Models/SmartSearchModels.swift Sources/BloomFileManager/Services/SmartSearchService.swift Tests/BloomFileManagerTests/SmartSearchModelTests.swift Tests/BloomFileManagerTests/SmartSearchServiceTests.swift
git commit -m "feat: integrate Korean initials into smart search"
```

### Task 3: Native search guidance, accessibility, and release verification

**Files:**
- Modify: `Sources/BloomFileManager/Views/SmartSearchView.swift`
- Modify: `Tests/BloomFileManagerTests/SmartSearchPresentationTests.swift`
- Modify: `README.md`
- Modify: `docs/verification/smart-search-checklist.md`

**Interfaces:**
- Produces: `SmartSearchPresentation.queryPrompt`, `idleSearchDetail`, and `queryAccessibilityHint` so visible and VoiceOver copy have one tested source.
- Preserves: existing search field identifier, submission policy, result row labels, navigation, and saved-search behavior.

- [ ] **Step 1: Write failing presentation-copy tests**

Add:

```swift
@Test func searchGuidanceExplainsAutomaticKoreanInitialMatching() {
    #expect(SmartSearchPresentation.queryPrompt == "Search names, paths, or Korean initials")
    #expect(SmartSearchPresentation.idleSearchDetail == "Try Korean initials such as ㅎㄱ for 한국 or 한글.")
    #expect(SmartSearchPresentation.queryAccessibilityHint == "Korean initial searches are supported, for example ㅎㄱ.")
}
```

Keep the existing state and accessibility tests unchanged so the new copy cannot weaken identifiers or result labels.

- [ ] **Step 2: Run presentation tests and verify RED**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --no-parallel --filter SmartSearchPresentationTests
```

Expected: compilation fails because the three presentation constants do not exist.

- [ ] **Step 3: Add minimal visible guidance and VoiceOver hint**

Define the three constants in `SmartSearchPresentation`. Use `queryPrompt` in the `TextField`, use `idleSearchDetail` for the idle state, and add:

```swift
.accessibilityHint(SmartSearchPresentation.queryAccessibilityHint)
```

Do not add a toggle. Do not add a second visible caption that duplicates the idle guidance. Preserve `.accessibilityIdentifier(AccessibilityIdentifiers.smartSearchQuery)` and the existing `.onSubmit(submitSearch)` path.

- [ ] **Step 4: Run presentation tests and verify GREEN**

Run the focused presentation suite and confirm all existing identifiers, state titles, root privacy, and result labels still pass.

- [ ] **Step 5: Document the behavior and manual UI gates**

Update `README.md` Smart Search bullets to mention automatic Korean-initial matching with `ㅎㄱ` and mixed terms. Update `docs/verification/smart-search-checklist.md` with explicit checks for:

- compatibility input `ㅎㄱ` and choseong input `ᄒᄀ` returning identical rows;
- Korean IME composition and Return submission;
- `ㄱㄷ` finding `구글 드라이브` but not an arbitrary subsequence;
- VoiceOver announcing the field hint once;
- light/dark appearance and narrow/wide window readability.

- [ ] **Step 6: Run focused and full automated verification**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --no-parallel --filter SmartSearch
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --no-parallel
git diff --check
./script/package_release.sh --verify-contract
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -c release --arch arm64
```

Expected: all Swift suites pass with zero failures; diff check, release contract, and arm64 release build exit 0.

- [ ] **Step 7: Run Luna Max UI verification and record evidence**

Build and launch the app through the existing script, then exercise the checklist with a temporary root containing `한국 보고서.pdf`, `한글 노트.txt`, `구글 드라이브/계획.txt`, and `개인 사진 다운로드/메모.txt`. Confirm query focus, Return submission, result order, double-click navigation, resizing, light/dark appearance, and VoiceOver hint. Record any environment-blocked physical check explicitly rather than claiming it passed.

- [ ] **Step 8: Commit documentation and UI changes**

```bash
git add Sources/BloomFileManager/Views/SmartSearchView.swift Tests/BloomFileManagerTests/SmartSearchPresentationTests.swift README.md docs/verification/smart-search-checklist.md
git commit -m "feat: surface Korean initial search guidance"
```

After Task 3, dispatch Sol Max for a whole-branch design and implementation review. Luna Max applies every load-bearing finding, reruns the focused suites after each fix, and repeats the full verification before completion.
