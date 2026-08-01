# Task 2 implementation report

## Files changed

- `Sources/BloomFileManager/Services/SmartSearchService.swift`
- `Tests/BloomFileManagerTests/SmartSearchServiceTests.swift`
- `.superpowers/sdd/2026-08-01-smart-search/task-2-report.md`

## Test-first evidence

Added `SmartSearchServiceTests` before adding the service implementation. The
focused red command was:

```text
swift test --enable-swift-testing --no-parallel --filter SmartSearchServiceTests
```

It failed during test-target compilation because this machine's active Command
Line Tools developer directory does not provide the Swift `Testing` module
(`no such module 'Testing'`), before it could report the expected absent-service
symbols. The same repository command requires Xcode; the prior Task 1 report
used `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`, but that Xcode
developer directory is not present on this machine.

After implementation, `swift build` passed cleanly. `git diff --check` also
passed. The focused test command was rerun and remains blocked by the same
environment-wide missing `Testing` module, so no green test count is claimed.

## Coverage added

- recursive traversal and duplicate root de-duplication;
- filename-preferred ranking and result cap;
- hidden, package, and symlink descendant exclusion, with hidden/package
  opt-in;
- directory result toggling;
- copied cloud availability with no materialization path;
- stable invalid-root failure;
- skipped unreadable entries; and
- prompt cancellation during a deliberately slow large traversal.

## Concerns

Focused runtime test verification requires an Xcode developer directory with
Swift Testing installed. The service target itself compiles successfully with
the available Command Line Tools. Symlink entries are always excluded as an
unsafe traversal boundary; the query model exposes opt-in controls only for
hidden and package descendants.

## Traversal hardening follow-up

The focused Xcode run initially exposed three issues: the ranking assertion
included directories despite the model's default, the symlink fixture placed
its target inside the searched root, and package directories could appear as
directory results. The test now disables directory results for its file-ranking
assertion and places the symlink target outside the root. The service performs
no-follow file-attribute checks at each enumerated URL and along its root-relative
path boundary, skips symlink descendants, and omits package directory entries
while still allowing opted-in package descendants.

```text
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --enable-swift-testing --no-parallel --filter SmartSearchServiceTests
```

Passed: 9 tests in 1 suite, 0 failures. `git diff --check` passed. Existing
unrelated `NSDraggingInfo` preconcurrency warnings remain in the test target.

## Distinct-root coverage follow-up

Expanded the explicit-root test to search two separate temporary directories
while repeating the first as `root/.`. It now asserts both distinct matching
files are returned exactly once. The focused Xcode command above passed again:
9 tests in 1 suite, 0 failures.
