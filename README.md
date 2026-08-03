# Pengrid

Pengrid is a dual-pane macOS file manager. The Swift package, executable, source
module, bundle identifier, and existing persistence locations retain the internal
name `BloomFileManager` for compatibility.

## Setup and verification

```bash
swift test --enable-swift-testing --no-parallel --filter BloomFileManagerTests
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

An unsigned compiled DMG is also available from the
[Pengrid 1.3 Developer Preview 2](https://github.com/pmh10401/Pengrid/releases/tag/v1.3.0-developer-preview.2).
It is not Developer ID signed or notarized, so only open it when you downloaded
it directly from this repository's GitHub release page.

The current verified development target is Apple Silicon on macOS 15 or newer
with full Xcode installed.

## Build locally

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --disable-sandbox --enable-swift-testing --no-parallel --filter BloomFileManagerTests
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

## Smart Search

Press **Command-Shift-F** (or choose **Edit > Search Files…**) to
search recursively from the active pane's current directory. Smart Search
matches filename and relative-path words; it does not search file contents.
Korean initial consonants are detected automatically: `ㅎㄱ` matches names
such as `한국` and `한글`, while `ㄱㄷ` can match a segmented name such as
`구글 드라이브`. Compatibility jamo and modern choseong input are equivalent,
and space-separated initial and literal terms such as `ㅎㄱ report` use AND
semantics. No search-mode toggle or network index is required.
The search view lets you add or remove explicit roots before a search starts,
and saved searches keep that query, its selected roots, and its result cap in
the Places rail for later reuse. The default cap is 500 ranked results and the
control is bounded to 1...2,000.

Smart Search is a local File Provider traversal. It has no remote-search
service and does not automatically download or materialize cloud-only items.
Cloud-only matches can appear with their availability indicated, but opening a
result follows Pengrid's normal navigation and File Provider behavior.

For traversal safety, a query must have one or more local directory roots.
Pengrid excludes symbolic-link entries and never traverses their descendants,
skips hidden items and packages unless their explicit options are enabled, and
continues past individual unreadable entries. It does not index in the
background. See
`docs/verification/smart-search-checklist.md` for the remaining physical
release checks.

## Archives

Pengrid can create and extract ZIP and TAR-family archives from **File
Operations** or a file row's contextual menu. Supported archive names are
**ZIP**, **TAR**, **TAR.GZ** (including **TGZ**), **TAR.BZ2** (including
**TBZ** and **TBZ2**), and **TAR.XZ** (including **TXZ**). New TAR-family
archives use the canonical `.tar`, `.tar.gz`, `.tar.bz2`, or `.tar.xz`
extension; the short extensions are recognized when extracting.

For a multi-item compression, Pengrid first stages the selected sources in a
private aggregate directory. Only that staging-copy phase runs in parallel,
with a bounded worker count of no more than four and no more than the available
processor or source count; the archive command itself is a single local native
operation. A cloud-backed source may be downloaded first when macOS File
Provider needs to materialize it.

Archive destinations are never overwritten. Pengrid chooses an available name
before starting and exclusive publication rejects a late collision, leaving the
existing item unchanged. Password-protected archives and 7z and RAR archives
are not supported in this release.

## Release status

See `docs/release.md`, `docs/verification/version-1.1-checklist.md`,
`docs/verification/version-1.2-checklist.md`,
`docs/verification/version-1.3-archive-checklist.md`, and
`docs/verification/storage-inspector-checklist.md`, and
`docs/verification/smart-search-checklist.md`. The 1.3 GitHub release is
an explicitly unsigned Developer Preview DMG: it has not been Developer ID
signed or notarized, and macOS may show a Gatekeeper warning. A signed public
release still requires the documented Developer ID, notarization, stapling,
Gatekeeper, and physical-manual gates.

Create and inspect the unsigned local app with:

```bash
./script/package_release.sh --unsigned
codesign --verify --deep --strict --verbose=2 dist/release/Pengrid.app
```

The `--unsigned` mode ad-hoc signs and replaces
`dist/release/Pengrid.app` and `dist/release/Pengrid.dmg`; it does not produce
or replace `dist/release/Pengrid.zip`. The `--signed` mode produces and
publishes the app, DMG, and ZIP. Any ZIP already present after an unsigned run
may be an older signed release. SwiftPM commands and the internal
`Sources/BloomFileManager` and `Tests/BloomFileManagerTests` module paths
remain unchanged.
