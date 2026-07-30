# Pengrid

Pengrid is a dual-pane macOS file manager. The Swift package, executable, source
module, bundle identifier, and existing persistence locations retain the internal
name `BloomFileManager` for compatibility.

## Setup and verification

```bash
swift test
./script/build_and_run.sh --verify
```

The development bundle is created at `dist/Pengrid.app`. Its executable remains
`dist/Pengrid.app/Contents/MacOS/BloomFileManager`.

## Download the source

Pengrid is currently available as a developer preview. Download the latest
reviewed source from the
[Pengrid repository](https://github.com/pmh10401/Pengrid) as a
[source ZIP](https://github.com/pmh10401/Pengrid/archive/refs/heads/main.zip),
or clone the repository:

```bash
git clone https://github.com/pmh10401/Pengrid.git
cd Pengrid
```

The current verified development target is Apple Silicon on macOS 15 or newer
with full Xcode installed.

## Build locally

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --disable-sandbox --no-parallel
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  ./script/build_and_run.sh --verify
open dist/Pengrid.app
```

Locally built or ad-hoc signed artifacts may trigger macOS trust warnings.
They are development artifacts, not the signed public release.

Google Drive and OneDrive locations are discovered through macOS File Provider.
This is macOS File Provider integration, not direct Google or Microsoft
OAuth/API integration, and Pengrid does not ask for those credentials.

## Storage Inspector

Storage Inspector is an on-demand workspace for local folders and directly
attached volumes. It publishes bounded scan batches progressively, groups only
fully verified exact duplicates, shows large and long-unmodified files, and
moves only explicitly reviewed, identity-revalidated selections to the macOS
Trash while retaining at least one copy. It does not background-index, traverse
symbolic links or packages, permanently delete files, or analyze cloud-only
content.

Generated scale, privacy, recovery, and identity-safe cleanup checks are
automated. Physical storage, real 100,000-file, disconnect/reconnect, Trash,
accessibility, and appearance checks remain unrun release gates in
`docs/verification/storage-inspector-checklist.md`.

## Navigation productivity

Each pane has an independent current-folder filename filter, Back and Forward
history, and session-only selection and scroll restoration. An open Quick Look
panel follows selection changes through the same identity and cloud
materialization safety gates used when it first opens.

The filename filter works only on the directory listing already loaded in
memory. It is not recursive or file-content search, and it does not download
cloud-only files.

## Release status

See `docs/release.md`, `docs/verification/version-1.1-checklist.md`,
`docs/verification/version-1.2-checklist.md`, and
`docs/verification/storage-inspector-checklist.md`. An unsigned package is for
local inspection only; distribution requires the documented Developer ID,
notarization, stapling, Gatekeeper, and physical-manual gates.
There is no signed prebuilt GitHub Release available yet.

Create and inspect the unsigned local app with:

```bash
./script/package_release.sh --unsigned
codesign --verify --deep --strict --verbose=2 dist/release/Pengrid.app
```

The `--unsigned` mode ad-hoc signs and replaces only
`dist/release/Pengrid.app`; it does not produce or replace
`dist/release/Pengrid.zip`. The `--signed` mode produces and publishes both the
app and ZIP. Any ZIP already present after an unsigned run may be an older signed
release. SwiftPM commands and the internal `Sources/BloomFileManager` and
`Tests/BloomFileManagerTests` module paths remain unchanged.
