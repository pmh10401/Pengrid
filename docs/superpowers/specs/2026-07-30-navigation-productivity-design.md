# Pengrid 1.2 Navigation Productivity Design

Date: 2026-07-30
Status: Approved design

## Objective

Pengrid 1.2 will make repeated navigation in large folders faster without
changing the existing file-operation or cloud-materialization safety model.
Each pane will gain an independent current-folder filename filter, navigation
history, per-directory view restoration, and a Quick Look panel that follows
live selection changes.

## Scope

### Included

- Show and focus a pane-local filename filter with `Command-F`.
- Filter the already-loaded items in the active pane as the user types.
- Clear and close the filter with `Escape`.
- Preserve and restore the unfiltered selection when a filter session ends,
  when that item still exists.
- Maintain independent backward and forward navigation history for each pane.
- Restore a directory's prior scroll anchor and selected item when revisiting
  it during the app session.
- Update an open Quick Look panel when the pane selection changes.
- Preserve compatibility with existing workspace persistence data.
- Provide keyboard and VoiceOver labels for all new controls and states.

### Excluded

- Recursive search through descendant folders.
- File-content or metadata search beyond the already-loaded filename.
- Spotlight integration.
- Persisting navigation history or scroll anchors across app relaunch.
- Downloading cloud-only files for filtering.
- Pengrid 1.3 work: batch rename, archive operations, operation queues, retry,
  or undo.

Recursive search can be designed later as a separate indexed or streamed
feature. It must not be implemented as an extension of the in-memory filter.

## User Experience

### Filename filter

Each pane has its own filter state. `Command-F` opens and focuses the filter for
the active pane. Matching is case-insensitive and diacritic-insensitive using
the user's locale. It applies only to item names in the current directory.

The filter operates on the directory listing already held by `FilePaneState`.
Typing never starts a directory scan, reads file contents, or materializes a
File Provider item. Sorting remains the pane's selected sort order; filtering
only removes nonmatching rows.

When filtering begins, the pane captures its current selection. If that item
matches, it remains selected. Otherwise, the filtered list begins with no
selection. Clearing the query shows all items again. Closing the filter with
`Escape` restores the captured item if it still exists; otherwise the pane
keeps no selection.

Changing directories ends the current filter session and clears its query.
This avoids carrying an accidental filter into an unrelated directory.

### Navigation history

Each pane owns backward and forward stacks. Successful user navigation pushes
the previous directory onto the backward stack and clears the forward stack.
Backward navigation moves the current directory to the forward stack; forward
navigation performs the inverse.

Failed, cancelled, or superseded navigation does not change either stack.
History-driven navigation does not create a duplicate entry. Adjacent
duplicates are removed after URL standardization.

If a history destination no longer exists or cannot be opened, the pane stays
at its current directory and removes only that invalid destination. The user
can continue to the next available history entry.

### Per-directory view restoration

Before leaving a successfully loaded directory, the pane records:

- the standardized directory URL;
- the selected item's stable identity and URL fallback, when available; and
- the first visible item's stable identity and URL fallback as the scroll
  anchor.

View state is bounded to the 100 most recently used directories per pane and is
kept in memory only. Returning to a directory restores the selection and scroll
anchor after its first listing batch contains the relevant identity. If an item
no longer exists, restoration skips that item without reporting an error. If
the exact scroll anchor is absent, the view remains at the nearest position
chosen by the list.

### Quick Look

The existing `QuickLookController` remains the owner of the Quick Look panel.
While the panel is open, selection changes in the active pane replace its
preview items and preserve the panel. Empty selection, a deleted item, or an
item that cannot be prepared closes the panel without changing the file list.

Opening a cloud-only file through Quick Look continues to use the existing
identity-preserving materialization gate. Filename filtering itself never calls
that gate.

## Architecture

### `FilePaneState`

`FilePaneState` remains the pane's source of truth and gains:

- pane-local filter presentation and query state;
- the selection captured when a filter session starts;
- backward and forward navigation stacks;
- a bounded per-directory view-state cache; and
- explicit navigation intents distinguishing user, backward, forward, and
  restoration navigation.

The existing loaded item collection remains unchanged. A derived
`visibleItems` projection applies the filename filter before the current sort
projection is presented to the view. Filtering logic will be isolated in a
small pure value type so matching rules can be tested without SwiftUI.

### View-state model

A dedicated value model represents the selected and scroll-anchor identities
for one directory. A small bounded cache handles insertion, lookup, and
least-recently-used eviction. It has no filesystem access and no persistence
responsibility.

### `FilePaneView`

`FilePaneView` renders the filter field, exposes accessibility labels, and
reports selection and first-visible-item changes back to `FilePaneState`.
SwiftUI scroll positioning is driven by stable item identity after listing
updates. View code does not mutate navigation stacks directly.

### Commands

`WorkspaceCommands` routes `Command-F`, backward, forward, and filter
dismissal to the active pane. Command availability is derived from pane state.
Text editing retains normal copy and paste routing.

### Quick Look integration

`QuickLookController` gains an idempotent selection-update entry point.
Workspace selection observation calls it only while the panel is open.
Materialization and identity validation remain in the existing service layer.

## Data Flow

### Filtering

1. The user invokes `Command-F` in the active pane.
2. The pane captures its current selection and presents the filter field.
3. Query changes update pane state.
4. The pure matcher projects the existing loaded items into `visibleItems`.
5. The view renders that projection without another filesystem request.
6. `Escape` clears the query, closes the field, and restores the captured item
   when it still exists.

### Successful navigation

1. A navigation intent identifies whether the request is user-, backward-, or
   forward-driven.
2. The pane records the current directory's view state.
3. The existing listing service attempts the destination.
4. Only after a successful committed navigation are history stacks updated.
5. Listing batches appear.
6. The pane restores a matching selection and scroll anchor once their stable
   identities become available.

### Live Quick Look

1. The selection changes while Quick Look is open.
2. The controller validates the current selection.
3. Local items update the preview immediately.
4. Cloud-only items pass through the existing materialization and identity
   checks before becoming preview items.
5. Cancellation or invalidation prevents a stale selection from replacing a
   newer preview.

## Error and Recovery Rules

- Filtering cannot surface new filesystem errors because it operates only on
  already-published listing items.
- Invalid history destinations are removed individually; the current directory
  and remaining history are preserved.
- Failed, cancelled, or superseded navigation never changes committed history.
- Missing selection or scroll-anchor identities are treated as ordinary stale
  view state and silently discarded.
- A Quick Look preparation failure closes the preview but does not change pane
  navigation or selection.
- Cancellation and generation checks prevent older listing or preview work from
  overwriting newer user intent.
- Existing persistence payloads decode with defaults because the new history
  and view-state data is session-only.

## Performance

Filtering must be linear in the number of already-loaded items and must not
perform filesystem I/O. Query normalization may be cached for the duration of a
listing generation if profiling shows it is useful.

The automated 10,000-item check uses a generous regression ceiling rather than
a four-second product promise. Manual validation judges whether typing and
clearing feel immediate on the supported Apple Silicon development machine.
Correctness and cancellation safety take precedence over optimizing an
arbitrary fixed duration.

The per-pane view-state cache is capped at 100 directories. Navigation stacks
are capped at 100 entries each to prevent unbounded session growth.

## Accessibility and Keyboard Behavior

- `Command-F` focuses the active pane's filter field.
- `Escape` closes filtering before it performs any broader dismissal action.
- Filter controls expose pane-specific accessibility labels and the result
  count.
- Back and Forward commands expose disabled states when no valid entry exists.
- Restored selection remains visible to VoiceOver.
- Focus returns to the file list when filtering closes.
- Reduced-motion settings are respected by avoiding required navigation
  animations.

## Testing

### Unit tests

- Case- and diacritic-insensitive filename matching, including Korean and
  English names.
- Stable sort order before, during, and after filtering.
- Captured selection restoration and missing-item fallback.
- Independent filter state and navigation stacks for both panes.
- User, backward, and forward stack transitions without duplicate entries.
- Failed, cancelled, and superseded navigation preserving committed history.
- Invalid history destination removal.
- Bounded least-recently-used view-state eviction.
- Selection and scroll-anchor restoration by stable identity with URL fallback.
- Quick Look update cancellation and stale-generation rejection.
- Existing workspace persistence decoding with no new stored fields.

### Integration tests

- `Command-F`, typing, result selection, and `Escape` in each pane.
- Back and Forward command enablement and pane routing.
- Restoration after revisiting a directory whose listing arrives in batches.
- Quick Look following selection changes and closing after target removal.
- File Provider filtering without a materialization request.
- A generated 10,000-item listing meeting the regression ceiling.

### Manual checks

- Keyboard-only operation and focus return.
- VoiceOver labels, result count, selection, and command availability.
- Quick Look behavior for local and online-only File Provider items.
- Scroll restoration with rows near the beginning, middle, and end of a large
  folder.
- Light, dark, high-contrast, and reduced-motion appearance.

## Release Boundary

Pengrid 1.2 is complete only after the new automated tests, the existing full
test suite, build verification, and the relevant physical UI checks pass.
Pengrid 1.3 file-operation features require a separate design because queuing
and undo change the safety and recovery semantics of every mutation.
