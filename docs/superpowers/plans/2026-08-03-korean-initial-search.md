# Korean Initial Search Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add automatic Korean initial-consonant matching and deterministic ranking to Pengrid Smart Search while preserving every literal-only search contract.

**Architecture:** A pure `SmartSearchTextAnalyzer` compiles a query into literal and Korean-initial clauses and prepares bounded document projections. `LocalSmartSearchService` uses the same plan and prepared features for candidate filtering, while `SmartSearchRanker` compares explicit evidence tuples before BM25-style relevance. Existing Store and persistence models remain unchanged.

**Tech Stack:** Swift 6.1, Foundation Unicode scalars and normalization, Swift Testing, SwiftUI/AppKit, Swift Package Manager on macOS 15+.

## Global Constraints

- Support only the 19 modern Hangul initials; map compatibility jamo and modern choseong jamo explicitly to the same compatibility-jamo key.
- Normalize document text to NFC; do not apply global NFKC.
- Match initial clauses only as consecutive substrings of explicit-initial runs, syllable runs, or adjacent run-head groups; never use arbitrary subsequences.
- Compile query clauses once per search and create initial projections only when an initial clause exists.
- Preserve literal-only candidate sets, BM25 scores, filename multiplier, bonuses, and standardized-path ordering.
- Preserve explicit local roots, hidden/package/symlink rules, metadata-only cloud behavior, 50,000 candidate bound, 2,000 result bound, progress, and cancellation.
- Do not change `SmartSearchQuery`, `SmartSearchRecord`, saved-search persistence, or add a search-mode toggle.
- Keep Unicode analysis linear and dependency-free.
- Follow strict red-green-refactor: each production behavior begins with a focused test observed failing for the expected reason.

---

### Task 1: Query planning and modern-initial canonicalization

**Files:**
- Create: `Sources/BloomFileManager/Models/SmartSearchTextAnalyzer.swift`
- Create: `Tests/BloomFileManagerTests/SmartSearchTextAnalyzerTests.swift`

**Interfaces:**
- Produces: `SmartSearchClause`, `SmartSearchQueryPlan`, and `SmartSearchTextAnalyzer.queryPlan(for:)`.
- Consumes: Foundation only.
- Later tasks rely on the exact clause cases `.literal(String)` and `.hangulInitials(String)`.

- [ ] **Step 1: Write failing query-plan tests**

```swift
import Foundation
import Testing
@testable import BloomFileManager

@Suite struct SmartSearchTextAnalyzerTests {
    @Test func canonicalizesCompatibilityAndChoseongInitials() {
        #expect(SmartSearchTextAnalyzer.queryPlan(for: "ㅎㄱ").clauses == [.hangulInitials("ㅎㄱ")])
        #expect(SmartSearchTextAnalyzer.queryPlan(for: "ᄒᄀ").clauses == [.hangulInitials("ㅎㄱ")])
        #expect(SmartSearchTextAnalyzer.queryPlan(for: "ㄲㄸㅃㅆㅉ").clauses == [.hangulInitials("ㄲㄸㅃㅆㅉ")])
    }

    @Test func splitsMixedLiteralAndInitialRunsWithAndSemantics() {
        #expect(SmartSearchTextAnalyzer.queryPlan(for: "ㅎㄱ report").clauses == [
            .hangulInitials("ㅎㄱ"), .literal("report")
        ])
        #expect(SmartSearchTextAnalyzer.queryPlan(for: "2026ㅎㄱ").clauses == [
            .literal("2026"), .hangulInitials("ㅎㄱ")
        ])
        #expect(SmartSearchTextAnalyzer.queryPlan(for: "ㅎ ㄱ").clauses == [
            .hangulInitials("ㅎ"), .hangulInitials("ㄱ")
        ])
    }

    @Test func leavesCompletedHangulAndUnsupportedJamoLiteral() {
        #expect(SmartSearchTextAnalyzer.queryPlan(for: "한국").clauses == [.literal("한국")])
        #expect(SmartSearchTextAnalyzer.queryPlan(for: "ㄳ").clauses == [.literal("ㄳ")])
    }
}
```

- [ ] **Step 2: Run the new suite and verify RED**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --no-parallel --filter SmartSearchTextAnalyzerTests
```

Expected: compilation fails because `SmartSearchTextAnalyzer` and clause types do not exist.

- [ ] **Step 3: Implement the minimal query-plan API**

Create these value types and mapping tables:

```swift
import Foundation

enum SmartSearchClause: Equatable, Hashable, Sendable {
    case literal(String)
    case hangulInitials(String)
}

struct SmartSearchQueryPlan: Equatable, Sendable {
    let clauses: [SmartSearchClause]
    var containsHangulInitials: Bool {
        clauses.contains { if case .hangulInitials = $0 { true } else { false } }
    }
}

enum SmartSearchTextAnalyzer {
    typealias AnalysisStep = @Sendable () throws -> Void

    private static let compatibilityScalars: [Unicode.Scalar] = [
        "ㄱ", "ㄲ", "ㄴ", "ㄷ", "ㄸ", "ㄹ", "ㅁ", "ㅂ", "ㅃ", "ㅅ",
        "ㅆ", "ㅇ", "ㅈ", "ㅉ", "ㅊ", "ㅋ", "ㅌ", "ㅍ", "ㅎ"
    ].compactMap { $0.unicodeScalars.first }

    private static let compatibilityValues: [UInt32: Int] = [
        0x3131: 0, 0x3132: 1, 0x3134: 2, 0x3137: 3, 0x3138: 4,
        0x3139: 5, 0x3141: 6, 0x3142: 7, 0x3143: 8, 0x3145: 9,
        0x3146: 10, 0x3147: 11, 0x3148: 12, 0x3149: 13,
        0x314A: 14, 0x314B: 15, 0x314C: 16, 0x314D: 17, 0x314E: 18
    ]

    static func queryPlan(for text: String) -> SmartSearchQueryPlan {
        // Trim, preserve current localized word boundaries, split supported
        // initial runs from literal runs inside each token, fold literal runs,
        // and omit empty runs while preserving clause order.
    }

    static func canonicalInitial(for scalar: Unicode.Scalar) -> Unicode.Scalar? {
        if let index = compatibilityValues[scalar.value] { return compatibilityScalars[index] }
        guard (0x1100...0x1112).contains(scalar.value) else { return nil }
        return compatibilityScalars[Int(scalar.value - 0x1100)]
    }
}
```

Implement the query scanner without regular expressions. Literal folding must use the same NFC plus case/diacritic-insensitive Foundation behavior as `SmartSearchRanker.tokens(in:)`.

- [ ] **Step 4: Run RED-to-GREEN verification**

Run the focused suite again. Expected: all Task 1 tests pass and the unsupported `ㄳ` case remains literal.

- [ ] **Step 5: Commit Task 1**

```bash
git add Sources/BloomFileManager/Models/SmartSearchTextAnalyzer.swift Tests/BloomFileManagerTests/SmartSearchTextAnalyzerTests.swift
git commit -m "feat: plan Korean initial search queries"
```

### Task 2: Document projections and shared match evidence

**Files:**
- Modify: `Sources/BloomFileManager/Models/SmartSearchTextAnalyzer.swift`
- Modify: `Tests/BloomFileManagerTests/SmartSearchTextAnalyzerTests.swift`

**Interfaces:**
- Consumes: `SmartSearchQueryPlan` from Task 1.
- Produces: `SmartSearchDocumentFeatures`, `SmartSearchInitialEvidence`, `documentFeatures(for:includeInitials:analysisStep:)`, `matches(_:path:)`, `bestInitialEvidence(for:filename:path:)`, and `initialEvidence(for:filename:path:)`.

- [ ] **Step 1: Add failing projection and false-positive tests**

Add literal fixtures with hand-derived expected values:

```swift
@Test func projectsNFCAndNFDHangulIntoTheSameInitialRuns() throws {
    let nfc = try SmartSearchTextAnalyzer.documentFeatures(for: "한국-드라이브", includeInitials: true)
    let nfd = try SmartSearchTextAnalyzer.documentFeatures(
        for: "한국-드라이브".decomposedStringWithCanonicalMapping,
        includeInitials: true
    )
    #expect(nfc.syllableInitialRuns == ["ㅎㄱ", "ㄷㄹㅇㅂ"])
    #expect(nfd.syllableInitialRuns == nfc.syllableInitialRuns)
    #expect(nfc.runHeadGroups == ["ㅎㄷ"])
}

@Test func runHeadsUseExplicitSegmentAndNonHangulBreakRules() throws {
    #expect(try features("구글(드라이브)").runHeadGroups == ["ㄱㄷ"])
    #expect(try features("구글/드라이브").runHeadGroups == ["ㄱㄷ"])
    #expect(try features("구글/2026/드라이브").runHeadGroups == ["ㄱ", "ㄷ"])
    #expect(try features("구글Drive드라이브").runHeadGroups == ["ㄱ"])
}

@Test func matchesConsecutiveInitialsButRejectsArbitrarySubsequences() throws {
    let compact = try features("한국.txt")
    let wordHeads = try features("구글 드라이브")
    let skipped = try features("개인 사진 다운로드")
    #expect(SmartSearchTextAnalyzer.matchesInitials("ㅎㄱ", in: compact))
    #expect(SmartSearchTextAnalyzer.matchesInitials("ㄱㄷ", in: wordHeads))
    #expect(!SmartSearchTextAnalyzer.matchesInitials("ㄱㄷ", in: skipped))
}

@Test func explicitInitialFilenameGetsLiteralEvidence() throws {
    let evidence = try SmartSearchTextAnalyzer.bestInitialEvidence(
        for: "ㅎㄱ", filename: features("ㅎㄱ.txt"), path: features("folder/ㅎㄱ.txt")
    )
    #expect(evidence?.field == .filename)
    #expect(evidence?.representation == .explicitLiteral)
}
```

- [ ] **Step 2: Run the focused suite and verify RED**

Expected: missing feature/evidence types and functions.

- [ ] **Step 3: Implement projections and evidence**

Add these exact value-type boundaries:

```swift
struct SmartSearchDocumentFeatures: Equatable, Sendable {
    let foldedText: String
    let literalTokens: [String]
    let explicitInitialRuns: [String]
    let syllableInitialRuns: [String]
    let runHeadGroups: [String]
    let initialCount: Int
}

enum SmartSearchMatchField: Int, Comparable, Sendable {
    case path = 1, filename = 2
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}
enum SmartSearchMatchRepresentation: Int, Comparable, Sendable {
    case runHead = 1, syllable = 2, explicitLiteral = 3
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}
enum SmartSearchMatchRelation: Int, Comparable, Sendable {
    case contains = 1, prefix = 2, exact = 3
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct SmartSearchInitialEvidence: Equatable, Comparable, Sendable {
    let field: SmartSearchMatchField
    let representation: SmartSearchMatchRepresentation
    let relation: SmartSearchMatchRelation
    let occurrenceCount: Double
    // Comparable checks field, representation, relation in that order.
}
```

Use NFC text and Unicode scalar arithmetic for `U+AC00...U+D7A3`. Use `CharacterSet.alphanumerics` to build maximal segments. A non-Hangul segment flushes the current run-head group. Explicit initial runs receive `.explicitLiteral` evidence before derived runs are considered. The path literal matcher remains `foldedText.contains(literalClause)`.

Use these exact match signatures. `initialEvidence` returns `nil` if any AND clause fails; otherwise its array has one evidence value per initial clause in plan order:

```swift
static func matches(_ plan: SmartSearchQueryPlan, path: SmartSearchDocumentFeatures) -> Bool
static func bestInitialEvidence(
    for initials: String,
    filename: SmartSearchDocumentFeatures,
    path: SmartSearchDocumentFeatures
) -> SmartSearchInitialEvidence?
static func initialEvidence(
    for plan: SmartSearchQueryPlan,
    filename: SmartSearchDocumentFeatures,
    path: SmartSearchDocumentFeatures
) -> [SmartSearchInitialEvidence]?
```

Add this test helper below the suite so every fixture requests initial projections explicitly:

```swift
private func features(_ text: String) throws -> SmartSearchDocumentFeatures {
    try SmartSearchTextAnalyzer.documentFeatures(for: text, includeInitials: true)
}
```

- [ ] **Step 4: Add and pass linear-work instrumentation test**

Pass `analysisStep` once per analyzed scalar. Use a lock-protected counter and assert that analyzing a doubled string uses no more than `2 * singleCount + 2` steps. Do not assert wall-clock time.

- [ ] **Step 5: Run Task 1 and Task 2 tests and commit**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --no-parallel --filter SmartSearchTextAnalyzerTests
git add Sources/BloomFileManager/Models/SmartSearchTextAnalyzer.swift Tests/BloomFileManagerTests/SmartSearchTextAnalyzerTests.swift
git commit -m "feat: analyze Korean initial search documents"
```

### Task 3: Use one query plan for recursive candidate filtering

**Files:**
- Modify: `Sources/BloomFileManager/Services/SmartSearchService.swift`
- Modify: `Sources/BloomFileManager/Models/SmartSearchModels.swift`
- Modify: `Tests/BloomFileManagerTests/SmartSearchServiceTests.swift`

**Interfaces:**
- Consumes: analyzer plan/features from Tasks 1-2.
- Produces: internal `PreparedSmartSearchCandidate` and a service candidate path that accepts `SmartSearchQueryPlan`.

- [ ] **Step 1: Add failing service tests with real temporary files**

Create files `한국.txt`, `한글.md`, `구글 드라이브.pdf`, `개인 사진 다운로드.txt`, and `2026-한국-report.txt`. Use the existing `service()`, `query(_:roots:)`, and `write(_:to:)` helpers and assert:

```swift
let koreanNames = try await service().search(query("ㅎㄱ", roots: [fixture.url], includeDirectories: false)).map(\.item.name)
let driveNames = try await service().search(query("ㄱㄷ", roots: [fixture.url], includeDirectories: false)).map(\.item.name)
let mixedNames = try await service().search(query("2026ㅎㄱ report", roots: [fixture.url], includeDirectories: false)).map(\.item.name)

#expect(koreanNames.contains("한국.txt"))
#expect(koreanNames.contains("한글.md"))
#expect(driveNames.contains("구글 드라이브.pdf"))
#expect(!driveNames.contains("개인 사진 다운로드.txt"))
#expect(mixedNames == ["2026-한국-report.txt"])
```

Also create `ㅎㄱ.txt` and verify it is included, and retain existing hidden/package/symlink test fixtures unchanged.

- [ ] **Step 2: Run only the new service tests and verify RED**

Expected: result arrays omit Hangul-derived matches because the current service uses literal `contains`.

- [ ] **Step 3: Prepare and filter candidates with the analyzer**

Compile `let queryPlan = SmartSearchTextAnalyzer.queryPlan(for: query.text)` once in `search`. Pass it into every root traversal. For each eligible path:

```swift
let pathFeatures = try SmartSearchTextAnalyzer.documentFeatures(
    for: relativePath, includeInitials: queryPlan.containsHangulInitials,
    analysisStep: { try Task.checkCancellation() }
)
guard SmartSearchTextAnalyzer.matches(queryPlan, path: pathFeatures) else { continue }
let filenameFeatures = try SmartSearchTextAnalyzer.documentFeatures(
    for: url.lastPathComponent, includeInitials: queryPlan.containsHangulInitials,
    analysisStep: { try Task.checkCancellation() }
)
```

Request cloud availability only after the guard. Store both feature values beside the result in an internal `PreparedSmartSearchCandidate`. Keep path deduplication, candidate count, progress, and cancellation in their current positions.

- [ ] **Step 4: Preserve the public ranker wrapper**

Keep `SmartSearchRanker.ranked([SmartSearchResult], for:)` compiling. It may prepare features internally and delegate to a new prepared-candidate overload; no existing model test call site changes solely for API convenience.

- [ ] **Step 5: Run analyzer, service, cloud-policy, and cancellation tests**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --no-parallel --filter SmartSearchTextAnalyzerTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --no-parallel --filter SmartSearchServiceTests
```

Expected: all new Korean candidate tests and existing service safety tests pass.

- [ ] **Step 6: Commit Task 3**

```bash
git add Sources/BloomFileManager/Models/SmartSearchModels.swift Sources/BloomFileManager/Services/SmartSearchService.swift Tests/BloomFileManagerTests/SmartSearchServiceTests.swift
git commit -m "feat: match Korean initials in Smart Search"
```

### Task 4: Rank initial evidence without changing literal-only results

**Files:**
- Modify: `Sources/BloomFileManager/Models/SmartSearchModels.swift`
- Modify: `Sources/BloomFileManager/Models/SmartSearchTextAnalyzer.swift`
- Modify: `Tests/BloomFileManagerTests/SmartSearchModelTests.swift`

**Interfaces:**
- Consumes: `PreparedSmartSearchCandidate` and evidence values.
- Produces: cancellable prepared-candidate ranking with evidence-vector then relevance then path comparison.

- [ ] **Step 1: Add failing ranking-contract tests**

Use hand-built results and assert only observable order:

```swift
@Test func explicitInitialFilenameOutranksDerivedFilenameAndPathOnlyMatches() throws {
    let query = try SmartSearchQuery(text: "ㅎㄱ", roots: [URL(filePath: "/search/root")])
    let ranked = SmartSearchRanker.ranked([
        result(name: "한국.txt", path: "한국.txt"),
        result(name: "ㅎㄱ.txt", path: "ㅎㄱ.txt"),
        result(name: "notes.txt", path: "한국/notes.txt")
    ], for: query)
    #expect(ranked.map(\.item.name) == ["ㅎㄱ.txt", "한국.txt", "notes.txt"])
}

@Test func syllableExactOutranksPrefixContainsAndRunHead() throws {
    let query = try SmartSearchQuery(text: "ㅎㄱ", roots: [URL(filePath: "/search/root")])
    let ranked = SmartSearchRanker.ranked([
        result(name: "한국", path: "한국"),
        result(name: "한국어", path: "한국어"),
        result(name: "대한민국한국자료", path: "대한민국한국자료"),
        result(name: "하늘 구름", path: "하늘 구름")
    ], for: query)
    #expect(ranked.map(\.item.name) == ["한국", "한국어", "대한민국한국자료", "하늘 구름"])
}
```

Add a literal-only golden regression that records names and scores for the existing `report` and `Café 보고서` fixtures before production changes, then asserts exact equality afterward.

- [ ] **Step 2: Verify ranking tests fail for the intended order**

Expected: Korean candidates have equal/zero relevance and fall back to path order.

- [ ] **Step 3: Implement evidence-vector ordering**

For every initial clause, collect the best filename/path evidence. Sort each candidate's evidence list weakest-first. Compare candidate lists lexicographically, higher evidence first. Only when lists are equal compare combined relevance.

- [ ] **Step 4: Implement the virtual initial BM25 tie-break**

Reuse `k1 = 1.2`, `b = 0.75`, and the existing IDF formula. Use occurrence TF `1.0` for explicit/syllable runs and `0.5` for run heads, multiply filename TF by `3`, use supported-initial count as field length, and compute average length/document frequency across prepared candidates. Check cancellation during feature scoring, document-frequency calculation, and merge sort.

- [ ] **Step 5: Run RED-to-GREEN and mutation checks**

Temporarily reverse one evidence comparison and confirm the ranking test fails; restore it. Temporarily make `ㅎㄱ` literal-only and confirm the service/model tests fail; restore it. Then run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --no-parallel --filter SmartSearchModelTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --no-parallel --filter SmartSearchServiceTests
```

- [ ] **Step 6: Commit Task 4**

```bash
git add Sources/BloomFileManager/Models/SmartSearchModels.swift Sources/BloomFileManager/Models/SmartSearchTextAnalyzer.swift Tests/BloomFileManagerTests/SmartSearchModelTests.swift
git commit -m "feat: rank Korean initial search matches"
```

### Task 5: Explain automatic initial search in the native UI

**Files:**
- Modify: `Sources/BloomFileManager/Views/SmartSearchView.swift`
- Modify: `Tests/BloomFileManagerTests/SmartSearchPresentationTests.swift`

**Interfaces:**
- Produces: `SmartSearchPresentation.queryPrompt`, `initialSearchGuidance`, and `queryAccessibilityHint`.
- Consumes: no Store or persistence changes.

- [ ] **Step 1: Add failing presentation tests**

```swift
@Test func queryGuidanceExplainsAutomaticKoreanInitialSearch() {
    #expect(SmartSearchPresentation.queryPrompt == "Search names, paths, or Korean initials")
    #expect(SmartSearchPresentation.initialSearchGuidance == "Try Korean initials such as ㅎㄱ for 한국 or 한글.")
    #expect(SmartSearchPresentation.queryAccessibilityHint == "Korean initial searches are supported, for example ㅎㄱ.")
}
```

Keep the existing result accessibility-label assertion unchanged.

- [ ] **Step 2: Run the new presentation test and verify RED**

Expected: the three constants do not exist.

- [ ] **Step 3: Wire the tested copy into SwiftUI**

Use `SmartSearchPresentation.queryPrompt` as the `TextField` prompt, attach `.accessibilityHint(SmartSearchPresentation.queryAccessibilityHint)`, and use `initialSearchGuidance` as the idle-state detail. Do not add a toggle, badge, or persistent setting.

- [ ] **Step 4: Run presentation and Store tests**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --no-parallel --filter queryGuidanceExplainsAutomaticKoreanInitialSearch
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --no-parallel --filter SmartSearchStoreTests
```

- [ ] **Step 5: Commit Task 5**

```bash
git add Sources/BloomFileManager/Views/SmartSearchView.swift Tests/BloomFileManagerTests/SmartSearchPresentationTests.swift
git commit -m "feat: surface Korean initial search guidance"
```

### Task 6: Documentation and complete verification

**Files:**
- Modify: `README.md`
- Modify: `docs/verification/smart-search-checklist.md`

**Interfaces:**
- Consumes: completed behavior from Tasks 1-5.
- Produces: user-facing feature documentation and repeatable manual checks.

- [ ] **Step 1: Document exact search examples and boundaries**

Add examples `ㅎㄱ → 한국/한글`, `ㄱㄷ → 구글 드라이브`, mixed `2026ㅎㄱ report`, and state that arbitrary subsequences and full-text content search are not supported. Add checklist cases for compatibility/choseong input, Korean IME, Return submission, VoiceOver hint, light/dark appearance, and result navigation.

- [ ] **Step 2: Run focused Smart Search suites separately**

Run analyzer, model, service, Store, and presentation suites individually so an AppKit helper exit cannot hide later suites. Record exact test counts and failures.

- [ ] **Step 3: Run complete automated gates**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --no-parallel
git diff --check origin/feature/smart-search...HEAD
./script/package_release.sh --verify-contract
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -c release --arch arm64
```

If the full suite repeats a pre-existing macOS `kLSDataUnavailableErr` failure, rerun the exact failing test once, preserve the focused Smart Search evidence, and report the environmental failure without claiming a clean full suite.

- [ ] **Step 4: Perform Luna UI verification**

Build and launch the isolated app. In a temporary folder, verify `ㅎㄱ`, `ㄱㄷ`, `2026ㅎㄱ report`, and a non-match `ㄱㄷ` against `개인 사진 다운로드`. Check keyboard Return, cancellation, double-click navigation, VoiceOver query hint, window resizing, and light/dark appearance. Do not use private user folders or cloud materialization for fixtures.

- [ ] **Step 5: Commit documentation and evidence**

```bash
git add README.md docs/verification/smart-search-checklist.md
git commit -m "docs: verify Korean initial Smart Search"
```

- [ ] **Step 6: Hand the complete branch to Sol Max for implementation review**

Provide Sol Max the design path, this plan path, base commit `51ab956100bd03632705e07ddcd6ab6f8ee66ef8`, HEAD, complete diff package, focused/full test evidence, build evidence, and Luna UI-verification notes. Resolve every Critical or Important finding, rerun affected focused tests, and ask Sol Max for a scoped re-review.

## Plan self-review

- Every design requirement maps to a task: Unicode/query planning (1), projections and false-positive control (2), recursive matching (3), deterministic ranking and literal regression (4), UI/accessibility (5), and documentation/verification (6).
- Production interfaces are introduced before consumers and use the same names across tasks.
- Every production task begins with a failing behavior test and an explicit RED command.
- Literal-only compatibility, persistence stability, safety policies, bounded work, cancellation, and UI non-goals have explicit regression gates.
- No task adds indexing, fuzzy search, highlighting, a mode toggle, or a persistence migration.
- The plan contains no unresolved placeholder, deferred implementation instruction, or ambiguous match rule.
