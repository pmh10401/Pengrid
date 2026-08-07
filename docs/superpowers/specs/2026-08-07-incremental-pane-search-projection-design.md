# Incremental Pane Search Projection Design

**Date:** 2026-08-07
**Status:** Approved
**Scope:** Pengrid pane filename filtering during interactive typing

## Context

The large-directory navigation work materially improved initial listing and
table publication, but it did not materially change the direct filename-filter
or sort algorithms. For 10,000 items, the current filter still calls
`localizedStandardContains` for every item, and each query projection sorts the
filtered result again. Rapid query changes reject stale publication, but an
unstructured detached worker can continue spending CPU after its result has
become obsolete.

The next optimization targets user-visible typing responsiveness. It does not
reclassify the existing direct single-query filter/sort performance gate as a
pass.

## Goals

- Reduce `key event -> accepted projection -> table apply` latency for English
  and Korean typing sequences in a 10,000-entry pane.
- Stop obsolete projection work cooperatively instead of only rejecting its
  publication.
- Preserve the exact results and ordering produced by the current
  `localizedStandardContains` and `FileSort` behavior.
- Preserve selection, inline rename, scroll restoration, keyboard focus,
  accessibility presentation, persistence, and generation safety.
- Use only already-loaded `FileItem` metadata. Listing and filtering must not
  materialize File Provider contents.
- Bound additional memory to no more than 10 percent peak-RSS regression in the
  approved fixture.

## Non-goals

- Changing pane search semantics or adding new Korean initial-consonant rules.
- Replacing localized comparison with folded or ASCII-only search keys.
- Caching several directories or several sort orders.
- Adding a persistent filesystem index or an external dependency.
- Enabling incremental AppKit structural updates by default.
- Treating debounce as an optimization before measurements show it is needed.

## Architecture

### Active order snapshot

For one current directory, item revision, and active `FileSort`, Pengrid keeps
one `ActiveOrderSnapshot` containing the fully ordered `FileItem` array. It is
created off the main actor when the raw item revision or active sort changes.
It is invalidated immediately when the directory identity, item revision, or
sort changes.

Filtering an already ordered array preserves the required order, so query edits
do not sort again. The empty query publishes the ordered array directly.

Sort changes use a cardinality-safe two-phase path. Pengrid immediately sorts
the accepted visible membership only when the accepted aggregate's directory,
item revision, and normalized query exactly match the current request. Otherwise
it runs the current full filter-then-sort fallback. Immediate subset publication
sets active order and accepted search seed unavailable for the new sort until a
matching warm-up is accepted.

After the exact visible result is published, Pengrid builds the full replacement
active order in a separate generation-bound warm-up task. The warm-up never
delays the visible sort change, never publishes rows, and is cancelled by a
newer query, sort, revision, or navigation. If a query arrives before warm-up is
accepted, that query uses the current exact filter-then-sort fallback instead of
waiting. After the fallback result is accepted, Pengrid starts a replacement
warm-up for the latest matching directory, revision, and sort unless a matching
active order has already been accepted. When the query is empty, the required
full sort directly becomes the new active order.

The conceptual state is:

```swift
struct ActiveOrderSnapshot: Sendable {
    let directoryKey: String
    let itemsRevision: UInt64
    let sort: FileSort
    let orderedItems: [FileItem]
    let asciiLiteralSafePositions: [Int]
    let localizedFallbackPositions: [Int]
}
```

### Accepted search snapshot

The last accepted query for the active order stores positions into
`orderedItems`, rather than a second independent copy of the raw directory
listing:

```swift
struct AcceptedSearchSnapshot: Sendable {
    let directoryKey: String
    let itemsRevision: UInt64
    let sort: FileSort
    let normalizedQuery: String
    let matchedASCIIPositions: [Int]
    let matchedLocalizedPositions: [Int]
}
```

If the new normalized query appends exactly one ASCII alphanumeric scalar to the
last accepted ASCII query, and the directory revision and sort are unchanged,
only previously matched ASCII-safe filename positions are narrowed. Every
non-ASCII or otherwise unsafe filename position is still rescanned. Backspace,
multi-scalar changes, empty-query changes, revision changes, sort changes, and
non-ASCII changes, including Korean IME marked or committed text, scan the full
active-order snapshot.

Every retained candidate is tested with the existing
`localizedStandardContains`; the optimization does not substitute a folded
search key.

### Accepted pane projection state

The worker returns an immutable result containing visible items, URL and entry
path indexes, the active-order identity, the accepted query snapshot, and the
request generation. It never mutates main-actor pane state.

Projection-owned observable fields are stored in one aggregate:

```swift
struct AcceptedPaneProjectionState: Sendable {
    let visibleItems: [FileItem]
    let indexByURL: [URL: Int]
    let urlByEntryPath: [String: URL]
    let selection: Set<URL>
    let activeOrder: ActiveOrderSnapshot?
    let search: AcceptedSearchSnapshot?
}
```

The main actor computes the selection intersection, constructs this complete
value, and publishes it with one stored-property assignment. Existing pane APIs
remain source-compatible through derived read-only accessors. In particular,
`selection` remains a computed get/set property; its setter replaces the stored
aggregate in one assignment and reruns the existing pending-rename identity
validation. A failed, cancelled, or stale computation leaves the prior
aggregate visible.

## Request and cancellation model

Each request captures:

- standardized directory identity;
- raw item revision;
- active sort;
- normalized query;
- navigation generation; and
- projection generation.

`ProjectionWork` explicitly owns both the main-actor publication task and the
detached-worker handle. `cancel()` calls both handles. Worker, filtering, and
index-building APIs are `async throws`; `CancellationError` propagates from
bounded `Task.checkCancellation()` calls, initially every 128 items. The
implementation must not use an unowned `await Task.detached { ... }.value`.
The chunk size is an implementation constant covered by cancellation tests and
may be tuned only from measurements.

The optional active-order warm-up has its own owned task handle and generation.
It obeys the same cancellation and zero-retention rules as visible projection
work. At most one current non-cancelled visible worker and one current
non-cancelled warm-up worker may exist. Cancelled workers may finish one final
bounded chunk and are counted separately in lifecycle and RSS measurements.

Swift's standard sort is not cooperatively cancellable. It runs only when the
active order must change, checks cancellation before and after sorting, and is
still protected by the final generation check. Ordinary query typing does not
invoke sort.

The main actor accepts a result only when all captured directory, revision,
sort, navigation-generation, and projection-generation values still match.
Cancellation is not presented as a user error.

## Search-equivalence policy

`localizedStandardContains` is not globally monotonic under query extension.
For example, `"ß"` does not match `"s"` but does match `"ss"`, and `"⑫"`
does not match `"1"` but does match `"12"`. Decomposed Hangul jamo has similar
composition cases. A query-only allowlist is therefore insufficient.

The active order partitions filenames once per revision:

- `asciiLiteralSafePositions`: every filename scalar is printable ASCII
  `U+0020...U+007E`;
- `localizedFallbackPositions`: every other filename, including Hangul,
  ligatures, circled digits, full-width forms, accents, and emoji.

Candidate narrowing is enabled only when the old and new trimmed queries are
ASCII alphanumeric, the new query appends exactly one scalar, and directory,
revision, and sort are unchanged. In that case, the worker narrows the prior
matched ASCII-safe positions but rescans *all* localized-fallback positions.
The two ordered result-position streams are merged by position before visible
items and indexes are built.

Every other string-observable transition uses a full active-order scan. The
current input boundary exposes only `String`, so the design does not claim to
distinguish typing from a one-character paste. A one-scalar ASCII-alphanumeric
paste follows the same safe path as typing. Multi-scalar changes and all
non-ASCII changes, including marked/committed Korean IME text, are always full
scans. `PaneFilenameFilter.normalize` remains whitespace trimming only; NFC is
never substituted into the exact predicate.

The equivalence corpus covers ASCII case and punctuation, composed and
decomposed Hangul, Korean syllables and jamo, Latin case, `ß`, ligatures,
circled digits, accents, full-width text, whitespace normalization, emoji, and
mixed-script filenames. It contains the non-monotonic counterexamples and
asserts that unsafe filename/query paths are rescanned. Randomized property
tests compare matched item identities and order with the current full-scan
oracle.

Expanding the ASCII-safe partition is a separate evidence-backed change, not an
incidental implementation tweak.

The active-order shortcut also requires unique standardized URL/path sort
tie-break identities. Malformed injected input with duplicate final tie-break
identities uses the current filter-then-sort fallback so subset sorting cannot
change an otherwise-equal row order.

## Memory policy

Accepted cache state is bounded to one active-order array, its two position
partitions, and two matched-position arrays for the visible pane. It is never
persisted and is released on directory, revision, or sort replacement.

The memory gate includes raw items, accepted visible result buffers, active
order and position arrays, the current worker, and any cancelled worker still
finishing its final chunk. The twenty-query burst must demonstrate through a
worker-lifecycle test hook that, after the burst drains, there are zero cancelled
workers and zero retained worker snapshots or result buffers.

Peak RSS is measured separately from aggregate test-suite RSS. If the approved
10,000-entry scenario regresses by more than 10 percent, the active-order cache
does not ship; cooperative cancellation and candidate narrowing are evaluated
without retaining the extra ordered snapshot.

## Data flow

```text
raw listing revision or empty-query sort change
    -> build one off-main active order
    -> full exact filter for current query
    -> build visible indexes
    -> generation-check and publish atomically

accepted non-empty-query warm-up
    -> generation-check directory/revision/sort
    -> replace only active-order metadata in the accepted aggregate
    -> retain visible items, indexes, and selection without row publication
    -> leave search seed unavailable until the next exact full scan

sort changes while a non-empty query is visible
    -> immediately sort and publish only current matched items
    -> start a cancellable full active-order warm-up without publishing rows
    -> accept only matching directory/revision/sort generation

eligible one-ASCII-scalar query extension
    -> narrow prior matched ASCII-safe positions
    -> rescan every localized-fallback position
    -> merge result positions in active order
    -> keep active-order sequence; do not sort
    -> build visible indexes
    -> generation-check and publish atomically

backspace / multi-scalar replacement / non-ASCII / empty query
    -> filter the full active order
    -> build visible indexes
    -> generation-check and publish atomically
```

## Performance evidence and acceptance

The existing independent single-query and single-sort measurements remain in
place. A new interactive trace measures the user-selected goal.

Required traces include:

- numeric: `"" -> "1" -> "19" -> "199" -> "1999"`, with fixed expected
  counts `3,439`, `299`, `20`, and `1` in the 10,000-item fixture;
- English: `"" -> "r" -> "re" -> "rep" -> "report"` (narrow the ASCII-safe
  partition and rescan every localized-fallback position);
- Korean: `"" -> "보" -> "보고" -> "보고서"`;
- reverse deletion to the empty query;
- replacement, paste, and whitespace normalization; and
- a rapid twenty-query burst where only the newest generation may publish.

Both the legacy baseline and candidate use the same fixture, device, release
build, three unrecorded warm-ups, and at least 30 recorded samples. Each trace
records median and nearest-rank p95 for:

- the existing `FilePaneView` filter-binding setter entry to the accepted
  aggregate assignment;
- accepted projection to table application;
- the filter-binding setter entry to `FileTableView.Coordinator.apply`
  completion;
- candidate visits performed by cancelled work; and
- scenario peak RSS in isolated processes.

Per-event p95 is calculated for each query transition. Complete-trace p95 is
the distribution of elapsed time from dispatching the first trace event until
the final query's table application completes.

### Hard acceptance gates

The change is accepted only when all hard gates pass:

- every ready-order query transition in the numeric, English, and Korean traces
  applies the newest 10,000-entry result within 50 milliseconds p95; the harness
  asserts that the matching active order was accepted before each measurement;
- cancelled work processes no candidates beyond the next bounded chunk and
  never publishes stale state;
- first-query, backspace, multi-scalar paste, and complete-load time regress by
  no more than 10 percent;
- for every `FileSortKey` and ascending/descending direction, sort-change p95
  regresses by no more than 10 percent for the fixed empty and numeric fixture
  cardinalities: empty `10,000`, broad `3,439`, medium `299`, narrow `20`, and
  one-result `1`; eligible non-empty cases must use the immediate subset-sort
  path and must not wait for full-order warm-up;
- peak RSS regresses by no more than 10 percent; and
- all visible identities and ordering equal the full filter/sort oracle.

### Aspirational targets

The initial performance ambitions remain visible but are not release-blocking
until paired measurements demonstrate that they are stable across workloads:

- every post-first-character step improves p95 by at least 30 percent; and
- the complete typing trace improves p95 by at least 40 percent.

Results are reported for every required trace and active sort key; no average or
selected trace may hide a slower case. These targets may be promoted to hard
gates only after the same-device, same-build 30-sample baseline and candidate
distributions meet them without violating a hard gate.

The existing direct single-query and sort 30-percent gate continues to be
reported independently. This project cannot turn that older miss into a pass by
changing the workload definition.

## Test strategy

### Pure tests

- Active-order filtering exactly matches the current production oracle,
  `FileSort.apply(to: PaneFilenameFilter.apply(to: rawItems))`, for every query,
  key, and direction.
- Candidate narrowing matches the full oracle for the complete equivalence
  corpus and randomized cases.
- Backspace, multi-scalar paste or replacement, revision, sort, and directory
  changes choose the full-scan path. A one-scalar ASCII-alphanumeric paste is
  intentionally indistinguishable from typing and follows the eligible path.
- Duplicate standardized URLs and entry paths retain the existing deterministic
  last-wins index behavior. Duplicate final sort-tie identities explicitly take
  the fallback and equal
  `FileSort.apply(to: PaneFilenameFilter.apply(to: rawItems))`.

### Concurrency tests

- A controlled worker proves cancellation reaches the detached computation.
- The worker-lifecycle hook reports zero cancelled workers and zero retained
  worker snapshots/results after the rapid burst drains.
- A controlled warm-up proves sort changes publish the exact subset immediately,
  warm-up never publishes rows, and newer query/sort/revision/navigation work
  cancels and releases it.
- A sort change while a newer query projection is still in flight rejects stale
  membership, uses the full oracle fallback, and never subset-sorts old rows.
- A query that cancels warm-up uses the exact fallback and starts one replacement
  warm-up only after that fallback is accepted.
- A late older query, sort, listing revision, refresh, and navigation result
  cannot publish.
- A cancelled worker stops by the next chunk boundary.
- Projection failure and cancellation retain the prior raw and visible state,
  indexes, and selection.

### Integration tests

- Both panes retain independent revisions, sorts, queries, and histories.
- Selection and inline rename are retained only when their standardized
  identities remain visible; otherwise selection is cleared and pending rename
  is cancelled. Scroll anchor is restored only when its identity remains
  visible. The filter field keeps keyboard focus and its existing accessibility
  identifiers, labels, and values.
- AppKit applies only the newest result and keeps the measured safe structural
  fallback.
- Sort-change tests cover empty, broad, medium, narrow, and one-result queries;
  the subset result equals the current oracle while full-order warm-up remains
  off the visible critical path.
- Google Drive and OneDrive doubles observe metadata-only filtering with no
  materialization dependency or call.
- Workspace and saved-search compatibility bytes continue decoding unchanged.

### Manual gates

Before release, repeat English and Korean typing, sort changes, cancellation,
selection, scroll restoration, inline rename, keyboard focus, and spoken
VoiceOver checks in both panes. Repeat the in-app metadata-only flow against
available Google Drive and OneDrive File Provider roots and verify no download
begins. Automated tests do not replace these manual release gates.

## Stop/go decisions

1. If the ASCII-safe partition fails exact equivalence, disable candidate
   narrowing entirely and use the full-active-order scan.
2. If the active-order snapshot exceeds the 10-percent RSS gate, remove that
   cache and remeasure the narrower design.
3. If the interactive trace misses the aspirational 30/40-percent targets but
   hard gates pass, report the miss without adding debounce automatically;
   instrument table publication and worker CPU before proposing another design.
4. If automatic tests pass but manual UI, VoiceOver, or File Provider checks are
   incomplete, the feature remains not release-ready.

## Expected code boundaries

Likely production changes are limited to the pane filtering/projection path:

- `PaneFilenameFilter.swift` for the exact candidate-filtering primitive;
- `PaneItemProjection.swift` for active-order and accepted-search snapshots;
- `FilePaneState.swift` for lifecycle, cancellation propagation, and atomic
  publication; and
- a narrowly scoped internal worker/protocol only if deterministic cancellation
  testing requires it.

Expected test changes are limited to filename-filter, projection, pane-state,
performance, AppKit lifecycle, accessibility, and cloud scoped-access suites.
File operations, Undo/recovery, archive/protected-ZIP, persistence formats, and
public cloud-operation APIs are outside this implementation scope.
