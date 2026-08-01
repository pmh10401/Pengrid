# Final review fix wave report — multi-format archives

## Findings addressed

- Replaced the stale hash-based checklist candidate with the stable
  `multi-format-archive-verified` marker. The checklist now says that this
  marker points to the final verified HEAD after the documented gates are
  rerun.
- Added live TAR-family extraction coverage for renamed `.tgz`, `.tbz`,
  `.tbz2`, and `.txz` archives.
- Added live selected-symlink preservation coverage for TAR, TAR.GZ, TAR.BZ2,
  and TAR.XZ.
- Added a self-contained USTAR hostile fixture with a `..` member and a
  symlink-to-parent escape. Extraction must fail without publishing a
  destination, leaving an outside target absent, or leaving staging data.

## Files changed

- `Tests/BloomFileManagerTests/ArchiveOperationIntegrationTests.swift`
- `docs/verification/version-1.3-archive-checklist.md`
- `.superpowers/sdd/2026-08-01-multi-archive-formats/final-review-fix-wave-report.md`

## Test evidence

- Focused, live integration suite:

  ```bash
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    swift test --enable-swift-testing --no-parallel \
    --filter ArchiveOperationIntegrationTests
  ```

  Passed: 8 tests in 1 suite, including all four alias cases and all four
  TAR-family symlink cases. The first test-only fixture compilation exposed
  helper errors; after correcting the fixture encoder, the focused suite passed
  without production changes.

## Concerns

- The coordinator must rerun the release gates and create
  `multi-format-archive-verified` at this commit's final verified HEAD. No
  source commits may follow that marker.
- Existing repository test warnings about `@preconcurrency` and weak-variable
  mutability remain unrelated to this fix wave.
