# Archive Progress Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show exact source-preparation progress, an honest indeterminate native encoding phase, and a publishing phase for ZIP and TAR-family archive operations.

**Architecture:** Make archive progress phase-aware at the model boundary, thread a progress callback through `ArchiveCommandRunning`, publish monotonic top-level staging completion from the bounded parallel preparation workers, and let `ArchiveOperationService` own the final publishing phase. Keep native `ditto` and `tar` command execution indeterminate because their verbose streams cannot supply one reliable cross-format entry count.

**Tech Stack:** Swift 6.1, Swift Concurrency actors and task groups, SwiftUI `ProgressView`, Foundation `Process`, Swift Testing, Swift Package Manager, macOS 15+

## Global Constraints

- Work in `/Users/mac/Documents/Pengrid/.worktrees/safe-operation-center` on `codex/safe-operation-center`.
- Preserve package, executable, source module, and bundle compatibility name `BloomFileManager`.
- Preserve ZIP, TAR, TAR.GZ, TAR.BZ2, and TAR.XZ archive contents and no-overwrite staged publication.
- Do not enable or parse `ditto -V` or `tar -v`; native command progress is indeterminate.
- Preparation counts are monotonic, bounded to `0...total`, and based only on completed top-level staging copies.
- Publish 100% only after the archive output is verified and moved exclusively to its final destination.
- Visible and accessibility copy contains only the request's sanitized display name, never an absolute path.
- Keep cancellation cleanup and the existing standard-error capture limit unchanged.
- Use strict TDD: each production behavior begins with a test that is run and observed failing for the intended reason.

---

### Task 1: Phase-aware archive progress model and presentation

**Files:**
- Modify: `Sources/BloomFileManager/Models/ArchiveOperationModels.swift`
- Modify: `Sources/BloomFileManager/Views/OperationStatusView.swift`
- Modify: `Tests/BloomFileManagerTests/OperationStatusViewTests.swift`
- Modify: `Tests/BloomFileManagerTests/ArchiveFormatTests.swift`

**Interfaces:**
- Produces: `ArchiveOperationPhase`
- Produces: `ArchiveOperationProgress.phase`
- Produces: `ArchiveOperationProgress.fractionCompleted: Double?`
- Produces: `ArchiveOperationStatusPresentation.progressLabel`

- [ ] **Step 1: Write failing model and presentation tests**

Add tests that construct all three phases and assert independently derived behavior:

```swift
@Test func archivePreparationClampsAndReportsDeterminateFraction() {
    let progress = ArchiveOperationProgress(
        kind: .compress,
        currentDisplayName: "Reports.zip",
        format: .zip,
        phase: .preparingSources(completedCount: 2, totalCount: 4)
    )
    #expect(progress.fractionCompleted == 0.5)
    #expect(ArchiveOperationStatusPresentation(progress: progress).progressLabel
        == "Preparing files, 2 of 4")
}

@Test func encodingAndPublishingRemainIndeterminate() {
    let encoding = ArchiveOperationProgress(
        kind: .compress,
        currentDisplayName: "Reports.tar.gz",
        format: .tarGzip,
        phase: .encoding
    )
    let publishing = ArchiveOperationProgress(
        kind: .compress,
        currentDisplayName: "Reports.tar.gz",
        format: .tarGzip,
        phase: .publishing
    )
    #expect(encoding.fractionCompleted == nil)
    #expect(publishing.fractionCompleted == nil)
    #expect(ArchiveOperationStatusPresentation(progress: encoding).progressLabel
        == "Encoding archive")
    #expect(ArchiveOperationStatusPresentation(progress: publishing).progressLabel
        == "Finishing archive")
}
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --disable-sandbox --no-parallel \
  --filter 'OperationStatusViewTests|ArchiveFormatTests'
```

Expected: compilation fails because `ArchiveOperationPhase`, `phase`,
`fractionCompleted`, and `progressLabel` do not exist.

- [ ] **Step 3: Add the minimal phase-aware model**

Add:

```swift
enum ArchiveOperationPhase: Sendable, Equatable {
    case preparingSources(completedCount: Int, totalCount: Int)
    case encoding
    case publishing
}
```

Extend `ArchiveOperationProgress` with `phase`, defaulting to `.encoding` for
source compatibility. Implement `fractionCompleted` only for preparation and
clamp its numerator and denominator. Extend
`ArchiveOperationStatusPresentation` with `progressLabel` and include it in the
VoiceOver status label.

- [ ] **Step 4: Render determinate and indeterminate phases**

In `archiveStatus`, select the progress view without duplicating the surrounding
layout:

```swift
if let fraction = progress.fractionCompleted {
    ProgressView(value: fraction, total: 1)
        .frame(maxWidth: 180)
} else {
    ProgressView().controlSize(.small)
}
Text(presentation.progressLabel)
    .font(.caption.monospacedDigit())
    .foregroundStyle(.secondary)
```

- [ ] **Step 5: Run focused tests and verify GREEN**

Run the command from Step 2. Expected: all selected tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/BloomFileManager/Models/ArchiveOperationModels.swift \
  Sources/BloomFileManager/Views/OperationStatusView.swift \
  Tests/BloomFileManagerTests/OperationStatusViewTests.swift \
  Tests/BloomFileManagerTests/ArchiveFormatTests.swift
git commit -m "feat: model archive progress phases"
```

### Task 2: Monotonic progress from bounded parallel archive preparation

**Files:**
- Modify: `Sources/BloomFileManager/Services/ArchiveCommandRunner.swift`
- Modify: `Tests/BloomFileManagerTests/ArchiveCommandRunnerTests.swift`
- Modify: `Tests/BloomFileManagerTests/ArchiveOperationIntegrationTests.swift`

**Interfaces:**
- Consumes: `ArchiveOperationProgress`
- Produces: `typealias ArchiveCommandProgressHandler`
- Changes: `ArchiveCommandRunning.run(..., progress:)`

- [ ] **Step 1: Write failing progress callback tests**

Add a test using two real top-level files and a live runner. Collect callbacks
in an actor and assert literal phase values:

```swift
#expect(phases.first == .preparingSources(completedCount: 0, totalCount: 2))
#expect(phases.contains(.preparingSources(completedCount: 1, totalCount: 2)))
#expect(phases.contains(.preparingSources(completedCount: 2, totalCount: 2)))
#expect(phases.last == .encoding)
```

Also add a unit test for a progress counter completing indices out of order and
still publishing counts `[1, 2, 3]` exactly once.

- [ ] **Step 2: Run and verify RED**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --disable-sandbox --no-parallel \
  --filter 'ArchiveCommandRunnerTests|ArchiveOperationIntegrationTests'
```

Expected: compilation fails on the new callback and counter APIs.

- [ ] **Step 3: Thread the callback through the runner**

Define:

```swift
typealias ArchiveCommandProgressHandler =
    @Sendable (ArchiveOperationPhase) async -> Void
```

Change the protocol and implementation to:

```swift
func run(
    kind: ArchiveOperationKind,
    format: ArchiveFormat,
    sources: [URL],
    destination: URL,
    progress: ArchiveCommandProgressHandler
) async throws
```

Provide a protocol-extension overload with the old four-argument signature so
existing direct runner call sites continue to compile and use `{ _ in }`.

- [ ] **Step 4: Publish bounded preparation completion**

Create a private actor `ArchivePreparationProgressCounter` with fixed `total`,
a completed count, and `completeOne()` returning the next bounded count. Before
aggregate preparation report `0/total`; after each successful `copyItem`, call
`completeOne()` and report its returned value. Report `.encoding` after
preparation succeeds and immediately before `Process.run()`.

Do not add verbose flags or read native status lines. Retain stderr capture only
for failure diagnostics.

- [ ] **Step 5: Run focused tests and verify GREEN**

Run the Step 2 command. Expected: callbacks are monotonic and every archive
round trip remains unchanged.

- [ ] **Step 6: Commit**

```bash
git add Sources/BloomFileManager/Services/ArchiveCommandRunner.swift \
  Tests/BloomFileManagerTests/ArchiveCommandRunnerTests.swift \
  Tests/BloomFileManagerTests/ArchiveOperationIntegrationTests.swift
git commit -m "feat: report archive preparation progress"
```

### Task 3: Service publishing phase and controller propagation

**Files:**
- Modify: `Sources/BloomFileManager/Services/ArchiveOperationService.swift`
- Modify: `Sources/BloomFileManager/Stores/FileOperationController.swift`
- Modify: `Tests/BloomFileManagerTests/ArchiveOperationServiceTests.swift`
- Modify: `Tests/BloomFileManagerTests/FileOperationControllerTests.swift`

**Interfaces:**
- Consumes: `ArchiveCommandRunning.run(..., progress:)`
- Produces: ordered `ArchiveOperationProgress` callbacks through publication

- [ ] **Step 1: Write failing service sequence tests**

Update `RecordingArchiveCommandRunner` to emit supplied phases and add a test
whose literal expected phase sequence is:

```swift
[
    .preparingSources(completedCount: 0, totalCount: 2),
    .preparingSources(completedCount: 1, totalCount: 2),
    .preparingSources(completedCount: 2, totalCount: 2),
    .encoding,
    .publishing
]
```

Add a failure case proving `.publishing` is absent when the command fails, and a
controller case proving the `stage` carries the current request's kind, format,
and sanitized display name for every phase.

- [ ] **Step 2: Run and verify RED**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --disable-sandbox --no-parallel \
  --filter 'ArchiveOperationServiceTests|FileOperationControllerTests'
```

Expected: sequence assertions fail because service progress is currently one
unphased callback.

- [ ] **Step 3: Map runner phases and publish final phase**

Change the private worker to
`perform(_ request: ArchiveRequest, progress: ArchiveProgressHandler) async throws`
and call it from the public request loop. In that worker, pass a runner callback
that wraps each phase with request metadata:

```swift
try await commandRunner.run(
    kind: request.kind,
    format: request.format,
    sources: request.verifiedSources,
    destination: reservation.item
) { phase in
    await progress(ArchiveOperationProgress(
        kind: request.kind,
        currentDisplayName: request.progressDisplayName,
        format: request.format,
        phase: phase
    ))
}
```

Emit `.publishing` after staged output existence verification and before
`moveExclusively`. Remove the old pre-command unphased callback so phases are not
duplicated. `FileOperationController` continues mapping the service callback to
`.archiving(progress)`.

- [ ] **Step 4: Run focused tests and verify GREEN**

Run the Step 2 command. Expected: phase order, failure behavior, and controller
metadata tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/BloomFileManager/Services/ArchiveOperationService.swift \
  Sources/BloomFileManager/Stores/FileOperationController.swift \
  Tests/BloomFileManagerTests/ArchiveOperationServiceTests.swift \
  Tests/BloomFileManagerTests/FileOperationControllerTests.swift
git commit -m "feat: surface archive publication progress"
```

### Task 4: Regression, accessibility, and documentation gate

**Files:**
- Modify: `README.md`
- Modify: `docs/verification/version-1.3-archive-checklist.md`
- Modify: `Tests/BloomFileManagerTests/AccessibilityPresentationTests.swift`

**Interfaces:**
- Consumes: complete phase-aware archive progress stack

- [ ] **Step 1: Add accessibility behavior tests**

Assert that determinate preparation speaks the exact count, encoding speaks no
percentage, publishing says “Finishing archive,” and no status label contains a
fixture's parent absolute path.

- [ ] **Step 2: Run and verify RED if production copy is incomplete**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --disable-sandbox --no-parallel \
  --filter 'AccessibilityPresentationTests|OperationStatusViewTests'
```

Expected: any missing accessibility requirement fails before documentation is
updated. If all behavior already exists from Task 1, record that the new test
passes because it protects the completed production behavior; do not invent a
production change solely to force a failure.

- [ ] **Step 3: Update user and release documentation**

Document the exact behavior: preparation shows a top-level item count,
`ditto`/`tar` encoding is intentionally indeterminate, cancellation remains
available, and final completion appears only after exclusive publication.

- [ ] **Step 4: Run full verification**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --disable-sandbox --no-parallel
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift build -c release --disable-sandbox
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  ./script/build_and_run.sh --verify
git diff --check
```

Expected: 0 test failures, release build exit 0, Pengrid process verification
exit 0, and no whitespace errors. Existing baseline compiler warnings are
reported separately and are not expanded by this change.

- [ ] **Step 5: Commit**

```bash
git add README.md docs/verification/version-1.3-archive-checklist.md \
  Tests/BloomFileManagerTests/AccessibilityPresentationTests.swift
git commit -m "docs: verify archive progress reporting"
```
