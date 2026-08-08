# Incremental pane-search baseline

## Environment

- Source commit: `bcde2489496632b000f32b7b574ae3ac0d805eea`
- Release command: `/usr/bin/xcrun swift test -c release --disable-sandbox --no-parallel --filter paneSearchReleaseBenchmark`
- macOS: 26.5.2 (25F84)
- Hardware: MacBook Pro (Mac14,6), Apple M2 Max, 12 CPU cores, 32 GB memory
- Fixture: 10,000 entries. Numeric filters `1`, `19`, `199`, and `1999` produce 3,439, 299, 20, and 1 entry respectively.

## Measurement definition

Each recorded transition captures the instant immediately before the real
`FilePaneState.updateFilterQuery` (or sort setter), the Observation notification
for accepted `visibleItems`, and completion of
`FileTableView.Coordinator.apply(items:selection:to:)` plus
`layoutSubtreeIfNeeded()`. The accepted item identity/order is checked against
the unchanged `PaneItemProjector` filter/sort oracle. RSS comes from
`task_info(MACH_TASK_BASIC_INFO)` and `/usr/bin/time -l` is retained per isolated
process in the aggregate JSON.

`NavigationProductivityPerformanceTests` retains five-second assertions only as
hang ceilings; they are not acceptance-latency proof.

## Release baseline

`script/benchmark_pane_search.sh --output docs/verification/2026-08-07-incremental-pane-search-baseline.json`
runs eight interaction traces and forty sort key/direction/cardinality cells in
isolated release-test processes. Each process has three unrecorded warm-ups and
thirty recorded samples. Raw samples, nearest-rank median/p95, and child stdout,
stderr, and `/usr/bin/time -l` output are kept in the JSON artifact.

See the JSON artifact for the executed scenario reports and raw evidence.

## Recorded result

All 48 isolated release scenarios completed with three warm-ups and thirty
recorded samples each. The aggregate contains 1,920 raw transition samples (720
interaction-trace transitions plus 1,200 sort transitions) and
per-child `/usr/bin/time -l` output. `completeLoad` median/p95 were
0.977424333s/1.050733792s; `firstQuery` was 0.733107666s/0.747287750s;
numeric was 1.056032167s/1.074096583s; and rapid burst was
1.003404125s/1.023574875s. The largest raw in-process RSS is retained on every
transition and the independent process maximum RSS is retained in `processLogs`.

The fixture deliberately makes English and Korean prefix transitions narrow
strictly while preserving numeric counts and 5,000 `report` rows. Benchmark-only
acceptance observation uses the internal post-assignment projection hook so a
sort that retains equal rows is still timestamped. Whitespace-normalized queries
that reuse an already accepted key are recorded as `accepted-projection-reuse`;
their rows/order are checked against the same oracle without scheduling work.

## 2026-08-08 candidate matrix and policy-v3 replay

The canonical candidate is
[`2026-08-07-incremental-pane-search-candidate.json`](2026-08-07-incremental-pane-search-candidate.json):
48 scenarios, 1,920 raw samples, and the `application-latency-v2` measurement
boundary. End-to-end time is setter-to-accepted-state plus accepted-state-to-table
application; it excludes oracle and evidence work and is not visual-paint time.

`pane-search-application-latency-v3` is the authoritative replay: all 267/267
hard gates pass, with zero oracle and projection-token failures. Stale-publication,
cancel-at-most-128, deterministic cancellation-and-drain, subset-sort, and RSS
gates all pass. RSS is 156,860,416 candidate bytes versus 147,816,448 baseline
bytes (about 6.12%, below the 10% cap). The historical
`candidateGateEvaluation.hardGatePassed: false` remains preserved as historical
legacy evaluation and is not rewritten.

The sole relative-p95 advisory is `modifiedAt` ascending at 10,000 rows:
canonical candidate p95 212.776 ms versus baseline 179.662 ms (advisory limit
197.628 ms). Its 300 ms absolute hard p95 gate passes. Exactly three 3,439-row
sort p50 stretch targets miss 75 ms (`modifiedAt` ascending, `name` ascending,
and `name` descending); all retain the hard p50/p95/max limits of 80/100/150 ms.
The 50 ms ready-order target is likewise a stretch target, not a hard gate.

The failed frame/async-icon and serial-ASCII experiments were rejected and rolled
back; they are not retained behavior. The cancellation marker-before-worker-cancel
race was fixed. The canonical rapid-burst artifact retains 30 samples: one
recorded 0 post-marker visits, 21 recorded 127, and eight recorded 128 (median
127, p95 128). Deterministic gated traversal separately provides the required
non-vacuous cancellation proof; every retained value remains within the 128-visit
hard bound and all workers drain.

## Supplemental targeted variability evidence

[`2026-08-08-incremental-pane-search-supplemental.json`](2026-08-08-incremental-pane-search-supplemental.json)
preserves two raw, targeted `modifiedAt` ascending 10,000-row release reports,
their stdout/stderr, thermal/power/load snapshots, exact command, canonical
candidate provenance, and release-binary SHA-256
`5a467d72e5cfd37f5406c09cbd642b34ae005f2d3c678c827e251f45f9b09f62`.
Its canonical candidate source-artifact SHA-256 is
`5ce7211642372129d14bda4b4c24865657d92de117402ca0b113d5eef7b03b81`.

The canonical capture records tracked-diff SHA-256
`ed8334c4e8ed023cf7da5c8fe2c56d18ab7b92f04038105842286eacefd9e13c`.
Later runner/evaluator contract and documentation edits intentionally make the
current aggregate tracked diff different; replay leaves the canonical source
artifact immutable. The exact release-test executable is still bound by the
matching SHA-256
`5a467d72e5cfd37f5406c09cbd642b34ae005f2d3c678c827e251f45f9b09f62`,
so these post-capture tooling/document changes do not require a rebenchmark.

- Run 1: p50/p95/max 192.203/242.445/245.509 ms; load average 6.28/5.63/5.72.
- Run 2: p50/p95/max 190.983/198.715/250.470 ms; load average 6.76/5.79/5.78.

Both had zero oracle/token failures and no thermal or performance warning. This
is diagnostic variability evidence only (`usedForHardGate: false`): neither run
replaces the canonical 48-scenario artifact or its v3 policy replay.

## Automated compatibility and build verification

On 2026-08-08 the complete, serial debug test run passed 1,223 tests in 80
suites after 83.501 seconds:

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --disable-sandbox --no-parallel
```

The production build then completed successfully in 38.77 seconds:

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift build -c release --disable-sandbox
```

SwiftPM emitted only the existing warning that 11 protected-ZIP test fixtures
are unhandled target resources; compilation and linking succeeded. `git diff
--check` also passed. The environment-gated provider-folder-preview smoke test
and `paneSearchReleaseBenchmark` were not enabled in the ordinary full run. The
release benchmark remains represented by the canonical 48-scenario artifact.

These automated results do not complete the manual release gates. Visual-paint
latency, interactive UI and VoiceOver behavior, and live Google Drive and
OneDrive File Provider metadata-only browsing still require on-device checks.

A fresh Sol read-only final review returned `SHIP` with no Critical, Important,
or Minor findings. It explicitly approved the automated Task 8 commit while
retaining those interactive checks as release-validation gates.

```bash
env PENGRID_PANE_SEARCH_BENCHMARK=1 PENGRID_PANE_SEARCH_CANDIDATE=1 \
  PENGRID_PANE_SEARCH_SCENARIO=sort:modifiedAt:ascending:10000 \
  PENGRID_PANE_SEARCH_REPORT=<run>.json \
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/time -l /usr/bin/xcrun swift test -c release --skip-build \
  --disable-sandbox --no-parallel --filter paneSearchReleaseBenchmark
```
