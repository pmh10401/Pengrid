# Task 1 report

Status: DONE

- Added a real pane/table benchmark probe, fixture contract, isolated runner, and 48-scenario release aggregate.
- Baseline JSON: 48 reports, 1,590 raw transitions, 30 recorded samples per scenario.
- Focused tests: pane-search contract and projection-acceptance post-assignment contract passed.
- Runner preserves failed staging logs, prebuilds release separately, and uses `--skip-build` for RSS evidence.
- Acceptance hook is internal/default-nil and runs only after visible rows, indexes, and accepted key are assigned.

Fix round 1: focused pane probe passed after real setter/timer boundary correction; runner now performs an untimed release prebuild before timed --skip-build children.
