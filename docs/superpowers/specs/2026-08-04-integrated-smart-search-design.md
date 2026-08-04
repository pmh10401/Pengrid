# Integrated Smart Search design

Date: 2026-08-04
Status: Approved for implementation planning

## Objective

Restore both Pengrid search experiences on top of the safe-operation code line
and extend recursive Smart Search into a practical file-manager workspace. Also
restore a useful Space-bar preview for folders instead of delegating folders to
the generic system Quick Look representation.

- **Command-F** filters the active pane's already-loaded current-directory
  listing without additional filesystem or network work.
- **Command-Shift-F** opens recursive Smart Search from the active pane's
  directory.
- Smart Search retains Korean-initial, literal, multi-clause, multi-root, saved
  search, cancellation, result-bound, and candidate-bound behavior.
- Smart Search adds metadata filters and safe result actions without weakening
  the file-operation queue, Undo authority, archive progress, accessibility, or
  cloud preparation rules completed on `codex/safe-operation-center`.
- Space keeps system Quick Look for files, packages, and multi-selection. A
  single ordinary folder opens a read-only, one-level contents preview.

Search itself reads names, relative paths, and ordinary File Provider metadata.
It never reads file contents and never initiates cloud materialization.

## Integration baseline and boundaries

Implementation starts from `codex/safe-operation-center` at or after
`b02eea2`. The recursive search implementation is selectively ported from
`codex/korean-search-final` at `afea689`.

The histories have diverged substantially. The Korean-search branch must not be
merged wholesale, and its versions of the following safety-sensitive areas must
not replace the baseline:

- `FileOperationController`
- `FileOperationService` and `FileOperationUndoService`
- `FileSystemAccess`
- archive command, operation, and progress implementations
- operation-center views and models
- shared workspace or app files without a hunk-by-hunk integration review

New Smart Search model, analyzer, service, store, and view files may be ported as
focused units. Shared application, workspace, command, persistence,
accessibility, status, places, and AppKit table files receive only the smallest
integration edits required by the approved interfaces.

Batch rename, tabs/workspaces, Finder tag editing, Spotlight integration, and
file-content search are separate future projects.

## Architecture

### Pane-local filename filter

`PaneFilenameFilter` remains a pure value projection over `FilePaneState.items`.
It keeps pane-local query and focus state, applies before the existing sort, and
never calls a listing, materialization, or search service. Closing the filter
restores the normal listing and preserves the existing selection/scroll safety
behavior.

### Recursive Smart Search

The ported search feature remains split into focused units:

- `SmartSearchModels` owns query validation, filter values, result records,
  ranking inputs, saved-search coding, and bounded-query constants.
- `SmartSearchTextAnalyzer` owns literal and Korean-initial analysis and
  multi-clause AND matching.
- `LocalSmartSearchService` validates roots, holds scoped access, enumerates
  without following symbolic links, prunes hidden/package boundaries, applies
  metadata filters, captures item identity through an injected
  `FileSystemAccess`, and returns bounded candidates.
- `SmartSearchStore` owns presentation state, cancellation generations,
  progress coalescing, selection/sort state, roots, filter values, and saved
  search persistence.
- `SmartSearchView` owns the search sheet, filter popover, result table, saved
  searches, and result actions.
- A small result-action router converts selected results into identity-checked
  Quick Look, navigation, transfer, or Trash requests. It does not implement
  filesystem mutations itself.

The search service applies metadata filters before retaining and ranking a
matching candidate. This bounds memory and sorting work even for broad text
queries.

### Folder contents preview

One `WorkspacePreviewCoordinator` owns the mutually exclusive preview modes
`closed`, `systemQuickLook`, and `folder`. Both the Space command and workspace
selection observer route through this coordinator. It prevents the existing
Quick Look selection-update path from materializing an ordinary folder before
the folder route takes ownership. It also owns generation cancellation, panel
switching, close behavior, editor-first Space/Escape priority, and restoration
of table focus.

The coordinator routes a single ordinary directory to a dedicated folder
preview and retains the existing `QLPreviewPanel` route for files, packages,
and multi-selection. A folder request captures pane ID, standardized URL, exact
`FileIdentity`, and a no-follow item kind. Packages and symbolic links cannot
enter the folder route. The folder implementation remains split into focused
units:

- `FolderPreviewModel` owns the captured request, visible child metadata,
  loading/error state, sort, and cancellation generation.
- `FolderPreviewListing` performs a nonrecursive, identity-bound directory
  snapshot through injected filesystem access. It reads only ordinary URL
  metadata and never invokes `CloudMaterializing` or a coordinated content read.
- `FolderPreviewController` owns the dedicated panel under the workspace
  coordinator and cancels stale snapshot work when mode or selection changes.
- `FolderPreviewView` renders the folder name and safe location, item count,
  loading/error state, and a read-only child table.

The live filesystem implementation opens the captured directory with no-follow
directory flags, verifies the opened descriptor's whole `FileIdentity`, and
enumerates relative child names and no-follow metadata through that stable
descriptor. Rows are staged privately; progress may update a loading count, but
no partial row batch becomes visible. After enumeration, the implementation
revalidates the descriptor identity, current path identity, request generation,
and cancellation state before atomically publishing the complete snapshot. This
stable-handle rule prevents path replacement or ABA replacement from producing
a mixed snapshot.

Child metadata is display-only authority; this preview exposes no child open,
navigation, transfer, rename, archive, or Trash action. The preview enumerates
only the directory's immediate children, does not follow symbolic links, and
does not descend into packages. `DirectoryVisibilityPolicy` is the shared source
of truth for the pane and preview. The baseline policy explicitly includes
hidden entries, matching the current pane listing's `contentsOfDirectory(...,
options: [])`; a future visibility preference must change the shared policy,
not either consumer independently. Closing or changing selection cancels stale
publication. Default order is folders first and then localized name order.

## Query and persistence model

`SmartSearchQuery` adds one backward-compatible metadata-filter value containing:

- item kind: all, files only, or directories only;
- a normalized set of filename extensions;
- optional minimum and maximum byte size;
- optional earliest and latest modification date;
- the existing hidden-item and package traversal choices.

Extension input removes leading dots, uses canonical Unicode normalization and
case-insensitive comparison, ignores empty comma-separated components, and
deduplicates values. Size bounds are inclusive and valid only when nonnegative
and minimum is not greater than maximum. Date bounds are inclusive and valid
only when the earliest date is not later than the latest date.

When an extension filter is active, directories and extensionless files do not
match. When a size or modification-date bound is active, an item whose
corresponding metadata is unavailable does not match. Filters never guess a
missing provider value.

An invalid filter keeps the current results visible, disables Search, and shows
the error beside the responsible control. It does not silently repair the value.

Saved searches encode the metadata filter while retaining compatibility with
the prior `includeDirectories` field. An older record that omits the metadata
filter decodes to all item kinds when `includeDirectories` is true and files
only when it is false, with no extension, size, or date restriction. A missing
legacy `includeDirectories` field retains its historical default. Current
complexity limits continue to apply only when a saved search is executed; an
older record that exceeds current limits stays visible for editing.

## Identity and cloud safety

Every `SmartSearchResult` carries the exact `FileIdentity` captured during
enumeration. The identity is authority for later actions, not merely display
metadata.

- Revalidation uses exact entry-identity equality. It must not use
  `refersToSameItem` and must not capture and adopt a replacement currently at
  the old path.
- Quick Look and pane navigation revalidate the result identity before
  presenting, selecting, or navigating any result.
- Copy and move use only the identified transfer path on
  `FileOperationController`, carrying the search-captured source identity. The
  opposite pane's destination identity is captured when the action is invoked.
- Trash uses only the identified Trash controller path. Multi-result actions
  preserve per-result identity.
- A missing, replaced, or inaccessible result fails closed with the safe
  message “Item changed. Search again.” No replacement is mutated or previewed.

Search enumeration calls the availability reader for display state but never
calls `CloudMaterializing`. Online-only results can therefore appear by name and
path without download. An explicit Quick Look, copy, or move action may enter
the baseline's existing cloud preparation flow after identity revalidation.

Folder contents preview follows the stricter search rule: it may ask the file
provider for ordinary directory and child metadata, but it performs zero
`CloudMaterializing` calls and zero coordinated content reads. Ordinary provider
metadata servicing is allowed and is not described as a content download. If
the provider cannot expose the directory listing under those constraints, the
panel shows an availability error and offers no implicit download or retry
action.

## User interface and commands

### Command-F pane filter

The active pane exposes its inline filter with Command-F. It includes a query
field, clear action, and “visible / total” result count. Escape closes the filter.
Both panes retain independent query state.

### Command-Shift-F Smart Search

Smart Search opens with the active pane's directory as its initial root. The
sheet contains:

1. query field plus Search or Cancel;
2. root summary and add/remove-root controls;
3. active filter chips and a Filters popover;
4. a sortable result table;
5. saved-search naming and list controls.

The Filters popover contains kind, comma-separated extensions, minimum and
maximum size with units, modification-date presets or a direct range, and the
existing hidden/package choices.

The result table exposes name, parent location, type, size, modification date,
and local/online availability. Result descriptions and accessibility labels use
basenames and safe relative locations rather than announcing unrestricted
absolute paths or provider metadata.

Single-result actions:

- Space: identity-checked Quick Look;
- reveal and select in the active pane;
- open the containing folder in the opposite pane.

Multi-result actions:

- copy to the opposite pane;
- move to the opposite pane;
- move to Trash.

Trash first presents an identity-bound confirmation for the captured result
selection. Confirmation copy uses item counts and basenames, never absolute
paths. Changing the result selection invalidates the pending confirmation.

Submitting a mutation dismisses Smart Search so the bottom operation center is
visible. The store retains the query, roots, filters, sort, and results for the
next presentation. Actions are disabled while selection, destination, or query
state is invalid; queueable actions remain compatible with the baseline command
policy.

All controls receive stable accessibility identifiers, explicit labels and
hints, keyboard focus order, and VoiceOver-safe state descriptions.

### Space folder preview

When exactly one non-package directory is selected, Space opens a dedicated
preview panel containing:

1. the folder name and a privacy-safe location description;
2. loading, item-count, or error status;
3. a read-only table with name, kind, size, and modification date.

The table is nonrecursive and defaults to folders-first localized name order.
Rows may receive keyboard and VoiceOver focus for inspection, but activating a
row performs no navigation in this release. Space or Escape closes the panel.
Changing the workspace selection while it is open reloads a newly selected
single folder or returns to existing system Quick Look routing for other valid
selections. All transitions go through `WorkspacePreviewCoordinator`; the
existing `WorkspaceView` observer must not call either concrete preview
controller directly. Text editing retains command priority, so typing a space
or Escape never opens or closes preview. Closing restores focus to the active
file table.

## Error handling and state transitions

- An invalid or missing root fails the search with a root-specific message.
- An inaccessible descendant is skipped; traversal continues and remains
  cancellable.
- Cancellation terminates enumeration and ranking, ignores stale generations,
  and preserves no partial result publication as a completed result set.
- Result and candidate limits remain hard bounds. Progress is coalesced through
  the existing newest-value relay.
- Invalid query complexity, empty searchable terms, and invalid metadata
  filters have distinct user-facing explanations.
- If the saved-search array cannot decode, the session shows an empty saved list
  and leaves the stored bytes untouched. It never fabricates or executes a
  fallback query.
- An action identity mismatch does not mutate, materialize, or preview the path.
- A folder request whose pane, URL, exact identity, or no-follow kind no longer
  matches fails before enumeration. A descriptor or path identity mismatch at
  final validation discards all privately staged rows and shows “Folder changed.
  Close the preview and try again.”
- An inaccessible or provider-unavailable folder shows a read-only error state;
  it never starts materialization as recovery.
- Closing the folder preview or changing selection cancels stale snapshot work,
  and a cancelled generation cannot publish rows or errors.

## Verification

### Automated coverage

- Query/model tests: normalization, inclusive boundaries, invalid ranges,
  filter combinations, equality/coding, and legacy saved-search decoding.
- Text-analysis tests: Korean initials, mixed literal/initial clauses,
  canonical Unicode forms, ranking, and complexity limits.
- Service tests: root normalization, metadata filters before retention,
  cancellation, progress, candidate/result bounds, hidden/package/symlink
  boundaries, identity capture, duplicate roots, and zero materialization.
- Store tests: state transitions, generation races, filter editing, sorting,
  saved searches, cancellation, and presentation restoration.
- Action tests: exact identity revalidation; replacement refusal for Quick Look,
  navigation, copy, move, and Trash; identified-controller routing; opposite-pane
  destination capture; and multi-selection ordering.
- UI/presentation tests: both shortcuts, filter errors and chips, sortable
  columns, result actions, keyboard focus, VoiceOver labels/hints, stable
  identifiers, and absolute-path privacy.
- Folder-preview tests: coordinator mode routing for single ordinary folders
  versus files, packages, symbolic links, and multi-selection; proof that the
  selection observer cannot materialize folder content; captured pane/URL/kind
  validation; stable no-follow descriptor enumeration; private staging and
  atomic publication; path and descriptor exact-identity validation; ABA
  replacement refusal; one-level folders-first listing; shared hidden-item
  policy; cancellation and stale-generation refusal; zero `CloudMaterializing`
  and coordinated content reads; provider-unavailable error state; repeated
  Space/Escape close behavior; editor priority and table-focus restoration;
  selection-change refresh; VoiceOver labels; and read-only row behavior.
- Regression tests: existing pane filter, Korean-search model/service/performance
  evidence, safe-operation controller/undo/transfer/archive focused suites, and
  app dependency/command policy coverage.

### Build and manual evidence

- Run the serial Swift Testing suite with full Xcode and a release build.
- Run focused search and safe-operation suites after every integration segment.
- Verify the actual app with keyboard-only navigation and VoiceOver.
- Search disposable local, Google Drive, and OneDrive trees and confirm search
  alone does not download online-only content.
- Replace a result between search and action and confirm Quick Look, copy, move,
  and Trash fail closed.
- Preview disposable local, Google Drive, and OneDrive folders and confirm the
  panel lists only immediate children without downloading online-only content;
  replace the folder during enumeration and confirm the mixed snapshot is not
  published.
- Confirm submitted mutations close the search sheet and appear in the operation
  center with valid progress, cancellation, and conservative Undo behavior.

## Sol Advisor commitment review

A fresh `sol_advisor_sol_reviewer` on GPT-5.6 Sol / High returned `proceed`.
It required exact entry-identity equality, identified controller overloads only,
default decoding for absent metadata filters, and hand-porting integration hunks
without replacing shared safety-sensitive files. Those requirements are
normative in this design.

The host broadened the requested reviewer isolation to
`danger-full-access / disabled`. Before and after review, both relevant worktrees
had unchanged HEADs, empty status, and empty staged and unstaged diff hashes.

After folder preview was added, a second fresh `sol_advisor_sol_reviewer` on
GPT-5.6 Sol / High returned `revise`. It required one workspace preview
coordinator, stable no-follow descriptor enumeration with private staging and
atomic publication, an enforceable metadata-only cloud rule, an explicit shared
hidden-item policy, and preservation of legacy `includeDirectories == false` as
files-only. Those corrections are normative above. This reviewer was likewise
broadened to `danger-full-access / disabled`; HEAD, status, and staged/unstaged
diff hashes remained unchanged during its review.

A third fresh `sol_advisor_sol_reviewer` on GPT-5.6 Sol / High reviewed the
corrected design and returned `proceed` with no required changes. It identified
File Provider compatibility of descriptor-relative enumeration under the
zero-materialization rule as the largest remaining implementation risk. The
review environment was again broadened to `danger-full-access / disabled`, and
the repository remained unchanged before and after review.
