# Command Palette, Empty File, and Advanced Selection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> `superpowers:executing-plans` to implement this plan task by task. Every
> production change follows a focused failing test.

**Goal:** Add safe empty-file creation, visible-row advanced selection, and a
typed Command-P Quick Go palette without weakening Pengrid's filesystem,
modal, accessibility, or Undo guarantees.

**Architecture:** Pure selection and palette models sit outside SwiftUI. Empty
file creation reuses the identity-bound `FileOperationService` and Operation
Center. `WorkspaceView` owns one palette sheet; `WorkspaceCommands` presents a
snapshot built from existing commands, pane history, favorites, profiles, and
saved searches. A closed action enum is consumed only after sheet dismissal.

**Tech Stack:** Swift 6.1, SwiftUI, AppKit, Observation, SwiftPM, Swift Testing,
Pengrid `FileSystemAccess`, Operation Center, Smart Search text analysis, and
conservative Undo.

## Global Constraints

- Work only in
  `/Users/mac/Documents/Pengrid/.worktrees/safe-operation-center` on
  `codex/medium-file-manager-features` and preserve unrelated history.
- Use `apply_patch` for source, test, and documentation edits.
- Use the full Xcode toolchain for every Swift command:

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --enable-swift-testing --no-parallel
```

- Do not add shell execution, arbitrary closures, executable URLs, persistent
  palette queries, or background indexing.
- Never form user-visible ordering by enumerating `Set<URL>`.
- Selection commands operate on `visibleItems` and are disabled while the pane
  filter is presented.
- Empty-file creation must be exclusive, no-follow, parent-identity bound, and
  undoable only while identity and fingerprint match.
- Close every returned file descriptor exactly once on every path.
- A palette action is routed only after the palette sheet dismisses.
- Keep palette rows stable and prefilter results outside `ForEach`.
- Fail closed while another modal or text editor owns the scene.
- Full paths may help visually disambiguate local locations, but logs,
  accessibility status, and operation labels use only safe basenames/counts.
- Do not claim live VoiceOver or File Provider validation without manual
  evidence.

## Baseline

- [x] Fetch `origin/main`, create `codex/medium-file-manager-features`, and
  confirm the worktree is clean.
- [x] Run the official nonparallel baseline suite.
- [x] Record baseline result: 1,654 tests in 110 suites, 0 failures.
- [x] Record the pre-existing SwiftPM warning about 11 unhandled fixture files.

---

### Task 1: Add pure visible-row selection behavior

**Files:**

- Create: `Sources/BloomFileManager/Models/PaneSelectionActions.swift`
- Modify: `Sources/BloomFileManager/Stores/FilePaneState.swift`
- Create: `Tests/BloomFileManagerTests/PaneSelectionActionsTests.swift`
- Modify: `Tests/BloomFileManagerTests/FilePaneStateTests.swift`

**Interfaces:**

```swift
enum PaneSelectionActions {
    static func selectAll(visibleItems: [FileItem]) -> Set<URL>
    static func invert(current: Set<URL>, visibleItems: [FileItem]) -> Set<URL>
    static func matchingExtension(
        current: Set<URL>,
        visibleItems: [FileItem]
    ) -> Set<URL>?
}

extension FilePaneState {
    func selectAllVisible()
    func invertVisibleSelection()
    @discardableResult func selectVisibleItemsWithSameExtension() -> Bool
}
```

- [ ] Write failing pure-model tests for empty, partial, full, and hidden
  selection inversion.
- [ ] Write failing extension tests for case/diacritic folding, one anchor,
  directories, packages, dotfiles, extensionless files, and nonvisible anchors.
- [ ] Write failing pane-state tests that selection changes request table focus.
- [ ] Run the focused tests and confirm the intended failure.
- [ ] Implement the smallest pure functions and thin pane methods.
- [ ] Rerun:

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --enable-swift-testing --no-parallel \
  --filter 'PaneSelectionActionsTests|FilePaneStateTests'
```

---

### Task 2: Add exclusive, identity-bound empty-file creation

**Files:**

- Modify: `Sources/BloomFileManager/Models/FileOperationJobModels.swift`
- Modify: `Sources/BloomFileManager/Services/OperationLogger.swift`
- Modify: `Sources/BloomFileManager/Services/FileOperationService.swift`
- Modify: `Sources/BloomFileManager/Services/FileOperationUndoService.swift`
- Modify: `Tests/BloomFileManagerTests/FileOperationMutationTests.swift`
- Modify: `Tests/BloomFileManagerTests/FileOperationUndoServiceTests.swift`

**Interfaces:**

```swift
extension FileOperationService {
    func createFile(
        in directory: URL,
        identifiedBy directoryIdentity: FileIdentity,
        named name: String
    ) async throws -> IdentifiedCreatedFileRequest
}

extension FileOperationJobKind { /* case createFile */ }
extension FileOperationKind { /* case createFile */ }
```

- [ ] Add failing service tests for success, collision, invalid name, parent
  identity replacement, created-entry replacement, cancellation, descriptor
  closure, logging, and identity/fingerprint output.
- [ ] Add a failing Undo test proving an unchanged created file produces a
  `removeCreated` recipe while a modified or replaced file does not.
- [ ] Confirm focused RED output before editing production code.
- [ ] Implement `createFile` with `.regularFile`, a single descriptor close,
  identity revalidation, fingerprint capture, and bounded logging.
- [ ] Add truthful job/logger cases and include `.createFile` in conservative
  created-output Undo.
- [ ] Rerun:

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --enable-swift-testing --no-parallel \
  --filter 'FileOperationMutationTests|FileOperationUndoServiceTests'
```

---

### Task 3: Queue New Empty File and expose advanced-selection commands

**Files:**

- Modify: `Sources/BloomFileManager/Stores/FileOperationController.swift`
- Modify: `Sources/BloomFileManager/Support/WorkspaceCommands.swift`
- Modify: `Sources/BloomFileManager/Support/AccessibilityIdentifiers.swift`
- Modify: `Tests/BloomFileManagerTests/FileOperationControllerTests.swift`
- Modify: `Tests/BloomFileManagerTests/WorkspaceCommandTests.swift`

**Interfaces:**

```swift
extension FileOperationController {
    @discardableResult
    func createFile(
        in directory: URL,
        named name: String,
        workspace: WorkspaceState,
        beginInlineRenameIn pane: FilePaneState? = nil,
        onCompletion: (@MainActor (FileOperationResult) -> Void)? = nil
    ) async -> Bool
}

enum WorkspaceSelectionCommandActions { /* three active-pane routes */ }
struct WorkspaceSelectionCommandPolicy: Equatable { /* fail-closed gates */ }
```

- [ ] Add failing controller tests for job kind/title, result metadata, pane
  refresh, exact created-row selection, inline rename, failure, and
  cancellation.
- [ ] Add failing command policy/action tests for text editing, filtering,
  empty/single/multiple selection, and focus restoration.
- [ ] Confirm RED before implementation.
- [ ] Implement `WorkspaceCommandActions.createFile`, choosing `New File` with
  `KeepBothNamer` from loaded sibling names.
- [ ] Add New Empty File to the new-item menu with Option-Command-N.
- [ ] Add the three selection commands to the Edit command group with the
  approved shortcuts and accessibility identifiers.
- [ ] Rerun:

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --enable-swift-testing --no-parallel \
  --filter 'FileOperationControllerTests|WorkspaceCommandTests'
```

---

### Task 4: Build typed palette models, matching, and store lifecycle

**Files:**

- Create: `Sources/BloomFileManager/Models/CommandPaletteModels.swift`
- Create: `Sources/BloomFileManager/Stores/CommandPaletteStore.swift`
- Create: `Sources/BloomFileManager/Support/CommandPaletteBuilder.swift`
- Create: `Tests/BloomFileManagerTests/CommandPaletteModelsTests.swift`
- Create: `Tests/BloomFileManagerTests/CommandPaletteStoreTests.swift`
- Create: `Tests/BloomFileManagerTests/CommandPaletteBuilderTests.swift`

**Interfaces:**

```swift
enum CommandPaletteAction: Hashable, Sendable {
    case createFolder
    case createFile
    case showFilter
    case showSmartSearch
    case navigate(URL)
    case openProfile(WorkspaceProfileID)
    case openSavedSearch(UUID)
}

struct CommandPaletteItem: Identifiable, Equatable, Sendable { /* stable ID */ }
enum CommandPaletteMatcher { static func ranked(...) -> [CommandPaletteItem] }

@MainActor @Observable
final class CommandPaletteStore {
    func present(items: [CommandPaletteItem])
    func requestExecution(itemID: String)
    func dismiss()
    func takePendingAction() -> CommandPaletteAction?
}
```

- [ ] Write failing matcher tests for empty query, exact/prefix/substring,
  normalized case/diacritics/width, subsequence, Hangul initials, and stable
  ties.
- [ ] Write failing builder tests for stable IDs, source priority, standardized
  path deduplication, unavailable favorites, profiles, and saved searches.
- [ ] Write failing store tests for presentation reset, first selection,
  query/result updates, explicit dismissal, one-shot pending action, and stale
  item rejection.
- [ ] Confirm RED, then implement models and pure ranking without inline view
  filtering.
- [ ] Implement presentation-time builder without filesystem crawl or content
  materialization.
- [ ] Rerun:

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --enable-swift-testing --no-parallel \
  --filter 'CommandPaletteModelsTests|CommandPaletteStoreTests|CommandPaletteBuilderTests'
```

---

### Task 5: Add the accessible palette sheet and modal ownership

**Files:**

- Create: `Sources/BloomFileManager/Views/CommandPaletteView.swift`
- Modify: `Sources/BloomFileManager/Views/WorkspaceView.swift`
- Modify: `Sources/BloomFileManager/Views/WorkspaceTabBarView.swift`
- Modify: `Sources/BloomFileManager/Support/WorkspaceCommands.swift`
- Modify: `Sources/BloomFileManager/App/BloomFileManagerApp.swift`
- Modify: `Sources/BloomFileManager/Support/AccessibilityIdentifiers.swift`
- Create: `Tests/BloomFileManagerTests/CommandPalettePresentationTests.swift`
- Modify: `Tests/BloomFileManagerTests/WorkspaceTabPresentationTests.swift`
- Modify: `Tests/BloomFileManagerTests/WorkspaceCommandTests.swift`

- [ ] Add failing source/presentation tests for a labelled query field, stable
  row IDs, Button semantics, default focus, Return, Escape, empty state,
  Command-P, and accessibility identifiers.
- [ ] Extend modal-policy tests so the palette blocks tab/profile mutations and
  is mutually exclusive with every existing sheet/alert.
- [ ] Add failing action-routing tests for navigation, profile, saved search,
  file/folder creation, filter, Smart Search, deleted IDs, and one-shot
  execution after dismissal.
- [ ] Confirm RED before adding the sheet.
- [ ] Implement `CommandPaletteView` with private focus state,
  `List(selection:)`, real Buttons, and `ContentUnavailableView.search`.
- [ ] Add `CommandPaletteStore` to app state and pass it with favorites into
  `WorkspaceView` and `WorkspaceCommands`.
- [ ] Add **Quick Go…** to the Go menu with Command-P and replace the unused
  standard Print command group to avoid shortcut ambiguity.
- [ ] Present only when no modal/text editor owns the scene. Consume and route
  the pending typed action from sheet `onDismiss`; restore table focus after a
  plain cancel.
- [ ] Include palette dismissal in workspace teardown and the modal aggregate.
- [ ] Rerun:

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --enable-swift-testing --no-parallel \
  --filter 'CommandPalette|WorkspaceTabPresentationTests|WorkspaceCommandTests'
```

---

### Task 6: Document the new workflows and source inspiration

**Files:**

- Modify: `README.md`
- Modify: `README.ko.md`
- Modify: `docs/user-guide.md`
- Modify: `docs/user-guide.ko.md`
- Modify: `docs/current-limitations.md`
- Modify: `docs/current-limitations.ko.md`

- [ ] Add concise feature entries and exact shortcuts in both languages.
- [ ] Explain that advanced selection targets only visible unfiltered rows.
- [ ] Explain that New Empty File begins inline rename and uses conservative
  Undo.
- [ ] Explain palette candidate sources and Hangul-initial support.
- [ ] Keep byte-level transfer verification and Finder tag editing listed as
  future work, not shipped behavior.
- [ ] Credit behavior inspiration with links to the public repositories; do not
  claim copied code or license compatibility beyond behavior study.
- [ ] Run documentation consistency searches for old shortcuts and conflicting
  feature claims.

---

### Task 7: Full verification and review

- [ ] Run `git diff --check`.
- [ ] Run the complete test target:

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --enable-swift-testing --no-parallel \
  --filter BloomFileManagerTests
```

- [ ] Run a release build:

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift build -c release
```

- [ ] Compare warnings with the recorded baseline and investigate every new
  warning.
- [ ] Ask a fresh read-only reviewer to inspect the final diff for filesystem
  safety, modal races, focus/accessibility, stable identity, and test gaps.
- [ ] Attempt the configured OpenRouter read-only reviewer; if the provider is
  unavailable, record the exact failure and rely on the internal independent
  review rather than presenting an absent result as evidence.
- [ ] Apply justified findings, rerun affected focused tests, then rerun the
  full suite if production code changed.
- [ ] Record changed files, exact test/build evidence, known manual-validation
  gaps, and the separate deferred tag/transfer-verification slices.

