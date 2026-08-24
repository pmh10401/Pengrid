# Transfer Content Verification Design

**Date:** 2026-08-24

**Status:** Approved for implementation
**Target branch:** `codex/transfer-content-verification`

## Context

Pengrid already performs identity and fingerprint checks around copy, duplicate,
cross-volume move, and reviewed one-way folder synchronization. Those checks
prove which filesystem entries an operation owns and whether their observable
metadata changed. They do not prove that every byte copied into a new payload
matches the source.

The previous productivity design deliberately deferred transfer verification
because it requires its own settings, staging integration, progress, failure,
retry, history, and recovery rules. This design adds that safety subsystem
without replacing Pengrid's existing transfer engine.

The interaction idea is informed by public projects, without copying their
code:

- [Nimble Commander](https://github.com/mikekazakov/nimble-commander/blob/main/Docs/Help.md)
  exposes optional verification for copy and cross-filesystem move.
- [rclone](https://github.com/rclone/rclone/blob/master/docs/content/commands/rclone_checksum.md)
  distinguishes matches, differences, missing entries, and read errors while
  bounding concurrent checks.

Pengrid keeps its own identity-bound staging, conservative cleanup, File
Provider coordination, operation queue, privacy, and accessibility model.

## Goals

- Add a persisted **Verify transferred file contents before publishing**
  setting that is off by default.
- Snapshot the setting when a job is enqueued so queued work and Retry retain
  the original semantics.
- Verify regular-file data forks with SHA-256 before a private staged copy is
  published.
- Verify the complete relative-path structure of recursively transferred
  directories and packages.
- Verify symbolic-link payloads without following their targets.
- Cover copy, duplicate, cross-volume move, and copy/replace actions inside
  reviewed one-way folder synchronization.
- Treat a same-volume move as not applicable because it renames an existing
  entry without copying bytes.
- Limit verification to two concurrently active file pairs per operation.
- Publish byte-weighted progress, safe cancellation points, bounded history
  summaries, and privacy-preserving accessibility text.
- Leave the original source and any pre-existing destination unchanged when
  verification fails before publication.

## Non-Goals

- Verifying or preserving resource forks, extended attributes, ACLs, ownership,
  flags, creation dates, or every metadata field
- Preserving or verifying hard-link relationships or sparse-file allocation
- Verifying archive creation or extraction output
- Verifying same-volume rename or move operations
- Persisting file paths, per-file hashes, or a checksum audit report
- Background verification, scheduled verification, or a new content index
- Direct Google Drive or OneDrive OAuth/API integration
- Replacing `FileManager`-backed copy behavior with a custom copy engine
- Claiming complete validation for File Provider behavior that was not tested
  manually
- Eliminating the inherently bounded interval between the last staged-content
  validation and the namespace publication primitive; the implementation must
  narrow and disclose this interval rather than claim atomic content locking
- Adding byte-copy behavior to Undo or Redo; current reversal recipes remove or
  move identified entries and do not create a new payload

## Approved Product Decisions

| Decision | Approved behavior |
| --- | --- |
| Default policy | Optional global setting, off by default |
| Verification point | After private staging and before publication |
| Operation scope | Copy, duplicate, cross-volume move, reviewed folder sync |
| Tree scope | Recursive directories and packages |
| Byte scope | Regular-file data fork; structure and symlink payload otherwise |
| Concurrency | At most two file pairs per operation |
| History | Status, verified file count, and logical byte count only |
| Failure | Clean owned staging; preserve source and existing destination |
| Retry | Reuse the policy captured by the original queued job |
| Manifest budget | 250,000 entries and depth 256 per transferred root |
| Transient failure | Surface once; no hidden automatic re-read or retry |
| Mismatch payload | Do not publish or expose private staging |

## User Experience

### Settings

The Settings scene becomes a tabbed root:

1. **File Operations**
   - Toggle: **Verify transferred file contents before publishing**
   - Default: off
   - Help text explains that verification increases elapsed time and read I/O,
     that File Provider content may need to be made available again, and that
     percentage is byte-weighted while the adjacent count is file-weighted.
2. **Cloud Locations**
   - Hosts the existing `CloudLocationsSettingsView` without changing its
     location-management semantics.

The preference is stored in `UserDefaults` through an injectable persistence
type. Missing or malformed storage restores the safe product default, off.

### Operation Center

When verification is enabled, active transfer jobs expose these user-facing
phases:

1. Preparing files
2. Copying to private staging
3. Preparing verification
4. Verifying contents
5. Publishing verified result

Hashing progress is based on logical bytes for which both sides of a file pair
have been read. A tree containing only empty regular files falls back to
verified-file counts so progress can still reach completion.

Successful history uses bounded summaries such as:

- **Verified 42 files · 1.8 GB**
- **No byte transfer** for a same-volume move
- no extra verification text when the captured policy was disabled

The Operation Center never displays or stores the SHA-256 digest. Existing
basename sanitization remains in force; an absolute parent path is not added to
status or accessibility text.

## Architecture

### Preference and policy snapshot

`TransferVerificationPreference` owns persisted user intent.
`TransferVerificationPolicy` is an immutable, `Sendable` job value:

```swift
enum TransferVerificationPolicy: Sendable, Equatable {
    case disabled
    case sha256(maxConcurrentPairs: Int)
}
```

The only user-selectable enabled policy is currently
`.sha256(maxConcurrentPairs: 2)`. The pending-operation model captures only
this policy value at enqueue time. It does not enumerate or fingerprint a
source while the job is waiting. Retry reconstructs the pending operation with
the captured value rather than consulting current Settings. Internal/test
construction clamps every enabled pair limit to `1...2`; zero or negative
values therefore remain enabled with one worker instead of silently disabling
verification or deadlocking a zero-worker session.

### Manifest model

A `TransferVerificationManifest` is rooted at a captured URL,
`FileIdentity`, open no-follow root authority, and the destination's captured
`FilenameComparisonPolicy`. Its entries use validated relative components,
never an untrusted concatenated path. Each entry records only what is needed
for content verification:

- relative path components;
- item kind: directory, regular file, or symbolic link;
- entry identity;
- regular-file logical byte size and stability fingerprint; or
- the raw symbolic-link payload returned without following the link.

Directory entries, including package directories, are recursively enumerated.
Special items that are neither directories, regular files, nor symbolic links
make verification unavailable and fail the enabled operation before
publication. Path traversal, a root replacement, a type transition, and
duplicate relative paths fail closed.

The manifest builder is descriptor-anchored. Every root retains its open parent
descriptor and raw basename. A directory root additionally remains open for
the lifetime of verification. At capture, recapture, and receipt revalidation,
the no-follow entry observed with `fstatat` in the parent must still match the
open root descriptor; retaining only the old directory descriptor is
insufficient because its namespace entry could have been replaced. Children
are enumerated and opened relative to an already verified parent descriptor with `openat` and
`fstatat` using `AT_SYMLINK_NOFOLLOW`; symbolic-link payloads are obtained with
`readlinkat`. Raw filesystem-name bytes are retained for equivalence keys,
while only sanitized Strings cross into presentation. Every opened directory
is checked against the no-follow identity observed in its parent. A regular
file or symbolic-link root retains equivalent parent-descriptor authority.
Path-based `lstat`, `contentsOfDirectory`, or `readlink` alone is not
sufficient for this subsystem.

The root parent bytes and raw basename are split from one lossless filesystem
representation of the input URL; Foundation path-component reconstruction is
not used for descriptor authority. Unsafe or non-lossless root names fail
closed. A manifest exposes an internal idempotent `close()` so the operation
can deterministically release the retained parent/root descriptors; deinit is
only a fallback.

Each regular-file entry exposes an internal async reader scope rather than a
path. The scope descriptor-walks from retained authority, validates every
component, creates an `F_DUPFD_CLOEXEC` reader duplicate, keeps that duplicate
alive across the Task 3 async hash call, and closes it afterward. It also
exposes the exact device/inode/mode/size/mtime/ctime fields from which Task 3
constructs `RawFileFingerprint`. The manifest layer uses a neutral typed error
for change, shape, unsupported item/name, read, scope, and cancellation;
the session maps a neutral change to source or staged-output failure based on
which side it was processing.

One root may contain at most 250,000 descendant entries; the root itself is not
counted. The root is depth zero, and the deepest descendant may be at depth
256. Exceeding either internal safety budget fails verification before
publication with a bounded `scope too large` error. Pengrid never falls back
to an unverified transfer while the captured policy is enabled. The user may
turn the setting off and start a separate new job after seeing the limitation.
Packages use exactly the same depth calculation as ordinary directories; a
package root is depth zero and every child component increases depth by one.

Descriptor traversal retains raw name bytes for opening the same entry again.
Cross-root comparison keys are derived only after a lossless UTF-8 conversion
and the existing destination `FilenameComparisonPolicy` normalization. A name
that cannot be converted losslessly fails closed as an unsupported name; it is
never repaired with replacement characters. Canonically equivalent names are
compared according to the captured policy, and any two source names that map
to one destination key are rejected before staging begins.

The service uses two distinct comparisons:

- **same-root stability** compares a later manifest with the earlier manifest
  of that same root, including root and entry identities and stability
  fingerprints; and
- **cross-root content shape** compares source with staging using relative-path
  keys derived from the destination's captured `FilenameComparisonPolicy`,
  item kinds, regular-file sizes, and symbolic-link payloads, but deliberately
  does not require newly copied entries to share source identities or
  metadata. Two source entries that collapse to one destination comparison key
  fail before copy instead of being treated as one item.

Metadata fields outside the approved byte scope do not participate in
cross-root equivalence. Keeping the comparisons distinct prevents a newly
allocated staged copy from being rejected merely because its inode differs
from the source while still detecting a replacement within either root.

### Secure paired hashing

The no-follow descriptor opening, fingerprint validation, chunked SHA-256, and
post-read path validation currently used by `LiveChecksumService` are moved
behind a reusable internal raw file-hashing boundary. Get Info, comparison,
Storage Inspector, and transfer verification continue to share the same
safety semantics. The existing high-level checksum service retains
materialization and scoped-access coordination; transfer verification calls
the raw boundary only while its owning operation's access leases remain alive.

`TransferVerificationService` receives a captured source manifest and a
captured staged-root identity. It:

1. requires the current source manifest to remain stable against the
   pre-copy capture, then captures the staged manifest and compares cross-root
   content shape;
2. schedules matching regular-file pairs with one operation-scoped permit pool
   limited to two pairs;
3. opens both regular-file entries with `O_RDONLY | O_NOFOLLOW | O_NONBLOCK |
   O_CLOEXEC`, immediately rejects a type/fingerprint change with `fstat`, and
   uses `O_DIRECTORY` for directory descriptors so a file-to-FIFO race cannot
   block verification;
4. alternates bounded chunk reads, updating independent SHA-256 states;
5. advances logical-byte progress only after both sides have supplied the
   corresponding data;
6. compares the final digests;
7. validates both descriptors and paths again; and
8. rebuilds both manifests after all hashes finish, requiring each root to
   remain stable against its own prior capture and cross-root content shape to
   remain equivalent; and
9. returns an internal, operation-lifetime verification receipt containing the
   source and staged root authorities plus their final per-entry stability
   snapshots, but no content digest.

The receipt never enters a result, logger, snapshot, or history store and is
discarded when the operation ends. The caller descriptor-rebuilds and validates
both receipt roots again immediately adjacent to `moveExclusively` or
`replace`. This narrows the final time-of-check to time-of-use interval.
Because another process can modify an inode in place and macOS does not provide
an atomic “content hash then rename” primitive, Pengrid does not claim that the
interval is eliminated. A receipt mismatch fails and cleans owned staging.

At the maximum manifest budget, retained stability data can occupy tens of
megabytes. The receipt therefore reuses the final source and staged manifest
backing storage instead of cloning a third per-entry array, retains at most one
final stability snapshot per side, uses overflow-checked size accounting, and
releases all earlier manifest generations before publication. An allocation
or accounting failure fails closed as verification unavailable.

The only aggregate value retained outside the operation-internal verification
exchange is:

```swift
struct TransferVerificationSummary: Sendable, Equatable {
    let verifiedFileCount: Int
    let verifiedLogicalByteCount: Int64
    let noByteTransferItemCount: Int
}
```

The ephemeral receipt may retain validated relative components needed for its
last stability comparison. Digests and complete path lists never cross into a
`FileOperationResult`, job snapshot, logger event, history record, or
presentation model.

### Progress

`TransferVerificationProgress` has explicit phases for manifest preparation,
hashing, and final validation, plus:

- completed and total regular-file counts;
- completed and total logical bytes;
- one sanitized current basename; and
- a monotonic fraction suitable for the Operation Center.

`FileOperationStage` gains a verification case rather than pretending byte
progress is ordinary item progress. `FileOperationJobProgress` gains an
explicit unit, `.items` or `.fraction`; verification uses a normalized
fraction and a separate verified-file count. Its accessibility description is
`Verifying contents, 42 percent, 8 of 20 files, <safe basename>`, never raw
byte counters. Existing operation progress defaults to `.items`.

Progress is monotonic within each named phase. Moving from Copying to Verifying
changes the phase label and intentionally resets its local progress to zero;
Pengrid does not synthesize a misleading overall percentage because the
existing copy primitive does not report bytes. Publication uses the existing
throttling style, always publishing phase boundaries and completion.

### Result and history

`FileOperationResult` gains an optional bounded verification report. A
present report aggregates verified-file count, verified logical bytes,
no-byte-transfer item count, and failed-verification item count. Absence means
the policy was disabled. Mixed-result batches may therefore describe successful
verified items without claiming the whole job succeeded.

`noByteTransferItemCount` counts only top-level same-volume move requests for
which the enabled policy was captured but no payload copy occurred. It does not
count directories, symbolic links, empty regular files, skipped conflicts, or
failed items. A `nil` report means disabled; a present all-zero report means the
policy was enabled but no request completed an eligible verification or
same-volume no-copy move. Those two states are intentionally not equal.

`FileOperationResult.merging` adds reports field-by-field and its equality
includes the report. Merging two absent reports stays absent; merging an absent
and present report preserves the present report; and merging two present
reports sums all fields with checked, saturating presentation counters. Existing
Undo metadata merge precedence is unchanged.
`FileOperationJobSnapshot` stores only the bounded terminal report needed for
active/history presentation. A typed logger event accepts only enabled state,
aggregate counts, logical-byte count, and a bounded failure-category enum. Its
API has no path, basename, digest, underlying-error, or free-form-string field.

## Operation Data Flows

### Copy and replace

1. Immediately before reserving staging for each item, capture its source
   manifest using the already validated request identity and destination
   filename-comparison policy. Other batch items are not enumerated early.
2. Reserve private staging beside the planned destination.
3. Copy into staging using the existing filesystem primitive.
4. Capture the staged identity.
5. Verify source against staging and receive a source-and-staging verification
   receipt.
6. Revalidate both sides of the receipt immediately adjacent to the existing
   commit/replace path, then publish.
7. Capture destination identity and fingerprint for conservative Undo.

If verification fails, only the identity-owned staging payload and reservation
are removed. A pre-existing destination chosen for replacement is untouched.
Conflict resolution and the existing capacity check precede this sequence; a
skip, cancel, or capacity failure does not build a manifest or begin
verification.

The current `prepareStagedCopy` helper combines reservation ownership and copy.
Implementation splits it into a pre-reservation manifest step followed by a
reservation/copy/cleanup owner so the required lazy capture point is explicit
without introducing a callback into the safety-critical helper.

### Duplicate

Duplicate uses its existing exclusive Keep Both publication loop. Each private
candidate is verified before `moveExclusively`. A racing name collision still
cleans the verified private candidate and retries with another name; it does
not reuse verification evidence for a different payload.

### Move

- Same volume, no replacement: use the existing identity-bound rename and
  record verification as not applicable.
- Cross-volume or replacement: copy to staging, verify, publish, then remove
  the still-identified source. A verification failure occurs before source
  removal.

### Reviewed folder synchronization

Synchronization captures the policy when its exclusive job is enqueued. Copy
and replace actions are staged exactly as today. Each source manifest is
captured lazily immediately before its action is staged. After staging metadata
checks, the transaction verifies all staged action roots using one shared
concurrency limit. It performs no destination quarantine or publication until
every required verification succeeds.

Live hashing is reported exclusively through
`TransferVerificationProgress`. The synchronization
`verifyingStaging` completed/total counter advances once per action after
that action's content verification completes; it is not overloaded with byte
counts.

Verification failure enters the existing detached rollback path. Completed
synchronization remains non-retryable and non-Undoable.

Each synchronization receipt is revalidated on both sides immediately before
its corresponding publication primitive. If a later action fails
revalidation, the transaction enters its existing rollback path for actions
already published in this transaction. The residual interval described in the
non-goals still applies; the UI and documentation do not call this an atomic
filesystem snapshot. A staged action replaces and releases its original source
manifest when it installs the final receipt; it never keeps both generations
through quarantine or publication.

### Disabled policy

When the captured policy is disabled:

- no manifest is built;
- no file content is read for verification;
- existing transfer ordering and progress remain unchanged; and
- no verification summary is added to history.

This is the compatibility path and must retain existing behavior and
performance characteristics.

## Cancellation, Failure, and Recovery

Cancellation is checked:

- before and after each manifest enumeration step;
- before acquiring a pair permit;
- between paired chunk reads;
- before final manifest validation; and
- before publication.

The verifier distinguishes bounded failure categories:

- source changed;
- staged output changed;
- structure mismatch;
- content mismatch;
- unsupported item;
- unsupported or unsafe filename;
- identity unavailable;
- read unavailable or failed;
- scope too large; and
- cancelled.

These categories are stable enum cases mapped to localized presentation; logger
metadata never accepts a free-form category string.

One policy-aware terminal-result normalization path covers queued cancellation,
cancelled-before-start, early preparation failure, and normal completion. The
same normalized value feeds `lastResult`, history, Retry metadata, Undo
projection, and `onCompletion`; current Settings are never reread during that
normalization.

User-facing text states the category and a safe basename where useful. It does
not include a digest or absolute path.

For ordinary transfers:

- successful staging cleanup produces a failed or cancelled, retry-eligible
  job;
- cleanup failure produces **Recovery Needed** and blocks the queue; and
- the source and old destination are never removed merely because verification
  failed.

For synchronization, the existing transaction rollback owns all staged,
quarantined, and published state. Verification occurs before quarantine, so a
verification failure normally needs to clean only private staging. Any cleanup
failure remains a recovery-blocking result.

## Cloud and Filesystem Boundaries

The enabled setting authorizes the additional content reads required for
verification. The existing `CloudLocationScopedAccessCoordinator` and
materialization service remain the only File Provider access boundary.

The ordinary transfer controller prepares source content with the existing
`.transfer` purpose before entering `FileOperationService`. The service's
operation-scoped access leases remain alive across source capture, copy,
verification, and publication. The verifier neither starts a second
security-scoped session nor materializes each file independently. Folder
synchronization retains its current immediate-availability rule and does not
download provider content for verification. Staged-side reads are local and
never invoke materialization.

The source may need to remain or become locally available for the verification
read even after the copy primitive finishes. The private staged output is
expected to be locally readable. Provider refusal, eviction, offline state, or
an identity change fails the operation before publication.

Verification does not claim that a provider later uploaded identical remote
bytes. It proves only that the locally exposed staged payload matched the
locally exposed source payload at the verified identities and time.

## Accessibility and Privacy

- The Settings toggle has a stable identifier, label, value, and help text.
- Phase changes are announced; intermediate progress is throttled.
- VoiceOver receives phase, percentage, count, and a sanitized basename.
- Verification accessibility labels use percentages and file counts; raw byte
  counters never occupy item-count fields.
- Absolute paths, relative tree lists, and SHA-256 values are not announced.
- Reduce Motion adds no new animation.
- History summaries use the same bounded text for visual and accessibility
  presentation.

## Verification Plan

Implementation begins with failing Swift Testing cases.

### Preference and policy

- default off;
- enabled persistence round trip;
- malformed/missing storage restores off;
- queued jobs and Retry retain their captured policy;
- changing Settings does not mutate active or queued work.
- Retry cannot disable the captured policy; the user must start a new transfer
  after changing Settings.

### Manifest behavior

- single file, empty file, nested directory, and package;
- exact relative-path set and type matching;
- missing, extra, duplicate, and traversal entries;
- size mismatch;
- symbolic-link payload equality without following targets;
- special-item rejection;
- root, child identity, type, and fingerprint replacement;
- a directory-root namespace replacement while its previous descriptor remains
  open;
- a regular-file-to-FIFO race between no-follow inspection and open fails
  promptly without blocking;
- source additions or removals during verification.
- descriptor-anchored traversal and `readlinkat` behavior;
- depth 257 and entry 250,001 fail closed without staging publication;
- a package root applies the same root-zero depth accounting;
- case-sensitive and case-insensitive canonical destination policies;
- canonically equivalent spellings collide according to the captured policy;
- a non-lossless UTF-8 name fails closed without lossy display conversion;
- comparison-key collision fails before copy.

### Paired hashing and progress

- equal and unequal data;
- short read, read error, and cancellation;
- before/after identity and fingerprint validation;
- empty-file and zero-byte-tree completion;
- monotonic byte-weighted progress;
- no more than two active pairs;
- permits released after failure and cancellation;
- no digest retained in summary or presentation.
- source- or staged-root mutation after hashing is rejected by receipt
  revalidation, including a nested regular file changed in place;
- the documented residual in-place mutation interval is not described as
  atomic protection.

### File operations

- disabled copy/duplicate/move behavior remains unchanged;
- enabled single-file and recursive copy verify before publication;
- replacement leaves the old destination untouched on mismatch;
- duplicate verifies every new candidate and handles a publication race;
- same-volume move records not applicable and performs no hash;
- cross-volume move retains source on mismatch and removes it only after
  verified publication;
- staged cleanup failure becomes Recovery Needed;
- ordinary Retry preserves the original policy.
- `.skip` conflict resolution creates no manifest, staging, verification, or
  report count for that item;
- capacity failure occurs before manifest capture and verification;
- a transient provider/read failure surfaces once and starts no automatic
  re-verification;
- content mismatch exposes no Keep Both or private-staging affordance.
- a single symbolic-link root completes an end-to-end verified transfer without
  following its target;
- an instrumented publication adapter proves that final receipt validation is
  the immediately preceding safety step before the publication call; the test
  and product copy do not claim the residual syscall interval is eliminated.

### Folder synchronization

- all staged copy/replace actions verify before quarantine;
- one operation-scoped concurrency bound covers all actions;
- mismatch prevents every publication;
- cancellation cleans staging;
- cleanup failure blocks the queue;
- receipt revalidation failure for action N rolls back already published
  actions 1 through N−1;
- completed synchronization remains non-retryable and non-Undoable.

### UI, accessibility, and privacy

- tabbed Settings root and toggle copy;
- verification phase and byte progress presentation;
- verified/not-applicable history summaries;
- stable accessibility identifiers and phase labels;
- verification labels contain percentage/file counts and no raw byte totals;
- no full paths or hash strings in job snapshots, logger metadata, or
  accessibility values.
- report equality and merge aggregation preserve verified, no-transfer, and
  failed counts.
- mixed-result history shows verified aggregates and the failed job state
  without implying that every item succeeded;
- byte-weighted percentage and file-weighted count remain correctly labeled
  even when one large file dominates progress.

### End-to-end and release checks

- full `BloomFileManagerTests` suite with parallel test execution disabled;
- ARM64 release build;
- app bundle, icon, ad-hoc signature, and DMG checksum verification;
- temporary APFS disk-image exercise for cross-volume move, recursive content,
  cancellation, and injected mismatch;
- APFS harness contract tests for plist parsing, device/image/mount identity,
  mountpoint substitution, partial attach, signal termination, and cleanup;
- manual File Provider and VoiceOver rows marked `NOT RUN` unless actually
  completed.
- operation leases remain active through hashing and a revoked/failed access
  fixture fails before publication.

There is no fixed four- or five-second target. Acceptance is based on bounded
parallelism, accurate progress, cancellation responsiveness, and safe failure.

## Documentation

Update:

- `README.md` and `README.ko.md`;
- `docs/user-guide.md` and `docs/user-guide.ko.md`;
- `docs/current-limitations.md` and
  `docs/current-limitations.ko.md`;
- release notes for the next source/release candidate; and
- a bilingual transfer-verification checklist under `docs/verification/`.

Documentation must distinguish the current source tree from the last published
Developer Preview DMG and must retain the metadata, File Provider, signing, and
notarization limitations.

## Review Resolutions

- Current Undo and Redo recipes do not create a new byte copy. They remain
  governed by identity/fingerprint checks and do not receive a misleading
  verification status. Any future reversal recipe that copies bytes must carry
  and honor a verification policy before it can ship.
- Transient cloud or read failures are surfaced once. Pengrid performs no
  hidden automatic re-read; the user controls Retry.
- Exceeding the manifest budget fails closed. There is no metadata-only
  fallback while verification is enabled.
- Retry keeps the original policy even after repeated mismatch. Changing the
  setting affects only a newly created job.
- A mismatch produces a plain failed/cancelled result with source and old
  destination preserved. Private staging is never offered through Keep Both or
  a manual recovery UI.

## Independent Review Record

- OpenRouter Ox Alpha Ultra performed a full read-only review against the
  current transfer, checksum, filesystem, queue, progress, and synchronization
  implementations on 2026-08-24.
- Final verdict: **SHIP**. It reported no critical finding and no unresolved
  product decision.
- Its implementation-scope, receipt-memory, result-equality, synchronization
  rollback, filename, accessibility, and test-coverage notes are incorporated
  in this document.

## Acceptance Criteria

The feature is complete only when:

1. the preference is off by default and captured per queued operation;
2. every enabled eligible transfer verifies its private staged regular-file
   content and recursive structure before publication;
3. same-volume moves are truthfully marked not applicable;
4. mismatch or cancellation preserves the source and old destination;
5. cleanup uncertainty becomes Recovery Needed rather than guessed deletion;
6. at most two file pairs run concurrently;
7. progress is phase-locally monotonic, unit-aware, and history stores no paths
   or digests;
8. ordinary Retry and synchronization restrictions remain truthful;
9. focused, full, release, package, and APFS-volume checks pass; and
10. independent review returns ship after any required fixes are reverified.
