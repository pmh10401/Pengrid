# Large-directory navigation verification — 2026-08-07

This document preserves the measurement-only Task 1 baseline, the Task 8
automated after-samples, and the independent system-level File Provider
evidence. Real in-app UI, accessibility, and spoken VoiceOver checks remain
pending because the required GUI automation tool was unavailable. Automated or
system-level passes below do not convert a measured performance miss or a
pending in-app gate into a pass.

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

## Task 8 final verification evidence — 2026-08-07

### Measurement method and environment

The after measurements use the exact Task 1 fixtures and test filters. Each
command had a separate unrecorded warm-up, followed by three recorded process
invocations. The 10,000-entry listing and the focused filter/sort/AppKit group
remain separate processes, just as in Task 1; their resident-set peaks are not
combined.

Environment: macOS 26.5.2 (25F84), MacBook Pro Mac14,6, Apple M2 Max,
12 cores, 32 GB RAM. SwiftPM used the full Xcode developer directory,
`--disable-sandbox`, and `--no-parallel`.

```text
/usr/bin/time -l env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcrun swift test --disable-sandbox --no-parallel --filter tenThousandItemsArriveProgressivelyAndCompletely

/usr/bin/time -l env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcrun swift test --disable-sandbox --no-parallel --filter 'listingPerformanceProbeReportsFirstBatchAndCompletion|filenameFilteringTenThousandLoadedItemsStaysBelowRegressionCeiling|fileSortingTenThousandLoadedItemsMeasuresEachSortKeyIndependently|tablePopulationTenThousandLoadedItemsMeasuresFirstRenderedNonemptyState'
```

Three samples are sufficient to show every raw value and a median, but not a
statistically useful p95. Nearest-rank p95 would merely equal the maximum for
three observations. The warm Task 1 listing reference has two process samples,
and the Task 1 filter, sort, and table references have one observation each.
Therefore no Task 8 p95 percentage or p95 acceptance claim is supported. The
maximums are retained as raw observations, not relabelled as p95.

### Raw optimized listing samples

The inner values use `ContinuousClock`; process values use `/usr/bin/time -l`.

| Run | First 256-entry batch | Complete 10,000-entry load | Test body | Process real | User | Sys | Maximum RSS |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 0.022753791 s | 0.541241125 s | 2.226 s | 3.02 s | 1.94 s | 2.42 s | 88,227,840 B |
| 2 | 0.022794208 s | 0.553369750 s | 2.390 s | 3.10 s | 1.94 s | 2.55 s | 88,784,896 B |
| 3 | 0.023412167 s | 0.567652292 s | 2.437 s | 3.23 s | 2.05 s | 2.64 s | 88,244,224 B |
| Median | 0.022794208 s | 0.553369750 s | 2.390 s | 3.10 s | 1.94 s | 2.55 s | 88,244,224 B |
| Maximum (not p95) | 0.023412167 s | 0.567652292 s | 2.437 s | 3.23 s | 2.05 s | 2.64 s | 88,784,896 B |

The exact same 300-entry Task 1 probe also produced:

| Run | First batch | Complete |
| ---: | ---: | ---: |
| 1 | 0.021602417 s | 0.023552209 s |
| 2 | 0.021583500 s | 0.023547583 s |
| 3 | 0.020959875 s | 0.022774500 s |
| Median | 0.021583500 s | 0.023547583 s |
| Maximum (not p95) | 0.021602417 s | 0.023552209 s |

### Raw optimized filter and sort samples

Every row preserved its Task 1 correctness count. These measurements time the
same direct filter or sort operation as the baseline; they do not use cached
repeated reads to hide recomputation cost.

| Filter query | Result count | Run 1 | Run 2 | Run 3 | Median | Maximum (not p95) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `1` | 3,439 | 0.034608042 s | 0.034430667 s | 0.034165917 s | 0.034430667 s | 0.034608042 s |
| `19` | 299 | 0.025827625 s | 0.025633916 s | 0.025263708 s | 0.025633916 s | 0.025827625 s |
| `199` | 20 | 0.025653791 s | 0.025446709 s | 0.025454875 s | 0.025454875 s | 0.025653791 s |
| `1999` | 1 | 0.025097625 s | 0.025511000 s | 0.025484708 s | 0.025484708 s | 0.025511000 s |
| `report` | 5,000 | 0.015067375 s | 0.014490833 s | 0.015103417 s | 0.015067375 s | 0.015103417 s |

| Sort key | Result count | Run 1 | Run 2 | Run 3 | Median | Maximum (not p95) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `name` | 10,000 | 0.084028792 s | 0.081897958 s | 0.083538292 s | 0.083538292 s | 0.084028792 s |
| `modifiedAt` | 10,000 | 0.026454625 s | 0.025439416 s | 0.025293250 s | 0.025439416 s | 0.026454625 s |
| `kind` | 10,000 | 0.140013459 s | 0.138132708 s | 0.139869292 s | 0.139869292 s | 0.140013459 s |
| `size` | 10,000 | 0.028427125 s | 0.027822333 s | 0.027361292 s | 0.027822333 s | 0.028427125 s |

### Raw optimized AppKit samples

The Task 1 table probe is `@MainActor`. `Coordinator application` is therefore
the measured main-actor application interval. The longest observed interval is
0.000119250 seconds (0.119250 ms). No broader event-loop stall metric was added
after the baseline, so this report does not claim one.

| Run | First nonempty 10,000-row table state | Coordinator/main-actor application | Focused-process maximum RSS |
| ---: | ---: | ---: | ---: |
| 1 | 0.015323417 s | 0.000089625 s | 112,607,232 B |
| 2 | 0.015487375 s | 0.000090833 s | 112,164,864 B |
| 3 | 0.017147666 s | 0.000119250 s | 111,968,256 B |
| Median | 0.015487375 s | 0.000090833 s | 112,164,864 B |
| Maximum (not p95) | 0.017147666 s | 0.000119250 s | 112,607,232 B |

No directly comparable Task 1 focused-process RSS was recorded, so the focused
RSS rows have no percentage claim. The listing-process RSS comparison below
uses only the matching Task 1 and Task 8 listing commands.

### Median comparison and performance decision

Negative delta is improvement. The Task 1 10,000-entry time reference uses the
median of warm runs 2 and 3; the listing RSS reference is the median of those
same two warm process values. Task 1 filter/sort/table values are explicitly
single-observation references.

| Metric | Task 1 reference | Task 8 median | Change | Gate |
| --- | ---: | ---: | ---: | --- |
| 10,000-entry first 256-entry batch | 0.059505709 s | 0.022794208 s | -61.69% | PASS: at least 30% faster |
| 10,000-entry complete load | 1.095723375 s | 0.553369750 s | -49.50% | PASS: no greater than 10% regression |
| 10,000-entry listing maximum RSS | 136,577,024 B | 88,244,224 B | -35.39% | PASS: no greater than 10% regression |
| First nonempty AppKit table state | 0.023634959 s | 0.015487375 s | -34.47% | PASS against the single baseline observation |
| Coordinator/main-actor application | 0.002811750 s | 0.000090833 s | -96.77% | PASS against the single baseline observation |
| 300-entry first batch | 0.038616541 s | 0.021583500 s | -44.11% | Supporting evidence only |
| 300-entry complete | 0.044044541 s | 0.023547583 s | -46.54% | Supporting evidence only |

| Direct projection case | Task 1 reference | Task 8 median | Change | 30% target |
| --- | ---: | ---: | ---: | --- |
| Filter `1` | 0.036255542 s | 0.034430667 s | -5.03% | FAIL |
| Filter `19` | 0.028535041 s | 0.025633916 s | -10.17% | FAIL |
| Filter `199` | 0.026707083 s | 0.025454875 s | -4.69% | FAIL |
| Filter `1999` | 0.028111416 s | 0.025484708 s | -9.34% | FAIL |
| Filter `report` | 0.015781458 s | 0.015067375 s | -4.52% | FAIL |
| Sort `name` | 0.084464042 s | 0.083538292 s | -1.10% | FAIL |
| Sort `modifiedAt` | 0.025344375 s | 0.025439416 s | +0.37% regression | FAIL |
| Sort `kind` | 0.142683459 s | 0.139869292 s | -1.97% | FAIL |
| Sort `size` | 0.029108166 s | 0.027822333 s | -4.42% | FAIL |

**Performance: FAIL overall.** First-batch, first-table, complete-load, and
matching listing-memory gates pass. The approved 30 percent direct filter/sort
target is missed by every case, and no variance revision is proposed from only
three after samples and one baseline observation per case.

The ordinary sorted-insert/no-reload completion gate also remains **FAIL**.
`FileTableUpdatePlanner` has a measured production default of
`maximumIncrementalChanges = 0`, so structural insertions choose `reloadAll`.
Tests for `insertRows` inject a non-production threshold; the production-default
test explicitly verifies full reload. Earlier 30-sample Task 6 threshold data
showed positive thresholds were materially slower, but that justified the safe
fallback, not a variance revision to the approved completion criterion.

### Automated verification gates

| Status | Area | Command and result |
| --- | --- | --- |
| PASS | Focused safety/navigation gate | Exact required filter: 189 tests in 9 reported suites passed after 8.830 s. |
| PASS | Full suite | `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcrun swift test --disable-sandbox --no-parallel`: 1,146 tests in 80 suites passed after 55.014 s. |
| PASS | Release build | `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcrun swift build --disable-sandbox -c release`: production build completed after 37.23 s. |

The existing 11 unhandled ProtectedZIP fixture warnings remain. No external
package dependency or persistent filesystem index is present. Static source
inspection shows that `LiveDirectoryListingService` accepts availability and
metadata readers, not a `CloudMaterializing` dependency, and its producer only
collects entries into `DirectoryEntryBatchBuilder`; availability is mapped into
the resulting `FileItem` projection. `CloudItemAvailabilityTests.
directoryListingDoesNotCallTheMaterializer` covers that availability mapping and
the requested URL. Its separately-created `InMemoryCloudMaterializer` is not
injected into the live listing service, so its empty call record is **not**
runtime-observable proof of zero materializer calls. This is architectural
absence evidence only; scoped-access lifetime tests provide separate coverage.

### Independent system File Provider evidence and GUI blocker

The requested GUI automation surface (`node_repl` with
`@oai/sky/computer-use`) was not callable for either the root agent or the
independent verifier. Therefore no real Pengrid launch, in-app provider flow,
accessibility-tree inspection, or spoken VoiceOver result is claimed. Both-pane
loading, scrolling, Korean/English filter, every sort, navigation cancellation,
refresh, selection, scroll restoration, focus, rename, and VoiceOver remain
**PENDING/BLOCKED** on that unavailable tool.

A full-Xcode debug build at source HEAD
`80b48ab52abb3019a4ae144d84ceb47b354a57dd` succeeded and produced
`.build/arm64-apple-macosx/debug/BloomFileManager`, with only the existing 11
fixture warnings. The existing `dist` application is stale v1.3.0 build 5 and
was not used. A process under `/Applications` was unrelated/stale. Neither is
evidence of a Task 8 app launch.

The following is a sanitized, copy-and-rerun system-level transcript. It
discovers only the two provider root patterns, reads their mode and
`com.apple.file-provider-domain-id` xattr, and obtains **metadata only** for
immediate children. The Swift snippet calls Foundation resource-value APIs for
download status/flag and the legacy percent key (through `NSURL` because that
URL resource key is unavailable in current Swift overlays). It does not open,
preview, hash, enumerate recursively, download, or materialize a file.

```bash
set -euo pipefail
CLOUD_ROOT=/Users/mac/Library/CloudStorage
snapshot() {
  printf '%s\n' \
    'import Foundation' \
    'let root = URL(fileURLWithPath: CommandLine.arguments[1])' \
    'let keys: Set<URLResourceKey> = [.ubiquitousItemIsDownloadingKey, .ubiquitousItemDownloadingStatusKey]' \
    'let percentKey = URLResourceKey("NSURLUbiquitousItemPercentDownloadedKey")' \
    'let urls = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: Array(keys), options: [])' \
    'var statuses: [String: Int] = [:]; var downloading = 0; var percentages = 0' \
    'for url in urls { let value = try url.resourceValues(forKeys: keys); let status = value.ubiquitousItemDownloadingStatus?.rawValue ?? "nil"; statuses[status, default: 0] += 1; if value.ubiquitousItemIsDownloading == true { downloading += 1 }; var raw: AnyObject?; try? (url as NSURL).getResourceValue(&raw, forKey: percentKey); if raw != nil { percentages += 1 } }' \
    'print("children=\(urls.count) statuses=\(statuses.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")) downloadingFlags=\(downloading) percentValues=\(percentages)")' \
  | env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcrun swift - "$1"
}
for root in "$CLOUD_ROOT"/GoogleDrive-* "$CLOUD_ROOT"/OneDrive-*; do
  [ -d "$root" ] || continue
  printf 'ROOT=%s ' "${root##*/}"
  /usr/bin/stat -f 'mode=%Lp' "$root"
  printf 'DOMAIN='
  /usr/bin/xattr -p com.apple.file-provider-domain-id "$root" \
    | /usr/bin/sed -E 's/gdrive-[0-9]+/gdrive-<redacted-domain-id>/'
done
for root in "$CLOUD_ROOT"/GoogleDrive-* "$CLOUD_ROOT"/OneDrive-*; do
  [ -d "$root" ] && { printf 'BEFORE %s ' "${root##*/}"; snapshot "$root"; }
done
/bin/sleep 2
for root in "$CLOUD_ROOT"/GoogleDrive-* "$CLOUD_ROOT"/OneDrive-*; do
  [ -d "$root" ] && { printf 'AFTER %s ' "${root##*/}"; snapshot "$root"; }
done
for root in "$CLOUD_ROOT"/GoogleDrive-* "$CLOUD_ROOT"/OneDrive-*; do
  [ -d "$root" ] || continue
  domain=$(/usr/bin/xattr -p com.apple.file-provider-domain-id "$root")
  printf 'FILEPROVIDERCTL %s\n' "${root##*/}"
  /usr/bin/fileproviderctl dump "$domain" --limit-dump-size 0 2>&1 \
    | /usr/bin/sed -n '/== action operation engine ==/,+3p'
done
```

Raw output from the 2026-08-07 rerun (provider domain IDs are deliberately
redacted; the pre-existing account-root label is retained):

```text
ROOT=GoogleDrive-pmh10401@gmail.com mode=500
DOMAIN=com.google.drivefs.fpext/gdrive-<redacted-domain-id>
ROOT=OneDrive-개인 mode=700
DOMAIN=com.microsoft.OneDrive.FileProvider/OneDrive
BEFORE GoogleDrive-pmh10401@gmail.com children=5 statuses=NSURLUbiquitousItemDownloadingStatusCurrent=5 downloadingFlags=0 percentValues=0
BEFORE OneDrive-개인 children=21 statuses=NSURLUbiquitousItemDownloadingStatusCurrent=19,NSURLUbiquitousItemDownloadingStatusNotDownloaded=2 downloadingFlags=0 percentValues=0
AFTER GoogleDrive-pmh10401@gmail.com children=5 statuses=NSURLUbiquitousItemDownloadingStatusCurrent=5 downloadingFlags=0 percentValues=0
AFTER OneDrive-개인 children=21 statuses=NSURLUbiquitousItemDownloadingStatusCurrent=19,NSURLUbiquitousItemDownloadingStatusNotDownloaded=2 downloadingFlags=0 percentValues=0
FILEPROVIDERCTL GoogleDrive-pmh10401@gmail.com
== action operation engine ==
=================
0 operations
FILEPROVIDERCTL OneDrive-개인
== action operation engine ==
=================
0 operations
```

The roots, provider-domain xattrs, two-second before/after counts, status
values, download flags, percent values, and File Provider action-operation
counts therefore matched the prior observation. No provider action was issued;
`fileproviderctl dump` is a read-only daemon-state query. This supports **PASS
for the narrowly-scoped, system-level metadata-only observation**. It does not
prove Pengrid's in-app list/filter/sort/navigation flow, so the live in-app
cloud gate remains **PENDING**.

### Repository-wide cleanup audit input

This is classification evidence for a separate cleanup plan, not deletion
authorization. `Sources/BloomFileManager` contains 31,784 Swift lines and
`Tests/BloomFileManagerTests` contains 46,624 Swift lines. A full Xcode
`indexstore-db` executable was not available, so the audit records that limit
instead of claiming index evidence.

| Classification | Candidate/evidence | Decision for Task 8 |
| --- | --- | --- |
| `proven-unused` | `MZUnused` and `entryExists` have one exact repository reference each: their private declarations. Detailed runtime review is below. | Retain for a separate deletion plan; do not delete in this audit. |
| `duplicate` | The same standardized, percent-decoded, trailing-slash-trimming URL-path body appears in `PaneEntryPath.normalize`, `FilePaneState.entryPath`, `PaneViewStateCache.key`, and `PaneNavigationHistory.path`; `FileOperationController.directoryKey` is also equivalent in shape. All have live references and distinct ownership today. | Consolidation candidate only. Prove cross-module semantics and run navigation, persistence, monitor, selection, Undo-overlap, and symlink tests before changing it. |
| `compatibility` | `SmartSearchQuery.includeDirectories`, its `CodingKeys`/optional metadata decoder, `SmartSearchMetadataFilter.legacy`, and the two-argument `compressSelection` overload are exercised by legacy decode, unchanged stored-bytes, metadata round-trip, and callable-overload tests. | Retain. A migration and compatibility window are required before removal. |
| `safety-boundary` | `legacyTransfer`; scoped-access leases; captured identity/fingerprint revalidation; Undo/quarantine/recovery paths; symlink boundaries; archive and protected-ZIP validation. | Retain. These are live fail-closed boundaries, not cleanup candidates. |
| `live-large-file` | Largest production Swift files: `FileSystemAccess.swift` 2,529 lines, `ComparisonCoordinator.swift` 1,981, `FileOperationController.swift` 1,670, `FileOperationService.swift` 1,137, `FilePaneState.swift` 1,059, `FileTableView.swift` 952, and `ProtectedZIPOperationService.swift` 887. | Live responsibility-split backlog only; line count is not dead-code evidence. |
| `test-support` | Test-only support includes `RecordingFileSystem.swift` 780 lines and the Task 1 `NavigationPerformanceProbe.swift` 74 lines. Exact references show they are used across operation, archive, cloud, listing, and performance tests. | Retain while those tests remain; production target does not consume them. |

#### Deletion-candidate evidence

| Candidate | Declaration and all exact references | Selector/Codable/reflection review | Relevant tests | Classification/next step |
| --- | --- | --- | --- | --- |
| `MZUnused` | `Sources/BloomFileManager/Services/ProtectedZIPEngine.swift:288`; exact **Sources/Tests code-only** identifier search (excluding `docs/` and build output) returns only that declaration. | Private generic free Swift function; not `@objc`, not a selector target, not a `CodingKey`/Codable member, not reflected, and not exported to the C protected-ZIP callback boundary. | Fresh full suite includes protected-ZIP engine, operation, end-to-end, model, routing, archive, cancellation, and recovery coverage; 1,146/1,146 passed. | `proven-unused`; propose isolated deletion plus focused protected-ZIP and full-suite rerun in a separate reviewed cleanup. |
| `entryExists` | `Sources/BloomFileManager/Services/FileSystemAccess.swift:2123`; exact **Sources/Tests code-only** identifier search (excluding `docs/` and build output) returns only that declaration. | Private instance Swift method; not `@objc`, not a selector target, not Codable, not reflected, and not protocol witness/dynamic dispatch. | Fresh full suite includes `FileSystemAccessTests`, file mutation/transfer/Undo, archive, quarantine, symlink, and recovery coverage; 1,146/1,146 passed. | `proven-unused`; propose isolated deletion plus focused filesystem/safety and full-suite rerun in a separate reviewed cleanup. |

Audit searches also reviewed private declarations with one/two textual
occurrences, legacy/CodingKeys/selector/reflection sites, resource-value reads,
`contentsOfDirectory`/enumerator calls, visible projection/index uses,
`reloadData`/`insertRows`, and the largest source/test files. No regex result was
deleted or treated as proof by itself.

### Independent acceptance status

| Area | Status | Evidence/blocker |
| --- | --- | --- |
| Performance | **FAIL** | Direct filter/sort 30% target and ordinary sorted-insert/no-reload gate are unmet; other measured performance sub-gates pass. |
| Safety | **PASS (automated)** | Focused and full suites cover cancellation/generation races, selection, rename, scroll/focus restoration, refresh rollback, monitor races, identity, Undo, journal/quarantine, symlink, archive, and protected ZIP. |
| Cloud | **PENDING overall** | Automated zero-materialization/scoped-access and independent system metadata-only Google Drive/OneDrive checks pass with no download indicators; the live Pengrid in-app flow is unverified because GUI automation was unavailable. |
| Compatibility | **PASS (automated)** | Workspace persistence, legacy saved-search bytes/decoding, `FileSort` Codable, and legacy compression-overload tests pass. |
| Full suite | **PASS** | 1,146 tests in 80 suites, 55.014 s. |
| Release build | **PASS** | Production build completed in 37.23 s. |
| UI | **PENDING/BLOCKED** | The GUI automation tool was unavailable; no real app UI, accessibility-tree, spoken VoiceOver, or in-app provider-flow pass is claimed. |

Overall Task 8 acceptance is **not complete**: performance has two explicit
misses, and real in-app UI/VoiceOver/File Provider checks remain pending.
Nothing in this report revises the approved variance rule.
