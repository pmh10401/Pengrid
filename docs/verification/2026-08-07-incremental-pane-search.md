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
recorded samples each. The aggregate contains 1,590 raw transition samples and
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
