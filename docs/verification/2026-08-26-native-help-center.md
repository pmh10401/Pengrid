# Native Help Center Verification — 2026-08-26

## Scope

This record covers the bilingual documentation for Pengrid's native Help
window: the **Help > Pengrid Help** command and **Command-?** shortcut, the
eight bundled topics, explicit Korean/English selection, cross-language literal
and Hangul-initial search, no-result recovery, and the two kinds of allowlisted
online destinations. It combines the focused documentation evidence from Task
6 with the complete suite, release build, bundle launch, and manual-check
evidence (or explicit NOT RUN boundaries) from Task 7.

## Automated Verification

Focused command:

```text
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcrun swift test --enable-swift-testing --no-parallel --filter 'HelpCatalogTests|HelpPresentationTests|AccessibilityPresentationTests'
```

Observed result:

- Exit status: `0`.
- The XCTest compatibility target reported `0` selected tests, `0` failures,
  in `0.002` seconds.
- Swift Testing reported `37` tests in `2` suites, `0` failures, in `0.272`
  seconds. `HelpCatalogTests` and `HelpPresentationTests` passed, along with
  the selected accessibility presentation tests.
- The build emitted the existing warning about 11 unhandled fixture resources;
  it did not fail the run.
- This is a focused result; the complete-suite results are recorded below.

Complete nonparallel suite (first run):

```text
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcrun swift test --enable-swift-testing --no-parallel
```

Observed result:

- The run reported `1,948` tests in `125` suites and failed after `207.405`
  seconds (`real 213.14`, `user 140.57`, `sys 48.96`) with `5` issues.
- The observed Help suites passed. The visible unrelated timing failure was
  `ComparisonPerformanceTests.fiftyThousandEntriesPublishProgressivelyCompleteAndStopPromptly()`:
  its completion expectation timed out after `10.133` seconds with `48,640`
  rows instead of `50,000`, leaving the phase `.comparing`; the test recorded
  `3` expectation issues. The run's final summary reported `5` issues total;
  no Help test failure was reported.
- The existing warning about `11` unhandled Protected ZIP fixture resources was
  emitted and did not itself fail the run.

Required focused retry of the observed timing test:

```text
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcrun swift test --enable-swift-testing --no-parallel --filter 'ComparisonPerformanceTests/fiftyThousandEntriesPublishProgressivelyCompleteAndStopPromptly'
```

Observed result: `1` test in `1` suite failed after `10.232` seconds with the
same timing condition (`39,168` rows, `.comparing`; `3` issues; `real 13.65`,
`user 16.64`, `sys 7.14`). This is an unrelated, host-load-sensitive timing
failure, not a Help regression.

One permitted clean full retry:

```text
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcrun swift test --enable-swift-testing --no-parallel
```

Observed result: `1,948` tests in `125` suites passed after `155.803` seconds
(`real 159.86`, `user 125.36`, `sys 43.58`). The Help suites and all other
tests passed on this retry. The same `11` unhandled-fixture warning appeared.

Documentation checks run for this record:

- `32` local Markdown links in `README.md`, `README.ko.md`,
  `docs/user-guide.md`, and `docs/user-guide.ko.md` resolved successfully;
  `0` were missing.
- The two Help guide destinations resolve to the existing repository files
  `docs/user-guide.md` and `docs/user-guide.ko.md`.
- English/Korean guide sections were reviewed for matching opening, search
  examples, language persistence, eight-topic coverage, offline/online
  boundaries, and no-result recovery.

## Release Build

Command:

```text
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcrun swift build -c release
```

Observed result: `PASS`. The release build completed in `89.12` seconds
(`real 89.59`, `user 115.26`, `sys 2.08`). It emitted the existing `11`
unhandled-fixture warning. No release packaging, installation, signing,
notarization, or DMG claim was made.

## Bundle and Process Evidence

The repository workflow was run unchanged:

```text
./script/build_and_run.sh --verify
```

Observed result: `PASS` (exit status `0`, `real 4.65`). The workflow built and
staged `/Users/mac/Documents/Pengrid/.worktrees/safe-operation-center/dist/Pengrid.app`,
performed native-linkage and ad-hoc signature verification, and reported
`valid on disk` plus `satisfies its Designated Requirement`. The script's
`--verify` branch ends after bundle verification, so the staged bundle was then
launched explicitly with `/usr/bin/open -n` (the script was not edited):

```text
/usr/bin/open -n /Users/mac/Documents/Pengrid/.worktrees/safe-operation-center/dist/Pengrid.app
```

After launch, `pgrep -x BloomFileManager` returned PID `58100`; `ps` reported
the executable at
`.../dist/Pengrid.app/Contents/MacOS/BloomFileManager`. This proves the GUI
bundle process launched, but does not substitute for an accessibility-tree UI
inspection.

## Manual Checks

The following checks are `NOT RUN — required Computer Use/node_repl tool
unavailable in this session`. No AppleScript, CGEvent, or other substitute UI
automation was used, so these statuses are intentionally not inferred from
source tests or the running process:

- Help > Pengrid Help opens one window.
- Command-? opens or focuses the same window without duplicates.
- The native Help UI works at 860×620 and at its minimum size.
- Korean/English switching preserves the selected topic and persists after
  reopening.
- English, Korean, Korean-initial, and mixed queries find their expected
  topics.
- No-result recovery clears the query.
- Search, topic list, language, detail, and error regions are keyboard reachable
  and expose meaningful VoiceOver text.
- Light and Dark appearances remain readable; Dynamic Type does not clip; and
  Reduce Motion introduces no unexpected animation.
- Bundled topics remain visible while offline.
- An allowlisted link opens the exact GitHub target online, and a rejected open
  shows bounded feedback.

## Known Boundaries

- The eight Help topics and their search text are bundled with the app. The
  native Help view adds no runtime content fetch, workspace/File Provider
  inspection, or OAuth flow.
- The user-guide and releases buttons leave Pengrid for the exact allowlisted
  GitHub HTTPS destinations and require an internet connection. If the browser
  open is rejected, the view reports bounded local feedback; the bundled topics
  remain available.
- The first full-suite run and the required focused timing rerun exposed a
  pre-existing host-load-sensitive comparison timing failure; the one allowed
  clean full retry passed all `1,948` tests. This record preserves both facts
  rather than collapsing them into an unconditional first-run PASS.
- The staged GUI process was observed, but Computer Use/node_repl was not
  available in this session. Therefore all menu, keyboard, sizing, search,
  language-persistence, accessibility-label, appearance, offline, and external
  link checks remain explicitly NOT RUN.
- No network/privacy/security setting was disabled or changed, and no
  unexpected permission prompt was accepted. Rejected-open and VoiceOver
  observations are NOT RUN for the same tool-availability reason.
