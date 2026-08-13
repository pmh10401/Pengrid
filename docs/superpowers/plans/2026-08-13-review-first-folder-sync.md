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
- Block type/name conflicts, checking, unstable, error, symbolic links, packages, special entries, equal/nested roots, changed roots, and unsupported ancestor relationships.
- Coalesce descendants when a selected top-level directory copy or Trash action already covers them.
- Capture exact root identities, source fingerprints, existing destination fingerprints, and expected destination absences before confirmation; recheck immediately before mutation.
- Stage and verify every copy before quarantining any pre-existing destination.
- Never call permanent deletion for pre-existing user data. Quarantines move to Trash only after publication verification.
- Cancellation/failure must restore all owned changes or return Recovery Needed and block the queue.
- Completed synchronization is intentionally not exposed as Undoable in the MVP; its transaction owns in-flight rollback only.
- Shared `FileOperationController`, comparison views, app injection, and docs are integration-owner-only until planner/preparation/transaction suites are independently green.
- Follow RED → observed expected failure → minimal GREEN → focused pass for every production behavior.

---

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
@Test func equalOrNestedRootsAreBlocked() throws
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

Acquire access for both roots, recheck root identities before and after per-item capture, use no-follow identity/fingerprint APIs, require every draft comparison fingerprint to agree with live values, and calculate capacity conservatively. Do not materialize File Provider items implicitly; return a typed unavailable blocker.

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
- Modify only when a narrow descriptor-safe primitive is proven necessary: `Sources/BloomFileManager/Services/FileSystemAccess.swift`
- Modify matching tests only when that primitive is added: `Tests/BloomFileManagerTests/FileSystemAccessTests.swift`

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

### Task 4: Comparison, queue, review UI, and documentation integration

**Files:**
- Modify: `Sources/BloomFileManager/Models/FileOperationJobModels.swift`
- Modify: `Sources/BloomFileManager/Stores/FileOperationController.swift`
- Modify: `Sources/BloomFileManager/Stores/ComparisonCoordinator.swift`
- Modify: `Sources/BloomFileManager/Views/ComparisonActionBar.swift`
- Modify: `Sources/BloomFileManager/Views/ComparisonView.swift`
- Modify: `Sources/BloomFileManager/Views/OperationStatusView.swift`
- Modify: `Sources/BloomFileManager/App/BloomFileManagerApp.swift`
- Modify: matching controller/comparison/presentation/accessibility tests
- Modify: `README.md`, `README.ko.md`, `docs/user-guide.md`, `docs/user-guide.ko.md`, `docs/current-limitations.md`, `docs/current-limitations.ko.md`

- [ ] **Step 1: Add failing controller and presentation tests**

Prove no enqueue before review confirmation, stale generation rejection, exclusive admission, cancellation source coverage, progress mapping, queue recovery blocking, reconciliation after success, and `canUndo == false`. Presentation tests cover direction, action counts, representative relative paths, capacity, blockers, destructive Trash wording, stable accessibility identifiers, and no absolute-path announcements.

- [ ] **Step 2: Run focused integration tests and verify RED**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --enable-swift-testing --no-parallel --filter 'FolderSynchronizationIntegrationTests|ComparisonPresentationTests|ComparisonAccessibilityTests|FileOperationControllerTests|OperationStatusViewTests'
```

- [ ] **Step 3: Wire a captured review into the exclusive queue**

Add `.synchronizeFolder` job kind and synchronization progress stage. `ComparisonCoordinator` may request a draft only from its current immutable snapshot; the review model prepares it; confirmation passes the exact prepared value to `FileOperationController`. The controller enqueues one exclusive non-retryable, non-Undoable transaction bound to the captured workspace and both roots. On complete success, reconcile comparison roots/subtrees; on any other result, invalidate and refresh the comparison.

- [ ] **Step 4: Build the review UI**

Expose `Review Left → Right` and `Review Right → Left` only when comparison is current. Present a sheet with Copy/Replace/Move to Trash counts, byte estimate, blockers, and Cancel/Start controls. Disable Start during preparation, stale comparison, an exclusive active/queued operation, or recovery blocking. VoiceOver values expose counts and relative names only.

- [ ] **Step 5: Update documentation and verify**

Document one-shot scope, review/confirmation, Trash semantics, whole-plan rollback, Recovery Needed, unsupported kinds, File Provider non-materialization default, and the absence of post-completion Undo. Run focused tests, the full `BloomFileManagerTests` suite, release build, bundle verification, placeholder scan, and `git diff --check`; require zero failures. Record live local smoke results and leave signed-in File Provider checks explicitly NOT RUN when unavailable.

- [ ] **Step 6: Commit integration**

```bash
git add Sources/BloomFileManager/Models/FileOperationJobModels.swift Sources/BloomFileManager/Stores/FileOperationController.swift Sources/BloomFileManager/Stores/ComparisonCoordinator.swift Sources/BloomFileManager/Views/ComparisonActionBar.swift Sources/BloomFileManager/Views/ComparisonView.swift Sources/BloomFileManager/Views/OperationStatusView.swift Sources/BloomFileManager/App/BloomFileManagerApp.swift Tests/BloomFileManagerTests README.md README.ko.md docs/user-guide.md docs/user-guide.ko.md docs/current-limitations.md docs/current-limitations.ko.md
git commit -m "feat: integrate reviewed folder synchronization"
```
