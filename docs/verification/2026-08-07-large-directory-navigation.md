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
