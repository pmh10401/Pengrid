# Transfer content verification

[한국어](transfer-content-verification.ko.md) · **English**

**Source status:** implemented in the current source tree. The last published
Developer Preview 7 DMG does **not** contain this feature. It becomes a shipped
feature only after a new candidate is built from the merged source, verified,
and published.

## Behavior contract

### Opt-in policy and eligible operations

The **File Operations** Settings tab contains **Verify transferred file contents
before publishing**. It is off by default. A job captures the setting when it is
enqueued, so a waiting job and its Retry keep the original policy even if the
user changes Settings later. The only enabled policy is
`.sha256(maxConcurrentPairs: 2)`; one operation never hashes more than two file
pairs concurrently.

Enabled verification applies to copy, Duplicate, cross-volume move, and the
copy/replace actions of reviewed one-way folder synchronization. A same-volume
move is an existing-entry rename, not a byte transfer. It therefore reports a
bounded **No byte transfer** result and does not hash the item.

### Data and tree scope

Pengrid captures the source before copying, copies into an identity-bound private
staging directory, verifies staging, revalidates the verification receipt, and
only then publishes the staged entry. Directory and package roots are traversed
recursively. Relative structure and item kinds must match. Regular-file data
forks are compared with SHA-256; symbolic-link payloads are compared without
following their targets.

The manifest budget is 250,000 descendants per transferred root and a maximum
descendant depth of 256. Exceeding either limit fails closed while verification
is enabled. There is no fallback to an unverified publication.

The following are deliberately outside the verified byte scope: resource forks,
extended attributes, ACLs, ownership, flags, creation dates, hard-link
relationships, sparse allocation, and archive creation or extraction output.
These exclusions are not presented as verified metadata.

### Progress, failure, and privacy

The percentage is byte-weighted across completed reads from both members of a
file pair. The adjacent file count is file-weighted, so the two indicators can
advance at different rates. Trees containing only zero-byte regular files use
the file count so determinate progress can still reach 100 percent.

A mismatch, read failure, changed source, changed staging entry, unsupported
item, scope overflow, or cancellation prevents publication. The original source
and any pre-existing destination remain unchanged. Pengrid removes only staging
whose ownership it can revalidate. If safe cleanup or rollback cannot be proven,
the result becomes **Recovery Needed** and automatic queue advancement stops for
review.

Operation Center history retains only the bounded status, verified file count,
and operation-wide logical-byte total for the current app session, formatting
the total for display. It is not persisted to disk. The diagnostic system log
records the same raw aggregate as `verifiedLogicalBytes`. Neither boundary
contains per-file sizes or digests, paths, relative tree lists, or underlying
errors. Status and VoiceOver text use sanitized basenames and a human-readable
aggregate, not absolute parent paths, hashes, or a raw numeric byte total.

File Provider verification requires both source and staged bytes to be locally
readable for the operation. macOS or the installed provider may materialize an
online-only source again. Pengrid does not claim provider coverage until Google
Drive and OneDrive are observed manually.

Receipt revalidation is the last awaited safety step before the filesystem
publication call. It narrows but cannot eliminate the residual syscall interval
between the final validation and `rename`/replacement. Documentation and UI must
not describe that interval as an atomic content lock.

## Automated evidence

The evidence below was recorded on 2026-08-24 KST in the Task 8 worktree based
on commit `68c542b`. It is pre-commit source evidence and does not claim a merged
candidate commit, packaged DMG, public asset, or release checksum.
The tested Task 8 staged snapshot, before adding these bilingual provenance
lines, had diff SHA-256
`c58c0417920cacbaa914e517353c7d7111d97f43b8f285a61379bda848610510`.

| Check | Result | Evidence |
| --- | --- | --- |
| Complete workspace regression | PASS | `swift test --enable-swift-testing --no-parallel` passed 1,931 tests in 123 suites in 97.056 seconds. The five opt-in APFS cases were skipped in this run because no mounted APFS test root was supplied. |
| Workspace arm64 Release build | PASS | `swift build -c release --arch arm64` completed successfully for the current unmerged working tree. This is compilation evidence, not the merged candidate DMG. |
| Disabled opt-in suite | PASS | Without `PENGRID_TRANSFER_APFS_ROOT`, five `TransferVerificationAPFSTests` cases are recorded as skipped. |
| Safe shell harness contracts | PASS | `/bin/bash script/tests/verify_transfer_content_contract_tests.sh` passed 20 cases covering success, Swift failure cleanup, malformed plist, invalid device, image/mount mismatch, mountpoint, cleanup-root, and random attach-capture substitution, partial attach, cancellation immediately before attach launch, detach target validation, genuinely blocked attach/Swift child signaling, repeated signals during detach cleanup, and a TERM-ignoring descendant. |
| APFS filesystem integration suite | PASS | `/bin/bash script/verify_transfer_content.sh` created and mounted a private APFS sparse image and passed five tests in one suite. No image remained attached and no harness temporary root remained after cleanup. This is a real mounted APFS filesystem test, not physical-media coverage. |
| Nested tree copy | PASS | Two nested regular files were verified before publication. |
| Cross-volume move | PASS | The source remained present at the deterministic verification gate and was removed only after verified publication. |
| Symbolic-link root | PASS | The link payload was copied and compared without following the target. |
| Verification cancellation | PASS | Cancellation preserved the source, prevented destination publication, and removed owned staging. |
| Receipt mutation | PASS | In-place staging mutation before receipt revalidation preserved the source and old destination and removed only owned staging. |

The harness uses `mktemp -d`, `hdiutil attach -plist`, an allowlisted
`/dev/disk[0-9]+(s[0-9]+)*` corroborating device, exact canonical image and
strict-child mount matching, mounted-filesystem identity checks, and an
idempotent cleanup trap. The attach plist is captured through a randomly named,
inode-checked file opened without truncation on private file descriptors and
immediately unlinked; its contents are then loaded into shell memory. The
`hdiutil info -plist` output remains directly in shell memory. Neither flow uses
a predictable plist path. The harness revalidates the same image, mount,
filesystem, and device before both test execution and detach, then detaches
through the validated private mount point rather than the reusable device name.
After detach, cleanup enters the identity-matched temporary root as its working
directory and deletes only below `.` without crossing a filesystem boundary. It
never targets `/`, the home directory, or the workspace root for deletion.
Attach and Swift run in managed process groups. INT or TERM forwards TERM to the
active group; after the leader is reaped, a bounded drain sends TERM and then
KILL if descendants remain. A signal received immediately before attach launch
does not claim that attach was attempted. An undrained group fails closed before
filesystem cleanup. Once EXIT cleanup begins, further INT and TERM signals are
ignored so they cannot interrupt detach or identity-bound deletion.

## Static-source evidence

| Invariant | Source evidence |
| --- | --- |
| Safe default and policy capture | `TransferVerificationPreference` defaults off; `FileOperationController` captures one immutable policy for queued work and Retry. |
| Pair bound | User-enabled policy is exactly `.sha256(maxConcurrentPairs: 2)` and internal limits clamp to one or two workers. |
| Pre-publication order | `FileOperationService` and `FolderSynchronizationTransactionService` verify private staging and revalidate the receipt before publication. |
| Recursive no-follow scope | `TransferVerificationManifest` uses descriptor-anchored traversal, regular-file readers, and `readlinkat` without following symbolic links. |
| Manifest limits | Production limits are 250,000 descendants and depth 256. |
| Bounded progress and history | Presentation exposes byte-weighted percentage, file-weighted count, and bounded aggregate history only. |
| Privacy | Typed logging contains the operation-wide raw logical-byte aggregate and bounded counts, but no per-file size or digest, raw tree, absolute path, or underlying error. Accessibility formats the aggregate and does not announce the raw number. |
| Recovery | Identity-safe cleanup failures propagate as Recovery Needed instead of deleting uncertain entries. |

## Physical manual evidence

| Scenario | Status | Required observation |
| --- | --- | --- |
| Google Drive File Provider, locally available bytes | **MANUAL NOT RUN** | Copy and cross-volume move with verification enabled; confirm success, progress, and no repeated materialization prompt. |
| Google Drive online-only or evicted bytes | **MANUAL NOT RUN** | Record provider materialization or bounded failure without unverified publication. |
| OneDrive File Provider, locally available bytes | **MANUAL NOT RUN** | Copy and cross-volume move with verification enabled; confirm source and destination behavior. |
| OneDrive online-only or evicted bytes | **MANUAL NOT RUN** | Record materialization or bounded failure and cleanup behavior. |
| VoiceOver Settings and progress | **MANUAL NOT RUN** | Confirm toggle value, phase announcements, increasing 10-percent buckets, file count, and separately discoverable Cancel button. |
| VoiceOver terminal history | **MANUAL NOT RUN** | Confirm verified/no-byte/mixed-failure wording contains no absolute path, digest, or raw byte total. |

## Release gate

- **PASS:** current source implementation, shell contracts, and APFS filesystem
  integration suite.
- **PASS:** documentation distinguishes current source from the published
  Developer Preview 7 DMG.
- **NOT RUN:** merged-commit candidate build, complete release regression,
  unsigned DMG inspection, and public asset checksum. These belong to the next
  candidate release workflow.
- **MANUAL NOT RUN:** Google Drive, OneDrive, and live VoiceOver observations.
  They must remain labeled this way until actually performed; automated APFS
  evidence does not substitute for them.
