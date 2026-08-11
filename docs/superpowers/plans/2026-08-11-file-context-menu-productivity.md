# File Context Menu Productivity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the approved Quick Look, Open With, Open in Other Pane, opposite-pane copy/move, Show in Finder, Copy Path, Duplicate, and New Folder with Selection actions without weakening Pengrid's identity, cloud, queue, cancellation, recovery, or Undo guarantees.

**Architecture:** A pure policy and immutable invocation snapshot feed one `FileContextActionRouter`. AppKit and menu-bar entry points pass stable table-order selections through that router. Presentation routes use injected system adapters; mutations enter `FileOperationController`. Existing identified transfer owns opposite-pane transfer and Duplicate. Selection enclosure uses a dedicated exclusive transaction with rollback and all-or-nothing reverse Undo.

**Tech Stack:** Swift 6, SwiftUI, AppKit, Observation, SwiftPM, Swift Testing, `NSWorkspace`, Pengrid `FileSystemAccess`, cloud materialization, Operation Center, and Undo infrastructure.

## Global Constraints

- Work in `/Users/mac/Documents/Pengrid/.worktrees/safe-operation-center` on `codex/safe-operation-center`; preserve unrelated changes and history.
- Use TDD for every task: failing focused test, smallest implementation, focused rerun, then commit.
- Run Swift with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` and `--no-parallel` tests.
- Preserve stable visible table order; never enumerate a `Set` to form an action request.
- Capture pane IDs and directory URLs synchronously at invocation. Never reread `workspace.activePane` to redirect queued work.
- Revalidate captured source and destination identities at the final action boundary.
- Never materialize for Open in Other Pane, Show in Finder, or Copy Path.
- Acquire scoped access for filesystem/system routes. Permission or identity failure fails closed without prompt loops.
- Mutations require `.writable`; `.readOnly` and `.unknown` remain disabled and are checked again before mutation.
- Duplicate always uses keep-both and no-overwrite. Enclosure and its Undo are exclusive transactions.
- Rollback failure publishes `.recoveryNeeded`; existing queue blocking remains authoritative.
- Accessibility and logs use basenames/counts, not absolute parent paths.
- Preserve existing context-menu actions, shortcuts, archive semantics, and tests unless the approved design explicitly changes them.
- Do not claim live Finder, Open With, VoiceOver, or OneDrive verification without recorded manual evidence.

---

### Task 1: Generalize the local mutation capability

**Files:**
- Modify: `Sources/BloomFileManager/Stores/BatchRenameModel.swift`
- Modify: `Sources/BloomFileManager/Stores/CloudLocationsStore.swift`
- Modify: `Tests/BloomFileManagerTests/CloudLocationsStoreTests.swift`

**Interfaces:**

```swift
enum LocalFileOperationCapability: Sendable, Equatable {
    case writable
    case readOnly
    case unknown
}

typealias BatchRenameLocationCapability = LocalFileOperationCapability

extension CloudLocationsStore {
    func localFileOperationCapability(for directory: URL) -> LocalFileOperationCapability
    func batchRenameCapability(for directory: URL) -> BatchRenameLocationCapability
}
```

- [ ] Record `git status --short`, then run the baseline suites.

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --enable-swift-testing --no-parallel --filter 'WorkspaceCommandPolicyTests|CloudLocationsStoreTests'
```

- [ ] Add failing cases for writable local, read-only, unavailable provider, unknown CloudStorage child, and provider local-operation capability.
- [ ] Introduce the generic enum/typealias and make `batchRenameCapability(for:)` delegate to the generic method.
- [ ] Rerun the command above; expect all tests to pass with unchanged batch rename behavior.
- [ ] Commit: `git commit -am "refactor: share local file operation capability"`.

---

### Task 2: Define immutable action snapshots and pure policy

**Files:**
- Create: `Sources/BloomFileManager/Models/ContextActionModels.swift`
- Create: `Sources/BloomFileManager/Support/FileContextMenuPolicy.swift`
- Modify: `Sources/BloomFileManager/Models/FileItem.swift`
- Modify: `Sources/BloomFileManager/Services/DirectoryEntryBatchBuilder.swift`
- Modify: `Sources/BloomFileManager/Services/SmartSearchService.swift`
- Create: `Tests/BloomFileManagerTests/ContextActionModelsTests.swift`
- Create: `Tests/BloomFileManagerTests/FileContextMenuPolicyTests.swift`
- Modify: `Tests/BloomFileManagerTests/DirectoryListingServiceTests.swift`
- Modify: `Tests/BloomFileManagerTests/SmartSearchServiceTests.swift`

**Interfaces:**

```swift
enum ContextActionKind: Sendable, Equatable {
    case quickLook
    case openWith(applicationURL: URL)
    case openInOtherPane
    case transferToOtherPane(TransferMode)
    case showInFinder
    case copyPath(PathCopyRepresentation)
    case duplicate
    case encloseSelection
}

enum PathCopyRepresentation: Sendable, Equatable {
    case fullPath, name, parentPath, fileURL
}

struct OpenWithApplication: Sendable, Equatable, Identifiable {
    let applicationURL: URL
    let displayName: String
    var id: URL { applicationURL }
}

struct ContextActionSource: Sendable, Equatable {
    let item: FileItem
    let identity: FileIdentity
}

struct ContextActionDraft: Sendable, Equatable {
    let requestID: UUID
    let sources: [FileItem]
    let sourcePaneID: PaneID
    let oppositePaneID: PaneID
    let sourceDirectory: URL
    let oppositeDirectory: URL
    let sourceCapability: LocalFileOperationCapability
    let oppositeCapability: LocalFileOperationCapability
}

struct ContextActionSnapshot: Sendable, Equatable {
    let requestID: UUID
    let sources: [ContextActionSource]
    let sourcePaneID: PaneID
    let oppositePaneID: PaneID
    let sourceDirectory: IdentifiedFileRequest
    let oppositeDirectory: IdentifiedFileRequest
    let sourceCapability: LocalFileOperationCapability
    let oppositeCapability: LocalFileOperationCapability
}

struct ContextActionAvailability: Equatable {
    let isVisible: Bool
    let isEnabled: Bool
    let disabledReason: String?
}
```

- [ ] Add `FileItem.isSymbolicLink` with a default of `false`; populate it from `.isSymbolicLinkKey` in directory listing and Smart Search metadata, with focused regression tests.
- [ ] Test stable order, standardized directories, distinct panes, and all-or-nothing identity capture.
- [ ] Test the policy matrix: empty/single/multiple, file/directory/package/symbolic link, editing, operation running, incomplete capture, same destination, and each capability.
- [ ] Confirm new suites fail to compile, then implement `FileContextMenuPolicy` with separate visibility and enablement for each action.
- [ ] Run:

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --enable-swift-testing --no-parallel --filter 'ContextActionModelsTests|FileContextMenuPolicyTests|WorkspaceCommandPolicyTests'
```

- [ ] Commit by staging the nine files listed in this task only, then use `git commit -m "feat: define file context action policy"`.

---

### Task 3: Implement snapshot capture, Finder reveal, and path copying

**Files:**
- Create: `Sources/BloomFileManager/Support/FileContextActionRouter.swift`
- Create: `Tests/BloomFileManagerTests/FileContextActionRouterTests.swift`
- Modify: `Tests/BloomFileManagerTests/Support/RecordingFileSystem.swift`

**Interfaces:**

```swift
@MainActor protocol FinderRevealing { func reveal(_ urls: [URL]) }
@MainActor protocol TextPasteboardWriting { func writePlainText(_ value: String) }

@MainActor
final class FileContextActionRouter {
    func capture(_ draft: ContextActionDraft) async -> ContextActionSnapshot?
    func showInFinder(_ snapshot: ContextActionSnapshot) async -> Bool
    func copyPath(_ kind: PathCopyRepresentation, from snapshot: ContextActionSnapshot) -> Int
}
```

- [ ] Test that capture resolves every source and both directories, preserves order, and ignores later workspace pane/directory changes.
- [ ] Test Finder all-valid, partial-stale, all-stale, stable ordering, one reveal call, scoped-access failure, and zero materialization.
- [ ] Test full path/name/file URL as one value per line, parent once, plain text only, and privacy-safe completion announcement.
- [ ] Implement injected adapters:

```swift
@MainActor
struct LiveFinderRevealer: FinderRevealing {
    func reveal(_ urls: [URL]) { NSWorkspace.shared.activateFileViewerSelecting(urls) }
}

@MainActor
struct LiveTextPasteboardWriter: TextPasteboardWriting {
    func writePlainText(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}
```

- [ ] Revalidate Finder identities immediately before reveal. Copy Path uses captured URL strings and never reads bytes.
- [ ] Run `swift test` with filter `FileContextActionRouterTests` using the global Xcode command prefix.
- [ ] Commit: stage `FileContextActionRouter.swift`, `FileContextActionRouterTests.swift`, and `Support/RecordingFileSystem.swift` only; use `git commit -m "feat: add safe finder and path routes"`.

---

### Task 4: Rebuild the AppKit context menu from shared policy

**Files:**
- Modify: `Sources/BloomFileManager/Views/AppKit/FileTableView.swift`
- Modify: `Sources/BloomFileManager/Support/AccessibilityIdentifiers.swift`
- Modify: `Tests/BloomFileManagerTests/FileTableViewLifecycleTests.swift`
- Modify: `Tests/BloomFileManagerTests/FileTableSelectionTests.swift`

**Interfaces:**

```swift
struct FileContextMenuPresentation: Equatable {
    let policy: FileContextMenuPolicy
    let openWithApplications: [OpenWithApplication]
}

var contextMenuPresentation: ([FileItem]) -> FileContextMenuPresentation
var onContextAction: (ContextActionKind, [FileItem]) -> Void
```

- [ ] Test approved group order, separators, labels, dynamic enclosure count, submenu order, identifiers, enablement/visibility, and retention of every legacy action.
- [ ] Test right-click inside a multi-selection preserves it, outside replaces it, and dispatch follows visible table order.
- [ ] Add stable identifiers for all new parent/child items.
- [ ] Use one ordered-selection helper for menu construction and selector dispatch:

```swift
private var orderedSelectedItems: [FileItem] {
    items.filter { parent.selection.contains($0.url) }
}
```

- [ ] Implement the approved Open; opposite-pane/Finder/path; create/favorite/rename; pasteboard; archive; Trash grouping. Omit only meaningless items.
- [ ] Run focused `FileTableViewLifecycleTests|FileTableSelectionTests`.
- [ ] Commit: `git add Sources/BloomFileManager/Views/AppKit/FileTableView.swift Sources/BloomFileManager/Support/AccessibilityIdentifiers.swift Tests/BloomFileManagerTests/FileTableViewLifecycleTests.swift Tests/BloomFileManagerTests/FileTableSelectionTests.swift && git commit -m "feat: expand file table context menu"`.

---

### Task 5: Route Quick Look and Open in Other Pane

**Files:**
- Modify: `Sources/BloomFileManager/Support/FileContextActionRouter.swift`
- Modify: `Sources/BloomFileManager/Views/FilePaneView.swift`
- Modify: `Sources/BloomFileManager/Views/WorkspaceView.swift`
- Modify: `Tests/BloomFileManagerTests/FileContextActionRouterTests.swift`
- Modify: `Tests/BloomFileManagerTests/WorkspacePreviewCoordinatorTests.swift`

**Interfaces:**

```swift
extension FileContextActionRouter {
    func quickLook(_ snapshot: ContextActionSnapshot,
                   previewCoordinator: WorkspacePreviewCoordinator) async -> Bool
    func openInOtherPane(_ snapshot: ContextActionSnapshot,
                         targetPane: FilePaneState) async -> Bool
}
```

- [ ] Test Quick Look order, folder preview reuse, multiple selection, cancellation, and stale-request suppression.
- [ ] Test folder navigation and file/package parent navigation plus exact identity-matched selection.
- [ ] Test stale source, failed navigation, active-pane switch, and target-pane navigation after invocation. Assert no materialization/external open.
- [ ] In `FilePaneView`, create `ContextActionDraft` synchronously before starting a `Task`; select the target from captured `oppositePaneID` only.
- [ ] Implement commit-on-success other-pane navigation. Revalidate and locate the listed URL before selecting a file/package.
- [ ] Run focused `FileContextActionRouterTests|WorkspacePreviewCoordinatorTests|WorkspaceCommandTests`.
- [ ] Commit the five files listed in this task only with `git commit -m "feat: route preview and other pane open"`.

---

### Task 6: Add deterministic and injectable Open With

**Files:**
- Create: `Sources/BloomFileManager/Services/OpenWithApplicationProvider.swift`
- Modify: `Sources/BloomFileManager/Support/FileContextActionRouter.swift`
- Modify: `Sources/BloomFileManager/Views/FilePaneView.swift`
- Modify: `Sources/BloomFileManager/Views/AppKit/FileTableView.swift`
- Create: `Tests/BloomFileManagerTests/OpenWithApplicationProviderTests.swift`
- Modify: `Tests/BloomFileManagerTests/FileContextActionRouterTests.swift`
- Modify: `Tests/BloomFileManagerTests/FileTableViewLifecycleTests.swift`

**Interfaces:**

```swift
struct OpenWithFileKindKey: Sendable, Hashable {
    let contentTypeIdentifier: String
    let filenameExtension: String
    let isPackage: Bool
}

@MainActor protocol OpenWithApplicationProviding {
    func cachedApplications(for item: FileItem) -> [OpenWithApplication]?
    func requestApplications(for item: FileItem)
}

@MainActor protocol ApplicationOpening {
    func open(_ urls: [URL], with applicationURL: URL) async throws
}
```

- [ ] Test exact-kind cache keys, deduplication, current-app exclusion, localized name/URL ordering, icons, and invalidation.
- [ ] Test Open With hidden for ordinary directories/multiple selection, visible for one file/package, disabled while uncached/empty, then populated without selection changes.
- [ ] Query `NSWorkspace.urlsForApplications(toOpen:)` outside menu construction and publish cached results on `@MainActor`.
- [ ] Test scoped access, identity-preserving `.open` materialization, exact app capture, cancellation, replaced source, and preparation failure with no launch.
- [ ] Implement `ApplicationOpening` using captured application URL and `NSWorkspace.OpenConfiguration`.
- [ ] Run focused provider/router/menu suites; tests must only hit injected recorders.
- [ ] Commit the provider, router, two view files, and three named test files only with `git commit -m "feat: add safe open with routing"`.

---

### Task 7: Queue opposite-pane Copy and Move

**Files:**
- Modify: `Sources/BloomFileManager/Support/FileContextActionRouter.swift`
- Modify: `Sources/BloomFileManager/Stores/FileOperationController.swift`
- Modify: `Sources/BloomFileManager/Views/FilePaneView.swift`
- Modify: `Tests/BloomFileManagerTests/FileContextActionRouterTests.swift`
- Modify: `Tests/BloomFileManagerTests/FileOperationControllerTests.swift`

**Interfaces:**

```swift
func identifiedTransferRequests(
    from snapshot: ContextActionSnapshot
) async -> [IdentifiedTransferRequest]?

func transferToCapturedDirectory(
    _ requests: [IdentifiedTransferRequest],
    mode: TransferMode,
    workspace: WorkspaceState
) -> Bool
```

- [ ] Test exact captured destination, source/destination replacement, non-writable capability, stable source order, and same-directory disablement.
- [ ] Test ordinary copy/move job behavior: conflict, pause, cancel, retry, recovery, pane refresh, and Undo.
- [ ] Revalidate destination identity/capability, then call `runIdentifiedTransfer(_:mode:workspace:onCompletion:includeSafeRelativePaths:)` with `includeSafeRelativePaths: false`; never compute destination inside the queued closure.
- [ ] Run focused router/controller/mutation suites.
- [ ] Commit the three production files and two test files listed in this task only with `git commit -m "feat: add opposite pane transfers"`.

---

### Task 8: Implement Duplicate as keep-both

**Files:**
- Modify: `Sources/BloomFileManager/Models/FileOperationJobModels.swift`
- Modify: `Sources/BloomFileManager/Stores/FileOperationController.swift`
- Modify: `Sources/BloomFileManager/Services/FileOperationService.swift`
- Modify: `Sources/BloomFileManager/Services/FileOperationUndoService.swift`
- Modify: `Tests/BloomFileManagerTests/FileOperationJobModelsTests.swift`
- Modify: `Tests/BloomFileManagerTests/FileOperationControllerTests.swift`
- Modify: `Tests/BloomFileManagerTests/FileOperationMutationTests.swift`
- Modify: `Tests/BloomFileManagerTests/FileOperationUndoServiceTests.swift`

**Interfaces:**

```swift
// Add to FileOperationJobKind
case duplicate

func duplicate(
    _ snapshot: ContextActionSnapshot,
    in pane: FilePaneState,
    workspace: WorkspaceState
) -> Bool

extension FileOperationService {
    func duplicate(
        _ requests: [IdentifiedTransferRequest],
        progress: OperationProgressHandler
    ) async -> FileOperationResult
}
```

- [ ] Test title/progress/retry/Undo presentation.
- [ ] Test files, directories, packages, symlinks, extension-preserving collisions, repeated collisions, replacement, cancellation, partial failure, and stable outcomes.
- [ ] Add adversarial service tests for a destination raced in after keep-both name planning and for same-identity source content mutation during copy. Neither case may overwrite or publish an unverified duplicate.
- [ ] Implement `FileOperationService.duplicate` as a distinct identified-copy policy: capture source fingerprint before copy, create the staged copy, verify source and staged fingerprints before publication, and publish with destination-parent-identity-checked `moveExclusively`.
- [ ] If exclusive publication reports `EEXIST`, discard only the owned staged copy, refresh occupied names, choose the next extension-preserving keep-both name, and retry without replacing the raced-in entry. Any source fingerprint or identity mismatch fails that source without publication.
- [ ] Enqueue one `.duplicate` job targeting the captured source parent and call the Duplicate-specific service method; never display replace conflict UI or route through the ordinary interactive copy resolver.
- [ ] Reuse `.removeCreated` Undo for `.duplicate`, requiring final identity and fingerprint and denying group Undo after partial completion.
- [ ] After successful refresh, select duplicate destinations only if the captured pane still displays captured parent.
- [ ] Run `FileOperationJobModelsTests|FileOperationControllerTests|FileOperationMutationTests|FileOperationUndoServiceTests`.
- [ ] Commit the four production files and four named test files only with `git commit -m "feat: add safe duplicate operation"`.

---

### Task 9: Add enclosure planning model and sheet

**Files:**
- Create: `Sources/BloomFileManager/Models/SelectionFolderModels.swift`
- Create: `Sources/BloomFileManager/Stores/SelectionFolderModel.swift`
- Create: `Sources/BloomFileManager/Views/SelectionFolderSheet.swift`
- Modify: `Sources/BloomFileManager/Views/WorkspaceView.swift`
- Modify: `Sources/BloomFileManager/Support/AccessibilityIdentifiers.swift`
- Create: `Tests/BloomFileManagerTests/SelectionFolderModelTests.swift`
- Create: `Tests/BloomFileManagerTests/SelectionFolderSheetTests.swift`
- Create: `Tests/BloomFileManagerTests/WorkspaceModalPresentationStateTests.swift`

**Interfaces:**

```swift
struct SelectionFolderPlan: Sendable, Equatable {
    let parentURL: URL
    let parentIdentity: FileIdentity
    let folderName: String
    let folderURL: URL
    let sources: [ContextActionSource]
}

@MainActor @Observable
final class SelectionFolderModel {
    private(set) var snapshot: ContextActionSnapshot?
    private(set) var validationMessage: String?
    var folderName = "New Folder with Items"
    var isPresented = false
    var canSubmit: Bool { get }
    func present(_ snapshot: ContextActionSnapshot) async
    func updateName(_ value: String)
    func beginSubmission() -> SelectionFolderPlan?
    func dismiss()
}
```

- [ ] Test default/trimmed names; empty, dot entries, slash, NUL, canonical/case collision; changed parent; non-siblings; fewer than two; and non-writable capability.
- [ ] On present, load `names(in:)` and comparison policy through scoped access. Disable Submit until the current request generation completes.
- [ ] Test dynamic count, validation, focus, Return, Escape, identifiers, and disabled submit.
- [ ] Make enclosure mutually exclusive with conflict, search, batch rename, and password sheets in `WorkspaceModalPresentationState`.
- [ ] Ensure submit returns captured identities and never live selection.
- [ ] Run focused model/sheet/modal tests.
- [ ] Commit the five production files and three test files listed in this task only with `git commit -m "feat: add selection folder planning sheet"`.

---

### Task 10: Build enclosure and reverse transactions

**Files:**
- Modify: `Sources/BloomFileManager/Services/FileSystemAccess.swift`
- Create: `Sources/BloomFileManager/Services/SelectionFolderTransactionService.swift`
- Modify: `Sources/BloomFileManager/Models/FileOperationModels.swift`
- Create: `Tests/BloomFileManagerTests/SelectionFolderTransactionServiceTests.swift`
- Modify: `Tests/BloomFileManagerTests/FileSystemAccessTests.swift`

**Interfaces:**

```swift
func removeEmptyDirectory(
    _ url: URL,
    identifiedBy identity: FileIdentity
) async throws

enum SelectionFolderTransactionPhase: Sendable, Equatable {
    case creatingFolder, movingItems, rollingBack
}

struct SelectionFolderUndoPlan: Sendable, Equatable {
    let parentURL: URL
    let parentIdentity: FileIdentity
    let folderURL: URL
    let folderIdentity: FileIdentity
    let entries: [SelectionFolderUndoEntry]
}

actor SelectionFolderTransactionService {
    func execute(_ plan: SelectionFolderPlan,
                 progress: @escaping @Sendable (SelectionFolderTransactionProgress) async -> Void)
        async -> FileOperationResult
    func reverse(_ plan: SelectionFolderUndoPlan,
                 progress: @escaping @Sendable (SelectionFolderTransactionProgress) async -> Void)
        async -> FileOperationResult
}
```

- [ ] First test descriptor-backed empty-directory removal: correct/wrong identity, symlink, file, non-empty folder, and raced-in child. No path may recurse.
- [ ] Implement with parent descriptor, `O_NOFOLLOW`, identity comparison, and `unlinkat(parentDescriptor, name, AT_REMOVEDIR)`; update all test doubles safely.
- [ ] Test forward preflight, exclusive final folder creation, ordered identity-checked moves, metadata, and scoped-access balance.
- [ ] Test cancel/failure before create, after create, and after every move; reverse rollback order; owned empty-folder removal; no overwrite; incomplete rollback Recovery Needed.
- [ ] Implement with `createEmptyItemAndCaptureIdentity(.directory)`, destination-parent identities, post-move fingerprints, and basename-only progress.
- [ ] Test reverse global preflight before mutation: parent/folder identities, exact child names, child identities/fingerprints, and all original paths empty.
- [ ] Implement reverse moves plus safe folder removal; on failure, move completed items back into the folder. Incomplete reverse rollback is Recovery Needed.
- [ ] Add `SelectionFolderUndoPlan` metadata to `FileOperationResult`; extend init, merge, and metadata accessors without dropping batch rename metadata or changing established public outcome equality semantics.
- [ ] Run `SelectionFolderTransactionServiceTests|FileSystemAccessTests|FileOperationModelsTests`.
- [ ] Commit the three production files, two named test files, and only the support doubles actually changed with `git commit -m "feat: add transactional selection enclosure"`.

---

### Task 11: Integrate enclosure queue, progress, Undo, and completion selection

**Files:**
- Modify: `Sources/BloomFileManager/Models/FileOperationJobModels.swift`
- Modify: `Sources/BloomFileManager/Stores/FileOperationController.swift`
- Modify: `Sources/BloomFileManager/Services/FileOperationService.swift`
- Modify: `Sources/BloomFileManager/Services/FileOperationUndoService.swift`
- Modify: `Sources/BloomFileManager/Views/WorkspaceView.swift`
- Modify: `Tests/BloomFileManagerTests/FileOperationJobModelsTests.swift`
- Modify: `Tests/BloomFileManagerTests/FileOperationControllerTests.swift`
- Modify: `Tests/BloomFileManagerTests/FileOperationUndoServiceTests.swift`

**Interfaces:**

```swift
// Add cases
case encloseSelection                  // FileOperationJobKind
case enclosingSelection(SelectionFolderTransactionProgress) // FileOperationStage
case selectionFolder(SelectionFolderUndoPlan)                // Undo recipe

func encloseSelection(
    _ plan: SelectionFolderPlan,
    in pane: FilePaneState,
    workspace: WorkspaceState
) -> Bool
```

- [ ] Test job title, each progress phase, exclusive admission, cancellation, retry rules, and recovery queue blocking.
- [ ] Add a service factory and inject the same transaction service into controller and Undo service while preserving initializer defaults.
- [ ] Enqueue one exclusive job with parent/folder touched directories and captured source cancellation URLs.
- [ ] Test Undo recipe acceptance only after complete success/revalidation. Changed child, extra child, occupied original, changed folder, or non-success outcome yields no mutation.
- [ ] Route recipe to `reverse`, publish Operation Center progress, and include parent/folder in Undo invalidation keys.
- [ ] On success, select only created folder if the captured pane is still at captured parent; never activate a different pane.
- [ ] Run job/controller/Undo/transaction suites.
- [ ] Commit the five production files and three named test files only with `git commit -m "feat: integrate selection enclosure operation"`.

---

### Task 12: Add menu-bar parity, shortcuts, app wiring, and accessibility

**Files:**
- Modify: `Sources/BloomFileManager/App/BloomFileManagerApp.swift`
- Modify: `Sources/BloomFileManager/Support/WorkspaceCommands.swift`
- Modify: `Sources/BloomFileManager/Views/WorkspaceView.swift`
- Modify: `Sources/BloomFileManager/Views/FilePaneView.swift`
- Modify: `Sources/BloomFileManager/Support/AccessibilityIdentifiers.swift`
- Modify: `Tests/BloomFileManagerTests/WorkspaceCommandTests.swift`
- Modify: `Tests/BloomFileManagerTests/AccessibilityPresentationTests.swift`

**Interfaces:**

```swift
Button("Copy Full Path") { dispatchContextAction(.copyPath(.fullPath)) }
    .keyboardShortcut("c", modifiers: [.command, .option])

Button("Duplicate") { dispatchContextAction(.duplicate) }
    .keyboardShortcut("d", modifiers: .command)
```

- [ ] Test Quick Look remains Space, Copy Full Path is Option-Command-C, Duplicate is Command-D, and other new File Operations entries have no shortcut.
- [ ] Test menu bar/right-click produce the same ordered draft and policy result.
- [ ] Instantiate exactly one router, provider/cache, and enclosure model in the app, using shared cloud runtime dependencies.
- [ ] Add accessibility projections for destination pane, item count, disabled reason, progress, and outcome; assert no absolute path.
- [ ] During text editing, disable file-path copy or preserve text-responder routing according to shared policy. Keep Command-C file copy unchanged.
- [ ] Run `WorkspaceCommandTests|WorkspaceCommandPolicyTests|AccessibilityPresentationTests|FileTableViewLifecycleTests`.
- [ ] Commit the five production files and two test files listed in this task only with `git commit -m "feat: wire context actions across workspace"`.

---

### Task 13: Performance, documentation, and complete verification

**Files:**
- Modify: `README.md`
- Modify: `README.ko.md`
- Modify: `docs/user-guide.md`
- Modify: `docs/user-guide.ko.md`
- Create: `docs/verification/2026-08-11-file-context-actions.md`
- Create: `Tests/BloomFileManagerTests/ContextMenuPerformanceTests.swift`

**Interfaces:**

```swift
struct ContextMenuPerformanceMeasurement: Sendable, Equatable {
    let itemCount: Int
    let elapsed: Duration
    let identityRequestCount: Int
    let materializationRequestCount: Int
}
```

The verification note records automated and manual rows separately with exactly
one of `PASS`, `FAIL`, or `NOT RUN`; it never promotes an inferred result.

- [ ] Add a 10,000-row menu-policy benchmark. Assert only in-memory metadata is filtered, no identity/content/materialization call occurs, and construction stays within one main-run-loop turn. Record timing as evidence, not a brittle four-second threshold.
- [ ] Document in English/Korean: exact groups, selection semantics, shortcuts, captured destination, collision rules, cloud limitations, progress/cancel/retry/recovery, and conservative Undo.
- [ ] Run the full suite:

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --enable-swift-testing --no-parallel --filter BloomFileManagerTests
```

- [ ] Run release gates:

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift build -c release
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./script/build_and_run.sh --verify
```

- [ ] Record test/suite totals, elapsed time, build result, and bundle verification in the verification note.
- [ ] Manually record `PASS`, `FAIL`, or `NOT RUN` for grouping/icons, selection, shortcuts, Quick Look, app launch, Finder reveal, path clipboard, pane changes after invocation, Duplicate/Undo, enclosure cancel/rollback/Undo, Full Keyboard Access, and VoiceOver order.
- [ ] If signed-in OneDrive File Provider is available, separately verify materialization, Open With, opposite-pane transfer, Duplicate, enclosure, progress/cancel, Undo, and prompt behavior. Otherwise record `NOT RUN`.
- [ ] Audit:

```bash
rg -n 'TODO|TBD|FIXME|fatalError\("not implemented"' Sources Tests README.md README.ko.md docs
git diff --check
git status --short
git log --oneline --decorate -15
```

- [ ] Commit only the README/user-guide files, verification note, and `ContextMenuPerformanceTests.swift` with `git commit -m "docs: document file context productivity actions"`.
- [ ] Stop before installation, push, DMG, or GitHub release; those require a separate delivery request after review.

## Final Acceptance Checklist

- [ ] All eight approved feature groups obey approved visibility and enablement.
- [ ] Menu-bar Quick Look, Copy Full Path, and Duplicate shortcuts have no collision.
- [ ] Right-click semantics and stable visible order have AppKit coverage.
- [ ] Byte-dependent actions use existing materialization; path/navigation actions do not.
- [ ] Mutations capture/revalidate identities and writable capability.
- [ ] Opposite-pane work cannot be redirected after invocation.
- [ ] Duplicate never overwrites and only unchanged complete results are undoable.
- [ ] Enclosure forward, rollback, reverse, and race tests preserve external entries.
- [ ] Full suite, release build, and bundle verification pass.
- [ ] Manual rows contain evidence or `NOT RUN`; no inferred passes.
- [ ] No install, push, DMG, or release occurred during implementation.
