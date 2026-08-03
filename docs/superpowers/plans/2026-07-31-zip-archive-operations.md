# ZIP archive operations implementation plan

> **For implementation:** Follow this plan task by task. Run the stated test command after each task and commit each completed task before moving on.

**Goal:** Add safe, native-feeling ZIP compression and extraction to Pengrid, using macOS `ditto`, existing cloud materialization/access-scope safety, atomic staging, and cancellable operation status.

**Architecture:** The workspace controller validates the selected files, materializes cloud-backed sources, calculates conflict-free destinations, then delegates archive creation/extraction to a dedicated actor. The actor runs `/usr/bin/ditto` without a shell and publishes only fully-created staged output to the user-visible destination with an exclusive rename. The existing operation controller remains the single owner of lifecycle, cancellation, view refresh, and error presentation.

**Tech stack:** Swift 6.1, SwiftUI, Swift Testing, macOS 15+, Foundation `Process`, `/usr/bin/ditto`, existing `FileSystemAccess` and scoped-access abstractions.

---

## Task 1: Make staged output publication exclusive

**Files:**

- Modify: `Sources/BloomFileManager/Services/FileSystemAccess.swift`
- Modify: `Tests/BloomFileManagerTests/FileSystemAccessTests.swift`

1. Write a failing test that creates a staged file and an already-existing destination, then verifies that the new publish operation fails without replacing the destination.
2. Write a failing test that publishes a staged file to an absent destination and verifies the destination identity/content is the staged item.
3. Extend `FileSystemAccess` with `moveExclusively(_:to:)`.
4. Implement it in `LiveFileSystemAccess` using the existing `renameatx_np(..., RENAME_EXCL)` support, opening the two parent directories and using the source/destination basenames. Preserve existing error mapping so `EEXIST` becomes a user-visible file-exists error.
5. Add the corresponding deterministic implementation to `RecordingFileSystem`, including operation recording used by existing assertions.
6. Run:

   ```bash
   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --enable-swift-testing --no-parallel --filter FileSystemAccessTests
   ```

7. Commit:

   ```bash
   git add Sources/BloomFileManager/Services/FileSystemAccess.swift Tests/BloomFileManagerTests/FileSystemAccessTests.swift
   git commit -m "feat: publish staged files without overwrite"
   ```

## Task 2: Define the archive domain and `ditto` runner

**Files:**

- Create: `Sources/BloomFileManager/Models/ArchiveOperationModels.swift`
- Create: `Sources/BloomFileManager/Services/ArchiveCommandRunner.swift`
- Create: `Tests/BloomFileManagerTests/ArchiveCommandRunnerTests.swift`

1. Write failing tests for compression arguments (`-c -k --keepParent --sequesterRsrc`) and extraction arguments (`-x -k`), including an argument containing spaces to prove that no shell string is used.
2. Add sendable value types:
   - `ArchiveOperationKind` (`compress`, `extract`) with user-facing title and accessibility label.
   - `ArchiveOperationProgress` with operation kind and current display name; it is intentionally indeterminate.
   - `ArchiveRequest` containing the kind, verified source URLs, and final destination URL.
   - `ArchiveOperationError` for command launch, non-zero termination, invalid request, and cancelled work.
3. Add `ArchiveCommandRunning` with an async `run(kind:sources:destination:)` requirement and a `LiveArchiveCommandRunner` implementation.
4. The live runner must create a `Process` at `/usr/bin/ditto`, set `arguments` directly, wait for process exit, capture bounded standard-error text, and throw a typed error on a non-zero status.
5. Use a cancellation handler that terminates a still-running process and reports cancellation; do not invoke a shell or interpolate source names into commands.
6. Run the focused test target from step 1 and commit:

   ```bash
   git add Sources/BloomFileManager/Models/ArchiveOperationModels.swift Sources/BloomFileManager/Services/ArchiveCommandRunner.swift Tests/BloomFileManagerTests/ArchiveCommandRunnerTests.swift
   git commit -m "feat: add safe ditto archive command runner"
   ```

## Task 3: Implement staged archive creation and extraction

**Files:**

- Create: `Sources/BloomFileManager/Services/ArchiveOperationService.swift`
- Create: `Tests/BloomFileManagerTests/ArchiveOperationServiceTests.swift`
- Modify: `Sources/BloomFileManager/Services/FileSystemAccess.swift`

1. Write failing integration-style service tests using an injected recording command runner:
   - Compression sends all selected sources in one request and publishes the completed ZIP only when the runner succeeds.
   - Extraction publishes a completed directory only when the runner succeeds.
   - A cancellation/error removes the staged payload and staging directory and never creates visible output.
   - A destination introduced after planning produces `FileOperationItemOutcome.failed` and preserves both the original item and the staged cleanup boundary.
   - The access coordinator is entered for every source and released after each request.
2. Add `ArchiveOperating` and an actor `ArchiveOperationService` depending on `FileSystemAccess`, `CloudLocationScopedAccessCoordinator`, and `ArchiveCommandRunning`.
3. For each request, reserve staging beside the final destination with the existing `reserveStagingDirectory(beside:)`. Invoke the command runner with `reservation.item` as destination.
4. Verify output exists after a successful command. Publish it with `moveExclusively`; never use `move`, `replace`, or a preflight-only existence check for final publication.
5. In `defer`, remove the staged payload first if it remains, then remove the staging directory using its captured identity. Preserve the primary failure and attach cleanup failures using the project’s established failure model where applicable.
6. Translate cancellation to a cancelled item outcome, keep the remaining request list untouched, and return `FileOperationResult` in the same semantics as transfer operations.
7. Run:

   ```bash
   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --enable-swift-testing --no-parallel --filter ArchiveOperationServiceTests
   ```

8. Commit:

   ```bash
   git add Sources/BloomFileManager/Services/ArchiveOperationService.swift Sources/BloomFileManager/Services/FileSystemAccess.swift Tests/BloomFileManagerTests/ArchiveOperationServiceTests.swift
   git commit -m "feat: add staged ZIP archive service"
   ```

## Task 4: Add destination planning and cloud preparation to the workspace controller

**Files:**

- Modify: `Sources/BloomFileManager/Services/CloudMaterializationService.swift`
- Modify: `Sources/BloomFileManager/Stores/FileOperationController.swift`
- Modify: `Sources/BloomFileManager/Models/FileOperationModels.swift`
- Modify: `Tests/BloomFileManagerTests/FileOperationControllerTests.swift`
- Modify: `Tests/BloomFileManagerTests/CloudMaterializationServiceTests.swift`

1. Write failing controller tests for:
   - one selected item becoming `<display name>.zip` (using the established keep-both naming policy if that name already exists);
   - multiple selected items becoming `Archive.zip` with the same conflict policy;
   - each selected ZIP being extracted into a dedicated `<zip stem>` folder, independently;
   - a cloud-backed selected item being materialized with a new `.archive` purpose before the archive service sees its URL;
   - cancellation during preparation preventing archive service work;
   - only panes displaying the touched destination directory being refreshed after success.
2. Add `CloudPreparationPurpose.archive` and update purpose labels/tests.
3. Inject an `ArchiveOperating` dependency into `FileOperationController` with the live service as the default. Keep existing initializer call sites source-compatible with a default argument.
4. Add controller entry points `compressSelection(_:)` and `extractSelection(_:)`. Each must capture selected URLs/identities before asynchronous work, call the existing materializer, revalidate identities, and then invoke the archive service through `beginOperation`.
5. Use existing conflict naming utilities, not a duplicate filename-suffix algorithm. Compression produces one destination in the active folder. Extraction produces one destination per selected ZIP in the active folder. Reject empty selections, mixed invalid extraction selections, directories selected for extraction, and non-ZIP sources before starting work.
6. Pass the active folder as a touched directory and retain the existing operation completion/error reporting route.
7. Run both focused controller/materialization suites, then commit:

   ```bash
   git add Sources/BloomFileManager/Services/CloudMaterializationService.swift Sources/BloomFileManager/Stores/FileOperationController.swift Sources/BloomFileManager/Models/FileOperationModels.swift Tests/BloomFileManagerTests/FileOperationControllerTests.swift Tests/BloomFileManagerTests/CloudMaterializationServiceTests.swift
   git commit -m "feat: connect ZIP operations to workspace controller"
   ```

## Task 5: Expose archive actions in commands and operation status

**Files:**

- Modify: `Sources/BloomFileManager/Support/WorkspaceCommands.swift`
- Modify: `Sources/BloomFileManager/Models/WorkspaceCommandPolicy.swift` (or its current defining file)
- Modify: `Sources/BloomFileManager/Views/OperationStatusView.swift`
- Modify: `Sources/BloomFileManager/Views/FilePaneView.swift` if selection context-menu construction lives there
- Modify: `Tests/BloomFileManagerTests/WorkspaceCommandPolicyTests.swift`
- Modify: `Tests/BloomFileManagerTests/OperationStatusViewTests.swift`

1. Write failing policy tests proving compression is enabled only for a non-empty selection while no operation/text edit is active, and extraction is enabled only when every selected item is a non-directory `.zip` item.
2. Extend command inputs with the selected `FileItem` values required for extraction eligibility; do not infer ZIP eligibility from filtered row count alone.
3. Add “Compress to ZIP” and “Extract ZIP” to the File Operations command menu and, if the existing pane offers contextual file actions, mirror them there. Wire actions to the controller entry points.
4. Add an `.archiving(ArchiveOperationProgress)` case to `FileOperationStage` and render an indeterminate status row with operation-specific title, current item name, Cancel button, and stable accessibility labels. Retain the existing determinate transfer progress UI unchanged.
5. Verify menu commands are disabled while typing in the filter/name field and while another operation runs.
6. Run focused UI-policy tests and commit:

   ```bash
   git add Sources/BloomFileManager/Support/WorkspaceCommands.swift Sources/BloomFileManager/Models/WorkspaceCommandPolicy.swift Sources/BloomFileManager/Views/OperationStatusView.swift Sources/BloomFileManager/Views/FilePaneView.swift Tests/BloomFileManagerTests/WorkspaceCommandPolicyTests.swift Tests/BloomFileManagerTests/OperationStatusViewTests.swift
   git commit -m "feat: expose ZIP operations in workspace"
   ```

## Task 6: Add macOS `ditto` end-to-end coverage and documentation

**Files:**

- Create: `Tests/BloomFileManagerTests/ArchiveOperationIntegrationTests.swift`
- Modify: `README.md`
- Create: `docs/verification/version-1.3-archive-checklist.md`

1. Write an integration test using temporary local files and `LiveArchiveCommandRunner` that compresses a file whose name contains a space, confirms a valid ZIP exists, extracts it, and verifies the original file name/content under its kept parent directory.
2. Add a second integration test asserting a failed/cancelled operation leaves no `.bloom-staging-*` directory or partial destination in the temporary parent.
3. Document the delivered scope: ZIP compression/extraction only, all work local to the selected destination, no overwrite, cloud files may be downloaded first, and no password/7z/RAR/tar support in this release.
4. Add the manual verification checklist covering keyboard/menu discovery, non-ZIP disabled extraction, collision behavior, cancellation cleanup, VoiceOver labels, a local ZIP round trip, and a cloud-provider materialization path.
5. Run:

   ```bash
   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --enable-swift-testing --no-parallel --filter ArchiveOperationIntegrationTests
   git diff --check
   ```

6. Commit:

   ```bash
   git add Tests/BloomFileManagerTests/ArchiveOperationIntegrationTests.swift README.md docs/verification/version-1.3-archive-checklist.md
   git commit -m "docs: document ZIP archive operations"
   ```

## Task 7: Full verification and publication

**Files:**

- Modify only if verification finds an implementation issue.

1. Run the entire selected test suite serially to avoid false passes from Xcode’s Swift Testing discovery:

   ```bash
   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --enable-swift-testing --no-parallel --filter BloomFileManagerTests
   ```

2. Run the project’s launch/package contract checks:

   ```bash
   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./scripts/build_and_run.sh --verify
   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./scripts/test_package_release_contract.sh
   ```

3. Review the final diff and history:

   ```bash
   git status --short
   git diff --check origin/main...HEAD
   git log --oneline origin/main..HEAD
   ```

4. Push the verified commits to `origin/main`; rely on the existing GitHub Actions workflow for a clean CI run. Do not create a public release/DMG or change the release version until a separate release review is requested.
