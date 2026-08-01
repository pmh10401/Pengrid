# Pengrid Local Smart Search Design

## Context

Pengrid's existing filename filter is intentionally shallow: it filters the
items already loaded for one pane. That is useful for a quick directory view,
but it cannot answer questions such as “find the PDF below this folder” or
“show the project notes I saved last week.” The next feature is a local Smart
Search that keeps the same dual-pane workflow while adding a cancellable,
recursive search surface.

The first release must remain useful without network access or a cloud API.
Search therefore reads the local file system directly, reports cloud-backed
items without downloading them, and keeps the query and results in Pengrid's
process. A persistent content index and remote semantic embeddings are
deliberately deferred.

## Goals

1. Search recursively below one or more user-selected local directory roots.
2. Rank filename and relative-path matches with a deterministic, lightweight
   BM25-style scorer. Exact names and filename tokens should outrank a path-only
   match; result ordering must be stable for equal scores.
3. Stream enough metadata to show a useful result row without materializing
   online-only cloud files.
4. Make traversal safe by default: do not follow symbolic links, do not descend
   into packages unless explicitly requested, skip hidden entries unless the
   user opts in, and never escape the selected root.
5. Cancel promptly and cap results so a large local volume cannot make the UI
   unresponsive.
6. Allow named saved searches to be stored locally and reopened from the
   sidebar. Saved searches store query settings and root paths, not file
   contents.
7. Expose an accessible search panel and a keyboard command while preserving
   the existing per-pane `Command-F` filename filter.

## Non-goals for this release

- Full-text indexing of document contents.
- Spotlight or a mandatory SQLite index.
- Automatic cloud download/materialization.
- Searching the entire computer without an explicit root.
- Cross-device synchronization of saved searches.

## User flow

1. The user chooses `Search Files…` from the Edit menu (Command-Shift-F) or
   activates a saved search in the sidebar.
2. The panel opens with the active pane's current directory as its root. The
   user can add or remove explicit roots, types a non-empty query, and can
   toggle hidden files, package contents, and directory results. The default
   result cap is 500 and its control is capped to `1...2_000`.
3. Search runs against the selected root(s). A progress label reports the number
   of examined entries and a cancel button stops the task. The panel never
   downloads an online-only item; its availability is shown in the row.
4. Double-clicking a result navigates the active pane to a directory result, or
   to the containing directory for a file result and selects that file when it
   is present in the listing.
5. `Save Search…` stores a user-provided name and the complete query settings.
   Saved searches appear in the sidebar and can be deleted from a context menu.

## Architecture

### Query and result model

`SmartSearchQuery` is `Codable`, `Equatable`, and `Sendable` and contains:

- trimmed text;
- one or more absolute file URL roots;
- `includeHidden` (default `false`);
- `includePackages` (default `false`);
- `includeDirectories` (default `true`); and
- `maximumResults` (default `500`, clamped to `1...2_000`).

`SmartSearchResult` contains a `FileItem`, a root-relative path, and a
non-negative score. `SmartSearchRecord` contains a UUID, display name, the
query, and a creation date. URLs are persisted as paths through Codable URL
support; no file contents or cloud credentials are persisted.

### Search service

`SmartSearching` is the small async boundary used by the store and tests. Its
progress overload reports examined-entry counts; a default implementation
delegates to `search(_:)` so simple fakes remain source-compatible:

```swift
protocol SmartSearching: Sendable {
    func search(_ query: SmartSearchQuery) async throws -> [SmartSearchResult]
    func search(
        _ query: SmartSearchQuery,
        progress: @escaping @Sendable (Int) -> Void
    ) async throws -> [SmartSearchResult]
}
```

`LocalSmartSearchService` uses `FileManager` directory enumeration with an
error handler that continues past unreadable descendants. It collects bounded
metadata candidates, computes document frequency once per query token, then
applies the scorer and returns the top `maximumResults` rows. Candidate count
is hard-bounded by `min(50_000, max(2_000, maximumResults * 20))` and ranking
also checks cancellation while scoring. Each traversal iteration reports the
number of examined entries and checks cancellation.
Resource values include directory/package/symbolic-link state, dates, size,
and localized type. Symbolic-link entries are always excluded, and their
descendants are never traversed. Package descendants are skipped unless
`includePackages` is true. Hidden entries are skipped unless `includeHidden` is
true. Root URLs are standardized, deduplicated, required to be absolute file
URLs, and are never replaced by a broader parent.

The service asks the existing `CloudItemAvailabilityReading` implementation
for metadata availability. It never calls `CloudMaterializing`; online-only
and unavailable results remain visible with their state so the user can choose
an explicit open/materialize action later.

### Ranking

The scorer tokenizes on non-alphanumeric boundaries using localized,
case/diacritic-insensitive text. It computes BM25-style IDF and TF for the
combined name/path document, with a filename-field multiplier and small exact,
prefix, and substring bonuses. Final ties sort by standardized path using
localized, numeric comparison. The algorithm is deterministic and has no
network or model dependency.

### Store and persistence

`SmartSearchStore` is a `@MainActor @Observable` store holding the panel state,
current query, progress counters, results, saved searches, and the active
search task. Starting a new search cancels the previous task. The store owns
only query/result state; the service owns traversal. A workspace receives the
store through dependency injection and exposes it as a focused scene value.

`WorkspacePersistence` stores saved searches under a separate versioned
UserDefaults key (`smartSearches.v1`) so old workspace snapshots decode
unchanged. Malformed data yields an empty saved-search list. Saving replaces
the complete list and writes sorted JSON.

### Views and commands

- `SmartSearchView` is an overlay panel in `WorkspaceView`, with a search field,
  root summary, option toggles, progress/cancel controls, result list, and save
  action. It supplies explicit accessibility labels and stable identifiers.
- `PlacesRailView` adds a Smart Searches section. Activating a row loads its
  saved query into the panel; a context menu removes it.
- `WorkspaceCommands` adds `Edit > Search Files…` on Command-Shift-F. Existing
  `Command-F` continues to open the pane-local filename filter.

## Safety and performance constraints

- Search roots must be absolute local file URLs and are never implicitly
  expanded to home or a volume root.
- Symbolic-link entries and descendants are always excluded. Package and
  hidden-file descent are disabled by default.
- Only metadata is read. Search does not materialize cloud files or read file
  contents.
- Cancellation is checked during traversal and before publishing results.
- Candidate collection is bounded to avoid unbounded memory use; the result cap
  is clamped to 2,000.
- User-visible messages and accessibility values use display names and relative
  paths; errors do not log full sensitive paths.

## Testing strategy

- Pure model tests cover query normalization/clamping, tokenization, BM25
  ordering, stable ties, and saved-search Codable round trips.
- Service tests use temporary directories to verify recursive matching, filename
  preference, hidden/package/symlink policies, multiple roots, result caps,
  cloud availability reporting, unreadable-entry continuation, invalid roots,
  and cancellation.
- Store tests use a controllable fake service to verify replacement/cancellation
  generations, saved-search CRUD, and empty-query handling.
- Persistence tests verify the separate key, malformed-data fallback, and
  relaunch round trips.
- Presentation tests verify accessibility labels and saved-search row values;
  the existing full Swift Testing suite remains the final regression gate.
