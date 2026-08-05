# Password-Protected ZIP Design

**Status:** Approved on 2026-08-06  
**Target branch:** `codex/safe-operation-center`  
**Initial scope:** Create WinZip AES-256 ZIP archives and extract password-protected ZIP archives

## Context

Pengrid currently creates and extracts ordinary ZIP archives with macOS
`/usr/bin/ditto`, and handles TAR-family formats with `/usr/bin/tar`. Archive
operations already materialize cloud files, stage private output, verify source
and destination identities, publish without replacing an existing item, clean
up after cancellation, and report preparation and archive phases through the
operation center.

The macOS command-line tools do not provide a suitable AES-256 creation path for
this feature. The system `zip` is Info-ZIP 3.0 and provides legacy ZIP
encryption; `ditto` can request a password while reading an encrypted PKZip but
does not provide an AES-256 creation interface. Passing a password to a bundled
command-line archiver would also risk exposing it through process arguments or
retaining it in process configuration.

Pengrid will therefore use an in-process ZIP engine only for protected ZIP
work. Ordinary ZIP and TAR-family behavior remains on the existing native-tool
path.

## Goals

- Add an explicit **Compress as Password-Protected ZIP…** action.
- Create ZIP archives whose file entries use WinZip AES-256 encryption.
- Detect encrypted ZIP archives during the normal extraction action and prompt
  only when a password is required.
- Read WinZip AES-128, AES-192, AES-256, and legacy ZipCrypto archives for
  compatibility. Pengrid never creates new ZipCrypto archives.
- Keep passwords out of command arguments, environment variables, logs,
  operation snapshots, history, retry recipes, pasteboard writes, and durable
  storage.
- Preserve Pengrid's existing identity checks, private staging, exclusive
  publication, cancellation cleanup, and recovery-review behavior.
- Provide determinate byte progress while the protected ZIP engine is encoding
  or decoding entry data.
- Keep the feature usable with VoiceOver and keyboard-only navigation.

## Non-goals

- Encrypting or hiding the ZIP central-directory filename list.
- Password-protected 7z, RAR, TAR, TAR.GZ, TAR.BZ2, or TAR.XZ.
- Changing or removing a password on an existing archive.
- Saving passwords in Keychain or caching them across jobs.
- Password hints, password recovery, archive repair, or split archives.
- Complete preservation of macOS resource forks, ACLs, Finder metadata, or
  arbitrary extended attributes in protected ZIP archives.
- Replacing the existing `ditto` and `tar` implementation for unprotected
  archives.

## Dependency and licensing

Vendor minizip-ng 4.2.2 at tag commit
`7b2387161c542fa9f427352dcdef76097d0d692b` into a local C target named
`EncryptedZIPCore`. Do not track a floating branch or download code while the
application runs or builds a release.

Build only the required ZIP reader/writer, Deflate, Traditional PKWARE read
support, WinZip AES, UTF-8 filename, ZIP64, file attribute, and symlink support.
Use the Apple crypto implementation on macOS and avoid an OpenSSL runtime
dependency. Disable unrelated BZip2, LZMA, PPMD, XZ, Zstandard, split-archive,
and example-command targets unless a source-level dependency requires a small
shared primitive.

Retain the upstream zlib license in the vendored source and add minizip-ng to
`THIRD_PARTY_NOTICES.md`, the detailed English and Korean documentation, and
release packaging checks. A dependency-update note must record the pinned tag,
commit, enabled features, and the upstream security review performed before an
upgrade.

## Architecture

### `EncryptedZIPCore`

The local C target wraps minizip-ng behind a narrow, Pengrid-owned C API. It
provides:

- archive inspection without a password;
- entry enumeration and metadata access;
- AES-256 writer setup;
- AES and ZipCrypto reader setup;
- pull-based entry reads and push-based entry writes;
- progress and cancellation callbacks;
- file-descriptor-backed streams; and
- explicit password-buffer clearing before reader or writer destruction.

No minizip-ng types cross the C target boundary. The wrapper returns stable
Pengrid error codes so Swift does not depend on upstream numeric values.

### Swift engine boundary

`ProtectedZIPEngine` is a `Sendable` protocol with an actor-backed live
implementation. Its responsibilities are inspection, compression, extraction,
progress delivery, cancellation, and mapping the C wrapper's stable error codes
to `ProtectedZIPError`.

The engine accepts an ephemeral `ArchiveSecret` value. `ArchiveSecret` owns a
mutable native buffer and clears it with `explicit_bzero` before release. It is
move-like at the API boundary: the password broker creates one value for one
engine attempt and no operation model retains it.

Swift and SwiftUI can create temporary immutable copies while accepting text,
so Pengrid cannot promise that every historical byte is physically erased.
The design minimizes that exposure by clearing field state immediately after
submission, converting once to a mutable native buffer, avoiding further
`String` conversion, and keeping the native buffer alive only for the current
engine attempt.

### Routing

Add protection metadata to archive planning, but never a password:

- ordinary compression and extraction continue through
  `ArchiveOperationService` and `LiveArchiveCommandRunner`;
- the explicit protected compression action selects `.aes256` protection and
  routes ZIP encoding through `ProtectedZIPEngine`;
- ZIP extraction first runs `ProtectedZIPInspection`; an unencrypted result
  continues through `ditto`, while any encrypted entry routes the entire
  archive through `ProtectedZIPEngine`; and
- unsupported encryption is rejected before any output is published.

`ArchiveRequest`, `PendingFileOperation`, `FileOperationJobSnapshot`, operation
history, and retry recipes contain only non-secret protection metadata.

### Password prompt coordination

`ArchivePasswordPromptCoordinator` bridges an active operation and one SwiftUI
sheet hosted by the workspace. It supports two prompt modes:

- creation: password plus confirmation; and
- extraction: one password plus an optional inline incorrect-password error.

The operation asks for a password only after cloud materialization and private
source staging are complete and immediately before encryption or decryption.
A queued job therefore contains no secret. While a prompt is visible, the job
state is `waitingForPassword`, cancellation remains available, and pause is
disabled. Cancelling or closing the prompt cancels the archive job.

If another workspace sheet is visible, the active archive job remains in
`waitingForPassword` until the workspace can present the password sheet. The
next queued file operation does not start while this job is waiting.

## Password rules and lifecycle

For creation:

- accept 8 through 256 UTF-8 bytes;
- require exact confirmation equality;
- recommend a 12-character-or-longer passphrase without assigning a misleading
  numeric strength score; and
- encode the password exactly as entered in UTF-8 without Unicode
  normalization.

AES-256 does not compensate for a short or predictable password. WinZip AES
uses a format-defined password derivation scheme that Pengrid cannot strengthen
without breaking interoperability, so the UI and documentation emphasize a
long, unique passphrase without claiming that the AES key size alone guarantees
password strength.

For extraction, accept any non-empty UTF-8 password up to 1,024 bytes. The
larger compatibility limit does not change the 256-byte creation limit.

Pengrid does not write a password to the pasteboard, but standard secure-field
paste remains available. It does not offer show-password, remember-password,
or password-hint controls in the first version.

After submission, the coordinator clears both secure-field bindings. Each
password attempt creates a new `ArchiveSecret`. Success, incorrect password,
failure, cancellation, and app termination destroy that secret. A retry from
operation history starts a new job and prompts again. Multiple archives never
share one submitted password automatically.

## Protected compression flow

1. Capture the selected items and destination identities with the existing
   archive planner.
2. Materialize cloud-backed sources and revalidate source identities.
3. Copy selected roots into the existing private aggregate staging directory,
   using the bounded maximum of four preparation workers.
4. Request and validate the creation password.
5. Reserve and open the staged ZIP output without replacing an existing item.
6. Enumerate the aggregate root without following symbolic links. Reject
   unsupported special filesystem objects.
7. Stream each directory, regular-file, and symbolic-link entry to the
   file-descriptor-backed AES-256 writer. All data-bearing entries are
   encrypted. Filenames and other central-directory metadata remain visible by
   ZIP-format design.
8. Report byte progress, honor cancellation callbacks, finalize the central
   directory, verify the opened output identity, and clear the password.
9. Revalidate the final destination parent, publish exclusively, fingerprint
   the result when possible, and clean all private staging.

The protected writer preserves file data, directory hierarchy, UTF-8 names,
modification times, POSIX modes, and symbolic links. It does not follow a
selected symbolic link or substitute the target's bytes.

## Protected extraction flow

1. Materialize and identity-check the selected ZIP.
2. Copy it into a private, identity-tracked input staging reservation.
3. Inspect the central directory. If no entry is encrypted, release protected
   routing and use the existing `ditto` path. If encryption is present, verify
   that every encrypted entry uses a supported AES variant or ZipCrypto.
4. Preflight all entries and the destination volume before asking for a
   password.
5. Request one extraction password and create a fresh output staging
   reservation for that attempt.
6. Stream decrypted entry data through the root-confined extraction writer.
7. On an incorrect-password verifier result or encrypted-data authentication
   failure, destroy the entire output reservation for that attempt, clear the
   secret, and return to the same prompt with a generic “password is incorrect
   or the encrypted data is damaged” error. The user may retry or cancel.
8. On success, verify output identity, publish exclusively, clear the secret,
   and remove input and output staging.

An archive containing both encrypted and unencrypted entries is supported, but
the whole archive uses the protected extraction path and one password attempt.

## Root-confined extraction and resource limits

Do not call minizip-ng's convenience extract-to-directory routine. The C
wrapper exposes entry metadata and decrypted bytes, while Pengrid creates the
filesystem objects itself relative to the already-open staging root.

Preflight rejects:

- absolute paths, empty path components, `.` or `..` components, NULs, and
  components that exceed the destination volume's limits;
- duplicate normalized paths and paths whose topology conflicts as file versus
  directory;
- more than 100,000 archive entries;
- block devices, character devices, FIFOs, sockets, and unknown special entry
  types;
- absolute symbolic-link targets, link targets that resolve lexically outside
  the extraction root, and any archive entry that descends through an archive
  symbolic-link entry; and
- a declared total uncompressed size that does not fit within the volume's
  important-usage capacity after retaining the larger of 512 MiB or ten percent
  of that capacity as a safety reserve.

The writer uses `openat`, `mkdirat`, exclusive creation, and `O_NOFOLLOW` for
every path component. It never changes the process-wide working directory and
never traverses a link created by the archive. Exact and destination-volume
canonical collisions are failures rather than overwrites.

Track actual bytes written per entry and overall. Abort if actual output exceeds
the central-directory declaration, the preflight byte budget, or the current
available-capacity budget. Do not impose a compression-ratio limit because
legitimate highly compressible files can have extreme ratios; entry-count,
declared-size, actual-byte, and disk-capacity budgets provide the required
resource bounds.

## Progress and cancellation

Protected ZIP preparation continues to report completed source count. During
encoding or extraction, `ProtectedZIPEngine` reports processed and expected
uncompressed bytes, throttled through the existing archive progress gate. A
zero-byte archive or an archive whose total cannot be trusted reports an
indeterminate encoding phase.

The engine checks cancellation between entries and from the C progress callback
during long entry reads or writes. Cancellation closes the reader or writer,
clears the password, removes all identity-tracked staging, records a cancelled
outcome, and does not publish partial output. If safe cleanup fails, retain the
existing recovery-required behavior and block the queue for review.

## Error behavior

Expose localized English and Korean messages for these categories:

- password confirmation mismatch or invalid creation length;
- incorrect password or failed AES authentication;
- unsupported ZIP encryption;
- corrupt or inconsistent ZIP metadata;
- unsafe archive entry;
- too many entries or insufficient disk capacity;
- source or destination identity change;
- cancellation;
- engine launch/setup failure; and
- cleanup failure requiring recovery review.

Incorrect-password errors stay inside the password sheet until the user retries
or cancels. Other errors terminate the job. Diagnostics and operation history
may contain the public archive basename and a stable error category, but must
not include the password, secret-derived values, the complete internal filename
list, or raw upstream error text that has not been audited for secret content.

## User interface and accessibility

Add **Compress as Password-Protected ZIP…** beside the existing compression
actions. Do not add protected variants for TAR-family menu items.

The creation sheet contains:

- a concise AES-256 label;
- secure password and confirmation fields;
- the eight-byte minimum and 12-character recommendation;
- a note that filenames remain visible; and
- Cancel and Compress actions.

The extraction sheet identifies only the selected archive basename, contains a
single secure field, and shows a generic inline incorrect-password message after
a failed attempt. Return submits when valid, Escape cancels, and focus starts in
the first secure field.

VoiceOver labels describe the purpose, validation state, and job state without
speaking or embedding password contents. Operation-center rows expose
`Waiting for password`, encoding/extracting progress, cancellation, terminal
state, and retry eligibility. Retrying never reuses a prior secret.

## Metadata compatibility

The first protected-ZIP release guarantees regular-file bytes, directory
structure, UTF-8 names, modification times, POSIX permission bits, ZIP64, and
safe symbolic-link round trips within Pengrid.

Unlike the ordinary `ditto` ZIP path, it does not guarantee complete resource
fork, ACL, Finder metadata, quarantine metadata, or arbitrary extended-attribute
round trips. Document this difference in both user guides and release notes.
Do not create an unencrypted intermediate ZIP merely to obtain AppleDouble
metadata because that would leave plaintext archive data on storage.

## Testing

### Automated unit and integration coverage

- C wrapper lifecycle, stable error mapping, file-descriptor streams,
  cancellation callbacks, and explicit buffer clearing hooks.
- AES-256 creation and extraction for regular, empty, nested, large, and ZIP64
  files.
- AES-128, AES-192, AES-256, and ZipCrypto extraction using small committed
  interoperability fixtures, including an AES archive created independently by
  7-Zip and a legacy archive created by Info-ZIP.
- Korean composed and decomposed names, emoji, spaces, leading dots, and long
  valid names.
- Exact password bytes, confirmation mismatch, creation limits, extraction
  compatibility limit, incorrect-password retry, and cancellation from the
  prompt.
- An archive with mixed encrypted and unencrypted entries.
- Absolute paths, traversal, duplicate and volume-canonical collisions,
  file/directory topology conflicts, link escape, entries below a link, special
  files, entry-count overflow, false declared sizes, capacity exhaustion, and
  truncated or authentication-corrupt data.
- Cancellation during source preparation, encryption, extraction, finalization,
  and publication, including cleanup-failure recovery.
- Queue snapshots, history, diagnostics, retry recipes, and accessibility labels
  tested with a sentinel password to prove that no observable model contains
  the sentinel.
- Ordinary ZIP and every TAR-family regression suite remains unchanged and
  passing.

Fixture provenance, generating tool version, command, expected password, and
SHA-256 are recorded in a test-fixture README. Fixture passwords are test-only
public data and must never be reused as examples in the product UI.

### Manual verification

- Create an AES-256 ZIP in Pengrid and extract it with current 7-Zip and WinZip
  implementations; extract independent AES and ZipCrypto fixtures in Pengrid.
- Confirm Finder/macOS-tool compatibility limitations are explained rather than
  silently falling back to ZipCrypto.
- Exercise Korean input, Return/Escape, sheet focus, incorrect-password retry,
  cancel, queue waiting, operation-center progress, and VoiceOver.
- Inspect the running process list and Pengrid logs while a sentinel password is
  in use; the sentinel must not appear.
- Inspect a packaged DMG for the pinned library, license notice, supported
  architectures, and absence of an unexpected OpenSSL dynamic dependency.
- Benchmark ordinary and protected ZIP operations on the same local and cloud
  fixtures, recording elapsed time, peak memory, and output size. There is no
  fixed four-second pass/fail threshold.

## Documentation and release impact

Update the English and Korean README, user guides, release guide, archive
verification checklist, and release notes. Explain:

- AES-256 creation and AES/ZipCrypto read compatibility;
- the filename-visibility limitation;
- password lifecycle and lack of recovery;
- Finder/macOS-tool compatibility caveats;
- protected-ZIP metadata limitations;
- resource-limit and unsafe-entry failures; and
- the unchanged status of 7z, RAR, protected TAR, Developer ID signing, and
  notarization.

The release artifact remains free and ad-hoc signed unless a later release task
changes the distribution policy.

## Acceptance criteria

The feature is ready for release when all of the following are true:

1. Pengrid creates only AES-256 protected ZIP archives and extracts supported
   AES and ZipCrypto fixtures successfully.
2. No secret is present in process arguments, environment, logs, snapshots,
   history, retry state, accessibility output, or persistent storage.
3. A queued job obtains its password only immediately before protected engine
   work, and history retry always prompts again.
4. Wrong-password attempts publish nothing and start each retry with fresh,
   identity-tracked output staging.
5. Path traversal, link escape, collision, special-file, size, entry-count, and
   disk-budget tests fail safely without public partial output.
6. Cancellation clears the active secret and either removes all staging or
   enters the existing recovery-review state if cleanup cannot be proven.
7. Protected progress, prompt focus, keyboard operation, and VoiceOver pass
   manual verification.
8. The complete Swift test suite, C wrapper tests, interoperability tests,
   packaging checks, and ordinary archive regressions pass.
9. English and Korean documentation accurately states security, compatibility,
   metadata, and distribution limitations.

## Design evidence

- minizip-ng 4.2.2 release and tag:
  <https://github.com/zlib-ng/minizip-ng/releases/tag/4.2.2>
- upstream feature and build-option documentation, including Traditional
  PKWARE, WinZip AES, macOS, ZIP64, UTF-8, attributes, and symlinks:
  <https://github.com/zlib-ng/minizip-ng#features>
- upstream writer API documenting AES-256 and password/progress callbacks:
  <https://github.com/zlib-ng/minizip-ng/blob/4.2.2/doc/mz_zip_rw.md>
- upstream zlib license:
  <https://github.com/zlib-ng/minizip-ng/blob/4.2.2/LICENSE>
- local macOS 26 tool probe on 2026-08-06: `/usr/bin/zip` reported Info-ZIP
  3.0 legacy encryption support, while `ditto -h` exposed `--password` for
  reading encrypted PKZip archives but no protected-archive creation option.
