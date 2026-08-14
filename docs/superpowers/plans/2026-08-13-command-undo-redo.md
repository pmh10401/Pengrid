# Command Undo and Redo Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace one-shot history-row Undo with safe process-local Undo/Redo stacks, dynamic Edit-menu commands, exact ⌘Z/⇧⌘Z shortcuts, and responder-chain delegation while text is being edited.

**Architecture:** `FileOperationUndoService` becomes a reversible-operation service: a successful reversal returns a freshly revalidated inverse recipe, while failure/cancellation/recovery returns no inverse. `FileOperationController` owns linear Undo and Redo stacks bound to the original workspace and touched directories, mutates stacks only after queue admission, clears Redo on a new forward branch, and invalidates overlapping history conservatively. `WorkspaceCommands` routes text-editing Undo/Redo to AppKit and file-operation Undo/Redo to the controller only when the exclusive queue is idle.

**Tech Stack:** Swift 6.1 actors, Observation, SwiftUI/AppKit commands, descriptor-safe `FileSystemAccess`, existing transaction services, Swift Testing, macOS 15.

## Global Constraints

- Prefix Swift verification commands with `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun`.
- Undo/Redo history is process-local in the MVP and is never restored across app launches.
- ⌘Z is Undo and ⇧⌘Z is Redo. During inline rename, filter, path, search, password, or other text editing, both commands must go to the active AppKit responder/UndoManager.
- File-operation Undo/Redo is enabled only when no operation is active or queued, no recovery acknowledgement is pending, and the top recipe still belongs to a live workspace.
- A reversal recipe is consumed only after queue admission succeeds. A failed, cancelled, or Recovery Needed reversal produces no inverse entry.
- Only a fully successful reversal that passes postflight may append a fresh inverse recipe to the opposite stack.
- Every move recipe captures identity and full `SourceFingerprint`; identity alone is insufficient authority.
- A newly admitted normal forward mutation clears Redo. Any overlapping completed mutation invalidates affected entries in both stacks.
- LIFO order is deterministic. Never skip an unsafe top entry to execute an older one silently.
- Existing operation-history row presentation remains historical; global stack availability is the authority for commands.
- Shared app/commands integration waits until Get Info command wiring is complete. Controller integration is serialized with folder synchronization integration.
- Follow RED → observed expected failure → minimal GREEN → focused pass for every production behavior.

---

### Task 1: Fingerprint-authoritative reversible recipes and fresh inverses

**Files:**
- Modify: `Sources/BloomFileManager/Services/FileOperationUndoService.swift`
- Modify only where inverse metadata must be returned: `Sources/BloomFileManager/Services/SelectionFolderTransactionService.swift`
- Modify: `Tests/BloomFileManagerTests/FileOperationUndoServiceTests.swift`
- Modify: `Tests/BloomFileManagerTests/SelectionFolderTransactionServiceTests.swift`

- [ ] **Step 1: Add failing move-authority tests**

```swift
@Test func moveRecipeCapturesIdentityAndFingerprint() async throws
@Test func moveUndoRejectsSameIdentityContentMutation() async throws
@Test func moveUndoRechecksFingerprintImmediatelyBeforeExclusiveMove() async throws
```

- [ ] **Step 2: Run tests and verify RED**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --enable-swift-testing --no-parallel --filter FileOperationUndoServiceTests
```

Expected: the move recipe has no fingerprint and the adversarial mutation test is not rejected.

- [ ] **Step 3: Strengthen move recipes**

```swift
struct FileOperationUndoMoveEntry: Sendable, Equatable {
    let currentURL: URL
    let currentIdentity: FileIdentity
    let currentFingerprint: SourceFingerprint
    let originalURL: URL
}
```

`makeRecipe` captures fingerprint between two matching identity checks. `moveBack` preflight and the immediate pre-move boundary require matching identity and fingerprint. Rollback accepts relocation-equivalent fingerprints only and rechecks identity around each fingerprint call.

- [ ] **Step 4: Add failing fresh-inverse tests**

Cover every recipe family:

```swift
@Test func successfulMoveBackReturnsSwappedMoveBackInverse() async throws
@Test func successfulRemoveCreatedReturnsTrashLocationMoveBackInverse() async throws
@Test func successfulBatchRenameReturnsResultMetadataAsInverse() async throws
@Test func successfulSelectionFolderReverseReturnsFingerprintBoundForwardInverse() async throws
@Test func successfulSelectionFolderForwardReturnsFreshReverseInverse() async throws
@Test func partialFailureCancellationAndRecoveryNeverReturnInverse() async throws
```

- [ ] **Step 5: Add reversible execution models**

```swift
struct SelectionFolderForwardRecipe: Sendable, Equatable {
    let plan: SelectionFolderPlan
    let expectedSourceFingerprints: [URL: SourceFingerprint]
}

enum FileOperationUndoRecipe: Sendable, Equatable {
    case moveBack([FileOperationUndoMoveEntry])
    case removeCreated([FileOperationUndoCreatedEntry])
    case batchRename(BatchRenameUndoPlan)
    case selectionFolderReverse(SelectionFolderUndoPlan)
    case selectionFolderForward(SelectionFolderForwardRecipe)
}

struct FileOperationReversalExecution: Sendable, Equatable {
    let result: FileOperationResult
    let inverseRecipe: FileOperationUndoRecipe?
}
```

Keep a compatibility `perform(_:progress:) -> FileOperationResult` wrapper during migration, but make `performReversal(_:progress:) -> FileOperationReversalExecution` the new authority.

- [ ] **Step 6: Implement fresh inverse generation**

- For `moveBack`, postflight the moved destination and return entries with URLs swapped and newly observed fingerprint.
- For `removeCreated`, use each successful Trash destination, then capture identity/fingerprint between identity checks and return `moveBack` entries targeting the former created URL.
- For batch rename, accept only a complete successful result whose `batchRenameUndoMetadata()` matches every outcome and live file.
- For selection-folder reverse, derive a forward plan from original sources, capture expected source fingerprints after reversal, and require the created folder to be absent.
- For selection-folder forward, validate expected fingerprints immediately before execution and accept only a complete result with a live `selectionFolderUndoMetadata()` plan.
- A skipped, failed, cancelled, or recovery outcome makes `inverseRecipe` nil for the whole operation.

- [ ] **Step 7: Run Task 1 tests and verify GREEN**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --enable-swift-testing --no-parallel --filter 'FileOperationUndoServiceTests|SelectionFolderTransactionServiceTests|FileOperationModelsTests'
git diff --check
```

- [ ] **Step 8: Commit Task 1**

```bash
git add Sources/BloomFileManager/Services/FileOperationUndoService.swift Sources/BloomFileManager/Services/SelectionFolderTransactionService.swift Tests/BloomFileManagerTests/FileOperationUndoServiceTests.swift Tests/BloomFileManagerTests/SelectionFolderTransactionServiceTests.swift
git commit -m "feat: make file operation reversals invertible"
```

### Task 2: Controller-owned linear Undo and Redo stacks

**Files:**
- Modify: `Sources/BloomFileManager/Models/FileOperationJobModels.swift`
- Modify: `Sources/BloomFileManager/Stores/FileOperationController.swift`
- Modify: `Tests/BloomFileManagerTests/FileOperationControllerTests.swift`
- Modify: `Tests/BloomFileManagerTests/FileOperationJobModelsTests.swift`

- [ ] **Step 1: Add failing stack and admission tests**

Cover LIFO order, dynamic titles, no skipping, active/queued/recovery gates, queue rejection without consumption, Undo→Redo→Undo, reversal failure, forward-branch Redo clearing, overlap invalidation in both stacks, history limit, and workspace deallocation.

- [ ] **Step 2: Run controller tests and verify RED**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --enable-swift-testing --no-parallel --filter 'FileOperationControllerTests|FileOperationJobModelsTests'
```

- [ ] **Step 3: Add privacy-safe presentation and private records**

```swift
enum FileOperationReversalDirection: Sendable, Equatable { case undo, redo }

struct FileOperationReversalAvailability: Sendable, Equatable {
    let title: String
    let itemCount: Int
    let isEnabled: Bool
}
```

The controller stores private records containing recipe, original operation kind, safe basename, item count, weak workspace binding, and normalized touched-directory keys. Public presentation contains no full paths. Add `.redo` to `FileOperationJobKind`; `.undo` and `.redo` are never retryable or directly Undoable history jobs.

- [ ] **Step 4: Implement stack transitions**

Expose:

```swift
var undoAvailability: FileOperationReversalAvailability?
var redoAvailability: FileOperationReversalAvailability?
@discardableResult func undoLatest() -> Bool
@discardableResult func redoLatest() -> Bool
func invalidateReversalHistory(for workspace: WorkspaceState)
```

On complete forward success, append its recipe to Undo and clear Redo. Preserve the existing history row `canUndo` projection only when that row is still represented by the authoritative Undo stack. `undoJob(_:)` may delegate only when the requested history row is the current top; otherwise return false.

For Undo/Redo, peek the top record, construct one exclusive pending job with the captured workspace, call `beginOperation`, and remove the record only if admission returns true. The operation calls `performReversal`. On complete success with non-nil inverse, append the inverse to the opposite stack. On any other result, append nothing. Prevent a reversal job from clearing its destination stack as if it were a normal forward mutation.

- [ ] **Step 5: Invalidate branches and overlaps conservatively**

When a normal mutation is admitted, clear Redo immediately. After any operation publishes a result, normalize its touched directories; invalidate every Undo and Redo record whose directory set overlaps. Do not invalidate the record being transformed until its reversal transition completes. Closing a workspace explicitly clears its bound entries.

- [ ] **Step 6: Run Task 2 tests and verify GREEN**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --enable-swift-testing --no-parallel --filter 'FileOperationControllerTests|FileOperationJobModelsTests|FileOperationUndoServiceTests|OperationStatusViewTests'
git diff --check
```

- [ ] **Step 7: Commit Task 2**

```bash
git add Sources/BloomFileManager/Models/FileOperationJobModels.swift Sources/BloomFileManager/Stores/FileOperationController.swift Tests/BloomFileManagerTests/FileOperationControllerTests.swift Tests/BloomFileManagerTests/FileOperationJobModelsTests.swift
git commit -m "feat: add operation undo and redo stacks"
```

### Task 3: Edit-menu routing, operation-center presentation, and documentation

**Files:**
- Modify: `Sources/BloomFileManager/Support/WorkspaceCommands.swift`
- Modify: `Sources/BloomFileManager/Views/OperationStatusView.swift`
- Modify: `Sources/BloomFileManager/Support/AccessibilityIdentifiers.swift`
- Modify: `Tests/BloomFileManagerTests/WorkspaceCommandTests.swift`
- Modify: `Tests/BloomFileManagerTests/OperationStatusViewTests.swift`
- Modify: `Tests/BloomFileManagerTests/AccessibilityPresentationTests.swift`
- Modify: `README.md`, `README.ko.md`, `docs/user-guide.md`, `docs/user-guide.ko.md`, `docs/current-limitations.md`, `docs/current-limitations.ko.md`

- [ ] **Step 1: Add failing command-routing tests**

Prove exact ⌘Z/⇧⌘Z shortcuts, dynamic `Undo <operation>`/`Redo <operation>` titles, file-operation dispatch while idle, disabled state during active/queued/recovery work, and AppKit responder routing during every workspace text-editing session. Static source tests must verify that no file-operation method is called from the text-responder branch.

- [ ] **Step 2: Run integration tests and verify RED**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --enable-swift-testing --no-parallel --filter 'WorkspaceCommandTests|OperationStatusViewTests|AccessibilityPresentationTests'
```

- [ ] **Step 3: Add responder-chain Undo/Redo helpers**

Extend `TextResponderCommand` with `undo(to:)` and `redo(to:)` using the AppKit responder chain. In `WorkspaceCommands`, replace the default Undo/Redo command group with two buttons. When `workspace.activeTextEditingSession != nil`, use responder titles and routes regardless of operation-stack state. Otherwise show controller availability, call `undoLatest()`/`redoLatest()`, and disable when no authoritative top entry exists.

- [ ] **Step 4: Update operation-center presentation**

Show privacy-safe Undo/Redo availability and explain why commands are temporarily unavailable during queued/exclusive/recovery work. Keep history-row Undo enabled only for the current top record. Add stable accessibility identifiers and values containing operation title/count/status, never absolute paths.

- [ ] **Step 5: Update English/Korean documentation and verify**

Document process-local lifetime, supported operations, fingerprint drift rejection, LIFO behavior, new-forward-branch Redo clearing, text-editing routing, idle-queue gating, and Recovery Needed behavior. Run focused tests, full `BloomFileManagerTests`, release build, bundle verification, placeholder scan, and `git diff --check`; require zero failures. Manually verify Edit-menu titles and real NSTextView Undo/Redo before release, or record those rows as NOT RUN.

- [ ] **Step 6: Commit integration**

```bash
git add Sources/BloomFileManager/Support/WorkspaceCommands.swift Sources/BloomFileManager/Views/OperationStatusView.swift Sources/BloomFileManager/Support/AccessibilityIdentifiers.swift Tests/BloomFileManagerTests/WorkspaceCommandTests.swift Tests/BloomFileManagerTests/OperationStatusViewTests.swift Tests/BloomFileManagerTests/AccessibilityPresentationTests.swift README.md README.ko.md docs/user-guide.md docs/user-guide.ko.md docs/current-limitations.md docs/current-limitations.ko.md
git commit -m "feat: integrate command undo and redo"
```
