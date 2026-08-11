# Safe Batch Rename Implementation Plan

> **For Codex:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a fast, preview-first, identity-safe batch rename workflow that handles swaps and cycles, reports transaction phases in the operation center, and supports conservative retry and Undo.

**Architecture:** A pure `BatchRenamePlanner` derives immutable old/new-name entries from one active-pane selection and an explicit filename-comparison policy. A main-actor `BatchRenameModel` owns sheet state and latest-only asynchronous preview generation. A `BatchRenameTransactionService` performs identity revalidation and same-directory two-phase moves through reserved temporary names, with rollback on cancellation or failure. `FileOperationController` owns queue/history integration, while `FileOperationUndoService` reuses the same transaction engine for reverse two-phase Undo.

**Tech Stack:** Swift 6.1, SwiftUI, AppKit `NSTableView`, Observation, Foundation file APIs through `FileSystemAccess`, Swift Testing, macOS 15+

---

## Task 1: Define rename rules, extension policy, and pure preview planning

**Files:**
- Create: `Sources/BloomFileManager/Models/BatchRenameModels.swift`
- Create: `Sources/BloomFileManager/Services/BatchRenamePlanner.swift`
- Modify: `Sources/BloomFileManager/Models/ArchiveFormat.swift`
- Test: `Tests/BloomFileManagerTests/BatchRenamePlannerTests.swift`

**Step 1: Write failing rule and extension-policy tests**

Cover literal find/replace with case-sensitive and localized case-insensitive modes, prefix, suffix, sequence numbering and padding, ordinary extensions, exact recognized compound archive suffixes, packages, directories, leading-dot files, invalid filenames, unchanged names, duplicate proposed names, collisions with unselected siblings, and selection count below two.

```swift
@Test func plannerPreservesCompoundArchiveSuffix() throws {
    let plan = try BatchRenamePlanner.plan(
        request: .fixture(names: ["logs.tar.gz", "notes.txt"]),
        rule: .prefix("old-"),
        occupiedNames: ["logs.tar.gz", "notes.txt"],
        comparisonPolicy: .caseInsensitiveCanonical
    )
    #expect(plan.entries.map(\.proposedName) == ["old-logs.tar.gz", "old-notes.txt"])
}

@Test func plannerRejectsSwapOnlyIfExternalCollisionExists() throws {
    let request = BatchRenamePlanningRequest.fixture(names: ["A.txt", "B.txt"])
    let plan = try BatchRenamePlanner.plan(
        request: request,
        proposedNames: ["B.txt", "A.txt"],
        occupiedNames: ["A.txt", "B.txt"],
        comparisonPolicy: .caseInsensitiveCanonical
    )
    #expect(plan.isExecutable)
}
```

**Step 2: Run the focused tests and confirm they fail**

Run:

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --enable-swift-testing --no-parallel \
  --filter BatchRenamePlannerTests
```

Expected: FAIL because the batch rename models and planner do not exist.

**Step 3: Implement value models and name decomposition**

Add these core types:

```swift
enum BatchRenameRule: Sendable, Equatable {
    case findReplace(find: String, replacement: String, caseSensitive: Bool)
    case prefix(String)
    case suffix(String)
    case sequence(baseName: String, start: Int, digits: Int)
}

enum FilenameComparisonPolicy: Sendable, Equatable {
    case caseSensitiveCanonical
    case caseInsensitiveCanonical

    func key(for name: String) -> String
}

struct BatchRenameSource: Sendable, Equatable {
    let url: URL
    let identity: FileIdentity
    let name: String
    let isDirectory: Bool
    let isPackage: Bool
}

struct BatchRenamePlanEntry: Sendable, Equatable {
    let source: BatchRenameSource
    let proposedName: String
    let destinationURL: URL
}

struct BatchRenamePlan: Sendable, Equatable {
    let parentURL: URL
    let parentIdentity: FileIdentity
    let entries: [BatchRenamePlanEntry]
    let comparisonPolicy: FilenameComparisonPolicy
}
```

Expose an `ArchiveFormat.recognizedSuffix(in:)` helper that preserves the exact suffix spelling from the original filename. Implement one `BatchRenameFilenameParts` policy:

- recognized archive: editable stem plus exact compound suffix;
- package: editable stem plus path extension;
- ordinary file: editable stem plus final path extension;
- ordinary directory: whole name;
- leading-dot file without another dot: whole name.

**Step 4: Implement the pure planner**

The planner must:

- require at least two sources from one parent;
- apply a rule only to editable stems and reattach preserved suffixes;
- validate every result with `FilenameValidator`;
- retain stable selection order for sequences;
- reject generated duplicates under `FilenameComparisonPolicy`;
- allow names currently occupied by another selected source;
- reject names occupied by any unselected sibling;
- reject unchanged whole plans and mark individual unchanged rows as non-mutating;
- return immutable entries suitable for execution and retry.

**Step 5: Run the focused tests and commit**

Run the Task 1 test command. Expected: PASS.

```bash
git add Sources/BloomFileManager/Models/BatchRenameModels.swift \
  Sources/BloomFileManager/Services/BatchRenamePlanner.swift \
  Sources/BloomFileManager/Models/ArchiveFormat.swift \
  Tests/BloomFileManagerTests/BatchRenamePlannerTests.swift
git commit -m "feat: plan safe batch renames"
```

## Task 2: Add filesystem comparison semantics and identity-safe transaction execution

**Files:**
- Modify: `Sources/BloomFileManager/Services/FileSystemAccess.swift`
- Create: `Sources/BloomFileManager/Services/BatchRenameTransactionService.swift`
- Test: `Tests/BloomFileManagerTests/BatchRenameTransactionServiceTests.swift`
- Modify: `Tests/BloomFileManagerTests/Support/RecordingFileSystem.swift`

**Step 1: Write failing transaction tests**

Use temporary directories for live integration cases and a recording filesystem for deterministic failures. Cover:

- ordinary two-file rename;
- `A -> B`, `B -> A` swap;
- three-entry cycle;
- source identity drift before staging;
- destination collision created after preview;
- cancellation during staging and publishing;
- rollback success restores original names;
- rollback failure reports `recoveryNeeded` with explicit affected URLs;
- no operation touches file contents or leaves reserved temp names after success.

```swift
@Test func executesSwapThroughTemporaryNames() async throws {
    let fixture = try BatchRenameTransactionFixture(names: ["A.txt", "B.txt"])
    let plan = try await fixture.plan(proposedNames: ["B.txt", "A.txt"])
    let result = await fixture.service.execute(plan, progress: { _ in })
    #expect(result.outcomes.allSatisfy(\.isSuccess))
    #expect(try fixture.contents(named: "A.txt") == "B")
    #expect(try fixture.contents(named: "B.txt") == "A")
}
```

**Step 2: Run the focused tests and confirm they fail**

Run the standard Swift test command filtered to `BatchRenameTransactionServiceTests`.

**Step 3: Extend filesystem semantics**

Add:

```swift
protocol FileSystemAccess: Sendable {
    // existing requirements...
    func filenameComparisonPolicy(in directory: URL) async throws -> FilenameComparisonPolicy
}
```

`LiveFileSystemAccess` reads `volumeSupportsCaseSensitiveNames`; unknown semantics fail closed for batch rename. Test doubles may use an explicit configured policy. Continue to route all mutations through `moveExclusively(_:identifiedBy:to:)`; do not add direct `FileManager.moveItem` calls outside the live filesystem actor.

**Step 4: Implement two-phase execution and rollback**

Add:

```swift
enum BatchRenameTransactionPhase: String, Sendable, Equatable {
    case staging
    case publishing
    case rollingBack
}

struct BatchRenameTransactionProgress: Sendable, Equatable {
    let phase: BatchRenameTransactionPhase
    let completedCount: Int
    let totalCount: Int
    let currentName: String
}

actor BatchRenameTransactionService {
    func execute(
        _ plan: BatchRenamePlan,
        progress: @escaping @Sendable (BatchRenameTransactionProgress) async -> Void
    ) async -> FileOperationResult
}
```

Execution rules:

1. Acquire one scoped-access lease set for parent, sources, temporary URLs, and final URLs.
2. Revalidate parent/source identities, comparison policy, sibling names, and all final collisions.
3. Generate unoccupied `.pengrid-rename-<UUID>-<index>` names in the same directory.
4. Move each changed source to its temporary URL with the captured source identity.
5. Move each temporary URL to its final URL with the newly captured temporary identity.
6. Capture final identity and fingerprint for Undo.
7. On error or cancellation after the first mutation, roll back published and staged entries in dependency-safe reverse two-phase order.
8. Return success only when all entries are final and no temporary name remains; return `recoveryNeeded` if rollback cannot prove restoration.

No mutation parallelism is permitted. Progress generation and preflight may be concurrent only when all results are indexed back into stable plan order.

**Step 5: Run focused tests and commit**

Expected: all transaction tests PASS.

```bash
git add Sources/BloomFileManager/Services/FileSystemAccess.swift \
  Sources/BloomFileManager/Services/BatchRenameTransactionService.swift \
  Tests/BloomFileManagerTests/BatchRenameTransactionServiceTests.swift \
  Tests/BloomFileManagerTests/Support/RecordingFileSystem.swift
git commit -m "feat: execute batch rename transactions safely"
```

## Task 3: Integrate batch rename with queue, history, retry, and Undo

**Files:**
- Modify: `Sources/BloomFileManager/Models/FileOperationModels.swift`
- Modify: `Sources/BloomFileManager/Models/FileOperationJobModels.swift`
- Modify: `Sources/BloomFileManager/Stores/FileOperationController.swift`
- Modify: `Sources/BloomFileManager/Services/FileOperationUndoService.swift`
- Test: `Tests/BloomFileManagerTests/FileOperationControllerTests.swift`
- Test: `Tests/BloomFileManagerTests/FileOperationUndoServiceTests.swift`
- Test: `Tests/BloomFileManagerTests/FileOperationJobModelsTests.swift`

**Step 1: Write failing controller, progress, retry, and Undo tests**

Cover one exclusive `.rename` job for N items, title `Rename N Items`, staging/publishing/rollback progress details, queue blocking, cancellation, exact immutable-plan retry, Undo availability only after complete success, changed-final fingerprint rejection, newly occupied original-name rejection, reverse swap/cycle Undo, and recovery-needed queue blocking.

**Step 2: Run focused tests and confirm they fail**

Run filters for `FileOperationControllerTests`, `FileOperationUndoServiceTests`, and `FileOperationJobModelsTests`.

**Step 3: Add explicit operation-center phase presentation**

Extend `FileOperationStage` with a batch-rename progress payload or map the transaction payload into `FileOperationJobProgress` using localized phase labels. Make `FileOperationJobSnapshot.title` return `Rename N Items` only for multi-item rename jobs; preserve the existing single-item `Rename` title.

**Step 4: Add controller entry point and immutable retry closure**

```swift
@discardableResult
func batchRename(
    _ plan: BatchRenamePlan,
    workspace: WorkspaceState
) -> Bool
```

The controller enqueues the operation exclusively, stores the exact plan for retry, updates progress on the main actor, refreshes only visible affected panes, reselects final URLs on success, and passes identity/fingerprint evidence into the Undo recipe.

**Step 5: Add a dedicated two-phase Undo recipe**

```swift
enum FileOperationUndoRecipe: Sendable, Equatable {
    // existing cases...
    case batchRename(BatchRenameUndoPlan)
}
```

Before Undo, verify every current final URL has the expected final identity and fingerprint and every original name is either part of the same reverse plan or free. Execute the reverse plan through `BatchRenameTransactionService`; never use the existing simple `moveBack` loop for swaps or cycles.

**Step 6: Run focused tests and commit**

Expected: all focused operation tests PASS.

```bash
git add Sources/BloomFileManager/Models/FileOperationModels.swift \
  Sources/BloomFileManager/Models/FileOperationJobModels.swift \
  Sources/BloomFileManager/Stores/FileOperationController.swift \
  Sources/BloomFileManager/Services/FileOperationUndoService.swift \
  Tests/BloomFileManagerTests/FileOperationControllerTests.swift \
  Tests/BloomFileManagerTests/FileOperationUndoServiceTests.swift \
  Tests/BloomFileManagerTests/FileOperationJobModelsTests.swift
git commit -m "feat: integrate batch rename operation history"
```

## Task 4: Build the latest-only preview model and performance contract

**Files:**
- Create: `Sources/BloomFileManager/Stores/BatchRenameModel.swift`
- Test: `Tests/BloomFileManagerTests/BatchRenameModelTests.swift`
- Create: `Tests/BloomFileManagerTests/BatchRenamePerformanceTests.swift`

**Step 1: Write failing model tests**

Cover selection capture, identity/parent capture, occupied-name snapshot, cloud/local-file-operation capability checks, presentation/dismissal, rule edits, stale generation suppression, submit eligibility, cancel, executing-state lock, and user-facing validation summaries.

**Step 2: Write the 10,000-row benchmark first**

```swift
@Test func tenThousandRowPreviewCompletesWithinFiveSeconds() async throws {
    let clock = ContinuousClock()
    let duration = try await clock.measure {
        _ = try BatchRenamePlanner.plan(
            request: .tenThousandRows,
            rule: .sequence(baseName: "Photo", start: 1, digits: 5),
            occupiedNames: .tenThousandSourceNames,
            comparisonPolicy: .caseInsensitiveCanonical
        )
    }
    #expect(duration < .seconds(5))
}
```

The five-second threshold is a regression ceiling, not a product animation target. Also verify the main actor yields while a new generation supersedes an older one.

**Step 3: Implement `BatchRenameModel`**

Use Observation on the main actor. Capture all source identities and directory metadata once on presentation. Every control change increments a generation token and computes a pure plan off the main actor; publish only if the token remains current. Cancel pending preview work on dismiss or operation submission. Expose only immutable `BatchRenamePlan` for the controller.

**Step 4: Run focused tests and commit**

Expected: model and benchmark tests PASS on the current development Mac.

```bash
git add Sources/BloomFileManager/Stores/BatchRenameModel.swift \
  Tests/BloomFileManagerTests/BatchRenameModelTests.swift \
  Tests/BloomFileManagerTests/BatchRenamePerformanceTests.swift
git commit -m "feat: generate responsive batch rename previews"
```

## Task 5: Add accessible sheet, commands, and context-menu entry

**Files:**
- Create: `Sources/BloomFileManager/Views/BatchRename/BatchRenameSheet.swift`
- Create: `Sources/BloomFileManager/Views/BatchRename/BatchRenamePreviewTable.swift`
- Modify: `Sources/BloomFileManager/App/BloomFileManagerApp.swift`
- Modify: `Sources/BloomFileManager/Views/WorkspaceView.swift`
- Modify: `Sources/BloomFileManager/Views/FilePaneView.swift`
- Modify: `Sources/BloomFileManager/Views/AppKit/FileTableView.swift`
- Modify: `Sources/BloomFileManager/Support/WorkspaceCommands.swift`
- Modify: `Sources/BloomFileManager/Support/AccessibilityIdentifiers.swift`
- Test: `Tests/BloomFileManagerTests/WorkspaceCommandPolicyTests.swift`
- Test: `Tests/BloomFileManagerTests/WorkspaceCommandTests.swift`
- Test: `Tests/BloomFileManagerTests/FileTableViewLifecycleTests.swift`
- Create: `Tests/BloomFileManagerTests/BatchRenamePresentationTests.swift`

**Step 1: Write failing routing and presentation tests**

Cover enablement for two or more active-pane items, disabled state during text editing/exclusive operations, command dispatch, context-menu routing, no selection leakage from the inactive pane, field labels/hints, row status labels, pluralized summary, default button behavior, Escape dismissal, error focus routing, VoiceOver strings, and Reduce Motion policy.

**Step 2: Run focused tests and confirm they fail**

Run filters for the four test files above.

**Step 3: Wire one shared model instance**

Construct `BatchRenameModel` in `BloomFileManagerApp` from the shared filesystem and scoped-access coordinator, then inject the same instance into `WorkspaceView`, `WorkspaceCommands`, and both panes. Add `WorkspaceCommandPolicy.canBatchRename`:

```swift
var canBatchRename: Bool {
    !isOperationRunning && !isTextEditing && selectionCount >= 2
}
```

Add `Batch Rename…` to File Operations and the table context menu. Both routes call one model presentation method with the active pane's stable selected-item order.

**Step 4: Build the sheet and virtualized preview**

Use SwiftUI controls for rule selection and parameters. Use `Table` or a narrowly wrapped `NSTableView` for virtualized Original / New Name / Status rows. The sheet must:

- show only basenames, never full paths in row labels;
- expose an accessible summary and actionable validation messages;
- submit with Return only when the current generation is valid;
- dismiss with Escape without mutation;
- disable editable controls while execution handoff occurs;
- honor Reduce Motion and avoid per-row animation.

**Step 5: Coordinate sheets**

Extend `WorkspaceModalPresentationState` so password, conflict, smart search, and batch rename cannot present simultaneously. A pending archive password waits while batch rename is visible, and a denied security scope surfaces one error without an automatic retry loop.

**Step 6: Run focused tests and commit**

Expected: routing and presentation tests PASS.

```bash
git add Sources/BloomFileManager/Views/BatchRename \
  Sources/BloomFileManager/App/BloomFileManagerApp.swift \
  Sources/BloomFileManager/Views/WorkspaceView.swift \
  Sources/BloomFileManager/Views/FilePaneView.swift \
  Sources/BloomFileManager/Views/AppKit/FileTableView.swift \
  Sources/BloomFileManager/Support/WorkspaceCommands.swift \
  Sources/BloomFileManager/Support/AccessibilityIdentifiers.swift \
  Tests/BloomFileManagerTests/WorkspaceCommandPolicyTests.swift \
  Tests/BloomFileManagerTests/WorkspaceCommandTests.swift \
  Tests/BloomFileManagerTests/FileTableViewLifecycleTests.swift \
  Tests/BloomFileManagerTests/BatchRenamePresentationTests.swift
git commit -m "feat: add accessible batch rename workflow"
```

## Task 6: Document, verify, and manually smoke-test the full workflow

**Files:**
- Modify: `README.md`
- Modify: `README.ko.md`
- Modify: `docs/USER_GUIDE.md`
- Modify: `docs/USER_GUIDE.ko.md`
- Modify: `docs/ARCHITECTURE.md`
- Modify: `docs/CURRENT_LIMITATIONS.md`
- Modify: `docs/CURRENT_LIMITATIONS.ko.md`

**Step 1: Update English and Korean documentation**

Document supported rules, extension preservation, preview validation, active-pane scope, cloud File Provider behavior, operation-center phases, cancellation/rollback, retry, conservative Undo, the 10,000-row/5-second regression ceiling, and out-of-scope regex/recursion/extension editing.

**Step 2: Run the complete test suite**

Run:

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --enable-swift-testing --no-parallel \
  --filter BloomFileManagerTests
```

Expected: all tests PASS. If the known low-file-descriptor Swift Testing child-process issue recurs, record it separately and rerun the affected tests in isolated filtered invocations; do not treat build success as runtime success.

**Step 3: Build the release product**

Run:

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift build -c release
```

Expected: release build PASS.

**Step 4: Run a local macOS smoke test**

Create a disposable folder and verify through the app:

1. select two ordinary files and open Batch Rename from the context menu;
2. verify preview, extension preservation, Enter, progress, final selection;
3. Undo and verify original names/content;
4. repeat a two-file swap and a three-file cycle;
5. cancel mid-operation on a larger set and verify rollback/no temp names;
6. verify VoiceOver labels and keyboard-only operation;
7. verify a File Provider folder and permission-denial path without repeated prompts.

**Step 5: Review the diff and commit documentation**

```bash
git diff --check
git status --short
git add README.md README.ko.md docs/USER_GUIDE.md docs/USER_GUIDE.ko.md \
  docs/ARCHITECTURE.md docs/CURRENT_LIMITATIONS.md docs/CURRENT_LIMITATIONS.ko.md
git commit -m "docs: explain safe batch rename"
```

**Step 6: Request final review and handle findings**

Use the project review workflow, rerun every affected focused test plus the complete suite, and only then prepare the branch for installation or release. Do not publish, install, or tag from this plan unless the user separately asks for that external state change.
