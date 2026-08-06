# Large-Directory Navigation Optimization and Safe Cleanup Design

Date: 2026-08-07
Status: Approved for implementation planning

## Objective

Improve Pengrid's perceived responsiveness when opening, filtering, sorting,
scrolling, refreshing, and cancelling a directory containing approximately
10,000 entries. The work will also remove demonstrably unused or duplicated
code and split oversized navigation files along existing responsibilities,
without changing file-operation authority, File Provider behavior, persistence
compatibility, or user-visible semantics.

The primary product outcome is that useful rows appear early and the interface
remains interactive while the remainder of the directory is still loading.
The design deliberately avoids treating one generous timeout, such as four or
five seconds, as the complete performance definition.

## Decision

Use measured, incremental optimization rather than a low-impact patch or a new
global indexing engine.

- Establish a reproducible baseline before changing production behavior.
- Make directory enumeration genuinely incremental.
- Publish cached, generation-bound filter and sort projections.
- Coalesce UI publications and apply bounded table changes instead of
  reloading the complete table for every batch.
- Clean the navigation path in the same work, then perform a separate
  repository-wide dead-code audit after the performance changes are stable.

A repository-wide indexed filesystem database is excluded from this project.
Its cache invalidation, File Provider consistency, and stale-authority risks are
not justified for the current navigation bottleneck.

## Baseline Findings

The existing implementation has three structural costs:

1. `LiveDirectoryListingService` calls `contentsOfDirectory`, which returns the
   complete child URL array before the service begins constructing and yielding
   256-entry batches. The stream is therefore batched after collection rather
   than incremental from the user's perspective.
2. Every entry performs one resource-value lookup for common metadata, another
   lookup for localized type, and a serial asynchronous availability lookup.
3. `FilePaneState.visibleItems` filters and sorts the complete loaded array each
   time the property is evaluated. `FileTableView` then calls `reloadData()`
   whenever the projected array differs.

The current 10,000-entry tests prove that multiple batches eventually arrive
and that filtering finishes below a five-second regression ceiling. They do not
measure time to first batch, time to first rendered row, main-thread stalls,
publication cost, cancellation latency, or peak memory.

## Scope

### Included

- Reproducible performance fixtures and release-build measurements for a local
  directory containing 10,000 entries.
- Time-to-first-batch, time-to-first-row, full-load, filter, sort, cancellation,
  publication, table-update, and memory measurements.
- A truly incremental, one-directory-level entry source.
- One-pass resource metadata collection per entry where Foundation supports it.
- Bounded and cancellable cloud-availability enrichment with no materialization.
- A cached visible-item projection keyed by listing revision, query, and sort.
- Off-main pure projection work with request-generation rejection.
- Coalesced pane publications and identity-based table update planning.
- Preservation of selection, inline rename, focus, and scroll restoration.
- Removal of proven unused or duplicated code in touched navigation files.
- Responsibility-based source-file splits that preserve existing interfaces.
- A subsequent repository-wide dead-code report and separately reviewable
  cleanup changes.

### Excluded

- A persistent filesystem index or database.
- Recursive indexing for ordinary pane navigation.
- File-content search or Spotlight replacement.
- Direct Google Drive or OneDrive OAuth/API integration.
- Materializing online-only files merely to list, filter, sort, or preview their
  metadata.
- Changing file-operation identity checks, Undo authority, recovery journal
  semantics, symlink policy, archive safety, or protected ZIP behavior.
- Deleting persisted-data compatibility code solely because it is named
  `legacy`.
- Optimizing Smart Search, comparison, storage inspection, or archive throughput
  before the pane-navigation gates pass. Their measurements may be recorded as
  a later backlog.

## Performance Measurement Contract

### Fixture

The automated fixture creates 10,000 immediate child entries with a stable mix
of files, directories, names, sizes, and modification dates. A smaller fixture
exercises packages, hidden entries, unavailable metadata, and File Provider
availability doubles. The benchmark never depends on the user's personal files
or network state.

Measurements run in an optimized build on the same supported Apple Silicon Mac
with warm-up iterations separated from recorded iterations. The verification
report records the machine, OS, build configuration, fixture shape, sample
count, median, and p95 where the harness can measure them reliably.

### Metrics

- listing request to first 256-entry batch;
- listing request to first rendered nonempty table state;
- listing request to complete 10,000-entry publication;
- time spent producing a filtered/sorted projection;
- time spent applying one table update;
- longest main-actor publication interval;
- cancellation request to termination;
- peak resident memory during the scenario; and
- correctness counts before and after each projection.

Unit and integration tests retain generous hard ceilings as hang and regression
guards. Product acceptance compares the optimized build with the recorded
baseline rather than promising one hardware-independent absolute duration.

The first implementation target is at least a 30 percent improvement in first
useful-row latency and filter/sort projection time, with no greater than a 10
percent regression in complete-load time or peak memory. If baseline variance
makes either comparison statistically misleading, the verification report must
show the samples and justify a revised target before code is accepted.

## Architecture

### Incremental directory entry source

`LiveDirectoryListingService` remains the implementation of
`DirectoryListingService`, so callers and tests retain the existing stream
contract. Its filesystem enumeration is moved behind a small internal entry
source that yields immediate child URLs one at a time and never descends into
children.

The live implementation will first use Foundation's lazy directory enumerator,
explicitly skipping descendants. Before adoption, an integration test must
prove that it yields the first direct children before exhausting the complete
directory and preserves the shared `DirectoryVisibilityPolicy`. A POSIX
`opendir`/`readdir` implementation is not the default because it could diverge
from macOS File Provider and scoped-access behavior; it may be considered only
if the Foundation enumerator fails the verified streaming contract.

Scoped access is acquired once for the directory and remains alive until the
stream completes, fails, or is cancelled. Cancellation is checked before
metadata work and before every batch publication. A superseded stream may not
publish another batch.

### Entry metadata and availability

The common display keys, including localized type description, are requested
in one resource-value lookup per entry. Missing optional values retain the
current safe fallbacks; one unreadable child does not invent metadata.

Availability lookup remains metadata-only and never calls cloud
materialization. Work is bounded rather than creating one task per entry or
serially blocking all later entries. Results are associated with standardized
URLs and the active listing generation. Stale enrichment cannot modify a newer
directory or a replaced item.

The first published row must contain all metadata required by the active sort
key. This prevents rows from repeatedly jumping merely because size, kind, or
date arrived later. Availability may transition from `unknown` to a verified
state after publication because it is display status rather than sort
authority. Local fast paths may publish `availableLocally` only when the same
metadata rules used by `LiveCloudItemAvailabilityService` establish that fact.

### Pane listing and projection state

`FilePaneState` remains the pane source of truth, but it no longer exposes a
fresh full-array calculation through `visibleItems`. It owns a published
`visibleItems` snapshot produced by a dedicated pure projection component.

The projection input contains:

- an immutable snapshot of loaded `FileItem` values;
- a monotonically increasing item revision;
- the normalized pane-filter query; and
- the selected `FileSort`.

A cache key combines the revision, query, and sort. Re-reading the projection
with the same key is constant-time. When the key changes, pure filter and sort
work runs away from the main actor. Publication returns to the main actor and
succeeds only if the directory and projection generations still match.

Query edits cancel or supersede earlier projections. Selection intersection is
performed against the accepted projection once, not by independently invoking
the filter and sort pipeline. Closing the filter restores the existing captured
selection semantics.

### Batch coalescing

The first nonempty listing batch is published immediately. Later batches may be
coalesced within a short bounded window to prevent dozens of main-actor and
table refreshes during a burst. The window is an implementation constant
covered by deterministic clock tests; it is not user-configurable.

Coalescing must not delay completion, errors, cancellation, the first batch, or
explicit refresh completion. Appending uses reserved capacity where useful but
must remain bounded by the actual listing size.

### Table update plan

`FileTableView.Coordinator` delegates change analysis to a pure identity-based
update planner. The planner compares old and new standardized URL identities
and returns one of:

- no row change;
- bounded inserts, removals, moves, and reloads; or
- full reload when the change is too large or ambiguous.

The coordinator applies bounded changes inside `beginUpdates`/`endUpdates` and
uses `reloadData()` only for the explicit fallback. The threshold is measured
and tested rather than guessed per call.

Selection indexes are calculated from a URL-to-index map built during projection
publication. Applying a row plan must preserve selection, first-visible anchor,
inline rename ownership, and focus. If any invariant cannot be established, the
coordinator chooses the full-reload fallback and restores state by stable
identity.

### Refresh and monitor events

Navigation keeps progressive publication. Explicit refresh and directory
monitor reconciliation continue to stage a complete replacement so a failed
refresh does not erase the current usable listing. Projection computation for
the staged replacement may run off-main, but the accepted refresh remains an
atomic generation-checked commit.

Monitor bursts continue to collapse into bounded refresh work. Performance
changes must not allow an older monitor refresh to overwrite later navigation.

## Code Cleanup Strategy

Cleanup is split into two independently reviewable scopes.

### Touched-path cleanup

The navigation optimization may:

- remove private declarations with no references;
- consolidate duplicate metadata, filtering, sorting, URL-index, and table
  update helpers;
- remove state that becomes unreachable after the cached projection replaces
  computed projections;
- split `FilePaneState` into focused navigation, projection/filter, refresh,
  monitoring, and view-restoration source files while keeping one state type;
- split `FileTableView` coordinator, update planning, cell presentation, and
  drag/drop responsibilities where this reduces review size; and
- split directory enumeration from metadata construction inside the listing
  service.

The split must not introduce new public API merely to move code between files.

### Repository-wide audit

After navigation performance and behavior gates pass, a separate audit
classifies candidates as:

1. proven unused;
2. duplicated behavior;
3. compatibility or persistence shim;
4. safety boundary;
5. oversized but still live code; or
6. test-only support.

Only categories 1 and verified category 2 are deleted automatically. Large live
files are split in separate, behavior-preserving commits. Categories 3 and 4
remain unless a migration design, compatibility evidence, and dedicated tests
explicitly authorize removal.

Reference search alone is insufficient for internal Swift declarations. A
candidate requires compiler/index evidence where available, direct reference
search, relevant test review, and a clean full test run. Reflection, selectors,
SwiftUI/AppKit callbacks, Codable keys, command routing, and Objective-C runtime
entry points receive explicit manual review.

## Safety and Compatibility Invariants

- File mutations continue to use captured identity and revalidation; no
  path-only mutation is introduced.
- Directory listing, pane filtering, sorting, and availability enrichment never
  materialize online-only file contents.
- Existing cloud scoped-access lifetime and File Provider metadata behavior are
  preserved.
- Packages, hidden entries, and symlinks retain the shared visibility and
  traversal policies.
- Cancellation and generation checks reject stale navigation, projection,
  availability, refresh, and monitor results.
- Existing workspace and saved-search payloads continue decoding.
- Compatibility overloads and legacy decoders are retained unless a separate
  migration proves they are no longer required.
- VoiceOver row count, selection, sort descriptions, focus, and inline rename
  continue to reflect the accepted visible snapshot.

## Error Handling

- Failure to open the destination before the first batch restores the committed
  pane snapshot using the existing navigation failure behavior.
- A per-entry optional metadata failure uses current fallbacks; a structural
  enumeration failure terminates the stream and surfaces the pane error.
- Cancellation finishes without publishing stale partial work.
- A failed off-main projection leaves the last accepted projection visible and
  reports a deterministic internal error in tests; production projection code
  is pure and should not ordinarily throw.
- An invalid table diff falls back to full reload rather than risking mismatched
  rows or selection.
- Refresh failure preserves the prior listing.

## Testing

### Unit tests

- Entry source yields only immediate children and honors hidden/package policy.
- First batch can be emitted without exhausting the 10,000-entry source.
- Metadata keys are collected once per entry through an injected reader.
- Availability concurrency remains within its configured bound.
- Listing, enrichment, and projection generations reject stale results.
- Projection cache hits do not repeat filtering or sorting.
- Query and sort changes produce correct stable order, including Korean names.
- Selection intersection runs against the accepted projection.
- Batch coalescing publishes the first batch immediately and flushes on
  completion, error, and cancellation.
- Table plans cover append, removal, reorder, metadata reload, ambiguous
  identity, and full-reload fallback.
- Selection, scroll anchor, focus, and inline rename survive applicable plans.
- Refresh remains atomic and monitor/navigation races retain the newest intent.

### Integration and performance tests

- A real 10,000-entry local directory reports first-batch and complete times.
- A pane harness records first accepted projection and first table population.
- Repeated filter queries and each sort key remain correct and responsive.
- Cancelling a large listing and immediately navigating elsewhere produces no
  stale rows.
- Refresh failure leaves the old listing visible.
- File Provider doubles prove listing and filtering make zero materialization
  calls.
- Existing navigation, search, Quick Look/folder preview, file-operation,
  archive, protected ZIP, persistence, accessibility, and recovery tests pass.

### Manual verification

- Open and scroll a generated 10,000-entry directory in both panes.
- Type and clear a Korean/English filename filter while loading continues.
- Change every sort key during and after loading.
- Navigate away during loading, return, refresh, and trigger monitor updates.
- Confirm selection, scroll restoration, inline rename, keyboard focus, and
  VoiceOver announcements.
- Repeat relevant listing checks in available Google Drive and OneDrive File
  Provider locations without causing content downloads.

## Delivery Sequence

1. Add measurement records and deterministic test seams without changing
   production behavior.
2. Record and review the baseline.
3. Implement incremental enumeration and consolidated metadata reads.
4. Implement bounded availability enrichment.
5. Implement cached, generation-bound projection publication.
6. Implement first-batch publication, later-batch coalescing, and table update
   planning.
7. Perform touched-path cleanup and responsibility-based file splits.
8. Run the full suite and manual UI/File Provider checks; publish the before and
   after verification report.
9. Perform the separately reviewed repository-wide dead-code audit.

Each step lands only after its focused tests pass. If a step fails its behavior
or safety gates, it is corrected or reverted before the next optimization is
layered on top.

## Acceptance Criteria

- Useful rows appear before complete directory enumeration finishes.
- The 10,000-entry scenario demonstrates the approved relative improvements or
  documents statistically justified revised targets.
- Filtering, sorting, scrolling, navigation cancellation, and refresh remain
  responsive and correct.
- Table updates no longer unconditionally reload all rows for every listing
  batch.
- No stale asynchronous result can replace newer pane intent.
- Listing, filtering, sorting, and preview metadata do not materialize cloud
  file contents.
- Existing persisted data and safety-sensitive file operations remain
  compatible.
- Every deleted declaration has recorded evidence and the full test suite
  passes after cleanup.
- The final verification report separates measured improvements, behavior
  checks, removed code, retained compatibility code, and remaining backlog.
