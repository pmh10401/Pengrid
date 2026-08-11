# File context actions verification

**Date:** 2026-08-11  
**Worktree:** `codex/safe-operation-center` at `65230f7`  
**Scope:** context-menu productivity actions, documentation, and verification

This record separates automated evidence from candidate-specific manual checks.
`NOT RUN` means no live claim is made.

## Automated evidence

| Gate | Status | Actual result |
| --- | --- | --- |
| 10,000-row policy measurement | PASS | `ContextMenuPerformanceTests`: 1 test in 1 suite passed in 0.047 s (test body). The measurement constructs `FileContextMenuPolicy` synchronously on the main actor from deterministic in-memory `FileItem` metadata. Static policy-source evidence found zero identity, content-read, and File Provider materialization dependencies; elapsed is evidence only and has no time ceiling. |
| Full Swift test suite | PASS | `xcrun swift test --enable-swift-testing --no-parallel --filter BloomFileManagerTests` exited 0: 1,401 tests in 92 suites passed in 80.832 s. |
| Release build | PASS | `xcrun swift build -c release` exited 0; production build completed in 44.03 s. |
| Development-bundle verification | PASS | `./script/build_and_run.sh --verify` exited 0 in about 1.45 s; debug build completed in 0.23 s and `dist/Pengrid.app` was valid on disk and satisfied its designated requirement. |

The performance test intentionally has no 4- or 5-second assertion. It verifies
the pure value-policy boundary and a single synchronous main-actor call; the
recorded test-body elapsed is evidence rather than a pass/fail limit.

### Corrected diagnostic evidence

| Diagnostic stage | Actual result |
| --- | --- | --- |
| Cancellation-cleanup and Quick Look routing investigation | The earlier 15-issue suite result identified a cancellation-cleanup regression and a stale static Quick Look routing assertion. They were corrected by `de34cf9 fix: preserve cleanup after cancellation` and `65230f7 test: follow shared quick look routing`. The focused regression run then passed 184 tests in 11 suites in 5.582 s before the final full-suite pass. |

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
| `git status --short` | The four owned documentation edits plus the new verification note and `ContextMenuPerformanceTests.swift` are the only uncommitted files. |
| `git log --oneline --decorate -15` | HEAD: `65230f7 (HEAD -> codex/safe-operation-center) test: follow shared quick look routing`; preceding fix: `de34cf9 fix: preserve cleanup after cancellation`. |
