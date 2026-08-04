# Integrated Smart Search design

Date: 2026-08-04
Status: Approved for implementation planning

## Objective

Restore both Pengrid search experiences on top of the safe-operation code line
and extend recursive Smart Search into a practical file-manager workspace.

- **Command-F** filters the active pane's already-loaded current-directory
  listing without additional filesystem or network work.
- **Command-Shift-F** opens recursive Smart Search from the active pane's
  directory.
- Smart Search retains Korean-initial, literal, multi-clause, multi-root, saved
  search, cancellation, result-bound, and candidate-bound behavior.
- Smart Search adds metadata filters and safe result actions without weakening
  the file-operation queue, Undo authority, archive progress, accessibility, or
  cloud preparation rules completed on `codex/safe-operation-center`.

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

Saved searches encode the metadata filter. Older records that omit it decode to
all item kinds with no extension, size, or date restriction. Current complexity
limits continue to apply only when a saved search is executed; an older record
that exceeds current limits stays visible for editing.

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
