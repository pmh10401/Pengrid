# Pengrid detailed feature guide

[한국어](user-guide.ko.md) · **English** · [README](../README.md)

This guide describes Pengrid 1.3.0 Developer Preview 5 and features completed in
the current source tree, including their safety boundaries and deliberately
omitted behavior. Features explicitly marked **current source builds** are not
part of the published Preview 5 DMG until a later release is packaged.

## Requirements and installation

Pengrid currently supports Apple Silicon Macs running macOS 15 or later.
Download the DMG from the
[Developer Preview 5 release](https://github.com/pmh10401/Pengrid/releases/tag/v1.3.0-developer-preview.5),
open it, and copy `Pengrid.app` to `Applications`.

The free DMG is ad-hoc signed, not Developer ID signed, and not notarized.
Gatekeeper may therefore block it. Pengrid does not instruct users to disable
macOS security controls. The [release guide](release.md) explains how to verify
the artifact and build it locally.

## Dual-pane workspace

Pengrid shows two file panes at the same time. Clicking or navigating in a pane
makes it active; commands use only the active pane's selection unless their
name explicitly describes a left-to-right or right-to-left action.

Each pane keeps its own:

- current folder and Back/Forward history;
- sort order;
- selected rows;
- remembered selection and scroll position for folders revisited during the
  current session;
- filename filter.

Useful navigation and file commands include:

| Action | Shortcut |
| --- | --- |
| Open selected item | **Command-O** |
| Rename one selected item | **Return** or **F2** |
| Batch rename selected items (current source builds) | **Command-Control-R** |
| New folder | **Command-Shift-N** |
| Copy and paste | **Command-C**, **Command-V** |
| Back and Forward | **Command-[**, **Command-]** |
| Parent folder | **Command-Up Arrow** |
| Edit location | **Command-L** |
| Move to Trash with confirmation | **Delete** |
| Move to Trash immediately | **Command-Delete** |

Double-click a row, press **Command-O**, or choose **Open** from the context menu.
Folders navigate in the current pane, while files and application or document
packages open through macOS.

Commands are disabled while the selection or current editing state makes them
unsafe. Rename, location editing, and filtering retain normal text-editing
priority for Return, Space, Escape, and Delete.

### Pane-local filtering

Press **Command-F** to filter the active pane. This searches only filenames that
are already loaded for the current folder. It is immediate, non-recursive, does
not search file contents, and does not download cloud-only files. Each pane has
its own filter and result count.

Use Smart Search when you need a recursive search, metadata filters, saved
queries, or actions across a larger result set.

## Smart Search and Korean initial-consonant matching

Press **Command-Shift-F** to open Smart Search at the active pane's current
folder. Smart Search recursively considers filenames and relative paths.

### Query matching

- Ordinary text uses localized, case-insensitive matching.
- Korean initial-consonant queries are supported. For example, `ㅍㄱ` can
  match `파일관리`.
- Mixed input creates required clauses. `ㅍㄱ report` requires both the Korean
  initial-consonant clause and the ordinary `report` clause to match.
- Empty or invalid filter combinations do not start an unrestricted mutation.

### Metadata filters

Results can be limited by:

- files or folders;
- one or more filename extensions;
- inclusive minimum and maximum size;
- inclusive earliest and latest modification date.

Search reads names, relative paths, and ordinary filesystem or File Provider
metadata. It is not a file-content search and does not maintain a background
index.

### Saved searches

A query and its filters can be saved, reopened, renamed, or deleted. Saved
searches use a separate persistence record from the two-pane workspace, so a
malformed saved-search record falls back safely without changing the pane
layout.

### Result actions and stale-item refusal

Results provide Quick Look, Reveal, open in the other pane, copy to the other
pane, move to the other pane, and Move to Trash. A result keeps the identity
captured during search. Before every action Pengrid verifies that the current
item still has that identity. If it was replaced, the action refuses with
**“Item changed. Search again.”**

Copy, move, and Trash actions are submitted to the operation center. They use
the same queue, progress, cancellation, recovery, and identity rules as actions
started from a normal file pane.

## Space folder preview and system Quick Look

Press **Space** with a selection in the active pane:

| Selection | Preview route |
| --- | --- |
| Exactly one ordinary, non-package folder | Pengrid folder-contents preview |
| File, package, or symbolic link | System Quick Look |
| Multiple items | System Quick Look |

The folder-contents preview is read-only. It shows one level of immediate
children with Name, Kind, Size, and Modified metadata. It follows the pane's
baseline visibility policy, which includes hidden entries. It does not open
children, navigate, rename, transfer, archive, or send anything to Trash.

The preview captures the selected folder's identity before listing. Results are
published as one sorted snapshot only if the selection and folder identity are
still current. Closing the preview or changing selection cancels obsolete work,
so late rows cannot replace a newer preview.

For cloud folders, this route reads directory-entry metadata through a
no-follow descriptor and does not ask the content materializer to download
children. If the File Provider does not expose enough metadata locally, the
panel reports **“Folder contents are unavailable without downloading.”**

Press Space again or Escape to close the current preview. When a system Quick
Look panel is open, selection changes update it through the same identity and
cloud-materialization gates used for the original selection.

## Safe file operation center

Copy, move, Trash, new-folder, rename, compression, extraction, and undo are
coordinated by one single-worker mutation queue. A single worker avoids two
mutations racing to replace the same destination.

### Captured intent and queue order

When an operation is submitted, Pengrid captures the relevant source and
destination identities before it waits. Waiting jobs start in first-in,
first-out order and can be moved earlier or later before they begin. If a source
is replaced or the destination root changes while a job waits, that job fails
closed instead of operating on the replacement.

### Pause and resume

Pause is cooperative. It takes effect at the next safe checkpoint between file
items or archive phases. Pengrid does not suspend a native `ditto` or `tar`
process that is already encoding or extracting an archive; the pause request is
acknowledged and takes effect when control returns to a safe boundary.

### Cancellation, cleanup, and recovery review

Cancelling a queued job removes it before mutation. Cancelling active work asks
the current operation to stop and complete rollback or owned temporary-file
cleanup before the next job starts.

If cleanup cannot prove that a remaining item is owned and safe to remove,
Pengrid preserves it for review. Automatic queue advancement stops, the
operation center reports that recovery may be needed, and the user must choose
**Continue Queue** before waiting work can resume. Pengrid never deletes an
unverified replacement just to make cancellation look successful.

### Recent history and privacy

The operation center keeps the 100 newest completed jobs for the current app
session. History is not written to disk. Rows and accessibility labels use item
names and safe summaries rather than absolute parent paths.

### Retry

Retry creates a new attempt from the original captured intent. It is offered
only when replaying the whole intent cannot repeat an item that already
succeeded. Partially successful multi-item work, Storage Inspector cleanup, and
Undo are not blindly retried.

### Conservative undo

Undo is available only when Pengrid can reverse its own unchanged mutation:

- Move, rename, and Trash restore require the mutation-created destination to
  retain the recorded identity and the original path to remain unoccupied.
- Removing a new folder, copy, archive, or extracted tree requires the exact
  mutation-created identity and its complete no-follow fingerprint to remain
  unchanged.
- A replacement conflict, content change, missing item, occupied restore path,
  or uncertain ownership disables or refuses Undo.

Undo does not overwrite a later item and does not remove a modified output.

## Preview-first batch rename (current source builds)

Select at least two complete rows in one pane and choose **File Operations >
Batch Rename…**, press **Command-Control-R**, or use **Batch Rename…** in the
file-row context menu. The command always captures the active pane only, in the
same visible order as its table. It is disabled during inline text editing or
while another exclusive file operation is running.

### Rules and extension preservation

The sheet provides four non-recursive rules:

- **Find & Replace** replaces literal text, either case-sensitively or with
  localized case-insensitive matching.
- **Prefix** inserts text before the editable filename stem.
- **Suffix** inserts text after the editable filename stem.
- **Sequence** generates one base name plus a number using the captured table
  order, configurable start value, and zero-padding width.

Rules edit names only; they do not edit paths or file contents. Ordinary files
retain their final extension, packages retain their package extension, and
recognized archive names retain their exact compound suffix, including
`.tar.gz`, `.tar.bz2`, and `.tar.xz`. Ordinary directories are treated as whole
names. A leading-dot file with no second dot is also treated as a whole name.

Regex, recursive subfolder renaming, manual extension editing, case-only policy
overrides, and per-row custom replacements are intentionally out of scope.

### Preview and capability gates

Every selected row appears with its old name, proposed name, and a status. The
preview refuses submission when there are fewer than two items, mixed parent
folders, an invalid generated name, duplicate proposed names, a collision with
an unselected sibling, or a plan in which no row changes. Names currently held
by another selected source remain available, which allows swaps and longer
cycles.

Only the latest asynchronous preview may publish results; stale generations are
discarded. Automated regression coverage requires a 10,000-row preview to
finish within five seconds. This five-second value is a ceiling for detecting a
large regression, not a promise that ordinary previews should take that long.

Local writable folders are supported. A configured File Provider location is
supported only when it advertises local file operations. Read-only providers
are refused, and an unregistered path under `~/Library/CloudStorage` fails
closed as an unknown capability. Pengrid acquires scoped access once for the
captured request; a denial reports one error rather than repeatedly prompting.

### Transaction, progress, cancellation, retry, and Undo

Press Return or choose **Rename N Items** only after the preview is executable.
The submitted plan is immutable and fields remain locked until the operation is
handed to the operation center. Before the first mutation, Pengrid revalidates
the parent, every source identity, filesystem name-comparison policy, sibling
names, and final destinations.

Execution is serial and same-directory. Changed sources first move to reserved
temporary names, then publish to their final names. This two-phase transaction
supports `A -> B, B -> A` swaps and longer cycles without overwriting content.
The operation center reports **Staging names**, **Publishing names**, and, when
needed, **Rolling back names**, with bounded item counts and no parent-path
disclosure.

Cancellation after mutation begins attempts a dependency-safe rollback. A job
succeeds only when all final names exist and no reserved temporary name remains.
If restoration cannot be proven, the result is marked for recovery review and
the queue stops rather than deleting an uncertain item.

Retry creates a new attempt from the exact captured plan after all preflight
checks run again. Undo reverses the complete transaction through the same
two-phase engine, but only while every final item retains its recorded identity
and fingerprint and every original name remains available. Changed or replaced
outputs, missing items, and newly occupied original names disable or refuse
Undo.

## Archive creation, extraction, and progress

Use **File Operations** or a file-row contextual menu to create or extract
archives.

### Supported formats

| Format | Created suffix | Recognized extraction suffixes |
| --- | --- | --- |
| ZIP | `.zip` | `.zip` |
| TAR | `.tar` | `.tar` |
| TAR.GZ | `.tar.gz` | `.tar.gz`, `.tgz` |
| TAR.BZ2 | `.tar.bz2` | `.tar.bz2`, `.tbz`, `.tbz2` |
| TAR.XZ | `.tar.xz` | `.tar.xz`, `.txz` |

New TAR-family archives use the canonical long suffix. Short aliases are
accepted as extraction inputs.

### Source handling and collision safety

Single files, folders, packages, and selected symbolic links can be archived.
A selected symbolic link is preserved as a link; Pengrid does not silently
substitute its target bytes. Unsupported special filesystem entries such as
device nodes, sockets, and FIFOs are rejected.

Archive and extraction destinations are never overwritten. Pengrid chooses an
available name before starting and uses exclusive publication. A destination
created by another process before publication causes a safe collision failure
or a new available-name decision, rather than replacement.

### Bounded parallel preparation

For multiple selected sources, Pengrid first copies them into a private
aggregate staging directory. Only this preparation phase runs in parallel. The
worker count is the smallest of:

- four;
- available processors;
- selected source count.

The native archive command remains one local process. Extraction also uses one
native process. This avoids claiming that compression itself is parallel when
only source preparation is.

### Progress phases

- **Preparing files, X of Y** reports exact top-level staging counts.
- **Encoding archive** or the matching extraction phase is indeterminate
  because macOS `ditto` and `tar` do not expose a reliable cross-format byte
  total.
- **Finishing archive** appears only after staged output validation and during
  exclusive destination publication.

Intermediate preparation updates are limited to ten per second, while phase
start and completion boundaries are always delivered. Cancel remains available
throughout the operation.

### Password-protected ZIP behavior

Creating a password-protected ZIP is supported for source builds with
**AES-256 only**. Reading accepts AES-128, AES-192, AES-256, and ZipCrypto
entries when their compression method is Store or Deflate and the archive
passes the current safety policy. ZIP filenames, sizes, timestamps, and other
central-directory metadata remain visible; encryption does not hide filenames.

Pengrid holds a password only for the active request. It does not save,
recover, or expose passwords. A wrong password or authentication failure asks
again with a fresh prompt rather than reusing a retained value.

Unsafe paths, traversal, malformed structures, and archives over the configured
size or entry limits fail closed. If cleanup cannot prove ownership of a
remaining temporary item, the item is retained for recovery review, queue
advancement stops, and the user must explicitly continue after review.
Resource forks, ACLs, and extended attributes are not guaranteed to round-trip.
Finder and Archive Utility may not open AES ZIP files; the repository's
third-party interoperability statement is limited to automated committed
fixtures, not a live Finder, Archive Utility, Windows, or WinZip result.

The source feature does not support 7z, RAR, or password-protected TAR. Developer
ID signing and notarization are also outside this source feature's supported
package boundary.

## Google Drive and OneDrive through macOS File Provider

Pengrid discovers provider roots already registered with macOS by Google Drive
or OneDrive. This is File Provider integration, not direct Google or Microsoft
OAuth/API integration; Pengrid does not ask for those account credentials.

Operations fall into two groups:

- Smart Search and folder preview use currently exposed metadata and do not
  intentionally read file contents or materialize online-only children.
- Opening, Quick Look, copying, moving, comparing contents, compression, and
  extraction may need bytes. In those cases macOS File Provider can download
  the required source before the local operation continues.

A provider can omit metadata that is not available locally. Pengrid reports an
unavailable or failed item instead of inventing results. Provider operations
retain scoped access only for the work that needs it and use the same identity
checks as local files.

## Directory comparison

Choose **Compare > Compare Folders** to compare the two pane roots. Pengrid
aligns entries by relative path and presents one-sided items, metadata
differences, name conflicts, and items that need content verification.

**Verify Selected Contents** and **Verify All Contents** calculate checksums
only for the requested candidates. Copy actions use explicit left-to-right or
right-to-left direction. Move actions require a confirmation sheet.

Comparison watches both roots for changes. A root replacement, lost filesystem
events, or changed item identity invalidates stale results and disables unsafe
actions until the affected data is reconciled. Symbolic links and packages are
treated as opaque entries during recursive listing rather than traversed.

## Storage Inspector

Choose **Storage > Enter Storage Inspector**, then select a local folder or a
directly attached volume and start a scan. Results are published progressively
instead of waiting for the complete tree.

Storage Inspector can show:

- large files;
- files that have not been modified for a long time;
- exact duplicates verified by complete content checksums.

Duplicate cleanup retains at least one copy and sends only explicitly reviewed,
identity-revalidated selections to the macOS Trash. It does not permanently
delete files.

Storage Inspector does not run a background index, follow symbolic links or
packages, scan network roots, or analyze cloud-only content. Root replacement,
disconnects, unreadable entries, and cancellation are reported without
silently switching to another mounted location.

## Accessibility, keyboard access, and privacy

Pengrid exposes stable labels for panes, search controls, preview status,
archive phases, operation-center controls, comparison rows, and Storage
Inspector results. VoiceOver can identify actions and current state without
operation rows announcing absolute parent paths. Reduce Motion disables
nonessential animation while preserving status changes.

Menu commands are available to Full Keyboard Access, and text editors keep
standard editing behavior. Automated coverage verifies identifiers, labels,
ordering, and privacy-preserving status text; candidate-specific manual
VoiceOver and keyboard checks remain recorded separately in the verification
documents.

## Current limitations

Developer Preview 5 and the current source tree deliberately do not provide:

- Intel Mac or macOS 14-and-earlier support;
- Developer ID signing or Apple notarization;
- direct Google Drive or OneDrive OAuth/API clients;
- background indexing or file-content search;
- guaranteed metadata for every online-only provider item;
- reliable per-byte progress from native archive tools;
- 7z, RAR, or password-protected TAR support;
- permanent deletion;
- automatic removal when ownership or identity cannot be proven;
- batch-rename regexes, recursive subfolder renaming, manual extension editing,
  or per-row custom names.

See [release and packaging](release.md) and the
[verification documents](verification/) for candidate-specific evidence and
manual checks that remain open.
