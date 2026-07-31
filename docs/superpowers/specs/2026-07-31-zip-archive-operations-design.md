# Pengrid 1.3 ZIP Archive Operations Design

Date: 2026-07-31
Status: Approved by the user's instruction to proceed

## Objective

Add local ZIP creation and ZIP extraction to Pengrid's normal file-operation
flow. The feature must preserve user data: it must never overwrite an existing
file, expose an inaccurate percentage, or write an archive's contents directly
into a directory containing unrelated files.

## Scope

### Included

- Create a PKZip archive from one or more selected files, folders, packages, or
  symbolic links using macOS `/usr/bin/ditto`.
- Extract one or more selected `.zip` files using the same macOS tool.
- Use a destination name that does not already exist: one selected item becomes
  `ItemName.zip`; multiple selections become `Archive.zip`; an extracted
  `Item.zip` becomes an `Item` directory. The existing keep-both naming rule
  chooses a numbered alternative when required.
- Build and extract in a private temporary sibling, then atomically move the
  completed result into the user's folder. A destination collision at commit
  time is a failure, never a replacement.
- Use existing identity capture, File Provider access leases, and cloud
  materialization before a source is passed to `ditto`.
- Share the existing operation cancel control, operation result summary, and
  directory refresh behavior.
- Add File Operations menu commands, disabled states, keyboard/VoiceOver
  labels, unit tests, and a physical verification checklist.

### Excluded

- Password-protected archives, 7z, RAR, tar, gzip, and non-ZIP archive types.
- Editing an archive in place, background operation queues, retry, and undo.
- Extracting an archive into an existing user-selected directory.
- Cloud-provider OAuth or any network API.

## User Experience

`File Operations` gains two actions for the active pane:

- **Compress to ZIP** is available when one or more rows are selected and no
  file operation or text edit is active. It creates the archive beside the
  selected items. The source rows remain unchanged; the new archive appears in
  the refreshed pane.
- **Extract ZIP** is available only when every selected row is a non-directory
  filename ending in `.zip` (case-insensitive). Each archive extracts beside
  itself into a new dedicated directory. Existing files are not merged or
  replaced.

The status bar shows an indeterminate **Compressing** or **Extracting** state
with the current archive name and the existing Cancel button. `ditto` has no
reliable byte-progress API, so Pengrid must not invent a percentage. When an
operation ends, the standard result summary and Details menu report the result.

## Architecture

### Archive models and planner

`ArchiveOperationModels.swift` owns pure ZIP eligibility, operation kind,
accessibility copy, and destination-name planning. `ArchiveDestinationPlanner`
uses `KeepBothNamer` over the active pane's full loaded collection, not its
filtered projection. A final exclusive destination move remains mandatory to
protect against changes after planning.

### Archive service

`ArchiveService` is an actor behind an `ArchiveOperating` protocol. It invokes
the system-owned `/usr/bin/ditto` directly with argument arrays, never through
a shell:

- compress: `ditto -c -k --keepParent --sequesterRsrc source... staging.zip`
- extract: `ditto -x -k source.zip staging-directory`

The service creates an isolated temporary staging location, runs the process,
and removes the staging location on error or cancellation. Extraction moves the
fully extracted staging directory to its final unique directory only after the
process succeeds. It does not follow symbolic links while inspecting staging
paths, and it treats every process, I/O, or commit error as an item failure.
Cancelling terminates the child process and prevents the final move.

### Controller and cloud safety

`FileOperationController` receives an `ArchiveOperating` dependency. It
captures each source's stable identity, prepares it with the existing
materializer under a new `.archive` purpose, and rejects an identity mismatch
before invoking the archive service. The service acquires scoped access for all
source and destination URLs. Its completion returns standard
`FileOperationResult` outcomes so the existing status view and pane refresh
remain the single UI owner.

`FileOperationStage` gains an archive stage with a truthful indeterminate
status rather than reusing a made-up transfer percentage.

### Commands and accessibility

`WorkspaceCommandPolicy` derives `canCompress` and `canExtractZIP` from the
active selection, text-editing state, and operation state. `WorkspaceCommands`
routes both actions from File Operations. Archive progress and menu actions use
stable accessibility identifiers and labels; command availability is exposed
to VoiceOver in the native disabled state.

## Error and Recovery Rules

- A source that cannot be identified, materialized, or revalidated produces a
  failure for that source and does not start `ditto` for it.
- An existing destination is never replaced. A race detected by the exclusive
  move reports failure and leaves the pre-existing path unchanged.
- A cancelled or failed process leaves no final archive or extraction folder;
  only a private staging item may be cleaned up.
- A selected non-ZIP archive is not extractable through this first release.
- Archive members may include symbolic links, but staging inspection never
  follows them and no archive result is merged into an existing directory.
- Folder listings are refreshed only after the operation finishes. The source
  selection is not otherwise changed.

## Testing

Automated tests must use an injectable archive-process runner and real
temporary filesystem paths to cover:

- ZIP eligibility and deterministic names, including filtered-out collisions;
- one-item and multi-item compression arguments and successful atomic publish;
- ZIP extraction into a new dedicated folder;
- collision, process failure, cancellation, and no-final-artifact cleanup;
- cloud preparation and identity mismatch rejection before archive execution;
- active-pane command routing, text-edit disabling, and VoiceOver labels;
- refresh of only panes whose displayed directory changed.

Physical macOS checks must cover compression and extraction of regular files,
folders, a package, a symbolic link, a case-sensitive volume, a OneDrive or
Google Drive File Provider location, cancellation of a large archive, and
VoiceOver/keyboard operation. They remain release gates until recorded.
