# Password-protected ZIP verification — 2026-08-06

This is the Task 11 verification record for the safe-operation-center worktree.
It records automated evidence only; it does not claim live provider, GUI, or
third-party interoperability observations.

## Tree and environment

- Date: 2026-08-06 (Asia/Seoul)
- Base commit: `33e5500fa988e800ab6474f68e7c25f8d10ad34e` (approved Task 10 head)
- Candidate: Task 11 working tree derived from that base; the final commit hash
  is intentionally omitted because the next task records final `HEAD`.
- Host: macOS arm64e; `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`
- Tests were serial (`--no-parallel`) and used temporary directories only.

## Automated evidence

All commands below exited 0.

| Status | Exact command | Result |
| --- | --- | --- |
| PASS — focused Task 11 | `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcrun swift test --disable-sandbox --no-parallel --filter 'ProtectedZIPEndToEndTests\|ArchiveOperationIntegrationTests\|CloudLocationScopedAccessTests'` | **45 tests in 3 suites**, 3.030 seconds. The incremental compile emitted only the existing no-effect `@preconcurrency` warnings in `FavoriteDropTests.swift` and `FileTableViewLifecycleTests.swift`; none originated in Task 11 files. |
| PASS — Task 7–10 regression | `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcrun swift test --disable-sandbox --no-parallel --filter 'ArchivePasswordPromptCoordinatorTests\|ArchivePasswordPresentationTests\|ProtectedZIPOperationServiceTests\|RoutingArchiveOperationServiceTests\|FileOperationControllerTests\|FileOperationCenterViewTests\|WorkspaceCommandTests\|WorkspaceCommandPolicyTests\|OperationStatusViewTests\|AccessibilityPresentationTests'` | **173 tests in 7 suites**, 0.473 seconds; no warning or error lines. |
| PASS — final full suite | `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcrun swift test --disable-sandbox --no-parallel` | **1031 tests in 76 suites**, 49.910 seconds; no warning or error lines. |

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
- Wrong password then correct password uses fresh request UUIDs, sets
  `previousAttemptFailed` to `[false, true]`, invalidates both retained secret
  buffers, and leaves no staging directory.
- Cancellation while waiting for a password and deterministic mid-entry
  cancellation both publish no destination and leave no staging directory.
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
  The test explicitly identifies the retained staging reservation as an
  intentional recovery artifact rather than an orphan.
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
