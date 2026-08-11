# File context actions verification

**Date:** 2026-08-11
**Verified code/test baseline:** `e4e60dd` on `codex/safe-operation-center`
**Scope:** context-menu productivity actions, documentation, and verification

This record separates automated evidence from candidate-specific manual checks.
`NOT RUN` means no live claim is made.

## Automated evidence

| Gate | Status | Actual result |
| --- | --- | --- |
| 10,000-row ordered selection and policy descriptor construction | PASS | `ContextMenuPerformanceTests` constructs 10,000 deterministic in-memory `FileItem` values, filters a reverse-inserted selection into table order, then constructs `FileContextMenuPolicy` synchronously on the main actor. Focused test body: 0.055 s; final full-suite test body: 0.052 s. The boundary accepts only captured value inputs and no I/O-capable collaborator; it is not a full `NSMenu`/AppKit-adapter measurement and has no timing ceiling. |
| Focused reviewer-fix suite | PASS | Primary focused run: 119 tests in 4 suites passed after 0.289 s. |
| Full Swift test suite | PASS | `xcrun swift test --enable-swift-testing --no-parallel --filter BloomFileManagerTests` exited 0: 1,405 tests in 92 suites passed after 83.824 s. |
| Release build | PASS | `xcrun swift build -c release` exited 0; production build completed in 45.73 s. |
| Development-bundle verification | PASS | `./script/build_and_run.sh --verify` exited 0; debug build completed in 0.25 s, tool wall time was 1.54 s, and `dist/Pengrid.app` was valid on disk and satisfied its designated requirement. |

The performance test intentionally has no 4- or 5-second assertion. It verifies
ordered selection filtering and one synchronous, captured-value policy-descriptor
construction; its reported body durations are observation only, not pass/fail limits.

### Corrected diagnostic evidence

| Diagnostic stage | Actual result |
| --- | --- | --- |
| Sol fix-first review and correction | Sol found post-publish Duplicate cancellation, post-move enclosure cancellation, post-preflight Undo mutation, exclusive-state wiring, capability-documentation mismatch, performance-scope mismatch, and whitespace. Corrections were committed as `e4e60dd`; the focused reviewer-fix run passed 119 tests in 4 suites after 0.289 s, followed by the final full-suite pass. |

## Manual macOS evidence

| Check | Status | Evidence |
| --- | --- | --- |
| Context-menu grouping and icons | NOT RUN | Candidate-specific visual check not performed. |
| Right-click selection preservation and replacement | NOT RUN | Candidate-specific interaction check not performed. |
| Quick Look, Copy Full Path, and Duplicate shortcuts | NOT RUN | Candidate-specific keyboard check not performed. |
| Quick Look presentation and close behavior | NOT RUN | Candidate-specific system-panel check not performed. |
| Open With compatible-application launch | NOT RUN | Candidate-specific Launch Services check not performed. |
| Show in Finder reveal | NOT RUN | Candidate-specific Finder check not performed. |
| Copy Path clipboard forms and visible-order text | NOT RUN | Candidate-specific pasteboard check not performed. |
| Pane changes after invocation do not redirect captured work | NOT RUN | Candidate-specific two-pane interaction check not performed. |
| Duplicate, Keep Both collision, and Undo | NOT RUN | Candidate-specific mutation and Undo check not performed. |
| New Folder with Selection cancellation, rollback, and Undo | NOT RUN | Candidate-specific transaction check not performed. |
| Full Keyboard Access menu reachability | NOT RUN | Candidate-specific accessibility check not performed. |
| VoiceOver order, destination, disabled-reason, progress, and outcome reading | NOT RUN | Candidate-specific accessibility check not performed. |

## Signed-in OneDrive File Provider evidence

| Check | Status | Evidence |
| --- | --- | --- |
| Online-only materialization | NOT RUN | No signed-in OneDrive live verification performed. |
| Open With after materialization | NOT RUN | No signed-in OneDrive live verification performed. |
| Opposite-pane copy and move | NOT RUN | No signed-in OneDrive live verification performed. |
| Duplicate and Keep Both collision | NOT RUN | No signed-in OneDrive live verification performed. |
| New Folder with Selection | NOT RUN | No signed-in OneDrive live verification performed. |
| Progress and cancellation | NOT RUN | No signed-in OneDrive live verification performed. |
| Conservative Undo | NOT RUN | No signed-in OneDrive live verification performed. |
| Permission and materialization prompts | NOT RUN | No signed-in OneDrive live verification performed. |

## Boundaries observed

- No installation, interactive launch, disk image creation, push, or GitHub
  release was performed.
- This verification does not turn source-level coverage into a manual Finder,
  Launch Services, accessibility, or signed-in OneDrive claim.

## Repository audit

| Command | Actual result |
| --- | --- |
| `rg -n 'TODO|TBD|FIXME|fatalError\("not implemented"' Sources Tests README.md README.ko.md docs` | Two matches: this quoted audit command and the same command in `docs/superpowers/plans/2026-08-11-file-context-menu-productivity.md:595`; no implementation marker was reported. |
| `git diff --check` | Exit 0; no whitespace errors. |
| `git status --short` | Immediately before the final documentation commit, only this verification note was modified. |
| `git log --oneline --decorate -15` | Verified code/test baseline: `e4e60dd`; this identifies the evidence baseline only and does not promise the branch's later HEAD after this note is committed. |
