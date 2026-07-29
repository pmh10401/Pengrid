# Storage Inspector Verification Checklist

Evidence date: 2026-07-29 (Asia/Seoul)
Tested source commit: `fd56d61c720bbf976a1352d2144fc596d12cb721`
Evidence documentation revision: the later docs-only commit with subject
`docs: record final storage security verification`; it is not represented as the
tested source commit and does not embed a self-referential SHA.

This record separates generated and automated evidence from physical-manual
release gates. A generated 100,000-entry fixture is not evidence for a physical
100,000-file tree, real storage devices, or interactive accessibility behavior.
The fixture's ten-second timeout is a hang watchdog, not a product SLA.
Focused and full Swift evidence below was collected with a clean worktree at
the exact tested source commit. The later evidence-documentation change does
not alter Swift source or tests.

## AUTOMATED PASS

- Focused Storage Inspector suites:

  ```bash
  env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    /usr/bin/xcrun swift test --disable-sandbox --no-parallel \
    --filter 'StorageScanServiceTests|StorageAnalysisStoreTests|StorageCleanupControllerTests|StorageInspectorPerformanceTests|StorageInspectorPresentationTests|FileOperationMutationTests'
  ```

  Tested source `fd56d61c720bbf976a1352d2144fc596d12cb721`,
  2026-07-29 21:13 KST: exit 0; 95 tests in 6 suites passed in
  1.493 seconds. Coverage includes a generated
  in-memory 100,000-entry source, 256-entry progressive batches, synchronous
  cancellation under 250 ms, a bounded ten-second scan-completion watchdog,
  root replacement between batches, and distinct live duplicate-service
  cancellation after instrumented partial-fingerprint and complete-checksum
  starts. It also covers live keep-copy revalidation, fail-closed location
  classification, protected-path intersections and distinct cleanup
  acknowledgement, root ownership through every verification stage, a fixed
  two-worker queue, stable cleanup outcome reconciliation, progressive
  presentation, group navigation, exact thresholds, and accessibility wiring.
  The follow-up adds provider-before-protected classification, regular-file
  overview counting, and a capacity-four slow-consumer stress case that
  observes critical-event backpressure while retaining every complete,
  excluded, and group event.

- Full nonparallel Swift suite:

  ```bash
  env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    /usr/bin/xcrun swift test --disable-sandbox --no-parallel
  ```

  Tested source `fd56d61c720bbf976a1352d2144fc596d12cb721`,
  2026-07-29 21:11 KST: exit 0; 551 tests in 41 suites passed in
  38.505 seconds.

- Development app verification:

  ```bash
  env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    ./script/build_and_run.sh --verify
  test -x dist/Pengrid.app/Contents/MacOS/BloomFileManager
  file dist/Pengrid.app/Contents/MacOS/BloomFileManager
  /usr/bin/lipo -archs dist/Pengrid.app/Contents/MacOS/BloomFileManager
  ```

  Tested source `fd56d61c720bbf976a1352d2144fc596d12cb721`,
  2026-07-29 21:12 KST: `build_and_run.sh --verify` exited 0. The resulting
  `dist/Pengrid.app/Contents/MacOS/BloomFileManager` is an arm64 Mach-O
  executable.
  This is exact final source-HEAD development-app evidence; it is not signing,
  notarization, stapling, Gatekeeper, or physical interaction evidence.

- Unsigned local package:

  ```bash
  env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    ./script/package_release.sh --unsigned
  ```

  Prior source commit `1a1f9c360d8318aca1ffc1d41aa1c332812db551`,
  2026-07-29 17:52 KST: exit 0 in 68 seconds. Its internal nonparallel gate
  passed 504 tests in 41 suites in 34.940 seconds and produced the ad-hoc signed
  local `dist/release/Pengrid.app`. Packaging was not rerun for
  `fd56d61c720bbf976a1352d2144fc596d12cb721`; this is not exact final
  source-HEAD or distribution-signing evidence.

## STATIC-SOURCE PASS

- Whitespace check:

  ```bash
  git diff codex/cloud-storage-integration-design..fd56d61c720bbf976a1352d2144fc596d12cb721 --check
  ```

  Tested source `fd56d61c720bbf976a1352d2144fc596d12cb721`,
  2026-07-29 21:13 KST: exit 0 with no output. Scope is the complete Storage
  Inspector branch relative to its integration base.
  A separate working-tree `git diff --check` also exited 0.

- Targeted Storage Inspector contract scan:

  ```bash
  rg -n 'removeItem|trashItem|OAuth|MSAL|Graph|googleapis|accessToken|refreshToken' \
    Sources/BloomFileManager/Models/StorageAnalysisModels.swift \
    Sources/BloomFileManager/Services/StorageScanService.swift \
    Sources/BloomFileManager/Services/StorageDuplicateDetectionService.swift \
    Sources/BloomFileManager/Stores/StorageAnalysisStore.swift \
    Sources/BloomFileManager/Stores/StorageCleanupController.swift \
    Sources/BloomFileManager/Views/StorageInspector \
    Sources/BloomFileManager/Views/AppKit/StorageResultsTableView.swift
  ```

  Tested source `fd56d61c720bbf976a1352d2144fc596d12cb721`,
  2026-07-29 21:12 KST: `rg` exit 1 with zero matching lines, the expected
  no-match result. The Task 5 behavior test, not this token scan, remains the
  automated proof that cleanup dispatches identified Trash requests and never
  calls path-only Trash or remove.

## MANUAL NOT RUN

- Local APFS scan on physical storage, including progressive results and
  cancellation.
- Scan on a physical directly attached external volume.
- Physical 100,000-file tree while observing CPU, memory, scrolling, selection,
  and cancellation.
- Physical external-volume disconnect and reconnect during enumeration,
  partial hashing, and complete hashing.
- Quick Look and Show in Finder from real results.
- Trash confirmation, partial-failure presentation, recovery, and inspection
  of actual macOS Trash contents.
- Protected `/System`, `/Library`, and user Library warning and analysis-only
  behavior.
- VoiceOver and Full Keyboard Access across entry, navigation, results,
  inspection, review, cancellation, and exit.
- Reduce Motion, Increased Contrast, Light Mode, and Dark Mode.

## RELEASE BLOCKER

- Every `MANUAL NOT RUN` item above requires dated evidence against the exact
  release candidate.
- Developer ID signing, Apple notarization acceptance, stapling validation, and
  Gatekeeper acceptance have not been run for this candidate.
- Unsigned packaging must be rerun at the exact final release candidate; the
  prior ad-hoc package is not evidence for the tested source commit above.
- The unsigned/ad-hoc local app is not a distributable release and must not be
  presented as one.
