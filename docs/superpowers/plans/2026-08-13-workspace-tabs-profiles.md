# Workspace Tabs and Profiles Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add multiple restorable dual-pane workspace tabs and named reusable folder-pair profiles without persisting volatile selection, operation, or preview state.

**Architecture:** Keep `WorkspaceState` as one dual-pane runtime. A new session owner creates and orders child workspaces through a runtime factory, receives committed descriptors through a callback, and persists a versioned v2 envelope with v1 migration. App/view/command wiring follows only after the session core is independently green.

**Tech Stack:** Swift 6.1, Observation, SwiftUI/AppKit, UserDefaults/JSON Codable, Swift Testing, macOS 15, existing `WorkspaceState`, `FilePaneState`, `WorkspacePersistence`, listing, and monitor APIs.

## Global Constraints

- Prefix Swift verification commands with `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun`.
- `WorkspaceState` remains exactly one left/right dual-pane runtime; it never owns a recursive collection of workspaces.
- Persist paths, sorts, split ratio, and active-pane identity only; never persist selection, filters, history, scroll, preview, comparison, sync review, operation history, or Undo/Redo.
- Use the new UserDefaults key `workspace.session.v2`; preserve `workspace.snapshot.v1` and never delete it.
- Load v2 first; migrate valid v1 to one tab only when v2 is absent; repair each invalid pane independently.
- An empty or malformed session always restores one Home/Downloads tab and a deterministic active ID.
- Profile names are trimmed, nonempty, and unique under case/diacritic-insensitive comparison.
- Opening a profile creates a new tab and never silently mutates the active tab.
- The last tab cannot close; a tab with active or queued bound work cannot close.
- Shared app/view/command files are integration-owner-only until Get Info and Spotlight wiring lands.
- Follow RED → observed expected failure → minimal GREEN → focused pass for every production behavior.

---

### Task 1: Versioned session/profile models and v1 migration

**Files:**
- Create: `Sources/BloomFileManager/Models/WorkspaceSessionModels.swift`
- Create: `Sources/BloomFileManager/Stores/WorkspaceSessionPersistence.swift`
- Create: `Tests/BloomFileManagerTests/WorkspaceSessionModelsTests.swift`
- Create: `Tests/BloomFileManagerTests/WorkspaceSessionPersistenceTests.swift`

**Interfaces:**
- Consumes: `WorkspaceSnapshot`, `FileSort`, and Foundation URL/UserDefaults.
- Produces: `WorkspaceTabID`, `WorkspaceProfileID`, `WorkspaceDescriptor`, `WorkspaceTabRecord`, `WorkspaceProfileRecord`, `WorkspaceSessionEnvelope`, `RestoredWorkspaceSession`, and `WorkspaceSessionPersistence`.

- [ ] **Step 1: Add failing literal model tests**

```swift
@Test func profileNameValidationIsTrimmedAndComparisonUnique() throws {
    let profile = try WorkspaceProfileRecord(
        name: "  Work  ",
        descriptor: .fixture(left: "/Work/Source", right: "/Work/Build")
    )
    #expect(profile.name == "Work")
    #expect(WorkspaceProfileRecord.normalizedNameKey("Wórk") == WorkspaceProfileRecord.normalizedNameKey("work"))
}

@Test func envelopeRepairsUnknownActiveIDToFirstTab() throws {
    let first = WorkspaceTabRecord(descriptor: .fixture(left: "/A", right: "/B"))
    let envelope = WorkspaceSessionEnvelope(
        tabs: [first],
        activeTabID: WorkspaceTabID(),
        profiles: []
    )
    #expect(envelope.repairedActiveTabID == first.id)
}
```

- [ ] **Step 2: Run model tests and verify RED**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --enable-swift-testing --no-parallel --filter WorkspaceSessionModelsTests
```

Expected: compilation fails because session/profile models do not exist.

- [ ] **Step 3: Implement immutable models**

Use these public shapes:

```swift
struct WorkspaceTabID: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: UUID
    init(rawValue: UUID) { self.rawValue = rawValue }
    init() { self.init(rawValue: UUID()) }
}

struct WorkspaceProfileID: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: UUID
    init(rawValue: UUID) { self.rawValue = rawValue }
    init() { self.init(rawValue: UUID()) }
}

enum WorkspacePersistedPane: String, Codable, Equatable, Sendable {
    case left, right
}

struct WorkspaceDescriptor: Codable, Equatable, Sendable {
    var leftPath: String
    var rightPath: String
    var leftSort: FileSort
    var rightSort: FileSort
    var splitRatio: Double
    var activePane: WorkspacePersistedPane
}

struct WorkspaceSessionEnvelope: Codable, Equatable, Sendable {
    static let schemaVersion = 2
    let version: Int
    var tabs: [WorkspaceTabRecord]
    var activeTabID: WorkspaceTabID
    var profiles: [WorkspaceProfileRecord]
}
```

Initializers validate absolute paths, clamp split ratio through `WorkspaceSplitRatio`,
normalize names, preserve tab/profile order, and reject duplicate IDs or normalized
profile names with typed `WorkspaceSessionValidationError` values.

- [ ] **Step 4: Add failing persistence and migration tests**

Use isolated `UserDefaults(suiteName:)` values and hand-authored JSON to cover:

```swift
@Test func v2RoundTripPreservesOrderDescriptorsAndActiveTab() throws
@Test func v1MigratesToOneTabWhenV2IsAbsent() throws
@Test func existingV2WinsWithoutRewritingV1() throws
@Test func malformedV2FallsBackWithoutDeletingV1() throws
@Test func restoreRepairsEachInvalidPaneIndependently() throws
@Test func emptyTabsRestoreOneHomeDownloadsTab() throws
```

- [ ] **Step 5: Run persistence tests and verify RED**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --enable-swift-testing --no-parallel --filter WorkspaceSessionPersistenceTests
```

Expected: compilation fails because `WorkspaceSessionPersistence` and restoration APIs do not exist.

- [ ] **Step 6: Implement v2 persistence and v1 migration**

```swift
final class WorkspaceSessionPersistence: @unchecked Sendable {
    static let storageKey = "workspace.session.v2"

    init(defaults: UserDefaults = .standard)
    func load() -> WorkspaceSessionEnvelope?
    func save(_ envelope: WorkspaceSessionEnvelope) -> Bool
    func restore(
        legacy: WorkspaceSnapshot?,
        home: URL,
        downloads: URL,
        isDirectory: (URL) -> Bool
    ) -> RestoredWorkspaceSession
}
```

Encode to local `Data` before `defaults.set`. Decode/validate v2 first. If v2 is absent,
map the supplied legacy snapshot to one tab after per-pane validation. If v2 is malformed,
use one repaired default tab without overwriting either key. Use the same non-finite ratio
encoding/decoding strategy as `WorkspacePersistence`.

- [ ] **Step 7: Run Task 1 tests and verify GREEN**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --enable-swift-testing --no-parallel --filter 'WorkspaceSessionModelsTests|WorkspaceSessionPersistenceTests|WorkspacePersistenceTests'
git diff --check
```

Require zero failures.

- [ ] **Step 8: Commit Task 1**

```bash
git add Sources/BloomFileManager/Models/WorkspaceSessionModels.swift Sources/BloomFileManager/Stores/WorkspaceSessionPersistence.swift Tests/BloomFileManagerTests/WorkspaceSessionModelsTests.swift Tests/BloomFileManagerTests/WorkspaceSessionPersistenceTests.swift
git commit -m "feat: add workspace session persistence"
```

### Task 2: Runtime factory and tab/profile session state

**Files:**
- Create: `Sources/BloomFileManager/Support/WorkspaceRuntimeFactory.swift`
- Create: `Sources/BloomFileManager/Stores/WorkspaceSessionState.swift`
- Modify: `Sources/BloomFileManager/Stores/WorkspaceState.swift`
- Create: `Tests/BloomFileManagerTests/WorkspaceSessionStateTests.swift`
- Modify: `Tests/BloomFileManagerTests/WorkspaceStateTests.swift`

**Interfaces:**
- Consumes: restored session records and existing listing/monitor factories.
- Produces: `WorkspaceRuntimeCreating`, `WorkspaceTabRuntime`, and observable `WorkspaceSessionState`.

- [ ] **Step 1: Add failing runtime/session tests**

```swift
@Test func newTabCopiesDescriptorButOwnsIndependentRuntimeState() async throws
@Test func profileOpenCreatesANewTabAndLeavesCurrentRuntimeUntouched() async throws
@Test func childDescriptorChangesPersistOnlyTheirOwningTab() async throws
@Test func closeSelectsNextThenPreviousAndRefusesTheLastTab() async throws
@Test func closeGateRefusesATabWithBoundActiveOrQueuedWork() async throws
@Test func renameAndDeleteProfilesPreserveOpenTabs() async throws
@Test func flushPersistsEveryChildCommittedDescriptor() async throws
```

- [ ] **Step 2: Run tests and verify RED**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --enable-swift-testing --no-parallel --filter 'WorkspaceSessionStateTests|WorkspaceStateTests'
```

Expected: compilation fails for missing runtime/session APIs.

- [ ] **Step 3: Add an owner-neutral WorkspaceState descriptor callback**

Extend `WorkspaceState.init` with:

```swift
descriptorDidChange: (@MainActor @Sendable (WorkspaceSnapshot) -> Void)? = nil
```

`saveWorkspaceSnapshot()` builds one snapshot, saves through legacy persistence when
present, and invokes the callback. Existing initializers and behavior remain source
compatible. Add `currentSnapshot()` and make `flushPendingPersistence()` invoke the
callback after draining its divider debounce.

- [ ] **Step 4: Implement the factory and session owner**

```swift
@MainActor protocol WorkspaceRuntimeCreating {
    func makeRuntime(
        id: WorkspaceTabID,
        descriptor: WorkspaceDescriptor,
        descriptorDidChange: @escaping @MainActor @Sendable (WorkspaceSnapshot) -> Void
    ) -> WorkspaceState
}

@MainActor @Observable final class WorkspaceSessionState {
    private(set) var tabs: [WorkspaceTabRuntime]
    private(set) var activeTabID: WorkspaceTabID
    private(set) var profiles: [WorkspaceProfileRecord]
    var activeWorkspace: WorkspaceState {
        tabs.first(where: { $0.id == activeTabID })!.workspace
    }

    func newTab() -> WorkspaceTabID
    func openProfile(_ id: WorkspaceProfileID) -> WorkspaceTabID?
    func closeTab(_ id: WorkspaceTabID, canClose: (WorkspaceTabID) -> Bool) -> Bool
    func selectTab(_ id: WorkspaceTabID) -> Bool
    func saveActiveProfile(named: String) throws -> WorkspaceProfileID
    func renameProfile(_ id: WorkspaceProfileID, to: String) throws
    func deleteProfile(_ id: WorkspaceProfileID) -> Bool
    func flushPersistence()
}
```

Route descriptor callbacks by stable tab ID. Save v2 after every structural/profile
mutation and debounce descriptor-only changes by 300 ms. Do not copy runtime objects
when creating/opening tabs.

- [ ] **Step 5: Run Task 2 tests and verify GREEN**

Run the Step 2 command and `git diff --check`; require zero failures.

- [ ] **Step 6: Commit Task 2**

```bash
git add Sources/BloomFileManager/Support/WorkspaceRuntimeFactory.swift Sources/BloomFileManager/Stores/WorkspaceSessionState.swift Sources/BloomFileManager/Stores/WorkspaceState.swift Tests/BloomFileManagerTests/WorkspaceSessionStateTests.swift Tests/BloomFileManagerTests/WorkspaceStateTests.swift
git commit -m "feat: add workspace tab session state"
```

### Task 3: Tab bar, profiles, lifecycle, commands, and app composition

**Files:**
- Create: `Sources/BloomFileManager/Views/WorkspaceTabBarView.swift`
- Create: `Sources/BloomFileManager/Views/WorkspaceProfilesView.swift`
- Modify: `Sources/BloomFileManager/App/BloomFileManagerApp.swift`
- Modify: `Sources/BloomFileManager/Views/WorkspaceView.swift`
- Modify: `Sources/BloomFileManager/Support/WorkspaceCommands.swift`
- Create: `Sources/BloomFileManager/Support/WorkspaceSessionAccessibilityIdentifiers.swift`
- Create: `Tests/BloomFileManagerTests/WorkspaceTabPresentationTests.swift`
- Modify: `Tests/BloomFileManagerTests/WorkspaceCommandTests.swift`
- Modify: `Tests/BloomFileManagerTests/AccessibilityPresentationTests.swift`
- Modify: `README.md`
- Modify: `README.ko.md`
- Modify: `docs/user-guide.md`
- Modify: `docs/user-guide.ko.md`

**Interfaces:**
- Consumes: `WorkspaceSessionState` and application-owned coordinators.
- Produces: visible tab/profile UI, lifecycle teardown, restoration, and shortcuts.

- [ ] **Step 1: Add failing presentation/lifecycle tests**

Cover accessible active tab labels, basename-only titles, New/Close/Next/Previous
commands and exact shortcuts, close gating for bound jobs, and teardown calls for
comparison, storage, preview, editing, pending Trash, and synchronization review.

- [ ] **Step 2: Run focused integration tests and verify RED**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --enable-swift-testing --no-parallel --filter 'WorkspaceTabPresentationTests|WorkspaceCommandTests|AccessibilityPresentationTests'
```

- [ ] **Step 3: Integrate one shared session and render the active runtime**

The app restores `WorkspaceSessionState` once and passes it to both scene content and
commands. `WorkspaceView` derives the active child workspace, renders
`WorkspaceTabBarView` above the existing split, loads a newly selected runtime exactly
once, and flushes all children on disappear/termination.

Before switching/closing, call the shared teardown closure that stops comparison and
storage, closes preview, dismisses Smart Search/sync review, ends editing, and clears
pending Trash. Query the operation controller for active/queued jobs bound to the tab ID.

- [ ] **Step 4: Add commands and profile management**

Use Command-T, Command-W, Control-Tab, and Control-Shift-Tab. Show profiles in a
submenu and a management sheet. Do not intercept Command-W while a modal or text editor
owns it. All controls receive stable accessibility IDs and values.

- [ ] **Step 5: Update English/Korean documentation and verify**

Run the focused command, full suite, release build, `./script/build_and_run.sh --verify`,
and `git diff --check`; require zero failures.

- [ ] **Step 6: Commit integration**

```bash
git add Sources/BloomFileManager/Views/WorkspaceTabBarView.swift Sources/BloomFileManager/Views/WorkspaceProfilesView.swift Sources/BloomFileManager/App/BloomFileManagerApp.swift Sources/BloomFileManager/Views/WorkspaceView.swift Sources/BloomFileManager/Support/WorkspaceCommands.swift Sources/BloomFileManager/Support/WorkspaceSessionAccessibilityIdentifiers.swift Tests/BloomFileManagerTests/WorkspaceTabPresentationTests.swift Tests/BloomFileManagerTests/WorkspaceCommandTests.swift Tests/BloomFileManagerTests/AccessibilityPresentationTests.swift README.md README.ko.md docs/user-guide.md docs/user-guide.ko.md
git commit -m "feat: integrate workspace tabs and profiles"
```
