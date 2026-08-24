# Pengrid current limitations

[한국어](current-limitations.ko.md) · **English** · [User guide](user-guide.md)

This list distinguishes the current source tree from the Developer Preview 7
DMG. Transferred-content verification and the other explicitly source-only
workflows are not shipped in that last published DMG.

## Platform and distribution

- Apple Silicon and macOS 15 or later only.
- The free public DMG is ad-hoc signed, not Developer ID signed or notarized.
- No Intel build, Mac App Store distribution, or automatic updater.

## Search, preview, and cloud

- Search uses names, relative paths, and available metadata by default. Its
  opt-in Spotlight content mode searches only already-indexed literal content;
  coverage can be incomplete for provider-backed, excluded, or unindexed
  locations and it supplies no snippets or persistent Pengrid index.
- Get Info is read-only. It does not change names, tags, permissions, ownership,
  dates, or extended attributes; SHA-256 remains an explicit single-file action.
- Folder preview is one level and read-only. File Provider metadata that is not
  locally exposed is reported unavailable rather than downloaded implicitly.
- Google Drive and OneDrive use their macOS File Provider roots. Pengrid has no
  direct Google or Microsoft OAuth/API client.
- An unregistered location under `~/Library/CloudStorage` has unknown mutation
  capability and batch rename fails closed there.

## Productivity workflows

> The productivity workflows in this section describe the current source tree.
> They are not a claim that these additions are available in the existing
> Developer Preview 7 DMG.

- **Quick Go…** is a scene-local typed palette. Its candidates are limited to
  fixed safe commands (**Create Folder**, **Create File**, **Show Filter**, and
  **Smart Search**), the active pane's current/Back/Forward locations,
  available favorites, workspace profiles, and saved searches. Matching uses
  normalized text with the existing Hangul-initial (Korean initial-consonant)
  support. It does not execute scripts, crawl an index, or materialize file
  contents.
- **New Empty File** uses **Option-Command-N** and performs regular-file
  creation bound to the captured parent-directory identity through an
  exclusive, no-overwrite operation. A successful create refreshes the pane
  before selecting the new row and beginning inline rename. Conservative Undo
  is available only while the exact created identity and fingerprint remain
  unchanged. Loaded sibling collisions choose `New File 2`, `New File 3`, and
  so on; only an unseen racing collision at exclusive publication fails.
- **Select All Visible** (**Option-Command-A**), **Invert Selection**
  (**Option-Command-I**), and **Select Same Extension**
  (**Option-Command-E**) operate on the active pane's currently visible,
  unfiltered rows. They are disabled while pane filtering or text editing is
  active. Select Same Extension additionally requires exactly one visible
  regular file with a real extension.
- Finder tag editing is not shipped; Get Info remains read-only. Optional
  transferred-content verification is implemented in current source, but not
  in the Developer Preview 7 DMG.

## Transferred-content verification in current source

- The global setting is off by default. It covers copy, Duplicate,
  cross-volume move, and reviewed synchronization copy/replace actions. It
  does not cover archive creation/extraction or same-volume rename-style moves.
- SHA-256 covers regular-file data forks. Recursive structure and symbolic-link
  payloads are checked, but resource forks, extended attributes, ACLs,
  ownership, flags, creation dates, hard-link relationships, and sparse
  allocation are excluded.
- One operation uses at most two file-pair workers. A root over 250,000
  descendants or depth 256 fails closed while verification is enabled.
- File Provider content must expose readable local bytes and may be
  materialized again. Google Drive and OneDrive verification remain manual
  release gates until observed on installed providers.
- Receipt revalidation is immediately before publication, but the final
  validation and namespace syscall cannot be made one atomic content lock. A
  narrow residual race remains.
- Failure preserves the source and old destination when cleanup ownership is
  provable. An uncertain cleanup becomes Recovery Needed rather than deleting
  an unverified item.

## Batch rename

- Requires at least two fully loaded selections from one active pane and one
  parent folder.
- Supports literal find/replace, prefix, suffix, and sequence rules only.
- Does not support regex, recursive subfolder renaming, manual extension edits,
  per-row custom names, or a user override of filesystem case semantics.
- Preserves ordinary/package extensions and recognized compound archive
  suffixes by design; use single-item rename when the extension itself must
  change.
- Mutations are serial. A recovery-needed rollback blocks the queue for review
  instead of guessing ownership or deleting an uncertain item.

## Folder synchronization

- One-way, review-first synchronization of the complete current comparison is
  available. There is no bidirectional merge, schedule, background watcher, or
  continuous sync.
- The plan is all-or-nothing. Individual copy, replace, or Trash rows cannot
  be selected independently.
- Completed synchronization is not Undoable and cannot be retried from the
  captured review. In-flight cancellation rolls back owned changes or reports
  Recovery Needed.
- Symbolic links, packages, special entries, type/name conflicts, and unsafe
  root relationships block the plan. File Provider items are not materialized
  to make a review or transaction possible.
- Destination-only items move to Trash after publication. Pengrid does not
  permanently delete pre-existing user data.

## Archives and destructive operations

- Native archive tools do not provide reliable cross-format byte progress.
- 7z, RAR, and password-protected TAR are unsupported.
- AES ZIP interoperability is fixture-backed; Finder and Archive Utility may
  not open AES ZIP files. Resource forks, ACLs, and extended attributes are not
  guaranteed to round-trip.
- Pengrid moves reviewed items to Trash and does not permanently delete them.
- No automatic cleanup occurs when ownership or identity cannot be proven.
