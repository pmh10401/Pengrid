# Task 1 report

Status: DONE

- Added a real pane/table benchmark probe, fixture contract, isolated runner, and 48-scenario release aggregate.
- Baseline JSON: 48 reports, 1,920 raw transitions (720 trace + 1,200 sort), 30 recorded samples per scenario.
- Focused tests: pane-search contract and projection-acceptance post-assignment contract passed.
- Runner preserves failed staging logs, prebuilds release separately, and uses `--skip-build` for RSS evidence.
- Acceptance hook is internal/default-nil and runs only after visible rows, indexes, and accepted key are assigned.

## Fix round 1 evidence

- Covering test files: `Tests/BloomFileManagerTests/PaneSearchBenchmarkTests.swift`, `Tests/BloomFileManagerTests/Support/PaneSearchPerformanceProbe.swift`, and `Tests/BloomFileManagerTests/FilePaneStateTests.swift`.
- Command: `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcrun swift test --disable-sandbox --no-parallel --filter paneSearchProbeMeasuresTheCurrentSetterAcceptanceAndTableBoundaries`
- Output: exit 0; Swift Testing ran one pane-search probe and passed in 1.870 seconds (the existing 11 protected-ZIP fixture warnings and existing AppKit test warnings remained).
- Runner prebuild smoke command: `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcrun swift test -c release --disable-sandbox --no-parallel --filter paneSearchReleaseBenchmark`.
- Runner behavior: `script/benchmark_pane_search.sh` now performs that untimed release prebuild before its child loop, then each `/usr/bin/time -l` child uses `--skip-build`; compiler RSS is therefore excluded from child measurement.

## Fix round 2 evidence

- Command: `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcrun swift test --disable-sandbox --no-parallel --filter paneSearchProbeMeasuresTheCurrentSetterAcceptanceAndTableBoundaries`
- Output: exit 0; one focused Swift Testing probe passed in 1.937 seconds.
- Command: `script/benchmark_pane_search.sh --output docs/verification/2026-08-07-incremental-pane-search-baseline.json --replace`.
- Output: regenerated aggregate contains `scenarioCount=48`, 48 reports, 30 recorded samples for every report, and 1,920 raw transitions.

## Fix round 3 evidence

- Added a test-only, default-nil timing event recorder to the pane-search probe. Setup and reset operations are intentionally excluded from recorded timing boundaries.
- Initial RED command: `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcrun swift test --disable-sandbox --no-parallel --filter paneSearchTimingOrder`.
- Initial output: the four timing-order tests compiled and ran; complete-load and rapid-burst stopped after the armed event, while sort and replacement stopped before the required acceptance/table sequence.
- GREEN command: `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcrun swift test --disable-sandbox --no-parallel --filter paneSearchTimingOrder`.
- GREEN output: exit 0; complete-load, rapid-burst, `sort:name:ascending:10000`, and multi-transition whitespace replacement all passed (4 tests, 6.197 seconds).
- Regression command: `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcrun swift test --disable-sandbox --no-parallel --filter paneSearchProbeMeasuresTheCurrentSetterAcceptanceAndTableBoundaries`.
- Regression output: exit 0; one focused pane-search probe passed in 1.942 seconds. Existing protected-ZIP fixture warnings remain unrelated.
