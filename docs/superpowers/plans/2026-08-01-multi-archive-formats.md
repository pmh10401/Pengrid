# Multi-Format Archive Operations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add native TAR-family archive support and bounded parallel source preparation while preserving Pengrid's staged, no-overwrite archive guarantees.

**Architecture:** Introduce a single `ArchiveFormat` model shared by planning, commands, extraction eligibility, progress presentation, and menus. Archive requests carry the selected/detected format explicitly; `ditto` remains the ZIP backend and `bsdtar` handles TAR variants. Multi-source staging uses a bounded Swift task group, while process completion uses a termination-handler latch instead of `waitUntilExit`.

**Tech Stack:** Swift 6.1, SwiftPM, SwiftUI/AppKit, Foundation `Process`/`FileManager`, macOS 15 `/usr/bin/ditto` and `/usr/bin/tar`.

## Global Constraints

- Supported formats are ZIP, TAR, TAR.GZ/TGZ, TAR.BZ2/TBZ/TBZ2, and TAR.XZ/TXZ; RAR, 7z, password-protected archives, and third-party tools remain out of scope.
- ZIP uses `/usr/bin/ditto`; TAR-family formats use `/usr/bin/tar` with explicit argument arrays and no shell.
- All archive output is staged and published through the existing exclusive move path; extraction remains isolated until publication.
- Parallel preparation is bounded by `min(4, max(1, ProcessInfo.processInfo.activeProcessorCount), sourceCount)` and checks cancellation before each copy.
- Existing call sites that omit a format continue to mean ZIP through default `.zip` initializers.
- Tests use `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` and `swift test --enable-swift-testing --no-parallel`.

---

### Task 1: Add the archive format model and request plumbing

**Files:**
- Create: `Sources/BloomFileManager/Models/ArchiveFormat.swift`
- Modify: `Sources/BloomFileManager/Models/ArchiveOperationModels.swift`
- Modify: `Sources/BloomFileManager/Models/FileOperationModels.swift`
- Test: `Tests/BloomFileManagerTests/ArchiveFormatTests.swift`
- Test: `Tests/BloomFileManagerTests/ArchiveCommandRunnerTests.swift`

**Interfaces:**
- `ArchiveFormat: CaseIterable, Hashable, Sendable, Equatable` with cases `.zip`, `.tar`, `.tarGzip`, `.tarBzip2`, `.tarXz`.
- `ArchiveFormat.canonicalSuffix`, `displayName`, `accessibilityName`, `tarCompressionFlag`, and `static func detect(filename: String) -> ArchiveFormat?`.
- `ArchiveRequest.format` defaults to `.zip`.
- `ArchiveOperationProgress.format` defaults to `.zip` and keeps its existing initializer call shape valid.
- `ArchiveDestinationPlan.formats` aligns one format with each selected source; compression has one element and extraction detects one per source.

- [ ] **Step 1: Write failing format and planner tests**

Add tests that assert canonical suffixes, case-insensitive aliases (`TGZ`, `TBZ2`, `TXZ`), unknown suffix rejection, `.zip` default request/progress behavior, a TAR.GZ destination name, and mixed-format extraction destinations.

- [ ] **Step 2: Run the focused tests to verify they fail**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --enable-swift-testing --no-parallel --filter ArchiveFormatTests
```

Expected: compile/test failure because `ArchiveFormat` and format-aware planner behavior do not exist.

- [ ] **Step 3: Implement the minimal format model and plumbing**

Implement filename detection by longest suffix first, map TAR compression flags to `nil`, `-z`, `-j`, and `-J`, add the format field to requests/progress, and update planner output and extraction eligibility to use detection.

- [ ] **Step 4: Run the focused tests to verify they pass**

Run the same command. Expected: all new format tests pass and existing archive model tests compile.

- [ ] **Step 5: Commit**

```bash
git add Sources/BloomFileManager/Models Tests/BloomFileManagerTests/ArchiveFormatTests.swift
git commit -m "feat: model native archive formats"
```

### Task 2: Implement format-specific command execution and reliable termination

**Files:**
- Modify: `Sources/BloomFileManager/Services/ArchiveCommandRunner.swift`
- Modify: `Sources/BloomFileManager/Services/ArchiveOperationService.swift`
- Modify: `Tests/BloomFileManagerTests/ArchiveCommandRunnerTests.swift`
- Modify: `Tests/BloomFileManagerTests/ArchiveOperationServiceTests.swift`
- Modify: `Tests/BloomFileManagerTests/FileOperationControllerTests.swift`

**Interfaces:**
- `ArchiveCommandRunning.run(kind:format:sources:destination:)` receives the explicit format.
- `LiveArchiveCommandRunner.arguments(kind:format:sources:destination:)` returns ZIP `ditto` arguments or TAR-family `tar` arguments.
- `ArchiveCommandRunner` prepares a single aggregate source root for compression and uses `-C` for TAR commands.

- [ ] **Step 1: Write failing argument and forwarding tests**

Add assertions for plain TAR, TAR.GZ, TAR.BZ2, and TAR.XZ create/extract argument arrays; assert a service request with `.tarGzip` forwards that format to the recording runner; update recording runner signatures to capture format.

- [ ] **Step 2: Run focused tests to verify they fail**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --enable-swift-testing --no-parallel --filter ArchiveCommandRunnerTests
```

Expected: compile/test failure because the runner has no format parameter or TAR arguments.

- [ ] **Step 3: Implement command mapping and termination latch**

Keep ZIP's existing `ditto` flags. For TAR create use `tar -c [compression flag] -f destination -C aggregateRoot .`; for TAR extraction use `tar -x [compression flag] -k -f archive -C destination`. Set a termination handler before `Process.run()`, store a result-safe status in a locked `@unchecked Sendable` latch, await it with the existing cancellation handler, and continue bounded stderr capture.

- [ ] **Step 4: Run focused and live integration tests**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --enable-swift-testing --no-parallel --filter ArchiveCommandRunnerTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --enable-swift-testing --no-parallel --filter ArchiveOperationIntegrationTests
```

Expected: argument tests and the existing ZIP live tests pass repeatedly without the prior `waitUntilExit` hang.

- [ ] **Step 5: Commit**

```bash
git add Sources/BloomFileManager/Services Tests/BloomFileManagerTests
git commit -m "feat: execute native TAR archive formats"
```

### Task 3: Add bounded parallel aggregate preparation and live TAR round trips

**Files:**
- Modify: `Sources/BloomFileManager/Services/ArchiveCommandRunner.swift`
- Modify: `Tests/BloomFileManagerTests/ArchiveOperationIntegrationTests.swift`
- Modify: `Tests/BloomFileManagerTests/ArchiveCommandRunnerTests.swift`

**Interfaces:**
- A private `ArchiveCopyWorkQueue` actor hands out source indexes.
- `LiveArchiveCommandRunner` uses at most four preparation workers and checks `Task.checkCancellation()` before each `FileManager.copyItem`.

- [ ] **Step 1: Write failing parallel/live tests**

Add a multi-source test with several spaced files that records the archive round trip for every TAR-family format, asserts root-level names and contents, and verifies no `.archive-source-` directory remains. Add an argument test proving multi-source preparation still emits one aggregate source to the backend.

- [ ] **Step 2: Run the tests to verify the new coverage fails**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --enable-swift-testing --no-parallel --filter ArchiveOperationIntegrationTests
```

Expected: TAR-family round-trip tests fail or do not compile before the parallel preparation implementation.

- [ ] **Step 3: Implement bounded preparation**

Validate duplicate basenames before starting workers, create up to four workers, let each worker claim indexes from the actor queue, cancel remaining work on the first error, and remove the aggregate root in the existing `defer` cleanup path.

- [ ] **Step 4: Run live tests repeatedly**

Run the integration filter twice. Expected: all ZIP and TAR-family round trips pass, no aggregate directory remains, and no process hangs.

- [ ] **Step 5: Commit**

```bash
git add Sources/BloomFileManager/Services/ArchiveCommandRunner.swift Tests/BloomFileManagerTests/ArchiveOperationIntegrationTests.swift Tests/BloomFileManagerTests/ArchiveCommandRunnerTests.swift
git commit -m "feat: parallelize archive source preparation"
```

### Task 4: Expose format choices in menus and accessibility status

**Files:**
- Modify: `Sources/BloomFileManager/Stores/FileOperationController.swift`
- Modify: `Sources/BloomFileManager/Support/WorkspaceCommands.swift`
- Modify: `Sources/BloomFileManager/Views/AppKit/FileTableView.swift`
- Modify: `Sources/BloomFileManager/Views/FilePaneView.swift`
- Modify: `Sources/BloomFileManager/Views/OperationStatusView.swift`
- Modify: `Tests/BloomFileManagerTests/WorkspaceCommandPolicyTests.swift`
- Modify: `Tests/BloomFileManagerTests/OperationStatusViewTests.swift`
- Modify: `Tests/BloomFileManagerTests/FileOperationControllerTests.swift`

**Interfaces:**
- `FileOperationController.compressSelection(_:format:)` defaults to `.zip`.
- `FileTableView.onCompress` accepts an `ArchiveFormat`; its context submenu maps each item to that format.
- `ArchiveOperationStatusPresentation` includes the format in title and VoiceOver labels.

- [ ] **Step 1: Write failing UI/model tests**

Assert TAR.GZ status labels (`Compressing TAR.GZ archive`, `Cancel TAR.GZ compression`), extraction eligibility for all supported suffixes, and format-specific controller requests.

- [ ] **Step 2: Run focused tests to verify they fail**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --enable-swift-testing --no-parallel --filter OperationStatusViewTests
```

Expected: label and eligibility assertions fail before UI/model wiring is updated.

- [ ] **Step 3: Implement menu and controller wiring**

Keep the existing ZIP button, add a `Compress as…` submenu to SwiftUI commands and the AppKit context menu, pass the selected format into planning, and rename extraction menu text to `Extract Archive` while preserving the default ZIP path.

- [ ] **Step 4: Run focused tests and build**

Run the status, policy, and controller filters, then `swift build`. Expected: all pass and the executable compiles with AppKit/SwiftUI menu changes.

- [ ] **Step 5: Commit**

```bash
git add Sources/BloomFileManager/Stores Sources/BloomFileManager/Support Sources/BloomFileManager/Views Tests/BloomFileManagerTests
git commit -m "feat: expose multi-format archive menus"
```

### Task 5: Update documentation and run release gates

**Files:**
- Modify: `README.md`
- Modify: `docs/release.md`
- Modify: `docs/verification/version-1.3-archive-checklist.md`

- [ ] **Step 1: Document supported formats and parallel boundary**

Replace the ZIP-only release wording with the supported TAR-family list, state that parallelism applies to multi-source staging, and retain the RAR/7z/password-protection exclusions and unsigned-release warning.

- [ ] **Step 2: Run the full verification suite**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --enable-swift-testing --no-parallel --filter BloomFileManagerTests
./script/tests/package_release_contract_tests.sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -c release --arch arm64
```

Expected: all tests, release contract checks, and the arm64 release build pass.

- [ ] **Step 3: Commit**

```bash
git add README.md docs/release.md docs/verification/version-1.3-archive-checklist.md
git commit -m "docs: document multi-format archive support"
```

- [ ] **Step 4: Review the final diff and branch state**

Run `git diff main...HEAD --check`, `git status -sb`, and `git log --oneline --decorate -8`; confirm no generated artifacts are tracked and every plan task has a test result.

