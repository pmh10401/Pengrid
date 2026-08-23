# Command Palette, Empty File, and Advanced Selection Design

**Date:** 2026-08-23
**Status:** Approved under the standing implementation direction

## Context

Pengrid already provides a two-pane workspace, tabs and profiles, favorites,
saved Smart Searches, Hangul-initial search, identity-checked file mutations,
an Operation Center, and conservative Undo/Redo. Three common desktop file
manager workflows are still needlessly indirect:

1. there is no safe **New Empty File** command;
2. a user cannot invert the current visible selection or select sibling files
   with the same extension;
3. navigation and existing commands are spread across menus, the places rail,
   profiles, saved searches, and pane history rather than being available from
   one keyboard-first launcher.

The behavior is inspired by public macOS file managers without copying their
code: Nimble Commander exposes new-file and advanced-selection workflows, while
Shuffle and F2 Commander use a Command-P quick launcher. Pengrid will retain its
own architecture, naming, safety model, and implementation.

## Goal

Add one coherent, medium-or-lower complexity productivity batch:

- **New Empty File** creates an exclusive regular file, selects it, and begins
  inline rename. The operation is queued, recorded, and undoable only while the
  exact created entry remains unchanged.
- **Advanced Selection** operates only on the active pane's currently visible
  rows: Select All Visible, Invert Selection, and Select Same Extension.
- **Quick Go / Command Palette** opens with Command-P and searches existing
  commands, pane history, favorites, workspace profiles, and saved searches.
  It supports Pengrid's existing Hangul-initial matching as well as normalized
  substring and subsequence matching.

## Non-Goals

- Finder tag editing or tag mutation Undo
- recursive archive-as-folder browsing
- terminal, shell, script, plugin, or arbitrary executable launch
- byte-level transfer verification, File Provider upload verification, or
  directory-content hashing
- a user-editable command registry or custom shortcuts
- background indexing or another search database
- new cloud OAuth flows
- changes to ordinary file opening, Quick Look, or rename semantics

The SHA-256 transfer-verification idea remains worthwhile, but its settings,
staging, progress, retry, and history requirements make it a separate safety
feature rather than part of this UI-focused batch.

## Approaches Considered

### Add only menu commands

This is the smallest change, but it leaves navigation fragmented and does not
provide the keyboard-first workflow demonstrated by the public projects.

### Build a general command framework

A fully extensible command registry could later support plugins and custom
actions. It would add persistence, permissions, shortcut conflicts, arbitrary
execution risks, and a larger public API before there is a demonstrated need.

### Add a closed, typed palette plus two focused file workflows

This is the selected approach. A typed action enum prevents arbitrary launch,
the candidate list is rebuilt from existing in-memory state when presented,
and every mutation continues through Pengrid's established operation path.

## New Empty File

### User behavior

- **File > New Empty File** uses Option-Command-N.
- The Command Palette also exposes the action.
- The proposed basename is `New File`; `KeepBothNamer` chooses a non-colliding
  sibling name.
- A successful operation refreshes the pane, selects the created row, and
  starts inline rename with the already captured `FileIdentity`.
- Failure or cancellation does not start rename and appears in the existing
  operation result UI.

### Mutation boundary

`FileOperationService.createFile(in:identifiedBy:named:)` will:

1. acquire scoped access to the parent;
2. validate the requested filename;
3. use the already captured parent identity;
4. call `FileSystemAccess.createEmptyItemAndCaptureIdentity` with
   `.regularFile`, which uses `openat` with `O_EXCL` and `O_NOFOLLOW`;
5. close the returned descriptor exactly once;
6. confirm the published path still has the captured identity;
7. capture a `SourceFingerprint` for Undo; and
8. log only bounded operation metadata.

The service never overwrites an existing entry and never follows a destination
symbolic link. `FileOperationController.createFile` mirrors the existing safe
folder-creation route and publishes identity and fingerprint metadata in its
`FileOperationResult`.

`FileOperationJobKind.createFile` and `FileOperationKind.createFile` keep the
Operation Center and telemetry labels truthful. Undo treats Create File like
Copy, Duplicate, and Create Folder: it removes the created entry only when both
identity and fingerprint still match. A modified or replaced file is left in
place and Undo is unavailable.

## Advanced Selection

`PaneSelectionActions` is a pure model over `FileItem` values and URLs. The
active `FilePaneState` applies its result and requests table focus; the AppKit
table continues to receive selection through its existing binding.

### Semantics

- **Select All Visible** selects each URL in `visibleItems`.
- **Invert Selection** returns visible URLs that are not currently selected.
  Selected URLs outside the visible projection are dropped.
- **Select Same Extension** is available only when exactly one visible regular
  file is selected and its `pathExtension` is non-empty. It selects visible
  regular files whose extension matches case- and diacritic-insensitively.
- Directories, packages represented as directories, dotfiles without an actual
  extension, and extensionless files are not extension anchors.
- The three commands are disabled while pane filtering is active because the
  current filter implementation intentionally restores the pre-filter
  selection when dismissed. This avoids presenting a selection that silently
  disappears later.
- Commands are disabled during text editing and when no focused workspace is
  available.

The menu labels live in the Edit command group. Nonstandard shortcuts avoid
intercepting the system Select All route used by text fields:

- Select All Visible: Option-Command-A
- Invert Selection: Option-Command-I
- Select Same Extension: Option-Command-E

## Quick Go / Command Palette

### Typed model

`CommandPaletteAction` is a closed, `Sendable` enum. Initial cases are:

- create folder;
- create empty file;
- focus the pane filter;
- present Smart Search;
- navigate the active pane to a captured URL;
- open a captured workspace profile ID; and
- open a captured saved-search ID.

There is no closure, shell string, executable URL, or dynamically decoded
action in a palette item.

`CommandPaletteItem` has a stable string ID derived from the action namespace
and stable source identity, a title, optional subtitle, category, keywords, and
the typed action. IDs are created by the builder, never inside a SwiftUI row.

### Candidate sources

The builder takes a presentation-time snapshot from:

- fixed safe commands;
- active pane current directory, backward history, and forward history;
- available favorites resolved through `FavoritesStore`;
- `WorkspaceSessionState.profiles`; and
- `SmartSearchStore.savedSearches`.

Standardized file paths are deduplicated while preserving source priority and
stable order. No filesystem crawl, Spotlight query, or cloud materialization is
started merely by opening the palette.

### Matching

`CommandPaletteMatcher` folds case, width, and diacritics. It ranks, in order:

1. exact title;
2. title prefix;
3. title substring;
4. existing `SmartSearchTextAnalyzer` match, including Hangul initials;
5. keyword/subtitle substring; and
6. ordered subsequence match.

Ties preserve original candidate order, then stable ID. Filtering and sorting
occur in the store, not inline inside `ForEach`.

### Store and execution lifecycle

`CommandPaletteStore` owns presentation, query, filtered results, selected ID,
and at most one pending action. Presentation resets stale query and action
state. Requesting execution records one typed action and dismisses the sheet.
The workspace consumes that action only from the sheet's `onDismiss`, ensuring
that an action which opens another sheet or tab does not race the palette
sheet. Cancellation clears the pending action.

The action is routed against the same active workspace snapshot that owned the
modal; tab switching is prohibited while the palette is open. Navigation and
file creation still call their established store/controller APIs.

## Modal Ownership and Focus

`WorkspaceView` owns the sheet and includes it in
`WorkspaceTabModalPolicy`. The Command-P menu item is fail-closed while another
modal or a text-editing session is active. Existing modal bindings also reject
presentation while the palette is active. Workspace teardown dismisses the
palette and clears pending execution.

`CommandPaletteView` uses a private `@FocusState`, a labelled `TextField`, a
stable-selection `List`, real `Button` rows, Return to execute, and Escape to
cancel. The search field is the default focus. Empty search results use
`ContentUnavailableView.search`. The row accessibility label combines the
title and category; the full local path is not placed in its VoiceOver value.
After dismissal without opening another modal, the active file table regains
focus.

## Error and Privacy Behavior

- Missing favorites are omitted from the current palette snapshot rather than
  exposing stale paths as actionable entries.
- A profile or saved search deleted after presentation is ignored safely by ID.
- Navigation and mutation errors remain owned by existing stores and operation
  results.
- Palette UI may visually show a shortened location subtitle to disambiguate
  identical basenames, but logs and accessibility status never publish a full
  path.
- Search query text is transient and is not persisted or logged.

## Verification

The implementation must start with failing Swift Testing cases for:

- visible-only selection, filter policy, extension edge cases, and focus;
- exclusive empty-file creation, collisions, parent replacement, descriptor
  closure, result metadata, inline rename, and conservative Undo;
- palette stable IDs, deduplication, ranking, Hangul initials, store lifecycle,
  one-shot action consumption, modal exclusion, and typed action routing;
- accessibility identifiers and privacy-safe presentation; and
- retention of existing folder creation, rename, selection binding, tab, Smart
  Search, and Operation Center behavior.

Focused tests run first, followed by the full `BloomFileManagerTests` suite and
a release build using the full Xcode toolchain with parallel test execution
disabled.
