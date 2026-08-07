# Large-directory navigation baseline verification — 2026-08-07

This is the measurement-only baseline for the large-directory navigation
optimization plan. It does not claim a production optimization; later tasks
must rerun the same probes after each behavior change.

## Scope and production boundary

- 300-item listing probe: records first batch and complete-load durations.
- Real 10,000-item listing: retains the existing progressive 256-item batch
  assertions and records monotonic first-batch/complete-load timings.
- 10,000-item filtering: five independent queries (`1`, `19`, `199`, `1999`,
  `report`) with deterministic expected result counts.
- 10,000-item sorting: each `FileSortKey` measured independently.
- 10,000-item table population: the production `FileTableView.Coordinator`
  applies the first nonempty array to an AppKit table, calls
  `layoutSubtreeIfNeeded()`, and records request-to-nonzero-row and
  coordinator-application durations.

No production `Sources/` file changed.

## Verification matrix

All SwiftPM commands used the full Xcode developer directory and serial,
unsandboxed execution.

| Status | Command | Result |
| --- | --- | --- |
| PASS | `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcrun swift test --disable-sandbox --no-parallel --filter listingPerformanceProbeReportsFirstBatchAndCompletion` | Required RED test first failed because `measureListing` was absent; after the test-only probe was added, 1 test passed. |
| PASS | `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcrun swift test --disable-sandbox --no-parallel --filter 'listingPerformanceProbeReportsFirstBatchAndCompletion\|filenameFilteringTenThousandLoadedItemsStaysBelowRegressionCeiling\|fileSortingTenThousandLoadedItemsMeasuresEachSortKeyIndependently\|tablePopulationTenThousandLoadedItemsMeasuresFirstRenderedNonemptyState'` | 4 tests in 1 suite passed. |
| PASS | `/usr/bin/time -l env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcrun swift test --disable-sandbox --no-parallel --filter tenThousandItemsArriveProgressivelyAndCompletely` | 3/3 real 10,000-item runs passed; raw samples are in the detailed report. |
| PASS | `/usr/bin/time -l env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcrun swift test --disable-sandbox --no-parallel` | 1,062 tests in 77 suites passed after 50.544 seconds; maximum resident set size 745,750,528 B. |

## Environment and headline baseline

Environment: macOS 26.5.2 (25F84), MacBook Pro Mac14,6, Apple M2 Max,
12 cores, 32 GB RAM.

| Measurement | Baseline |
| --- | ---: |
| 300-item first batch / complete | 0.038616541 s / 0.044044541 s |
| Warm 10,000-item first batch | 0.059255667–0.059755750 s |
| Warm 10,000-item complete load | 1.093987041–1.097459709 s |
| Filter query maximum (five independent runs) | 0.036255542 s (`1`) |
| Sort-key maximum (four independent runs) | 0.142683459 s (`kind`) |
| Table request-to-first-nonempty rows | 0.023634959 s |
| Table coordinator application | 0.002811750 s |

### Focused test-body timings

These are the Swift Testing body durations from the four-test focused run;
the inner operation timings below remain the comparison values.

| Test | Test body |
| --- | ---: |
| `listingPerformanceProbeReportsFirstBatchAndCompletion` | 0.101 s |
| `filenameFilteringTenThousandLoadedItemsStaysBelowRegressionCeiling` | 0.154 s |
| `fileSortingTenThousandLoadedItemsMeasuresEachSortKeyIndependently` | 0.312 s |
| `tablePopulationTenThousandLoadedItemsMeasuresFirstRenderedNonemptyState` | 0.115 s |

### Raw 10,000-item listing process samples

Each row is one complete invocation of the required
`/usr/bin/time -l ... --filter tenThousandItemsArriveProgressivelyAndCompletely`
command. The inner first-batch and complete-load values are measured with
`ContinuousClock`; the remaining columns are the process-level `/usr/bin/time`
values.

| Run | First batch | Complete | Test body | Real | User | Sys | Maximum RSS |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 (cold/build) | 0.060584166 s | 1.097706083 s | 2.675 s | 12.61 s | 8.38 s | 2.40 s | 640,761,856 B |
| 2 | 0.059755750 s | 1.093987041 s | 2.671 s | 3.32 s | 1.44 s | 1.87 s | 136,380,416 B |
| 3 | 0.059255667 s | 1.097459709 s | 2.648 s | 3.33 s | 1.45 s | 1.85 s | 136,773,632 B |

The first process sample includes a cold build/startup; runs 2–3 are the
steadier warm-process reference. These process values are kept separate from
the in-test monotonic first-batch timings.

### Raw 10,000-item filtering (each query measured independently)

| Query | Expected/result count | Elapsed |
| --- | ---: | ---: |
| `1` | 3,439 | 0.036255542 s |
| `19` | 299 | 0.028535041 s |
| `199` | 20 | 0.026707083 s |
| `1999` | 1 | 0.028111416 s |
| `report` | 5,000 | 0.015781458 s |

### Raw 10,000-item sorting (each `FileSortKey` measured independently)

| Sort key | Result count | Elapsed |
| --- | ---: | ---: |
| `name` | 10,000 | 0.084464042 s |
| `modifiedAt` | 10,000 | 0.025344375 s |
| `kind` | 10,000 | 0.142683459 s |
| `size` | 10,000 | 0.029108166 s |

### Raw 10,000-item AppKit table population

| Rows | Request to first nonempty rows | Coordinator application |
| ---: | ---: | ---: |
| 10,000 | 0.023634959 s | 0.002811750 s |

## Known baseline warnings

SwiftPM emits the existing 11 unhandled ProtectedZIP fixture-file warnings
and two existing `@preconcurrency` test warnings. They are baseline noise; no
new warning or test failure originated from this harness.

For the complete raw samples, TDD RED/GREEN transcript, self-review, and
concerns, see
`.superpowers/sdd/2026-08-07-large-directory-navigation-optimization/task-1-report.md`.

## Task 7 touched-path cleanup — 2026-08-07

Task 7 preserved the app-facing listing, pane, and table APIs while removing
only the named duplicated paths and moving table support declarations to their
responsibility-focused source file. No compatibility, safety, selector,
Codable, command-routing, archive, or task-lifecycle path was broadened or
deleted.

### Focused pre-refactor GREEN

At baseline commit `e3b73ba03f3169fd8be53aad10619d6110df98e4`, before the Task 7
edits, this required command passed:

```text
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcrun swift test --disable-sandbox --no-parallel --filter 'FileTableSelectionTests|DropIntentTests|FileTableViewLifecycleTests|FilePaneStateTests|DirectoryListingServiceTests'
```

Result: 114 tests in 2 suites passed. SwiftPM emitted the existing 11
unhandled ProtectedZIP fixture warnings and existing test warnings only.

### Cleanup Evidence

| Named path | Task 7 action and replacement | Covering evidence |
| --- | --- | --- |
| `FileTableSelection`, `InlineRenameSelection`, `FileTableDropRouting`, `InlineTextEditingEvent`, `PaneActivatingTableView` in `FileTableView.swift` | Moved verbatim to `Sources/BloomFileManager/Views/AppKit/FileTableSupport.swift`; private `Column` and all coordinator callbacks remain in `FileTableView.swift`. | `FileTableSelectionTests`, `DropIntentTests`, and `FileTableViewLifecycleTests` pass after extraction. |
| Old computed `FilePaneState.visibleItems` | Already absent at Task 7 start: Task 5 replaced it with the stored accepted projection snapshot and `visibleIndexByURL`/`visibleURLByEntryPath`. No live compatibility path was deleted. | `PaneItemProjectionTests`, `FilePaneStateTests`, `PaneBatchBufferTests`, and repeated-read performance coverage. |
| Second localized-type resource read | Already absent at Task 7 start: Task 3's one-pass `DirectoryEntryBatchBuilder`/`LiveDirectoryEntryMetadataReader` is the only metadata path. | `DirectoryListingServiceTests`, `CloudItemAvailabilityTests`, and full-suite listing coverage. |
| Task 2 temporary serial builder | Already absent at Task 7 start: `LiveDirectoryListingService` delegates each collected batch to `batchBuilder.build(urls:)`. | `DirectoryListingServiceTests`, `LargeDirectoryTests`, and `CloudLocationScopedAccessTests`. |
| Unconditional table reload branch | Already absent at Task 7 start: Task 6's planner selects explicit `reloadAll` only for its measured safe fallback; bounded plans and value reloads remain. | `FileTableUpdatePlannerTests` and `FileTableViewLifecycleTests`, including measured-threshold and real-`NSTableView` cases. |
| Repeated visible URL/index scans | `FilePaneState` rename selection now resolves through the existing `visibleURLByEntryPath` projection index; accepted-selection intersection uses the stored `visibleIndexByURL` map. Coordinator rename completion uses its existing standardized identity index instead of scanning `items`. | `FilePaneStateTests.inlineRenameSelectionUsesVisibleEntryPathIndex`, `WorkspaceCommandTests`, `FileTableSelectionTests`, and `FileTableViewLifecycleTests`. |

The following named paths were inspected and required no further deletion after
Tasks 1–6: `LiveDirectoryListingService.swift` and
`PaneItemProjection.swift`. Their optimized cursor/batch-builder and immutable
projection/index implementations are live and were retained.

### Task 7 post-refactor verification

| Status | Command | Result |
| --- | --- | --- |
| PASS | `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcrun swift test --disable-sandbox --no-parallel --filter 'FileTableSelectionTests\|DropIntentTests\|FileTableViewLifecycleTests\|FilePaneStateTests\|DirectoryListingServiceTests'` | 115 tests in 2 suites passed after 5.986 s. |
| PASS | `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcrun swift test --disable-sandbox --no-parallel --filter 'FileTableSelectionTests\|DropIntentTests\|FileTableViewLifecycleTests\|FilePaneStateTests\|DirectoryListingServiceTests\|PaneItemProjectionTests\|PaneBatchBufferTests\|FileTableUpdatePlannerTests'` | 135 tests in 5 suites passed after 5.993 s. |
| PASS | `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcrun swift build --disable-sandbox` | Build completed successfully. |
| PASS | `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcrun swift test --disable-sandbox --no-parallel` | 1,146 tests in 80 suites passed after 59.220 s. |

The existing SwiftPM warning set (11 unhandled ProtectedZIP fixtures and
pre-existing test warnings) remained unchanged.
