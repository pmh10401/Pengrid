# Review-First One-Way Folder Synchronization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn a stable directory comparison into a reviewed, identity-bound one-way synchronization transaction that never mutates before confirmation and never permanently deletes pre-existing user data.

**Architecture:** A pure planner converts one immutable comparison snapshot into ordered actions and blockers. A preparation service revalidates roots, captures exact source/destination fingerprints, expected absences, and capacity before presenting a review. A dedicated transaction stages all copied data, quarantines replacements and destination-only entries, publishes verified staged outputs, and only then transfers quarantines to Trash. It rolls back the whole plan or reports Recovery Needed; it does not compose existing per-item transfer and Trash jobs.

**Tech Stack:** Swift 6.1 actors, Foundation, Observation/SwiftUI, descriptor-safe `FileSystemAccess`, `SourceFingerprint`, `ComparisonCoordinator`, Swift Testing, macOS 15.

## Global Constraints

- Prefix Swift verification commands with `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun`.
- MVP is one-shot and one-way. There is no background watcher, recurring schedule, two-way merge, or mirror-without-review mode.
- Planning requires `ComparisonPhase.upToDate`, a current `ComparisonSession`, and one captured generation.
- Copy source-only entries; replace supported same-kind changed entries; move destination-only entries to Trash; skip identical entries.
- Block type/name conflicts, checking, unstable, error, symbolic links, packages, special entries, equal identities, lexically equal/nested roots, changed roots, and unsupported ancestor relationships. Because the pure planner performs no I/O, preparation must additionally reject canonical, alias-, mount-, or symbolic-link-mediated equal/nested roots before review or mutation.
- Coalesce descendants when a selected top-level directory copy or Trash action already covers them.
- Capture exact root identities, source fingerprints, existing destination fingerprints, and expected destination absences before confirmation; recheck immediately before mutation.
- Stage and verify every copy before quarantining any pre-existing destination.
- Never call permanent deletion for pre-existing user data. Quarantines move to Trash only after publication verification.
- Cancellation/failure must restore all owned changes or return Recovery Needed and block the queue.
- Completed synchronization is intentionally not exposed as Undoable in the MVP; its transaction owns in-flight rollback only.
- Shared `FileOperationController`, comparison views, app injection, and docs are integration-owner-only until planner/preparation/transaction suites are independently green.
- Follow RED → observed expected failure → minimal GREEN → focused pass for every production behavior.

---

## Execution status

Tasks 1–3 are already implemented and integrated through commits `a71db40`, `4e8b2bb`,
and `b698f0f`. Do not repeat or rewrite them. The remaining implementation scope is
Tasks 4–7 only.

### Task 1: Pure synchronization plan models and planner

**Files:**
- Create: `Sources/BloomFileManager/Models/FolderSynchronizationModels.swift`
- Create: `Sources/BloomFileManager/Services/FolderSynchronizationPlanningService.swift`
- Create: `Tests/BloomFileManagerTests/FolderSynchronizationModelsTests.swift`
- Create: `Tests/BloomFileManagerTests/FolderSynchronizationPlanningServiceTests.swift`

**Interfaces:**
- Consumes immutable `ComparisonSession`, `ComparisonPhase`, `[ComparisonRow]`, and `ComparisonDirection` values only.
- Produces immutable ordered actions and a typed ready/already-synchronized/blocked result. The planner performs no file-system calls.

- [ ] **Step 1: Add failing literal model tests**

```swift
@Test func readyDraftRetainsGenerationRootsAndDeterministicActions() throws
@Test func blockerPresentationDoesNotExposeAbsolutePaths() throws
@Test func actionKindDefinesCopyReplaceAndTrashOnly() throws
```

- [ ] **Step 2: Run model tests and verify RED**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --enable-swift-testing --no-parallel --filter FolderSynchronizationModelsTests
```

Expected: compilation fails because synchronization models do not exist.

- [ ] **Step 3: Implement value models**

Use these shapes, adding validated initializers rather than accepting inconsistent paths:

```swift
enum FolderSynchronizationActionKind: String, Sendable, Equatable {
    case copy
    case replace
    case moveDestinationToTrash
}

struct FolderSynchronizationAction: Sendable, Equatable, Identifiable {
    let relativePath: ComparisonRelativePath
    let kind: FolderSynchronizationActionKind
    let source: ComparisonEntry?
    let destination: ComparisonEntry?
    var id: ComparisonRelativePath { relativePath }
}

enum FolderSynchronizationPlanningResult: Sendable, Equatable {
    case ready(FolderSynchronizationPlanDraft)
    case alreadySynchronized(FolderSynchronizationPlanSummary)
    case blocked([FolderSynchronizationBlocker])
}
```

`FolderSynchronizationPlanDraft` stores direction, comparison generation, both roots and identities, ordered actions, skip count, and estimated regular-file copy bytes. `FolderSynchronizationBlocker` stores relative path plus a stable reason enum; it never stores localized error text containing absolute paths.

- [ ] **Step 4: Add failing planner tests**

Cover both directions and every comparison status:

```swift
@Test func sourceOnlyRegularFileBecomesCopy() throws
@Test func supportedChangedSameKindBecomesReplace() throws
@Test func destinationOnlyEntryBecomesTrash() throws
@Test func identicalEntriesAreSkippedAndEmptyPlanIsAlreadySynchronized() throws
@Test func topLevelDirectoryActionSuppressesDescendantActions() throws
@Test func actionsSortParentsBeforeChildrenAndUseStableRelativePathOrder() throws
@Test func nonCurrentPhaseAndMissingSessionAreBlocked() throws
@Test func conflictsCheckingUnstableErrorsAndUnsupportedKindsAreBlocked() throws
@Test func equalIdentityOrLexicallyNestedRootsAreBlocked() throws
```

- [ ] **Step 5: Run planner tests and verify RED**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --enable-swift-testing --no-parallel --filter FolderSynchronizationPlanningServiceTests
```

Expected: compilation fails because the planner does not exist.

- [ ] **Step 6: Implement the pure planner**

```swift
struct FolderSynchronizationPlanningService: Sendable {
    func plan(
        phase: ComparisonPhase,
        session: ComparisonSession?,
        rows: [ComparisonRow],
        direction: ComparisonDirection
    ) -> FolderSynchronizationPlanningResult
}
```

Map source/destination through `ComparisonRow.source(for:)` and `destination(for:)`. Reject the entire draft if any actionable row is unsafe. Coalesce only when a parent directory action has the same semantic effect for every descendant; never hide a descendant blocker. Sort by component count and `ComparisonRelativePath` so parent operations precede children deterministically.

- [ ] **Step 7: Run Task 1 tests and verify GREEN**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --enable-swift-testing --no-parallel --filter 'FolderSynchronizationModelsTests|FolderSynchronizationPlanningServiceTests|ComparisonCoordinatorTests'
git diff --check
```

- [ ] **Step 8: Commit Task 1**

```bash
git add Sources/BloomFileManager/Models/FolderSynchronizationModels.swift Sources/BloomFileManager/Services/FolderSynchronizationPlanningService.swift Tests/BloomFileManagerTests/FolderSynchronizationModelsTests.swift Tests/BloomFileManagerTests/FolderSynchronizationPlanningServiceTests.swift
git commit -m "feat: plan reviewed folder synchronization"
```

### Task 2: Identity-bound preparation and review state

**Files:**
- Create: `Sources/BloomFileManager/Services/FolderSynchronizationPreparationService.swift`
- Create: `Sources/BloomFileManager/Stores/FolderSynchronizationReviewModel.swift`
- Create: `Tests/BloomFileManagerTests/FolderSynchronizationPreparationServiceTests.swift`
- Create: `Tests/BloomFileManagerTests/FolderSynchronizationReviewModelTests.swift`

- [ ] **Step 1: Add failing preparation tests**

Use an in-memory `FileSystemAccess` double to cover root replacement, source/destination mutation, expected-absence occupation, capacity shortage, scoped-access failure, and cancellation. Require balanced scoped-access leases.

- [ ] **Step 2: Run tests and verify RED**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --enable-swift-testing --no-parallel --filter 'FolderSynchronizationPreparationServiceTests|FolderSynchronizationReviewModelTests'
```

- [ ] **Step 3: Implement prepared-plan authority**

```swift
struct PreparedFolderSynchronizationPlan: Sendable, Equatable {
    let draft: FolderSynchronizationPlanDraft
    let sourceFingerprints: [ComparisonRelativePath: SourceFingerprint]
    let destinationFingerprints: [ComparisonRelativePath: SourceFingerprint]
    let expectedAbsentDestinations: Set<ComparisonRelativePath>
    let requiredCapacityBytes: Int64
}

actor FolderSynchronizationPreparationService {
    func prepare(_ draft: FolderSynchronizationPlanDraft) async throws
        -> PreparedFolderSynchronizationPlan
}
```

Acquire access for both roots, resolve and reject canonical, alias-, mount-, and symbolic-link-mediated equal/nested root relationships, recheck root identities before and after per-item capture, use no-follow identity/fingerprint APIs, require every draft comparison fingerprint to agree with live values, and calculate capacity conservatively. This preparation check is the filesystem authority for root ancestry; a pure-planner lexical pass is never sufficient by itself. Do not materialize File Provider items implicitly; return a typed unavailable blocker.

- [ ] **Step 4: Implement review state**

`FolderSynchronizationReviewModel` owns idle/preparing/ready/blocked states, the captured direction and generation, summary counts, representative relative paths, explicit confirmation, cancellation, and reset. A late preparation result must not replace a newer generation.

- [ ] **Step 5: Run Task 2 tests and verify GREEN**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --enable-swift-testing --no-parallel --filter 'FolderSynchronizationPreparationServiceTests|FolderSynchronizationReviewModelTests'
git diff --check
```

- [ ] **Step 6: Commit Task 2**

```bash
git add Sources/BloomFileManager/Services/FolderSynchronizationPreparationService.swift Sources/BloomFileManager/Stores/FolderSynchronizationReviewModel.swift Tests/BloomFileManagerTests/FolderSynchronizationPreparationServiceTests.swift Tests/BloomFileManagerTests/FolderSynchronizationReviewModelTests.swift
git commit -m "feat: prepare folder synchronization reviews"
```

### Task 3: Whole-plan synchronization transaction

**Files:**
- Create: `Sources/BloomFileManager/Services/FolderSynchronizationTransactionService.swift`
- Create: `Tests/BloomFileManagerTests/FolderSynchronizationTransactionServiceTests.swift`
- Modify: `Sources/BloomFileManager/Services/FileSystemAccess.swift`
- Test: `Tests/BloomFileManagerTests/FileSystemAccessTests.swift`

- [ ] **Step 1: Add a deterministic phase/fault test double and RED tests**

Inject cancellation and failure before/after each boundary: preflight, stage copy, staged verification, quarantine, exclusive publication, publication verification, Trash transfer, and rollback. Prove that pre-existing destination bytes are either restored or represented by Recovery Needed.

- [ ] **Step 2: Run transaction tests and verify RED**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --enable-swift-testing --no-parallel --filter FolderSynchronizationTransactionServiceTests
```

- [ ] **Step 3: Implement explicit transaction phases**

```swift
enum FolderSynchronizationTransactionPhase: Sendable, Equatable {
    case preflighting
    case staging
    case verifyingStaging
    case quarantining
    case publishing
    case verifyingPublished
    case movingToTrash
    case rollingBack
}

actor FolderSynchronizationTransactionService {
    func execute(
        _ plan: PreparedFolderSynchronizationPlan,
        progress: @escaping @Sendable (FolderSynchronizationProgress) async -> Void
    ) async -> FileOperationResult
}
```

Create all staging under service-owned unique directories. Recheck the complete prepared authority immediately before the first mutation. Stage copy/replace sources and verify relocation-safe fingerprints. Quarantine replacements and Trash actions without deleting them. Publish with exclusive no-replace moves, then verify. Only after every publication is valid may quarantines move to Trash. On cancellation/failure, detach rollback from the cancelled task, remove owned publications identity-safely, restore quarantines exclusively, and clean only owned staging. Escalate any incomplete rollback to `.recoveryNeeded`.

- [ ] **Step 4: Prove no permanent deletion and balanced access**

Add source inspection and runtime tests that reject `removeItem`, `unlink`, or equivalent permanent deletion of pre-existing paths; owned staging cleanup remains allowed. Test scoped access balance and no staging residue after success, clean cancellation, and recoverable failure.

- [ ] **Step 5: Run Task 3 tests and verify GREEN**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --enable-swift-testing --no-parallel --filter 'FolderSynchronizationTransactionServiceTests|FileSystemAccessTests|FinalReviewFixTests'
git diff --check
```

- [ ] **Step 6: Commit Task 3**

```bash
git add Sources/BloomFileManager/Services/FolderSynchronizationTransactionService.swift Tests/BloomFileManagerTests/FolderSynchronizationTransactionServiceTests.swift Sources/BloomFileManager/Services/FileSystemAccess.swift Tests/BloomFileManagerTests/FileSystemAccessTests.swift
git commit -m "feat: execute atomic folder synchronization"
```

### Task 4: Exclusive queue contract and operation-center progress

**Files:**
- Modify: `Sources/BloomFileManager/Models/FileOperationJobModels.swift`
- Modify: `Sources/BloomFileManager/Stores/FileOperationController.swift`
- Modify: `Sources/BloomFileManager/Views/OperationStatusView.swift`
- Modify: `Sources/BloomFileManager/App/BloomFileManagerApp.swift`
- Test: `Tests/BloomFileManagerTests/FileOperationControllerTests.swift`
- Test: `Tests/BloomFileManagerTests/OperationStatusViewTests.swift`

**Interfaces:**
- Consumes: `PreparedFolderSynchronizationPlan`, `FolderSynchronizationTransactionService.execute(_:progress:)`, and `WorkspaceState`.
- Produces: `FileOperationJobKind.synchronizeFolder(ComparisonDirection)`, `FileOperationStage.synchronizing(FolderSynchronizationProgress)`, `FileOperationController.canAdmitFolderSynchronization`, and `FileOperationController.synchronizeFolder(plan:workspace:onCompletion:) -> Bool`.

- [ ] **Step 1: Write the failing queue-contract tests**

Add tests that construct a prepared plan and prove all of the following before production edits:

```swift
#expect(controller.canAdmitFolderSynchronization)
#expect(controller.synchronizeFolder(plan: plan, workspace: workspace))
#expect(controller.activeJob?.kind == .synchronizeFolder(.leftToRight))
#expect(controller.activeJob?.canRetry == false)
#expect(controller.activeJob?.canUndo == false)
```

Also assert admission is false during termination preparation, Recovery Needed blocking,
an active job, or a queued job; rejection must not invoke the transaction service.
Parameterize all eight `FolderSynchronizationTransactionPhase` values and assert exact
`FileOperationStage.synchronizing` publication with bounded counts and relative-path-only
detail. A recovery result must engage the existing global recovery gate.

- [ ] **Step 2: Run the focused tests and observe RED**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --enable-swift-testing --no-parallel --filter 'FileOperationControllerTests|OperationStatusViewTests'
```

Expected: compile failures for the new job kind, stage, admission property, and controller method.

- [ ] **Step 3: Add the queue and progress surface**

Add these exact public controller seams:

```swift
var canAdmitFolderSynchronization: Bool {
    !isTerminationPreparationActive
        && !isQueueBlockedByRecovery
        && activeOperation == nil
        && pendingOperations.isEmpty
}

@discardableResult
func synchronizeFolder(
    plan: PreparedFolderSynchronizationPlan,
    workspace: WorkspaceState,
    onCompletion: (@MainActor (FileOperationResult) -> Void)? = nil
) -> Bool
```

The method calls `beginOperation` with both roots as touched directories, every action
source/destination URL as cancellation sources, `allowsRetry: false`, and
`requiresExclusiveQueue: true`. It invokes the injected shared transaction service and
publishes `.synchronizing(progress)`. Do not ask `FileOperationUndoService` to create a
recipe for this job. Extend `OperationStatusView` with stable visual and VoiceOver labels
for every phase; expose only `currentRelativePath?.string`, never root paths.

- [ ] **Step 4: Run GREEN and commit the queue contract**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --enable-swift-testing --no-parallel --filter 'FileOperationControllerTests|OperationStatusViewTests'
git diff --check
git add Sources/BloomFileManager/Models/FileOperationJobModels.swift Sources/BloomFileManager/Stores/FileOperationController.swift Sources/BloomFileManager/Views/OperationStatusView.swift Sources/BloomFileManager/App/BloomFileManagerApp.swift Tests/BloomFileManagerTests/FileOperationControllerTests.swift Tests/BloomFileManagerTests/OperationStatusViewTests.swift
git commit -m "feat: queue reviewed folder synchronization"
```

### Task 5: Full-difference review ownership and admission-before-confirmation

**Files:**
- Modify: `Sources/BloomFileManager/Stores/ComparisonCoordinator.swift`
- Modify: `Sources/BloomFileManager/Stores/FolderSynchronizationReviewModel.swift`
- Create: `Tests/BloomFileManagerTests/FolderSynchronizationIntegrationTests.swift`
- Test: `Tests/BloomFileManagerTests/ComparisonCoordinatorTests.swift`
- Test: `Tests/BloomFileManagerTests/FolderSynchronizationReviewModelTests.swift`

**Interfaces:**
- Consumes: `FolderSynchronizationPlanningService.plan(phase:session:rows:direction:)`, `FolderSynchronizationReviewModel.prepare(_:)`, `FileOperationController.canAdmitFolderSynchronization`, and the Task 4 enqueue method.
- Produces: one observable review-presentation state representing planner-blocked, already-synchronized, preparing, preparation-blocked, and ready states; `requestFolderSynchronization(_:)`, `cancelFolderSynchronizationReview()`, and `confirmFolderSynchronizationReview(operationController:workspace:) -> Bool` on `ComparisonCoordinator`.

- [ ] **Step 1: Write the failing orchestration tests**

Use the coordinator's complete `rows`, not `visibleRows` or `selection`, and assert:

```swift
comparison.requestFolderSynchronization(.leftToRight)
#expect(planner.receivedRows == comparison.rows)
#expect(planner.receivedDirection == .leftToRight)
```

Cover `.upToDate + .ready`, `.alreadySynchronized`, planner blockers, and non-current
comparison. Assert planner-blocked and already-synchronized states never call the
preparer. Add a late-preparation test: cancelling or starting a newer direction must make
the earlier completion unable to publish. Most importantly, set controller admission to
false, invoke confirmation, and assert the review remains ready and `confirm()` was not
consumed. Then admit and prove exactly one confirmation and one enqueue.

- [ ] **Step 2: Run orchestration tests and observe RED**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --enable-swift-testing --no-parallel --filter 'FolderSynchronizationIntegrationTests|ComparisonCoordinatorTests|FolderSynchronizationReviewModelTests'
```

- [ ] **Step 3: Implement review ownership and safe completion reconciliation**

Keep planning pure and synchronous. Only a `.ready(draft)` result calls
`FolderSynchronizationReviewModel.prepare`. Store the captured workspace identity,
session roots, direction, and comparison generation in the presentation request.
Confirmation follows this order exactly:

```swift
guard operationController.canAdmitFolderSynchronization else { return false }
guard let plan = synchronizationReview.confirm() else { return false }
return operationController.synchronizeFolder(
    plan: plan,
    workspace: workspace,
    onCompletion: completionForCapturedComparison
)
```

`canAdmitFolderSynchronization` and the synchronous main-actor enqueue path must share
the exact same predicate, so no actor interleaving can invalidate admission between the
guard, `confirm()`, and enqueue. Cover that equivalence directly in Task 4 tests. On
complete success explicitly reconcile both captured roots without requiring the original
generation to remain current. On failure/cancellation, invalidate and restart only when
the same `WorkspaceState` still owns a comparison with the captured left/right roots;
never replace another workspace or a newer root pair.

- [ ] **Step 4: Run GREEN and commit orchestration**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --enable-swift-testing --no-parallel --filter 'FolderSynchronizationIntegrationTests|ComparisonCoordinatorTests|FolderSynchronizationReviewModelTests|FolderSynchronizationTransactionServiceTests'
git diff --check
git add Sources/BloomFileManager/Stores/ComparisonCoordinator.swift Sources/BloomFileManager/Stores/FolderSynchronizationReviewModel.swift Tests/BloomFileManagerTests/FolderSynchronizationIntegrationTests.swift Tests/BloomFileManagerTests/ComparisonCoordinatorTests.swift Tests/BloomFileManagerTests/FolderSynchronizationReviewModelTests.swift
git commit -m "feat: orchestrate reviewed folder synchronization"
```

### Task 6: Review sheet, modal ownership, tab teardown, and accessibility

**Files:**
- Modify: `Sources/BloomFileManager/Views/Comparison/ComparisonActionBar.swift`
- Modify: `Sources/BloomFileManager/Views/Comparison/ComparisonWorkspaceView.swift`
- Create: `Sources/BloomFileManager/Views/Comparison/FolderSynchronizationReviewSheet.swift`
- Modify: `Sources/BloomFileManager/Views/WorkspaceView.swift`
- Modify: `Sources/BloomFileManager/Views/WorkspaceTabBarView.swift`
- Modify: `Sources/BloomFileManager/Support/AccessibilityIdentifiers.swift`
- Test: `Tests/BloomFileManagerTests/ComparisonPresentationTests.swift`
- Test: `Tests/BloomFileManagerTests/ComparisonAccessibilityTests.swift`
- Test: `Tests/BloomFileManagerTests/AccessibilityPresentationTests.swift`
- Test: `Tests/BloomFileManagerTests/WorkspaceTabPresentationTests.swift`

**Interfaces:**
- Consumes: Task 5's presentation state and request/cancel/confirm actions.
- Produces: two full-scope Sync buttons, one exclusive review sheet, stable accessibility identifiers, and a non-no-op `dismissSynchronizationReview` teardown action.

- [ ] **Step 1: Write failing presentation and lifecycle tests**

Assert the action bar labels are exactly `Sync Left to Right…` and
`Sync Right to Left…`, do not inspect selection count, and dispatch their matching
direction. Render each sheet state and assert ready content includes root basenames,
copy/replace/Move to Trash/skip counts, formatted estimated bytes, and no more than eight
relative paths. Search rendered labels/values for the captured absolute root paths and
require zero matches. Assert destructive Trash wording and stable identifiers for sheet,
status, confirm, cancel, counts, and representative paths.

Add direct lifecycle tests proving the synchronization review participates in
`WorkspaceModalPresentationState`, sets `WorkspaceTabModalPolicy` to presented, and is
dismissed by `WorkspaceTabTeardownActions` without cancelling an already enqueued job.

- [ ] **Step 2: Run presentation tests and observe RED**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --enable-swift-testing --no-parallel --filter 'ComparisonPresentationTests|ComparisonAccessibilityTests|AccessibilityPresentationTests|WorkspaceTabPresentationTests'
```

- [ ] **Step 3: Implement the sheet and modal gates**

Mount the sheet from `ComparisonWorkspaceView`, but route its availability through the
shared workspace modal state. Disable Confirm while preparing, blocked, already
synchronized, stale, or controller admission is closed. Dismissal calls the Task 5 cancel
action. Add `synchronizationReviewPresented` to `WorkspaceTabModalPolicy.isPresented`,
and replace the existing no-op `dismissSynchronizationReview` teardown closure with the
captured comparison cancellation. Password, conflict, Smart Search, Batch Rename,
Selection Folder, Trash confirmation, Profiles, and synchronization review must remain
mutually exclusive.

- [ ] **Step 4: Run GREEN and commit UI integration**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --enable-swift-testing --no-parallel --filter 'FolderSynchronizationIntegrationTests|ComparisonPresentationTests|ComparisonAccessibilityTests|AccessibilityPresentationTests|WorkspaceTabPresentationTests|WorkspaceModalPresentationStateTests'
git diff --check
git add Sources/BloomFileManager/Views/Comparison/ComparisonActionBar.swift Sources/BloomFileManager/Views/Comparison/ComparisonWorkspaceView.swift Sources/BloomFileManager/Views/Comparison/FolderSynchronizationReviewSheet.swift Sources/BloomFileManager/Views/WorkspaceView.swift Sources/BloomFileManager/Views/WorkspaceTabBarView.swift Sources/BloomFileManager/Support/AccessibilityIdentifiers.swift Tests/BloomFileManagerTests
git commit -m "feat: present folder synchronization review"
```

### Task 7: Documentation, independent review, and release gates

**Files:**
- Modify: `README.md`
- Modify: `README.ko.md`
- Modify: `docs/user-guide.md`
- Modify: `docs/user-guide.ko.md`
- Modify: `docs/current-limitations.md`
- Modify: `docs/current-limitations.ko.md`
- Create: `docs/verification/2026-08-13-reviewed-folder-synchronization.md`

**Interfaces:**
- Consumes: the completed Tasks 4–6 behavior and test evidence.
- Produces: user-facing English/Korean guidance and an evidence ledger that separates automated, manual local-volume, and signed-in File Provider verification.

- [ ] **Step 1: Update user documentation**

Document full-difference scope, direction, planner/preparation blockers, review counts,
relative-path preview, Trash semantics, whole-plan in-flight rollback, Recovery Needed,
non-retryable execution, absence of post-success Undo, and File Provider
non-materialization. Remove any limitation that says one-way reviewed sync is absent;
retain explicit limits for bidirectional, scheduled, background, and permanent-delete
sync.

- [ ] **Step 2: Run focused and full automated gates**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --enable-swift-testing --no-parallel --filter 'FolderSynchronizationIntegrationTests|FolderSynchronizationTransactionServiceTests|FileOperationControllerTests|ComparisonPresentationTests|ComparisonAccessibilityTests|WorkspaceTabPresentationTests|OperationStatusViewTests'
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --enable-swift-testing --no-parallel
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift build -c release
./script/build_and_run.sh --verify
git diff --check
rg -n 'T[B]D|T[O]DO|F[I]XME|implement la[t]er' Sources Tests README.md README.ko.md docs
```

Expected: every command exits 0; the placeholder scan has no implementation or current
documentation matches. Existing protected-ZIP fixture declaration warnings may remain,
but record them rather than presenting them as new failures.

- [ ] **Step 3: Record verification without inventing manual evidence**

Record exact test/suite counts, durations, release and bundle results, and Grok/Codex
review verdicts. Mark local GUI smoke steps and signed-in OneDrive/Google Drive File
Provider steps `NOT RUN` unless they were actually performed. Required manual checks are
both directions, already-synchronized and blocked sheets, cancellation during copy and
Trash phases, Recovery Needed acknowledgement, VoiceOver relative-path output, and tab
close gating.

- [ ] **Step 4: Commit documentation and evidence**

```bash
git add README.md README.ko.md docs/user-guide.md docs/user-guide.ko.md docs/current-limitations.md docs/current-limitations.ko.md docs/verification/2026-08-13-reviewed-folder-synchronization.md
git commit -m "docs: document reviewed folder synchronization"
```
