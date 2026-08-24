# Pengrid architecture notes

[한국어 사용자 안내](user-guide.ko.md) · [English user guide](user-guide.md) ·
[README](../README.md)

This document records the source-level boundaries behind Pengrid's file-manager
features. It describes the current source tree, not necessarily the latest
published DMG.

## Mutation boundary

All user-visible filesystem mutations are submitted to the main-actor
`FileOperationController`. It owns an ordered single-worker queue, publishes
operation-center snapshots, coordinates cancellation and recovery blocking, and
retains the newest 100 completed jobs for the current session. Filesystem work
runs behind `FileSystemAccess`; views do not call `FileManager` to mutate user
items directly.

```text
SwiftUI/AppKit commands
        │ captured selection and intent
        ▼
FileOperationController ──► ordered exclusive or queueable job
        │
        ├──► operation-specific service ──► FileSystemAccess
        ├──► operation-center progress/history
        └──► FileOperationUndoService (verified recipes only)
```

Identity and no-follow fingerprints are safety inputs, not presentation data.
Operations revalidate them at the last responsible moment and fail closed when
the referenced item has been replaced. User-visible rows and accessibility
labels avoid absolute parent paths.

## Transferred-content verification boundary

Transferred-content verification is an opt-in source feature and defaults off.
`TransferVerificationPreference` persists user intent, while
`FileOperationController` captures one immutable `TransferVerificationPolicy`
at enqueue time. The operation closure, queued snapshot, Retry record, terminal
result, history, and Undo-eligibility projection all retain that captured value
or its bounded report; execution never rereads the live setting.

```text
Settings: default-off preference
        │ immutable policy captured at enqueue
        ▼
FileOperationController
        │
        ├── copy / Duplicate / cross-volume move
        └── reviewed synchronization copy / replace
                    │
                    ▼
        capture source manifest
                    │
        copy to owned private staging
                    │
        verify shape, symlink payloads, and SHA-256 pairs (≤ 2)
                    │
        recapture and revalidate source + staging receipt
                    │
                    ▼
        publish by identity-checked move or replacement
```

`TransferVerificationManifest` retains descriptor-anchored authority over each
root. Children are opened relative to verified parent descriptors; regular
files are read through no-follow duplicated descriptors and symbolic-link
payloads through `readlinkat`. Cross-root comparison uses the destination's
captured filename policy. Same-root comparison includes identity and stability
fingerprints, while source-to-staging shape comparison deliberately permits new
destination inode identities.

The production manifest budget is 250,000 descendants and depth 256 per root.
`LiveTransferVerificationSessionFactory` creates one operation-scoped session;
its shared permit pool caps regular-file hashing at two pairs. The session
publishes manifest preparation, hashing, and final validation progress.
Presentation interprets the fraction as byte-weighted while displaying an
independent file-weighted count. Zero-byte-only trees fall back to file-count
completion.

`FileOperationService` and `FolderSynchronizationTransactionService` publish
only after successful verification and one final receipt revalidation. They
preserve the source and any old destination on pre-publication failure and
remove only identity-confirmed staging. Cleanup uncertainty becomes Recovery
Needed and blocks queue advancement. A same-volume move bypasses the byte path
and records No byte transfer because it relocates the existing entry.

The typed verification logger carries aggregate file counts, the operation-wide
verified logical-byte total, and a bounded failure category. Operation history
retains the same aggregate logical-byte total in memory and formats it for
display. Neither boundary carries per-file digests, URLs, relative tree lists,
per-file sizes, or underlying errors. Accessibility uses sanitized basenames,
a human-readable aggregate byte total, and bounded progress announcements; it
does not announce the raw numeric total.

The final receipt check is the last awaited step before the namespace mutation.
It narrows but cannot eliminate the syscall interval between validation and
`rename`/replacement; this subsystem does not claim an atomic content lock.
Resource forks, extended attributes, ACLs, ownership, flags, creation dates,
hard-link relationships, and sparse allocation are outside the verification
contract.

## Safe batch rename flow

`BatchRenameModel` is the single shared main-actor presentation model injected
into the workspace and command set. A presentation captures one active pane's
selected rows in visible table order, their parent identity, sibling names,
filesystem comparison semantics, and one scoped-access result. Capability
gates reject read-only or unknown cloud locations before filesystem capture.

`BatchRenamePlanner` is pure and sendable. It decomposes names according to the
extension policy, applies one `BatchRenameRule`, validates generated names and
collisions, and returns both row statuses and an immutable executable
`BatchRenamePlan`. Preview computation runs away from the main actor. A
generation token ensures that only the latest result can publish.

```text
active pane selection
        │
        ▼
BatchRenameModel ──► capability and scoped-access capture
        │
        ▼
BatchRenamePlanner ──► latest-only preview ──► immutable plan
        │
        ▼
FileOperationController
        │
        ▼
BatchRenameTransactionService
   1. revalidate all identities and destinations
   2. source names ──► reserved temporary names
   3. temporary names ──► final names
   4. capture final identities and fingerprints
```

`BatchRenameTransactionService` is an actor and performs mutations serially in
one directory. Moving every changed source through a reserved temporary name
allows swaps and cycles without overwriting content. Failure or cancellation
after the first mutation invokes dependency-safe rollback. A rollback whose
ownership or restoration cannot be proven returns recovery-needed state and
blocks the queue.

Retry captures the exact immutable plan in the job. It does not silently rebuild
the request from the current selection. Undo stores a complete
`BatchRenameUndoPlan` and delegates the reverse operation to the same
transaction engine only after final identity/fingerprint and original-name
availability checks pass.

## AppKit and SwiftUI boundary

SwiftUI owns batch-rename state, validation, focus routing, modal coordination,
keyboard submission, Reduce Motion behavior, and accessibility labels. The
AppKit `NSTableView` bridge contributes only the native row context-menu route
and passes the table's stable ordered selection back to the shared SwiftUI
action. The menu bar and context menu therefore use the same enablement policy
and action closure.

## Performance contract

Preview work is latest-only and detached from the main actor. The automated
regression test plans 10,000 rows under a five-second ceiling. This is a broad
regression guard rather than the desired interactive latency; normal selections
should update substantially faster. Filesystem mutation remains serial because
correct rollback and exclusive name publication are more important than
parallel rename throughput.
