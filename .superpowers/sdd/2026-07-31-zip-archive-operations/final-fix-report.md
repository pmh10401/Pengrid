# ZIP archive operations final fix report

Date: 2026-07-31 (Asia/Seoul)
Reviewed base: `61c653e`
Branch: `feature/zip-archive-operations`

## Status

All five final-review findings were addressed with focused red/green
regressions. The directly affected suites and the full serial package suite
pass. No push, merge, release, or version change was performed.

## Decisions

- Compression always creates a private aggregate source root beside the staged
  payload, copies each selected item under its exact selected basename, and
  gives `ditto` one source root without `--keepParent`. This makes real
  multi-selection compression work while leaving the selected entries at the
  ZIP root. The aggregate root is explicitly removed by the runner and remains
  inside the archive service's captured staging cleanup boundary.
- A selected symbolic link is preserved as a symbolic link. Archive-purpose
  cloud preparation revalidates the link identity but does not materialize or
  coordinate a read of its target. The private aggregate copy preserves the
  link object, so top-level `ditto` never receives the selected link directly
  and cannot silently substitute target bytes.
- The controller's default archive service is derived from the existing
  `FileOperationService`. Production therefore uses the same app-owned
  `FileSystemAccess` and `CloudLocationScopedAccessCoordinator` already wired
  through `CloudRuntimeDependencies`.
- Cancellation is checked after staged-output verification and again inside
  the exclusive-publication actor immediately before the atomic rename.
- Manual release gates now explicitly cover selected packages, the preserved
  selected-symlink policy, and case-sensitive APFS behavior.

## TDD evidence

### Multi-item live `ditto`

Red:

```text
swift test ... --filter dittoCompressionArchivesMultipleSelectedItemsAtTheZIPRoot
failed: ArchiveOperationError.nonZeroTermination(
  status: 1,
  standardError: "ditto: Can't archive multiple sources ..."
)
```

Green:

```text
1 test passed: dittoCompressionArchivesMultipleSelectedItemsAtTheZIPRoot
```

The live integration extracts the archive and verifies both selected files,
their independent contents, and the absence of a leaked aggregate parent.

### Production cloud dependency wiring

Red:

```text
swift test ... --filter runtimeDependenciesShareRegisteredAccessWithArchiveOperations
failed: observed 3 shared scoped-access acquisitions; expected 4
```

The missing fourth acquisition was the archive service, which used a new empty
coordinator.

Green:

```text
1 test passed: runtimeDependenciesShareRegisteredAccessWithArchiveOperations
```

The test drives the same default controller construction used by the app and
observes four balanced acquisitions on the registered production coordinator.

### Selected symbolic link

Red, live runner:

```text
swift test ... --filter dittoCompressionPreservesATopLevelSelectedSymbolicLink
failed: extracted "Selected Link.txt" did not exist
```

Red, materializer:

```text
swift test ... --filter archivePurposePreservesSelectedSymbolicLinkWithoutReadingItsTarget
failed: preparedRequests was empty; failure was itemChanged
```

Green:

```text
1 live integration test passed
1 archive-purpose materialization test passed
```

The live test verifies `destinationOfSymbolicLink` equals the original relative
link text and confirms the target file is absent from the extraction root. The
materializer test verifies no target URL is coordinated.

### Cancellation during post-process verification

Red:

```text
swift test ... --filter cancellationDuringOutputVerificationPreventsFinalPublication
failed:
- result was succeeded instead of cancelled
- final destination existed
- moveExclusively was recorded
```

Green:

```text
1 test passed: cancellationDuringOutputVerificationPreventsFinalPublication
```

The test deterministically suspends `exists(payload)`, cancels the operation,
resumes verification, and verifies no exclusive move or visible archive.

### Honest direct archive arguments

Red:

```text
swift test ... --filter directCompressionArgumentsRejectMultipleDittoArchiveSources
failed: expected invalidRequest, but multi-source archive arguments were returned
```

Green:

```text
ArchiveCommandRunnerTests: 3 tests passed
```

Direct archive-mode argument construction now accepts exactly one source. The
runner's aggregate path is the only multi-selection route.

## Changed files

- `Sources/BloomFileManager/Services/ArchiveCommandRunner.swift`
- `Sources/BloomFileManager/Services/ArchiveOperationService.swift`
- `Sources/BloomFileManager/Services/CloudMaterializationService.swift`
- `Sources/BloomFileManager/Services/FileOperationService.swift`
- `Sources/BloomFileManager/Services/FileSystemAccess.swift`
- `Sources/BloomFileManager/Stores/FileOperationController.swift`
- `Tests/BloomFileManagerTests/ArchiveCommandRunnerTests.swift`
- `Tests/BloomFileManagerTests/ArchiveOperationIntegrationTests.swift`
- `Tests/BloomFileManagerTests/ArchiveOperationServiceTests.swift`
- `Tests/BloomFileManagerTests/CloudLocationScopedAccessTests.swift`
- `Tests/BloomFileManagerTests/CloudMaterializationServiceTests.swift`
- `Tests/BloomFileManagerTests/Support/RecordingFileSystem.swift`
- `docs/verification/version-1.3-archive-checklist.md`
- `.superpowers/sdd/2026-07-31-zip-archive-operations/final-fix-report.md`

## Commands and results

Baseline:

```text
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --enable-swift-testing --no-parallel \
--filter BloomFileManagerTests
PASS: 619 tests in 50 suites
```

Behavior probes:

```text
/usr/bin/ditto -c -k --keepParent --sequesterRsrc first second output.zip
EXIT 1: ditto: Can't archive multiple sources

/usr/bin/ditto -c -k --keepParent --sequesterRsrc selected-link output.zip
EXIT 0, but extraction contained target bytes rather than the selected link

Foundation copyItem(selected-link, aggregate/selected-link), followed by
/usr/bin/ditto -c -k --sequesterRsrc aggregate output.zip
EXIT 0, extraction preserved the symbolic link and its relative link text
```

Focused red/green commands:

```text
swift test ... --filter dittoCompressionArchivesMultipleSelectedItemsAtTheZIPRoot
swift test ... --filter runtimeDependenciesShareRegisteredAccessWithArchiveOperations
swift test ... --filter dittoCompressionPreservesATopLevelSelectedSymbolicLink
swift test ... --filter archivePurposePreservesSelectedSymbolicLinkWithoutReadingItsTarget
swift test ... --filter cancellationDuringOutputVerificationPreventsFinalPublication
swift test ... --filter directCompressionArgumentsRejectMultipleDittoArchiveSources
```

Directly affected suites:

```text
ArchiveCommandRunnerTests: 3 passed
ArchiveOperationIntegrationTests: 4 passed
ArchiveOperationServiceTests: 9 passed
CloudMaterialization*: 17 passed
CloudLocationScopedAccessTests: 17 passed
FileOperationControllerTests: 28 passed
FileSystemAccessTests: 2 passed
Total: 80 passed, 0 failed
```

Final verification:

```text
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --enable-swift-testing --no-parallel \
--filter BloomFileManagerTests
PASS: 625 tests in 50 suites, 0 failures

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
./script/build_and_run.sh --verify
PASS

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
./script/tests/package_release_contract_tests.sh
PASS: package release contract tests

git diff --check
PASS
```

The implementation plan names stale plural-path commands
`./scripts/build_and_run.sh` and `./scripts/test_package_release_contract.sh`;
the first failed with "no such file or directory". Repository inspection found
and the verification used the actual singular-path scripts listed above.

## Self-review

- Confirmed `/usr/bin/ditto` is still launched directly through `Process` with
  argument arrays and no shell.
- Confirmed final publication still uses only `moveExclusively`.
- Confirmed aggregate names are private UUID paths inside the owned staging
  boundary and selected basenames are validated for duplicates.
- Confirmed extraction behavior and determinate transfer UI were not changed.
- Confirmed no existing source, archive destination, or unrelated worktree file
  is overwritten or removed.

## Remaining concerns

- The selected package, File Provider, case-sensitive APFS, VoiceOver, keyboard,
  and large-operation cancellation checks remain physical release gates marked
  `NOT RUN` in the checklist.
- Private aggregation uses `FileManager.copyItem`; cancellation is checked
  between selected roots and before launching `ditto`, but Foundation does not
  expose mid-copy cancellation for one very large selected root. The aggregate
  remains inside the identity-owned staging cleanup boundary, so cancellation
  cannot publish a partial final archive, but physical responsiveness for this
  phase remains part of the large-operation release check.
