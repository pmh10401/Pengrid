# Get Info and Optional Spotlight Content Search Parallel Design

Date: 2026-08-13
Status: Approved for implementation

## Objective

Develop two independent file-manager improvements in parallel:

1. A read-only, nonmodal Get Info panel for the active pane selection.
2. An opt-in Spotlight-backed indexed-content mode inside Smart Search.

Both features preserve Pengrid's current identity checks, File Provider boundaries,
Korean-initial filename search, cancellation behavior, accessibility, and safe file
operation routing.

## Parallel ownership boundary

The features do not share production models or services.

- Get Info owns new `GetInfo*` model, service, store, panel, and controller files.
- Spotlight owns `SmartSearch*` model, service, store, view, and dedicated
  `Spotlight*` files.
- `FileItem` remains unchanged. Get Info metadata lives in a separate immutable
  snapshot and Spotlight hydrates ordinary `SmartSearchResult` values.
- Get Info does not modify `ChecksumService`, `FileSystemAccess`,
  `ComparisonModels`, or `StorageScanService`; it consumes their existing APIs.
- Spotlight never modifies file-operation, context-action, preview, archive, or
  storage-inspector implementations.
- One integration owner applies the final changes to `BloomFileManagerApp`,
  `WorkspaceCommands`, `WorkspaceView`, `FilePaneView`, and `FileTableView` after
  both isolated implementations pass their focused tests.

## Get Info design

### Presentation

`Command-I` and a `Get Info` context-menu item present one reusable nonmodal
`NSPanel`. The panel floats with the application, remains usable while Smart Search
or another ordinary workspace surface is visible, and updates when the user invokes
Get Info again. Closing it cancels inspection and checksum work.

The panel is read-only in this version. It does not edit Finder tags, permissions,
ownership, dates, or extended attributes.

### Captured authority and metadata

The inspection service receives captured `FileItem` values, acquires scoped access,
and reads no-follow entry metadata. It captures exact identity before reading and
revalidates exact identity afterward. A changed or missing item produces an explicit
per-item failure rather than displaying stale metadata.

A single-item snapshot can expose:

- display name, standardized path, type description and UTI;
- entry kind, symbolic-link destination, logical size and allocated size;
- creation and modification dates;
- numeric owner/group IDs and POSIX mode;
- Finder tag names and File Provider availability;
- an identity-bound `ComparisonFingerprint` only for a regular non-symbolic-link
  file eligible for SHA-256.

A multi-selection summary exposes item count, successful/failed inspection counts,
known logical and allocated byte totals, common parent when one exists, and distinct
type descriptions. Directory sizes are entry sizes, not recursive content totals.

### Checksum boundary

Opening Get Info never calls `CloudMaterializing` and never reads file bytes.
`Calculate SHA-256` is visible only for one eligible regular file. That explicit
action sends the captured URL and fingerprint to the existing `ChecksumService`,
which owns cloud preparation, progress, cancellation, descriptor-safe reading, and
final identity revalidation. A completed digest is rendered as lowercase hexadecimal
and can be copied to the pasteboard.

## Spotlight content-search design

### Opt-in semantics

The current recursive name, relative-path, metadata-filter, Korean-initial, and saved
search behavior remains the default. Smart Search adds `Search indexed file contents`
as an explicit persisted query option.

When enabled for a literal-only query, Pengrid runs the existing local name/path
search and an `NSMetadataQuery` content search concurrently. Results are standardized,
restricted to the captured roots, identity-validated, metadata-filtered, deduplicated
by path, and ranked through the existing result pipeline.

Korean-initial or mixed initial queries continue to search names and paths only.
The UI reports that indexed-content search was skipped for that query rather than
silently changing its semantics.

### Query lifecycle

A dedicated main-actor query session owns `NSMetadataQuery`, its notification
observers, continuation, and cancellation state. It:

1. builds an AND predicate over normalized literal tokens using
   `NSMetadataItemTextContentKey`;
2. always assigns validated file-URL roots to `searchScopes`;
3. completes from `NSMetadataQueryDidFinishGathering`;
4. disables updates, snapshots only `NSMetadataItemURLKey`, stops the query, removes
   observers, and resumes its continuation exactly once;
5. performs the same cleanup and resumes with `CancellationError` when cancelled.

The MVP is a static search. It does not subscribe to live updates and never reads
`NSMetadataItemTextContentKey` values for snippets.

### Coverage and fallback

The store publishes one of four coverage states:

- names and paths only;
- indexed contents included;
- indexed contents unavailable, so names and paths only were returned;
- indexed contents skipped because the query contains Korean initials.

Spotlight failure, startup rejection, cancellation, or timeout never triggers direct
file-content scanning. Ordinary failure falls back to the existing local results with
an explicit coverage message. User cancellation still cancels the whole Smart Search.

Spotlight does not invoke `CloudMaterializing`, `NSFileCoordinator`, `FileHandle`,
`Data(contentsOf:)`, or any other byte-read API. File Provider items appear only when
their provider has already made searchable indexed metadata available. Opening or
performing a byte-dependent action on a result continues through existing routes.

## Accessibility and privacy

- Both opt-in content-search controls and Get Info controls receive stable
  accessibility identifiers, labels, values, and hints.
- Search status does not reveal paths.
- Get Info intentionally displays the selected item's path because path inspection is
  the feature's purpose, but announcements and global status text use item counts or
  basenames only.
- Keyboard behavior remains unchanged except for the standard `Command-I` Get Info
  shortcut. Existing Command-F and Command-Shift-F routes remain intact.

## Excluded from this delivery

- Finder-tag, permission, ownership, or date mutation.
- Recursive directory-size calculation in Get Info.
- Content snippets, custom Spotlight importers, persistent Pengrid indexing, or direct
  content reads.
- Korean-initial matching inside indexed file contents.
- Automatic cloud-file materialization for searching.
- Live Spotlight result updates after the initial gather.

## Verification gates

- Every production behavior follows RED, observed expected failure, minimal GREEN,
  and focused regression verification.
- Each feature passes its focused model/service/store/presentation tests independently.
- Integration passes context-menu, workspace-command, accessibility, checksum, and
  existing Smart Search suites.
- Final verification runs the complete Swift test suite, release build, bundle
  verification, `git diff --check`, and a source audit for prohibited content-read or
  materialization calls in the Spotlight implementation.
