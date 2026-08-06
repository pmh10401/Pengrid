# Final review fix B — protected ZIP entry-count ceiling

Date: 2026-08-06 (Asia/Seoul)

## Scope

This fix addresses whole-feature final-review Important #3: protected ZIP
creation previously trusted the caller's extraction-style entry limit and had
no hard production ceiling. Creation now enforces exactly 100,000 entries,
independent of Swift-provided limits.

## Implementation

- `pengrid_zip_collect_directory` checks the count before `fstatat`, relative
  path construction, or symlink-target allocation for the first candidate over
  the ceiling.
- `pengrid_zip_append_entry` repeats the check before content-size arithmetic,
  `realloc`, `strdup`, and ownership transfer.
- The overflow result remains the stable `PENGRID_ZIP_STATUS_OVERFLOW` ABI
  value and therefore maps to Swift `ProtectedZIPError.entryCountOverflow`.
- A private, header-free dlsym seam drives the production append primitive in
  memory for boundary evidence without generating 100,000 filesystem files.

## TDD evidence

The boundary test first ran RED because the dlsym seam was absent. After the
minimal guard and seam were added, 100,000 succeeded and 100,001 returned
overflow. The service test first failed to compile because its one-shot
overflow engine was absent; after adding that test helper it proved the real
compression-service cleanup path leaves neither public output nor staging
residue.

For mutation evidence, temporarily replacing the append guard with
`if (0 && ...)` made the boundary test fail (`100,001 → 0`, expected
`PENGRID_ZIP_STATUS_OVERFLOW → -2003`). The original guard was restored before
all green verification.

## Verification

- Focused writer/service filter: 44 tests in 2 suites passed.
- Broad `ProtectedZIP` filter: 104 tests in 5 suites passed.
- Full serial SwiftPM suite: 1,048 tests in 76 suites passed (50.052 seconds).
- `./script/build_and_run.sh --verify`: passed (arm64, non-launching,
  8.526 seconds).
- `script/tests/package_release_contract_tests.sh`: passed.

Known SwiftPM fixture-resource warnings remain unchanged and are unrelated to
this fix. No release or external publication action was performed.
