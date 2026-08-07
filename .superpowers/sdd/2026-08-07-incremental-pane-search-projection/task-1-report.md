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

## Fix round 4 evidence

- Restored the committed replacement trace order: `report-1999`, `보고서-1998`, then whitespace-normalized `report-1999`; the release aggregate was not regenerated.
- Added a dedicated test-only normalized-equivalent reuse probe. It warms the session and establishes `report-1999` without recording setup, clears the recorder, then invokes the production transition path for ` \n report-1999 \t`.
- The timing recorder records whether both mechanisms were installed; the three async timing tests require `[true]` in addition to their exact six-event sequence.
- Setter mutation RED command: `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcrun swift test --disable-sandbox --no-parallel --filter paneSearchTimingOrderWhitespaceReuse` after temporarily removing `session.pane.updateFilterQuery(toQuery)` from the reuse branch.
- Setter mutation output: exit nonzero; the test failed with `.filterQuerySetterDidNotTakeEffect` after 1.178 seconds.
- Armed-placement mutation RED command: `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcrun swift test --disable-sandbox --no-parallel --filter paneSearchTimingOrderCompleteLoad` after temporarily recording `armed` before installing either mechanism.
- Armed-placement mutation output: exit nonzero; the test observed `armedMechanismsInstalled == [false]` instead of `[true]` after 0.604 seconds.
- GREEN command: `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcrun swift test --disable-sandbox --no-parallel --filter paneSearchTimingOrder`.
- GREEN output: exit 0; all four timing tests passed in 6.016 seconds.
- Regression command: `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcrun swift test --disable-sandbox --no-parallel --filter paneSearchProbeMeasuresTheCurrentSetterAcceptanceAndTableBoundaries`.
- Regression output: exit 0; the focused probe passed in 2.017 seconds.
- Aggregate-order command: `jq -e '(.reports // .) | map(select(.scenario == "replacement"))[0].rawSamples | group_by(.sampleIndex) | all(.[]; map(.toQuery) == ["report-1999", "보고서-1998", " \n report-1999 \t"])' docs/verification/2026-08-07-incremental-pane-search-baseline.json`.
- Aggregate-order output: `true`; all committed replacement samples retain the restored source order.

## Fix round 5 evidence

- Replaced the literal observation-installed value with local state: `observationInstalled` starts `false`, changes to `true` only after `withObservationTracking` returns, and is passed to `recordArmed` immediately before the measured operation.
- Mutation RED command: `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcrun swift test --disable-sandbox --no-parallel --filter paneSearchTimingOrderCompleteLoad` after temporarily moving `recordArmed` before `withObservationTracking`.
- Mutation output: exit nonzero; the test observed `armedMechanismsInstalled == [false]` instead of `[true]` after 0.989 seconds.
- GREEN command: `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcrun swift test --disable-sandbox --no-parallel --filter paneSearchTimingOrder`.
- GREEN output: exit 0; all four timing tests passed in 6.024 seconds.
- Regression command: `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcrun swift test --disable-sandbox --no-parallel --filter paneSearchProbeMeasuresTheCurrentSetterAcceptanceAndTableBoundaries`.
- Regression output: exit 0; the focused probe passed in 1.932 seconds.
- Aggregate-order output: the committed replacement-order `jq` check returned `true`; no baseline data was regenerated.
