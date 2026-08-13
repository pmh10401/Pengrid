# Pengrid current limitations

[한국어](current-limitations.ko.md) · **English** · [User guide](user-guide.md)

This list covers the current source tree. The published Developer Preview 6 DMG
also excludes source features that have not yet been packaged into a later
release, including batch rename.

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

## Archives and destructive operations

- Native archive tools do not provide reliable cross-format byte progress.
- 7z, RAR, and password-protected TAR are unsupported.
- AES ZIP interoperability is fixture-backed; Finder and Archive Utility may
  not open AES ZIP files. Resource forks, ACLs, and extended attributes are not
  guaranteed to round-trip.
- Pengrid moves reviewed items to Trash and does not permanently delete them.
- No automatic cleanup occurs when ownership or identity cannot be proven.
