# Protected ZIP entry-count ceiling verification — 2026-08-06

This record covers the whole-feature final-review Important #3 fix in the
`safe-operation-center` worktree. It is automated evidence only; it does not
claim live provider, GUI, or third-party interoperability observations.

## Production boundary

Protected ZIP creation now has a hard, non-configurable ceiling of exactly
100,000 entries in `Sources/EncryptedZIPCore/pengrid_zip_writer.c`. Directory
enumeration rejects the 100,001st candidate before `fstatat`, path creation, or
symlink-target allocation. The ownership-transferring append primitive repeats
the guard before size arithmetic, capacity growth, or ownership transfer.
The existing stable `PENGRID_ZIP_STATUS_OVERFLOW` ABI value (`-2003`) is
returned and maps to Swift `ProtectedZIPError.entryCountOverflow`.

The test-only `pengrid_zip_test_append_entry_count` symbol is intentionally
absent from the public header and is reached only through `dlsym`. It drives
the actual append primitive entirely in memory, so the 100,000-entry boundary
does not require creating 100,000 filesystem files. Production behavior does
not arm or call this seam.

## TDD and mutation evidence

The boundary test was written before the production guard and first ran RED:

```text
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --disable-sandbox --no-parallel \
  --filter writerHardEntryLimitAllowsExactly100000AndRejects100001ThroughAppendPath
```

The run failed with `entry-count append test seam is not exported`. After the
minimal C guard and private probe were added, the same test passed: the
100,000th append returned `PENGRID_ZIP_STATUS_OK` and the 100,001st returned
`PENGRID_ZIP_STATUS_OVERFLOW`.

The service cleanup test was also added before its test-only overflow engine;
the first compile failed because `Task8EntryCountOverflowEngine` was absent.
The green test then drove the real compression service staging path and
asserted `.entryCountOverflow`, no public destination, and no
`.bloom-staging-*` residue.

Mutation evidence was captured and reverted before the final green runs. The
append guard was temporarily changed to `if (0 && ...)`; the boundary test
then failed with:

```text
Expectation failed: (appendEntryCount(100_001) → 0) ==
(PENGRID_ZIP_STATUS_OVERFLOW → -2003)
```

Restoring the guard returned the test to green.

## Verification matrix

All commands used serial SwiftPM execution on macOS arm64 with the Xcode
developer directory above.

| Status | Exact command | Result |
| --- | --- | --- |
| PASS | `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcrun swift test --disable-sandbox --no-parallel --filter 'ProtectedZIPEngineWriterTests\|ProtectedZIPOperationServiceTests'` | 44 tests in 2 suites passed. |
| PASS | `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcrun swift test --disable-sandbox --no-parallel --filter 'ProtectedZIP'` | 104 tests in 5 suites passed. |
| PASS | `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcrun swift test --disable-sandbox --no-parallel` | 1,056 tests in 77 suites passed; prior full run before the final lifecycle addition. |
| PASS | `./script/build_and_run.sh --verify` | Non-launching arm64 build, ad-hoc signature, and artifact verification exited 0 (8.526 seconds). |
| PASS | `/bin/bash script/tests/package_release_contract_tests.sh` | `package release contract tests: PASS`. |

The full and build runs emitted the repository's known SwiftPM warning about
11 committed ProtectedZIP fixture files being unhandled resources; no warning
originated in the entry-count fix. No release, tag, push, DMG publication,
Developer ID signing, or notarization action was performed.

## Final review — termination-safe Quit (2026-08-06)

The application lifecycle now registers the same `FileOperationController` and
`ArchivePasswordPromptCoordinator` instances used by the SwiftUI scene with an
AppKit termination coordinator. A normal Quit request enters a one-shot
preparation gate, cancels active work and any password prompt, and returns
`.terminateLater`. The coordinator replies only after the controller is idle,
private staging cleanup has completed, and no recovery-required result remains;
it replies `false` on the bounded timeout or recovery path and allows the queue
to resume. Re-entrant Quit requests do not create duplicate preparation tasks
or replies.

The focused lifecycle command passed all eight tests:

```text
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --disable-sandbox --no-parallel \
  --scratch-path /tmp/pengrid-termination-green \
  --filter ApplicationTerminationTests
```

Result: 8 tests in 1 suite passed. The load-bearing protected-extraction test
uses the real `FileOperationController`, routing service, protected operation
service, and live filesystem. Its test engine writes plaintext into the private
`.bloom-staging-*` destination and then blocks. Quit returned `.terminateLater`
with no reply while that plaintext was present; releasing the gate allowed
cancellation and deferred cleanup to finish, after which exactly one `true`
reply was observed and both staging and public-destination residue were absent.

Mutation evidence was captured and reverted. The coordinator's non-idle wait
branch was temporarily changed to reply `true` immediately, then the gated
test was run with:

```text
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --disable-sandbox --no-parallel \
  --scratch-path /tmp/pengrid-termination-mutation2 \
  --filter 'ApplicationTerminationTests/protectedExtractionQuitWaitsForPlaintextStagingCleanup'
```

The mutation failed as intended: the test observed an unexpected early
`[true]` reply and then found the controller still running with archive staging
and plaintext descendants remaining (four failed expectations at lines 243 and
251–253 of `ApplicationTerminationTests.swift`). Restoring the wait gate
returned the focused suite to green.

## Post-commit verification — 7755113 (2026-08-06)

The committed lifecycle change was verified from clean `HEAD` with the
following serial commands:

| Status | Exact command | Result |
| --- | --- | --- |
| PASS | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --disable-sandbox --no-parallel --scratch-path /tmp/pengrid-protectedzip-final --filter ProtectedZIP` | 104 tests in 5 suites passed (11.635 seconds). |
| PASS | `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --disable-sandbox --no-parallel --scratch-path /tmp/pengrid-full-final2` | 1,056 tests in 77 suites passed (50.495 seconds). |
| PASS | `./script/build_and_run.sh --verify` | Debug arm64 build, ad-hoc signing, and artifact verification passed (7.32 seconds); `codesign` reported valid on disk and satisfied its designated requirement. |
| PASS | `/bin/bash script/tests/package_release_contract_tests.sh` | `package release contract tests: PASS`. |

The SwiftPM runs emitted only the repository's existing warning about 11
committed ProtectedZIP fixtures being unhandled resources (plus unrelated
test-source warning diagnostics); no lifecycle warning or failure occurred.
