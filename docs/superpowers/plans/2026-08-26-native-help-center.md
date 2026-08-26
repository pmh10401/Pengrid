# Native Help Center Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a searchable, offline, bilingual native Help window to Pengrid, opened from the standard Help menu with Command-?, while preserving strict network, accessibility, and release-claim boundaries.

**Architecture:** Immutable typed models feed a fixed bilingual catalog. `HelpCatalog` searches a combined Korean/English index with `SmartSearchTextAnalyzer`, while `HelpView` displays the chosen language. A closed destination enum owns every online URL. A singleton SwiftUI `Window` is opened by a small Help command and has no file, cloud-provider, or operation-service dependency.

**Tech Stack:** Swift 6.1, SwiftUI, SwiftPM, Swift Testing, SwiftUI `openURL`, and Pengrid `SmartSearchTextAnalyzer`.

**Spec:** `docs/superpowers/specs/2026-08-26-native-help-center-design.md`

## Global Constraints

- Work only in `/Users/mac/Documents/Pengrid/.worktrees/safe-operation-center` on `codex/help-center`; preserve unrelated history and user changes.
- Use `apply_patch` for source, test, and documentation edits.
- Follow RED-GREEN-REFACTOR. Run each new focused test and observe its expected failure before production edits.
- Run Swift commands with `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcrun swift ...` and `--enable-swift-testing --no-parallel` for tests.
- Keep help content as bundled typed Swift data. Do not add Markdown parsing, WebView, Apple Help Book, background indexing, or runtime network fetching.
- Search both languages regardless of display language. Preserve catalog order; do not rank or highlight matches in v1.
- Only `HelpExternalDestination` may create online URLs. Do not accept arbitrary URLs, paths, queries, or redirects.
- Help must not depend on file URLs, panes, bookmarks, File Provider, operations, or cloud services.
- Persist only an explicit language code. Query and selection remain local to the Help window.
- Accessibility IDs must never contain translations, queries, URLs, or filesystem paths.
- Update documentation only after code verification. Do not claim a new DMG or GitHub release.
- Record live VoiceOver, keyboard, singleton-window, or link-opening checks only if actually performed.

## File and Responsibility Map

| File | Responsibility | Output |
|---|---|---|
| `Models/HelpModels.swift` | Language, immutable values, copy, URL allowlist | Pure help types |
| `Support/HelpCatalog.swift` | Bilingual content, search, selection | Stable display topics |
| `Views/HelpView.swift` | Split UI, local state, link feedback | Accessible native window |
| `Support/PengridHelpCommands.swift` | Help menu and Command-? | Singleton scene request |
| `App/BloomFileManagerApp.swift` | Scene and command registration | App integration |
| `Support/AccessibilityIdentifiers.swift` | Stable Help IDs | UI automation contract |
| `HelpCatalogTests.swift` | Models, content, search tests | Behavioral evidence |
| `HelpPresentationTests.swift` | Native UI and wiring tests | Integration evidence |
| README/user guides/verification record | Verified user documentation | Bilingual guidance |

---

### Task 1: Add pure help types, language resolution, and URL allowlist

**Files:**

- Create: `Sources/BloomFileManager/Models/HelpModels.swift`
- Create: `Tests/BloomFileManagerTests/HelpCatalogTests.swift`

**Interfaces:**

```swift
enum HelpLanguage: String, CaseIterable, Sendable {
    case korean = "ko"
    case english = "en"
    static func resolve(storedCode: String, preferredLanguages: [String]) -> Self
}
enum HelpTopicID: String, CaseIterable, Sendable {
    case gettingStarted, dualPaneNavigation, search, fileOperations
    case archives, cloudLocations, shortcuts, troubleshooting
}
struct HelpSection: Equatable, Sendable {
    let heading: String
    let paragraphs: [String]
    let bulletItems: [String]
}
struct HelpShortcut: Equatable, Sendable { let keys: String; let action: String }
struct HelpTopic: Identifiable, Equatable, Sendable {
    let id: HelpTopicID
    let title: String
    let summary: String
    let sections: [HelpSection]
    let shortcuts: [HelpShortcut]
    let externalDestination: HelpExternalDestination?
}
enum HelpExternalDestination: String, CaseIterable, Sendable {
    case userGuide, releases
    func url(for language: HelpLanguage) -> URL
    func buttonTitle(for language: HelpLanguage) -> String
}
struct HelpPresentationCopy: Equatable, Sendable {
    let windowTitle: String
    let searchPrompt: String
    let languageLabel: String
    let noResultsTitle: String
    let noResultsMessage: String
    let clearSearch: String
    let openOnlineGuide: String
    let internetRequired: String
    let externalOpenFailedTitle: String
    let externalOpenFailedMessage: String
    static func value(for language: HelpLanguage) -> Self
}
```

- [ ] Add this failing suite:

```swift
import Foundation
import Testing
@testable import BloomFileManager

@Suite struct HelpCatalogTests {
    @Test func explicitLanguageWinsAndSystemFallbackIsDeterministic() {
        #expect(HelpLanguage.resolve(storedCode: "ko", preferredLanguages: ["en-US"]) == .korean)
        #expect(HelpLanguage.resolve(storedCode: "en", preferredLanguages: ["ko-KR"]) == .english)
        #expect(HelpLanguage.resolve(storedCode: "", preferredLanguages: ["ko-KR"]) == .korean)
        #expect(HelpLanguage.resolve(storedCode: "invalid", preferredLanguages: ["fr-FR"]) == .english)
        #expect(HelpLanguage.resolve(storedCode: "", preferredLanguages: []) == .english)
    }

    @Test func externalDestinationsAreExactAllowlistedHTTPSURLs() {
        #expect(HelpExternalDestination.userGuide.url(for: .english).absoluteString == "https://github.com/pmh10401/Pengrid/blob/main/docs/user-guide.md")
        #expect(HelpExternalDestination.userGuide.url(for: .korean).absoluteString == "https://github.com/pmh10401/Pengrid/blob/main/docs/user-guide.ko.md")
        #expect(HelpExternalDestination.releases.url(for: .english).absoluteString == "https://github.com/pmh10401/Pengrid/releases")
        for destination in HelpExternalDestination.allCases {
            for language in HelpLanguage.allCases {
                let url = destination.url(for: language)
                #expect(url.scheme == "https")
                #expect(url.host == "github.com")
                #expect(!destination.buttonTitle(for: language).isEmpty)
            }
        }
    }

    @Test func presentationCopyIsCompleteInBothLanguages() {
        for language in HelpLanguage.allCases {
            let copy = HelpPresentationCopy.value(for: language)
            #expect(!copy.windowTitle.isEmpty)
            #expect(!copy.searchPrompt.isEmpty)
            #expect(!copy.externalOpenFailedMessage.isEmpty)
        }
    }
}
```

- [ ] Run RED: `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcrun swift test --enable-swift-testing --no-parallel --filter HelpCatalogTests`.
  Expected: compilation fails because the new types do not exist.
- [ ] Implement the declarations. A valid stored raw value wins; otherwise only the first preferred language is inspected. `ko` or `ko-*` selects Korean; every malformed, empty, or other case selects English.
- [ ] Implement the three exact HTTPS URLs and localized destination-specific button titles without any arbitrary URL initializer.
- [ ] Add complete Korean and English presentation copy, including that online guides require internet.
- [ ] Run the same command for GREEN.
- [ ] Commit: `git add Sources/BloomFileManager/Models/HelpModels.swift Tests/BloomFileManagerTests/HelpCatalogTests.swift && git commit -m "feat: add typed Help models"`.

---

### Task 2: Build the complete bilingual eight-topic catalog

**Files:**

- Create: `Sources/BloomFileManager/Support/HelpCatalog.swift`
- Modify: `Tests/BloomFileManagerTests/HelpCatalogTests.swift`

**Interfaces:**

```swift
enum HelpCatalog {
    static func topics(for language: HelpLanguage) -> [HelpTopic]
    static func topic(id: HelpTopicID, language: HelpLanguage) -> HelpTopic?
}
```

- [ ] Add these failing tests:

```swift
@Test func catalogHasTheSameCompleteStableTopicSetInBothLanguages() throws {
    let expected = HelpTopicID.allCases
    for language in HelpLanguage.allCases {
        let topics = HelpCatalog.topics(for: language)
        #expect(topics.map(\.id) == expected)
        #expect(Set(topics.map(\.id)).count == expected.count)
        for topic in topics {
            #expect(!topic.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect(!topic.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect(!topic.sections.isEmpty)
            #expect(topic.sections.allSatisfy { !$0.heading.isEmpty && (!$0.paragraphs.isEmpty || !$0.bulletItems.isEmpty) })
            #expect(HelpCatalog.topic(id: topic.id, language: language) == topic)
        }
    }
}

@Test func catalogCoversApprovedProductCapabilities() {
    let ko = String(describing: HelpCatalog.topics(for: .korean))
    let en = String(describing: HelpCatalog.topics(for: .english)).lowercased()
    for term in ["듀얼", "초성", "작업 센터", "Undo", "암호", "Google Drive", "OneDrive", "개인정보"] { #expect(ko.contains(term)) }
    for term in ["dual", "initial", "operation center", "undo", "password", "google drive", "onedrive", "privacy"] { #expect(en.contains(term)) }
}

@Test func onlyRelevantTopicsExposeAllowlistedOnlineDestinations() throws {
    let topics = HelpCatalog.topics(for: .english)
    #expect(try #require(topics.first { $0.id == .gettingStarted }).externalDestination == .userGuide)
    #expect(try #require(topics.first { $0.id == .troubleshooting }).externalDestination == .releases)
    #expect(topics.filter { ![.gettingStarted, .troubleshooting].contains($0.id) }.allSatisfy { $0.externalDestination == nil })
}
```

- [ ] Run RED with `--filter HelpCatalogTests`; the missing catalog is the intended failure.
- [ ] Implement immutable arrays in `HelpTopicID.allCases` order. Every topic needs a summary and at least one useful section.
- [ ] Cover: starting/preview; dual panes/history/tabs/profiles/comparison/review-first sync; pane filter/Smart Search/optional Spotlight/Korean initials; Operation Center/conflicts/trash/verification/conservative Undo; currently documented formats/parallel progress/password ZIP/cancellation; File Provider Google Drive and OneDrive/manual locations/local availability/no OAuth claim; source-verified shortcuts; access prompts/provider availability/privacy/rejected browser open.
- [ ] Attach `.userGuide` only to Getting Started and `.releases` only to Troubleshooting. Reuse only shortcuts verified in current source/tests.
- [ ] Run GREEN with `--filter HelpCatalogTests`.
- [ ] Commit: `git add Sources/BloomFileManager/Support/HelpCatalog.swift Tests/BloomFileManagerTests/HelpCatalogTests.swift && git commit -m "feat: add bilingual Help catalog"`.

---

### Task 3: Add deterministic cross-language search and selection reconciliation

**Files:**

- Modify: `Sources/BloomFileManager/Support/HelpCatalog.swift`
- Modify: `Tests/BloomFileManagerTests/HelpCatalogTests.swift`

**Interfaces:**

```swift
extension HelpCatalog {
    static func search(_ query: String, displaying language: HelpLanguage) -> [HelpTopic]
    static func reconciledSelection(current: HelpTopicID?, results: [HelpTopic]) -> HelpTopicID?
}
```

- [ ] Add focused failing tests:

```swift
@Test func blankSearchReturnsEveryTopicInStableOrder() {
    #expect(HelpCatalog.search("  \n", displaying: .english).map(\.id) == HelpTopicID.allCases)
}

@Test func searchIndexesBothLanguagesAndReturnsDisplayLanguageCopy() throws {
    let englishUI = HelpCatalog.search("암호 보호", displaying: .english)
    #expect(englishUI.map(\.id) == [.archives])
    #expect(try #require(englishUI.first).title == HelpCatalog.topic(id: .archives, language: .english)?.title)
    let koreanUI = HelpCatalog.search("privacy", displaying: .korean)
    #expect(koreanUI.map(\.id) == [.troubleshooting])
    #expect(try #require(koreanUI.first).title == HelpCatalog.topic(id: .troubleshooting, language: .korean)?.title)
}

@Test func koreanInitialAndMixedQueriesReuseSmartSearchSemantics() {
    #expect(HelpCatalog.search("ㅇㅎ", displaying: .korean).map(\.id).contains(.archives))
    #expect(HelpCatalog.search("ㅇㄷ operation", displaying: .english).map(\.id) == [.fileOperations])
}

@Test func literalSearchUsesCaseAndDiacriticFolding() {
    #expect(HelpCatalog.search("CLOUD", displaying: .english).map(\.id).contains(.cloudLocations))
    #expect(HelpCatalog.search("prívacy", displaying: .english).map(\.id) == [.troubleshooting])
}

@Test func noMatchAndSelectionReconcileDeterministically() {
    #expect(HelpCatalog.search("definitely-no-such-help-topic", displaying: .english).isEmpty)
    let results = HelpCatalog.search("cloud", displaying: .english)
    #expect(HelpCatalog.reconciledSelection(current: .cloudLocations, results: results) == .cloudLocations)
    #expect(HelpCatalog.reconciledSelection(current: .archives, results: results) == results.first?.id)
    #expect(HelpCatalog.reconciledSelection(current: .archives, results: []) == nil)
}
```

- [ ] Run RED with `--filter HelpCatalogTests`; missing search APIs are the intended failure.
- [ ] Flatten both languages for each ID: title, summary, section headings/paragraphs/bullets, shortcut keys/actions, and destination raw value.
- [ ] For whitespace return all topics. Otherwise compile `SmartSearchTextAnalyzer.queryPlan(for:)`; a nonblank plan with zero clauses returns no results. Pass a stable title as `filename` and the combined bilingual text as `relativePath` to `match`.
- [ ] Filter in `HelpTopicID.allCases` order and map to the requested language. Do not sort by title or match quality.
- [ ] Preserve the current ID only while present; otherwise use `results.first?.id`.
- [ ] Run GREEN, then regression:

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --enable-swift-testing --no-parallel \
  --filter 'HelpCatalogTests|SmartSearchTextAnalyzerTests'
```

- [ ] Commit: `git add Sources/BloomFileManager/Support/HelpCatalog.swift Tests/BloomFileManagerTests/HelpCatalogTests.swift && git commit -m "feat: add searchable bilingual Help index"`.

---

### Task 4: Build the native accessible Help view

**Files:**

- Create: `Sources/BloomFileManager/Views/HelpView.swift`
- Modify: `Sources/BloomFileManager/Support/AccessibilityIdentifiers.swift`
- Modify: `Tests/BloomFileManagerTests/AccessibilityPresentationTests.swift`
- Create: `Tests/BloomFileManagerTests/HelpPresentationTests.swift`

**Accessibility interfaces:**

```swift
static let helpWindow = "help.window"
static let helpSearch = "help.search"
static let helpTopicList = "help.topicList"
static let helpDetail = "help.detail"
static let helpLanguage = "help.language"
static let helpNoResults = "help.noResults"
static let helpExternalError = "help.externalError"
static func helpTopic(_ id: HelpTopicID) -> String { "help.topic.\(id.rawValue)" }
```

- [ ] Add stable-ID expectations to `accessibilityIdentifiersRemainStable()`:

```swift
#expect(AccessibilityIdentifiers.helpWindow == "help.window")
#expect(AccessibilityIdentifiers.helpSearch == "help.search")
#expect(AccessibilityIdentifiers.helpTopicList == "help.topicList")
#expect(AccessibilityIdentifiers.helpDetail == "help.detail")
#expect(AccessibilityIdentifiers.helpLanguage == "help.language")
#expect(AccessibilityIdentifiers.helpNoResults == "help.noResults")
#expect(AccessibilityIdentifiers.helpExternalError == "help.externalError")
#expect(AccessibilityIdentifiers.helpTopic(.cloudLocations) == "help.topic.cloudLocations")
```

- [ ] Create `HelpPresentationTests.swift` with the same repository-relative `source(named:)` helper used by `AccessibilityPresentationTests`, then add:

```swift
import Foundation
import Testing
@testable import BloomFileManager

@Suite struct HelpPresentationTests {
    @Test func helpViewUsesNativeSplitNavigationAndNoWebContent() throws {
        let source = try source(named: "Views/HelpView.swift")
        #expect(source.contains("NavigationSplitView"))
        #expect(source.contains("@AppStorage"))
        #expect(source.contains("@Environment(\\.openURL)"))
        #expect(source.contains("HelpCatalog.search"))
        #expect(source.contains("HelpCatalog.reconciledSelection"))
        #expect(!source.contains("WebView"))
        #expect(!source.contains("WKWebView"))
        #expect(!source.contains("URLSession"))
    }

    @Test func helpViewExposesStableAccessibleRegions() throws {
        let source = try source(named: "Views/HelpView.swift")
        for id in ["helpWindow", "helpSearch", "helpTopicList", "helpDetail", "helpLanguage", "helpNoResults", "helpExternalError"] {
            #expect(source.contains("AccessibilityIdentifiers.\(id)"))
        }
        #expect(source.contains("AccessibilityIdentifiers.helpTopic(topic.id)"))
    }

    @Test func rejectedExternalOpenProducesBoundedLocalFeedback() throws {
        let source = try source(named: "Views/HelpView.swift")
        #expect(source.contains("case .discarded"))
        #expect(source.contains("externalOpenFailedMessage"))
        #expect(source.contains("externalErrorMessage"))
    }
}
```

- [ ] Run RED:

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --enable-swift-testing --no-parallel \
  --filter 'HelpPresentationTests|AccessibilityPresentationTests'
```

Expected: the view file and Help IDs are absent.

- [ ] Implement `HelpView` with exactly these persisted/local boundaries:

```swift
@AppStorage("pengrid.help.language") private var storedLanguageCode = ""
@State private var query = ""
@State private var selectedTopicID: HelpTopicID?
@State private var externalErrorMessage: String?
@Environment(\.openURL) private var openURL
```

- [ ] Resolve language from stored code and `Locale.preferredLanguages`. Picker writes only `ko` or `en`; do not persist the automatic fallback.
- [ ] Use `NavigationSplitView`: sidebar search, compact language Picker, precomputed result list; scrolling detail with headings, paragraphs, bullets, and shortcut rows.
- [ ] Reconcile selection on first appearance and query/language change. Keep topic ID across language changes. Empty results show a clear-search recovery and no stale detail.
- [ ] External buttons use `destination.buttonTitle(for:)`, show the internet note, and call only `destination.url(for:)`. `.discarded` sets localized bounded feedback; `.handled` and `.systemAction` are accepted.
- [ ] Apply all stable identifiers and `.frame(minWidth: 720, minHeight: 520)`. Never derive an ID from content or query.
- [ ] Use semantic SwiftUI text styles and system colors/materials only. Localize visible accessibility labels and hints from the displayed Help language; add no custom animation that would bypass Reduce Motion.
- [ ] Run GREEN with the focused command, then `--filter 'HelpCatalogTests|HelpPresentationTests|AccessibilityPresentationTests'`.
- [ ] Commit: `git add Sources/BloomFileManager/Views/HelpView.swift Sources/BloomFileManager/Support/AccessibilityIdentifiers.swift Tests/BloomFileManagerTests/AccessibilityPresentationTests.swift Tests/BloomFileManagerTests/HelpPresentationTests.swift && git commit -m "feat: add native Help interface"`.

---

### Task 5: Register the singleton Help scene and standard menu command

**Files:**

- Create: `Sources/BloomFileManager/Support/PengridHelpCommands.swift`
- Modify: `Sources/BloomFileManager/App/BloomFileManagerApp.swift`
- Modify: `Tests/BloomFileManagerTests/HelpPresentationTests.swift`

**Interfaces:**

```swift
enum PengridHelpScene { static let id = "pengrid-help" }
struct PengridHelpCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    var body: some Commands { /* standard Help group */ }
}
```

- [ ] Add failing source-contract tests:

```swift
@Test func helpCommandUsesStandardMenuShortcutAndSingletonSceneID() throws {
    let commands = try source(named: "Support/PengridHelpCommands.swift")
    #expect(commands.contains("CommandGroup(replacing: .help)"))
    #expect(commands.contains("Button(\"Pengrid Help\")"))
    #expect(commands.contains(".keyboardShortcut(\"?\", modifiers: .command)"))
    #expect(commands.components(separatedBy: ".keyboardShortcut(\"?\"").count - 1 == 1)
    #expect(commands.contains("openWindow(id: PengridHelpScene.id)"))
    #expect(commands.contains("static let id = \"pengrid-help\""))
}

@Test func appRegistersOneHelpWindowAndInstallsCommands() throws {
    let app = try source(named: "App/BloomFileManagerApp.swift")
    #expect(app.contains("Window(\"Pengrid Help\", id: PengridHelpScene.id)"))
    #expect(app.contains("HelpView()"))
    #expect(app.contains(".defaultSize(width: 860, height: 620)"))
    #expect(app.contains("PengridHelpCommands()"))
    #expect(!app.contains("WindowGroup(\"Pengrid Help\""))
}
```

- [ ] Run RED with `--filter HelpPresentationTests`; absent command/scene wiring is expected.
- [ ] Implement one `Pengrid Help` button in `CommandGroup(replacing: .help)`, with Command-? and `openWindow(id: PengridHelpScene.id)`.
- [ ] Add `PengridHelpCommands()` beside `WorkspaceCommands` in the main scene's command builder.
- [ ] Add after the main scene:

```swift
Window("Pengrid Help", id: PengridHelpScene.id) { HelpView() }
    .defaultSize(width: 860, height: 620)
```

- [ ] Run GREEN, then `--filter 'HelpCatalogTests|HelpPresentationTests|WorkspaceCommandTests|AccessibilityPresentationTests'`.
- [ ] Commit: `git add Sources/BloomFileManager/Support/PengridHelpCommands.swift Sources/BloomFileManager/App/BloomFileManagerApp.swift Tests/BloomFileManagerTests/HelpPresentationTests.swift && git commit -m "feat: wire Pengrid Help window"`.

---

### Task 6: Update bilingual product documentation after code verification

**Files:**

- Modify: `README.md`
- Modify: `README.ko.md`
- Modify: `docs/user-guide.md`
- Modify: `docs/user-guide.ko.md`
- Create: `docs/verification/2026-08-26-native-help-center.md`

- [ ] First run `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcrun swift test --enable-swift-testing --no-parallel --filter 'HelpCatalogTests|HelpPresentationTests|AccessibilityPresentationTests'` and retain the exact counts and duration.
- [ ] Add a short README feature bullet in both languages: Help > Pengrid Help or Command-?, bundled offline topics, Korean/English switch, and bilingual literal/initial search.
- [ ] Add equivalent detailed Help sections to both user guides covering:
  1. opening the window;
  2. selecting and searching topics;
  3. one Korean-initial and one mixed-query example;
  4. remembered explicit language selection;
  5. all eight topics;
  6. offline bundled content;
  7. internet-required GitHub guide/release buttons;
  8. no-result clear-search recovery.
- [ ] Do not mention a Naver blog draft. Do not alter version, published DMG, signing, notarization, or release claims.
- [ ] Create the verification record with `Scope`, `Automated Verification`, `Release Build`, `Manual Checks`, and `Known Boundaries`. Insert only observed results.
- [ ] State that online links leave Pengrid, require internet, and that this feature adds no runtime content fetch or OAuth.
- [ ] Check all local links in the four edited docs and verify the two guide destinations map to existing repository paths.
- [ ] Run `git diff --check`, then review only the four docs and verification record for Korean/English factual parity.
- [ ] Commit: `git add README.md README.ko.md docs/user-guide.md docs/user-guide.ko.md docs/verification/2026-08-26-native-help-center.md && git commit -m "docs: document native Help center"`.

---

### Task 7: Run full verification and record only observed manual evidence

**Files:**

- Modify only with actual results: `docs/verification/2026-08-26-native-help-center.md`

- [ ] Run the complete suite without skipping build:

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --enable-swift-testing --no-parallel
```

The pre-feature baseline was 1,931 tests in 123 suites. Record the new exact counts and duration, not the baseline.

- [ ] Build release configuration:

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift build -c release
```

- [ ] Launch via the repository's existing local bundle/run workflow. Do not package, install, push, merge, or publish in this task.
- [ ] Record PASS/FAIL/NOT RUN for every manual item:
  - Help > Pengrid Help opens one window.
  - Command-? opens or focuses the same window, without duplicates.
  - The UI works at 860×620 and its minimum size.
  - Korean/English switching preserves selection and persists after reopening.
  - English, Korean, Korean-initial, and mixed queries find expected topics.
  - No-results recovery clears the query.
  - Search, list, language, detail, and error regions are keyboard reachable and have meaningful VoiceOver text.
  - Light and Dark appearances remain readable, Dynamic Type text does not clip, and Reduce Motion introduces no unexpected animation.
  - Bundled topics remain visible offline.
  - An allowlisted link opens the exact GitHub target online; a rejected open shows bounded feedback.
- [ ] For a core failure, add a failing automated regression where practical, fix through RED-GREEN, rerun focused/full suites, and update evidence. Never close with a core failure.
- [ ] Run:

```bash
git diff --check
git status --short --branch
git log --oneline --decorate -8
```

- [ ] If actual results changed the verification record, commit: `git add docs/verification/2026-08-26-native-help-center.md && git commit -m "test: verify native Help center"`.
- [ ] Confirm the branch is clean and ahead of `origin/main` only by this feature's design, implementation, documentation, and verification commits.

## Completion Criteria

- [ ] Both languages expose exactly eight nonempty topics in identical ID order.
- [ ] Literal, case/diacritic-folded, Korean-initial, mixed, and cross-language searches preserve deterministic catalog order.
- [ ] The standard Help menu and Command-? open a singleton native window.
- [ ] Help has no file/cloud/operation dependency and performs no content fetch.
- [ ] Only exact allowlisted GitHub HTTPS destinations can leave the app.
- [ ] Language persistence, no-results recovery, rejected-link feedback, and stable accessibility IDs are covered.
- [ ] Focused tests, full tests, release build, docs checks, and actual manual results are recorded truthfully.
- [ ] No new release, DMG, signing, notarization, push, or merge claim appears.
