# Task 1 implementation report

## Files changed

- `Sources/BloomFileManager/Models/SmartSearchModels.swift`
- `Tests/BloomFileManagerTests/SmartSearchModelTests.swift`
- `.superpowers/sdd/2026-08-01-smart-search/task-1-report.md`

## Test-first evidence

Added the focused Smart Search model suite before its production model file.

```text
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --enable-swift-testing --no-parallel --filter SmartSearchModelTests
```

The initial run failed at compile time because `SmartSearchQuery`,
`SmartSearchResult`, `SmartSearchRecord`, `SmartSearchValidationError`, and
`SmartSearchRanker` did not exist. After the minimum implementation, the same
command passed: 7 tests in 1 suite, 0 failures.

`git diff --check` also passed.

## Concerns

The focused command recompiles the existing test target and reports pre-existing
compiler warnings in unrelated drag/drop and directory-reconciliation tests.
The Smart Search model tests and model source produce no warnings.

## Review fix

Hardened `SmartSearchQuery` invariants after task review:

- decoded queries now use the validating initializer, so malformed persisted
  text, roots, and result limits cannot bypass normalization;
- remote `file://` hosts are rejected, while only an empty host or `localhost`
  is accepted for local file URLs;
- `maximumResults` is `private(set)` and can only be changed through the
  clamping mutation API; and
- equal scores now have localized path ordering, a raw standardized-path
  fallback, and a relative-path fallback for identical standardized paths.

The review-fix red run failed because the new clamped mutation API and
identical-path tie fallback were absent. The green run used the same focused
command and passed: 11 tests in 1 suite, 0 failures. `git diff --check` passed.
