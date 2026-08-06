# Password-protected ZIP verification — 2026-08-06

This is the Task 11 verification record for the safe-operation-center worktree.
It records automated evidence only; it does not claim live provider, GUI, or
third-party interoperability observations.

## Tree and environment

- Date: 2026-08-06 (Asia/Seoul)
- Base commit: `33e5500fa988e800ab6474f68e7c25f8d10ad34e` (approved Task 10 head)
- Initial verified Task 11 candidate tree (non-self-referential):
  `86aa3d7f0ca6b9e3debfc1bd4693582b7d861400`.
- Fix-round base: `e9c9416` (`test: verify protected zip workflows`).
- Fix-round 2 base: `d48906c` (frozen lifecycle coverage follow-up).
- Fix-round 3 base: `15cbcf1` (frozen one-shot observability follow-up).
- Candidate: fix-round working tree; the final commit hash is intentionally
  omitted from this record.
- Host: macOS arm64; test target reports `arm64e-apple-macos14.0`;
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`
- Tests were serial (`--no-parallel`) and used temporary directories only.

## Automated evidence

All commands below exited 0.

| Status | Exact command | Result |
| --- | --- | --- |
| PASS — native gate lifecycle + cancellation | `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcrun swift test --disable-sandbox --no-parallel --filter 'ProtectedZIPEndToEndTests/nativeProgressGateIsOneShotAndSafeWhenCleared\|ProtectedZIPEndToEndTests/cancellingDuringAuthenticatedEntryLeavesNoPublishedArchive'` | **2 tests in 1 suite**, 0.391 seconds; target `arm64e-apple-macos14.0`; no warning or error lines. |
| PASS — focused Task 11 | `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcrun swift test --disable-sandbox --no-parallel --filter 'ProtectedZIPEndToEndTests\|ArchiveOperationIntegrationTests\|CloudLocationScopedAccessTests'` | **46 tests in 3 suites**, 3.319 seconds; target `arm64e-apple-macos14.0`; no warning or error lines in this cached invocation. |
| PASS — Task 5 writer/native cancellation regression | `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcrun swift test --disable-sandbox --no-parallel --filter 'ProtectedZIPEngineWriterTests\|ProtectedZIPOperationServiceTests/progressCallbackCancellationIsObservedByEngineAndDoesNotPublish'` | **15 tests in 2 suites**, 1.221 seconds; target `arm64e-apple-macos14.0`; no warning or error lines. |
| PASS — Task 7–10 regression | `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcrun swift test --disable-sandbox --no-parallel --filter 'ArchivePasswordPromptCoordinatorTests\|ArchivePasswordPresentationTests\|ProtectedZIPOperationServiceTests\|RoutingArchiveOperationServiceTests\|FileOperationControllerTests\|FileOperationCenterViewTests\|WorkspaceCommandTests\|WorkspaceCommandPolicyTests\|OperationStatusViewTests\|AccessibilityPresentationTests'` | **173 tests in 7 suites**, 0.460 seconds; target `arm64e-apple-macos14.0`; no warning or error lines. |
| PASS — final full suite | `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcrun swift test --disable-sandbox --no-parallel` | **1032 tests in 76 suites**, 49.307 seconds; target `arm64e-apple-macos14.0`; no warning or error lines. |

SwiftPM planning is cache-sensitive: a cold focused plan may additionally
print the known warning that 11 ProtectedZIP fixture files are unhandled. The
final focused invocation above used the cached plan and printed no such line;
the warning does not change test results or indicate a Task 11 source warning.

The one-shot observability follow-up first ran the lifecycle assertion before
the getter symbols existed; that honest TDD RED recorded
`native writer progress checkpoint counters are not exported`. With the
test-only dlsym getters present, each 2 MiB armed cycle observed **31** positive
non-final 64 KiB candidates and exactly **1** gate entry, with counters reset to
zero on the next arm. The third unarmed operation left both counters unchanged.
Temporarily removing the native `consumed` guard produced 31 gate entries and
failed the `== 1` assertion, demonstrating that the proof catches a broken
one-shot branch while the release remains set.

The focused suite drives the real controller → routing service → protected
service → `LiveProtectedZIPEngine` → exclusive publication path. The support
projection exposes only public title, basename, state label, and progress
detail.

## Fixture SHA-256 inventory

The committed fixture bytes were copied into temporary roots before each
controller extraction test. The hashes below came from:

```bash
shasum -a 256 Tests/BloomFileManagerTests/Fixtures/ProtectedZIP/*.zip
```

| Fixture | SHA-256 | Policy/result |
| --- | --- | --- |
| `7zip-aes256.zip` | `136ca9275ad091af11e700886d0afb41d9be0c04804df22bdb39b098fed3f99c` | PASS — AES-256 extraction |
| `minizip-aes128.zip` | `b02a342fd9c6694155d7ee87c9e1eff12c2bdd69ac8dd23979db2085943efb75` | PASS — AES-128 extraction |
| `minizip-aes192.zip` | `6e501670d5e2259400b28f0f126ae257f17af125841fc08010e9112d5084c91e` | PASS — AES-192 extraction |
| `infozip-zipcrypto.zip` | `e9bcc8168d54002f0c8b0176db37b456e79864e6ebe3a89e259ad462c9a5ff0c` | PASS — legacy ZipCrypto extraction |
| `aes-password-1.zip` | `0d6dca4bc5923cdeb23c6a3120c304376879826c6f7c831bb40fe18983c8ff6e` | PASS — one-byte password |
| `aes-password-257.zip` | `d3c81a181b198de65bd64e7e58b7de4022c69572af8b57a53ef070979ce7930e` | PASS — 257-byte password |
| `aes-password-1024.zip` | `95f64f040e506e695e9e94074827bf2a793b1595dac1ea6e0576d17e9409eb87` | PASS — 1024-byte password |
| `minizip-aes256-symlink.zip` | `04179e98fd60abf9f91d10ed8efcd9a9a721b2ec1a6c305abb4bbc435064a3f7` | PASS — safe relative symlink target |
| `minizip-aes256-symlink-mismatch.zip` | `f17d693d44828b784a73c6319c80ad04ac77959c282b67cf7549147b7209d69d` | PASS — hostile target refusal (Task 6/8 evidence) |
| `minizip-aes256-symlink-nul.zip` | `058a5ee7ee4e595244fe3cd65acb6b49cb8211c34ceab8b0ea79a041d26f60ff` | PASS — NUL target refusal (Task 6/8 evidence) |

No external interoperability claim is inferred from the in-process mixed-entry
fixture. That fixture is generated in test memory with one plain stored entry
and one ZipCrypto stored entry; it never passes a password through a child
process, environment, stdout, or stderr. The committed AES/ZipCrypto fixtures
are the only independent compatibility evidence recorded here.

## Protected workflow outcomes

- Authenticated AES-256 creation and extraction round-trip bytes through the
  controller, router, protected service, live engine, staging, and exclusive
  publication path. Archive bytes, logger reflection, observable job text, and
  history contain no password sentinel.
- Wrong password then correct password uses fresh request UUIDs, distinct
  `ArchiveSecret` object identities, sets `previousAttemptFailed` to
  `[false, true]`, invalidates both retained secret buffers, and leaves no
  staging directory.
- Cancellation while waiting for a password and deterministic mid-entry
  cancellation at the native writer's first positive non-final checkpoint both
  publish no destination and leave no staging directory. The test-only C gate
  is disabled by default, one-shot, and safely reset between real operations;
  the old async progress-wrapper gate is not used. The lifecycle proof keeps
  each of two armed gates active through bounded real successful completion
  before clearing it, then verifies a third unarmed operation succeeds. Its
  mutex-protected counters record 31 candidates and one actual gate entry per
  armed cycle without adding work to the unarmed fast path.
- Cloud materialization emits its completion event before the protected prompt;
  this is a deterministic scoped-access/materializer seam, not a live Google
  Drive or OneDrive run.
- Replacing the selected source during materialization fails closed with
  `cloud-preparation:item-changed`, prompts zero times, and publishes no
  archive. Destination identity/fingerprint checks are covered by the nearest
  Task 5–10 tests as well.
- A pre-existing destination survives a protected compression collision byte for
  byte; no replacement is attempted.
- Injected source-preparation cleanup failure reaches the real controller as
  `.recoveryNeeded`, retains undo identity/fingerprint metadata, marks history
  failed/non-retryable, and blocks the queue until `continueAfterRecovery()`.
  The test records the exact prepared reservation URL, directory identity,
  retained-root fingerprint, copied-entry identity, and failed→failed cleanup
  order; staging inventory is exactly that one intentional recovery artifact
  with no output reservation orphan. A second real ordinary ZIP queued while
  blocked resumes after `continueAfterRecovery()`, cleans its own reservation,
  and round-trips output bytes through extraction.
- Korean public names and selected symbolic links round-trip without leaking
  password text; symlink extraction asserts the exact relative target.
- A single ZIP containing one plain entry and one ZipCrypto entry follows the
  protected extraction policy and recovers both payloads with one prompt.
- Ordinary ZIP and TAR controller round trips remain on the ordinary archive
  service and pass unchanged.

## Secrecy, staging, and diff checks

The following checks were run on the final Task 11 tree:

```bash
rg -n 'e2e-public-test-passphrase|wrong-retry-passphrase|retry-passphrase|mixed-entry-passphrase|korean-public-sentinel' Sources/BloomFileManager
rg -n 'Process\(|/usr/bin/zip|zip -P|DEBUG_MIXED_ROOT' Tests/BloomFileManagerTests/ProtectedZIPEndToEndTests.swift
git diff --check
```

The first two scans produced no output; sentinels exist only in the owned test
provider assertions. The mixed-entry helper is pure Swift test-fixture
generation and launches no process. `git diff --check` produced no output.
Every success, failure, retry, and cancellation test that expects cleanup calls
`archiveTestExpectNoStagingDirectories`; the recovery test instead scans and
labels the intentionally retained reservation.

## Manual checks not run

These checks remain **NOT RUN** and are not represented as automated passes:

- Live VoiceOver readout of password waiting, progress, errors, and recovery.
- Finder/Archive Utility opening and extracting the newly created archive.
- WinZip/Windows extraction or creation.
- Live Google Drive or OneDrive materialization with user credentials.
- DMG/Gatekeeper/signing or notarization behavior.
- Process-list inspection during password entry.
- Performance benchmarks or large-archive throughput measurements.

## Task 12 fix round 1 verification

Fix round 1 is based on the Task 12 commit `e517656f87885a38d9350e7067f00abb5b70c3b5`.
The notice provenance now distinguishes raw Store streams from system-zlib
Deflate, records the three upstream minizip-ng crypto sources excluded by
`Package.swift`, identifies the Pengrid-owned AES/PBKDF2/Apple replacements, and
identifies the compiled upstream `mz_strm_pkcrypt.c` ZipCrypto stream.

The package fixture now uses a local `cmp` wrapper that logs exact arguments and
executes `/usr/bin/cmp`. Its unsigned assertions prove the staged notice
comparison (`/dev/fd/20`) and first staged `otool -L` call occur before the
`PUBLICATION_CHECKPOINT before_publication` recorder; the public notice
comparison (`/dev/fd/21`) occurs after `after_app_install`. The OpenSSL fixture
seeds old app/DMG markers and proves they remain unchanged with no publication
checkpoint. The recorder is TESTING-only and remains behind the existing marked
temporary-fixture guard.

TDD evidence for the load-bearing checks includes these controlled mutations,
each reverted before the green run: disconnecting the staged notice `cmp`
caused `notice-otool` to fail; disconnecting the staged binary `otool` caused
the order assertion to fail with `staged otool ran after publication
checkpoint`; disconnecting the OpenSSL rejection caused `openssl-linkage` to
fail with `OpenSSL-linked executable was accepted`. The structural build test
also captured the pre-fix RED where fd9 closed after the verify path and was
still referenced by it.

Fix-round commands and results:

- `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcrun swift test --disable-sandbox --no-parallel --filter BuildScriptTests`: **6 tests passed**, Swift run 1.373 seconds.
- `/bin/bash script/tests/package_release_contract_tests.sh notice-otool`: PASS.
- `/bin/bash script/tests/package_release_contract_tests.sh openssl-linkage`: PASS.
- `/usr/bin/time -p /bin/bash script/tests/package_release_contract_tests.sh`: PASS, real 152.55 seconds (user 71.87, sys 13.58).
- `/usr/bin/time -p ./script/build_and_run.sh --verify`: PASS, real 9.05 seconds; no app launch.
- Artifact `otool -L`, no-OpenSSL scan, ad-hoc codesign verification, notice `cmp`, and bundle-structure inspection: PASS. The artifact contains the executable, icon, notice resource, Info.plist, and `_CodeSignature`.
- Final-tree Task 11 focused filter: **46 tests in 3 suites passed**, Swift run 3.272 seconds, timed real 16.58 seconds; the known 11-fixture warning was emitted.

The complete final Swift suite and final shell contract then passed on this
fix-round tree:

- Final full Swift suite: **PASS** — 1,033 tests in 76 suites; Swift run
  49.761 seconds, timed real 50.61 seconds (user 27.47, sys 20.17), exit 0.
- Final package contract: **PASS** — `package release contract tests: PASS`,
  timed real 152.55 seconds (user 71.87, sys 13.58), exit 0.
- The first final-suite launch stopped before test execution with
  `posix_spawn error: Resource temporarily unavailable` while writing the
  Swift version file (0 tests ran). The successful run above was a fresh
  command after that pre-test launcher failure, not a flaky test retry.

## Task 12 package, notice, and documentation verification

This append-only section records the package-contract and artifact checks for
the safe-operation-center Task 12 tree. The approved Task 11 parent is
`e79d11287b49c52043369d23512dfd58b7e0badc` (`test: expose native gate one-shot
counters`). The candidate identity policy is parent-based: the final docs
commit is verified as a child of that parent, and this record does not embed a
self-referential final commit hash. Re-run `git rev-parse HEAD^` and
`git show --stat HEAD` after the commit to verify that relationship.

### Package and contract evidence

The following commands passed before the initial Task 12 commit
`e517656f87885a38d9350e7067f00abb5b70c3b5`:

| Result | Exact command | Evidence |
| --- | --- | --- |
| PASS | `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcrun swift test --disable-sandbox --no-parallel --filter BuildScriptTests` | **6 tests**, 1.349 seconds in the Swift Testing run; known SwiftPM warning lists 11 unhandled committed fixture files. |
| PASS | `/bin/bash script/tests/package_release_contract_tests.sh` | `package release contract tests: PASS`; all existing publication/rollback cases plus notice-byte and OpenSSL-rejection cases passed (serial shell fixture run). |
| PASS | `./script/build_and_run.sh --verify` | Nonpublishing arm64 build and verification exited 0 in 9.174 seconds of command wall time; the app was not launched. |

The shell contract creates a fixture-only `otool` recorder. It records
`OTOOL -L <binary>` and returns a zlib-only dependency list; a second fixture
returns `libcrypto` and proves the release script fails before publication.
The notice fixture compares
`THIRD_PARTY_NOTICES.md` byte-for-byte with
`Pengrid.app/Contents/Resources/THIRD_PARTY_NOTICES.md`.

### Artifact inspection

The verified local artifact is:

`dist/Pengrid.app`

Its inspected structure contains `Contents/Info.plist`,
`Contents/MacOS/BloomFileManager`,
`Contents/Resources/Pengrid.icns`,
`Contents/Resources/THIRD_PARTY_NOTICES.md`, and `Contents/_CodeSignature`.

`/usr/bin/otool -L dist/Pengrid.app/Contents/MacOS/BloomFileManager` listed
CoreFoundation, Security, system zlib (`/usr/lib/libz.1.dylib`), AppKit,
Swift/runtime frameworks, and system libraries. No `libssl` or `libcrypto`
entry appeared; the explicit OpenSSL scan exited 0.

`/usr/bin/codesign --verify --deep --strict --verbose=2 dist/Pengrid.app`
reported `valid on disk` and `satisfies its Designated Requirement`.
`/usr/bin/cmp -s THIRD_PARTY_NOTICES.md
dist/Pengrid.app/Contents/Resources/THIRD_PARTY_NOTICES.md` exited 0.
The local build signs ad-hoc for verification only; Developer ID signing and
notarization were not performed.

### Task 11 regression and final-suite evidence

The focused regression passed **46 tests in 3 suites**:

```text
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --disable-sandbox --no-parallel \
  --filter 'ProtectedZIPEndToEndTests|ArchiveOperationIntegrationTests|CloudLocationScopedAccessTests'
```

Measured command wall time was 4.47 seconds (Swift run reported 3.271
seconds); the same known 11-file fixture warning was emitted.

The final complete Swift suite, final package contract, and static checks were
run on this final documentation tree:

- Final full Swift suite: **PASS** — `xcrun swift test --disable-sandbox
  --no-parallel` completed with **1,033 tests in 76 suites** passed after
  50.071 seconds (timed command: real 50.68, user 26.90, sys 19.66); the
  known SwiftPM warning lists 11 unhandled committed fixture files.
- Final package contract: **PASS** — `/usr/bin/time -p /bin/bash
  script/tests/package_release_contract_tests.sh` reported
  `package release contract tests: PASS` (real 103.14, user 71.35, sys
  11.04).
- Final shell/Markdown/link/sentinel checks: **PASS** — `git diff --check`,
  `bash -n` for all three owned shell scripts, local Markdown-link/path
  resolution, documentation-scope scan, no forbidden source or
  test sentinels, artifact `otool` OpenSSL scan, ad-hoc `codesign --verify`,
  and notice byte comparison all passed.

### Bilingual documentation checklist

English/Korean README, user guide, and release guide were updated side by side
for AES-256-only creation; AES-128/192/256 and ZipCrypto Store/Deflate reading;
visible ZIP names and metadata; nonpersistent passwords and retry prompts;
Finder/Archive Utility AES caveat; fixture-only third-party evidence;
non-guaranteed resource forks, ACLs, and xattrs; fail-closed unsafe/oversized
input and recovery review; unsupported 7z, RAR, protected TAR, Developer ID,
and notarization. Each guide labels the linked v1.3 preview DMG as predating
this source feature.

### Physical or external checks still NOT RUN

These checks remain **NOT RUN** and are not implied by the package fixture or
source evidence:

- Live Finder or Archive Utility AES-ZIP opening.
- Windows or WinZip interoperability.
- Live Google Drive or OneDrive materialization with user credentials.
- Live VoiceOver readout and keyboard/accessibility observations.
- DMG/Gatekeeper behavior, Developer ID signing, or notarization.
- Process-list inspection during password entry.
- Performance benchmarks or large-archive throughput measurements.
