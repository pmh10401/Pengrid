# File Context Menu Productivity Design

**Date:** 2026-08-11
**Status:** Approved

## Context

Pengrid's file-table context menu already exposes **Open**, folder creation,
favorites, single and batch rename, copy and paste, archive operations, and
Trash. The application also has identity-checked file operations, a serial
Operation Center queue, conservative Undo, cloud-scoped access, and a two-pane
workspace.

Several common right-click actions remain undiscoverable or unavailable. In
particular, Quick Look is keyboard-only in the table, system application
selection and Finder reveal are absent, and the context menu does not use the
opposite pane as a direct destination. Adding unrelated power-user commands
would make the menu longer without strengthening Pengrid's main workflow.

## Goal

Add a hybrid, selection-aware productivity layer that combines Finder-like
actions with Pengrid's two-pane model:

1. Quick Look;
2. Open With;
3. Open in Other Pane;
4. Copy and Move to Other Pane;
5. Show in Finder;
6. Copy Path variants;
7. Duplicate;
8. New Folder with Selection.

The new actions must reuse existing opening, preview, cloud, queue, conflict,
progress, cancellation, recovery, and Undo infrastructure instead of creating
parallel execution paths.

## Non-Goals

- Tags or Finder label editing
- Terminal launch, shell execution, or custom scripts
- Symbolic-link or hard-link creation
- macOS Services or Quick Actions integration
- User-configurable context-menu commands or shortcuts
- Direct Google Drive or OneDrive APIs
- Permanent deletion
- A general menu customization system
- Redesign of existing archive, rename, favorites, or Trash behavior

## Approaches Considered

### Finder parity only

Add Quick Look, Open With, Show in Finder, Copy Path, and Duplicate. This is a
small and familiar change, but it does not capitalize on Pengrid's two-pane
workspace.

### Two-pane productivity

Add Finder-parity actions plus opposite-pane open, copy, and move, and a safe
New Folder with Selection transaction. This creates a coherent workflow while
staying within existing product boundaries. This is the selected approach.

### Power-user command layer

Also add terminal launch, Services, links, and custom commands. This is useful
for a narrower audience but adds security, configuration, sandbox, process,
localization, and menu-complexity concerns. It is deferred.

## Hybrid Menu Model

Core groups retain stable positions. Selection-specific commands are omitted
when they have no meaning; temporarily unavailable commands remain visible but
disabled. The resulting order is:

```text
Open
Quick Look
Open With >                     single file or package
Open in Other Pane              single item
-------------------------------------------
Copy to Other Pane
Move to Other Pane
Show in Finder
Copy Path >
-------------------------------------------
New Folder
New Folder with Selection…      two or more items
Add to Favorites
Duplicate
Rename
Batch Rename…
-------------------------------------------
Copy
Paste
-------------------------------------------
Existing archive actions
-------------------------------------------
Move to Trash…
```

The menu bar exposes Quick Look through its existing command and adds Copy Full
Path and Duplicate with their shortcuts. The remaining new selection actions
also appear in **File Operations** without shortcuts. Both entry points use the
same policy and action router.

## Selection Semantics

- Right-clicking inside the current selection preserves the complete selection.
- Right-clicking an unselected row selects that row before the menu is built.
- Commands consume selected items in stable visible table order.
- An invocation captures source URLs, `FileIdentity` values, active pane ID,
  opposite pane ID, source directory, and the relevant destination directory.
- Invocation does not retain a live dependency on `workspace.activePane`.
  Switching panes or navigating after invocation cannot redirect an operation.
- Operations that mutate or open bytes revalidate captured identities before
  acting. Path-only presentation actions do not materialize file contents.

## Policy

`FileContextMenuPolicy` is a pure projection over the existing
`WorkspaceCommandPolicy`, selected `FileItem` values, pane state, cloud
capability, and whether an exclusive operation or text-editing session is
active.

It determines visibility and enablement for every new item:

- **Quick Look:** one or more selected items, no text editing.
- **Open With:** exactly one regular file or package; hidden for ordinary
  directories and multiple selection. The submenu provider determines whether
  the visible parent is enabled after resolving compatible applications.
- **Open in Other Pane:** exactly one selected item and a valid opposite pane.
- **Copy/Move to Other Pane:** one or more selected items, a captured writable
  opposite directory, and source and destination directories that differ.
- **Show in Finder:** one or more file URLs.
- **Copy Path:** one or more file URLs.
- **Duplicate:** one or more completely captured items and no text editing.
- **New Folder with Selection:** two or more completely captured items in the
  same parent, no text editing, and no exclusive mutation in progress.

The existing `WorkspaceCommandPolicy` remains the shared authority for actions
that it already models. New policy does not weaken current archive, rename,
pasteboard, or Trash gates.

## Captured Action Snapshot

`ContextActionSnapshot` is an immutable, Sendable value containing:

- ordered sources with URL, basename, kind, and `FileIdentity`;
- active and opposite pane IDs;
- captured source and opposite directory URLs and identities;
- cloud location capability needed by the chosen action;
- an invocation generation or request ID for stale UI suppression.

System presentation and mutation routes accept this snapshot rather than
reading current selection or pane state again. Mutation services still perform
their own authoritative filesystem preflight.

## Action Behavior

### Quick Look

- Label: **Quick Look**
- Shortcut: Space, using the existing command route
- Sends the captured stable-order selection to
  `WorkspacePreviewCoordinator`.
- Ordinary folders use Pengrid's folder preview. Files, packages, symbolic
  links, and multiple selections use system Quick Look under existing policy.
- Cloud materialization and stale-request rejection remain owned by the preview
  coordinator.

### Open With

- Label: **Open With** submenu
- Exactly one regular file or package is accepted.
- An injectable application provider obtains compatible applications through
  Launch Services or `NSWorkspace`, caches the result for the exact captured
  file kind, and shows application icon and display name in deterministic
  localized order. An empty result leaves the visible submenu disabled.
- Selecting an application captures its URL, runs the existing identity and
  scoped-access preparation with purpose `.open`, and opens only the validated
  prepared item with that application.
- No app launch occurs after cancellation, preparation failure, source
  replacement, or incompatible application resolution.
- Ordinary directories and multiple selections do not show the submenu.

### Open in Other Pane

- Label: **Open in Other Pane**
- Exactly one item is accepted.
- An ordinary directory navigates the captured opposite pane to that directory.
- A file, package, or symbolic link navigates the opposite pane to the captured
  source parent and selects the exact identity-matched item.
- The route never externally launches the file and does not materialize bytes.
- Navigation failure leaves the opposite pane at its last committed directory.

### Copy and Move to Other Pane

- Labels: **Copy to Other Pane** and **Move to Other Pane**
- One or more items are accepted.
- The destination is the opposite pane directory captured at invocation.
- The destination identity and writability are revalidated before queue
  admission and again before mutation.
- The existing Operation Center, transfer service, conflict policy, progress,
  cancellation, retry, recovery, and Undo paths remain authoritative.
- A same-directory destination is disabled. Users use Duplicate for a
  same-directory copy.
- No initial shortcuts are assigned, avoiding conflicts with macOS and existing
  Pengrid commands.

### Show in Finder

- Label: **Show in Finder**
- One or more selected file URLs are passed together to Finder's reveal API.
- This action validates that each path still has its captured entry identity but
  does not read bytes, materialize cloud content, or follow symbolic links.
- A missing or replaced item is omitted only when at least one other captured
  item remains valid; if none remain, the action reports one bounded error.

### Copy Path

- Parent label: **Copy Path**
- Submenu actions:
  - **Copy Full Path** — Option-Command-C
  - **Copy Name**
  - **Copy Parent Path**
  - **Copy File URL**
- Full paths, names, and file URLs are emitted in captured visible order, one
  value per line.
- Because a pane selection has one parent, Copy Parent Path writes that parent
  once.
- The clipboard receives plain UTF-8 text only for these commands; it does not
  replace the existing file-URL **Copy** operation.
- The completion announcement reports only the value kind and item count, not
  the copied path.

### Duplicate

- Label: **Duplicate**
- Shortcut: Command-D
- One or more items are accepted and queued as one operation job.
- Each destination uses Pengrid's existing extension-preserving keep-both name
  planner and exclusive no-overwrite publication.
- Source identity and fingerprint are revalidated around byte-dependent copy.
- Symbolic links are duplicated as links, not followed. Packages remain opaque
  package entries.
- Per-item progress and outcomes remain in stable source order. Successful
  duplicates are selected after the pane refresh.
- Undo removes only unchanged duplicates whose final identities and fingerprints
  still match the operation result.

### New Folder with Selection

- Label: **New Folder with Selection (N Items)…**
- Two or more selected sibling entries are accepted.
- A sheet requests the destination folder name and starts with
  **New Folder with Items**.
- The name is trimmed and validated through `FilenameValidator`. Empty, `.`,
  `..`, slash, NUL, and sibling collisions prevent submission.
- Submission creates the folder with an exclusive, identity-capturing operation,
  then moves selected entries into it sequentially using no-overwrite,
  identity-checked moves.
- On cancellation or failure, moved entries return to the original parent in
  reverse order. The created folder is removed only if Pengrid still owns its
  identity and it is empty.
- An incomplete rollback becomes **Recovery Needed** and preserves every
  recoverable item without adopting or overwriting external entries.
- Success selects the new folder. Undo first verifies the folder, every child,
  and every original destination, then moves the children back and removes the
  empty owned folder. If any precondition fails, Undo performs no mutation.

## Architecture and Components

- `Models/ContextActionModels.swift`: immutable action snapshot and action kinds
- `Support/FileContextMenuPolicy.swift`: pure visibility and enablement policy
- `Support/FileContextActionRouter.swift`: system, preview, navigation, and
  pasteboard routing from captured snapshots
- `Services/SelectionFolderTransactionService.swift`: exclusive folder
  creation, child moves, rollback, and reverse transaction
- `Stores/FileOperationController.swift`: queue jobs for opposite-pane transfer,
  Duplicate, and New Folder with Selection
- `Support/WorkspaceCommands.swift`: menu-bar entry points and shared policy
- `Views/AppKit/FileTableView.swift`: ordered context-menu construction,
  accessibility identifiers, and callback dispatch
- `Views/FilePaneView.swift`: captures pane-specific dependencies and routes
  actions without duplicating business rules

Small system-action adapters are injectable protocols so application discovery,
Finder reveal, and pasteboard writes can be tested without launching apps or
Finder. Existing preview, open, transfer, cloud, and operation services remain
the single authority for their domains.

## Failure, Cancellation, and Recovery

- Policy is predictive; service-level identity and no-overwrite checks are
  authoritative.
- A source or destination replacement fails closed before external open or
  mutation.
- Opposite-pane navigation changes after invocation do not redirect queued
  work.
- Cloud permission denial is attempted once and does not trigger a prompt loop.
- Open With and Quick Look suppress stale completion after cancellation or a
  newer request.
- Transfer and Duplicate use existing per-item outcomes. New Folder with
  Selection is transactional because partial enclosure is not an acceptable
  successful state.
- User-facing errors use basenames, counts, and actionable guidance. Operation
  logs and accessibility announcements do not expose unrelated absolute parent
  paths.

## Cloud and File Provider Boundaries

- Quick Look and Open With may materialize bytes through existing services only
  after scoped access and identity capture.
- Open in Other Pane, Show in Finder, and Copy Path never intentionally
  materialize bytes.
- Opposite-pane Copy, Move, Duplicate, and New Folder with Selection require
  the location's advertised local-file-operation capability and current live
  writability.
- Unknown or read-only capability disables mutation. Direct OAuth and provider
  APIs remain out of scope.

## Accessibility and Keyboard Behavior

- Every new menu item and submenu has a stable accessibility identifier.
- Menu labels use action-first wording and dynamic item counts only where the
  count changes the action's meaning.
- Quick Look retains Space, Copy Full Path uses Option-Command-C, and Duplicate
  uses Command-D. No initial shortcuts are assigned to opposite-pane mutation.
- Full Keyboard Access can reach the same menu-bar actions when a shortcut is
  defined.
- VoiceOver announces whether the destination is the other pane, the number of
  selected items, disabled reasons where AppKit permits, progress phases, and
  terminal outcomes without reading full parent paths.
- Menu rebuilding does not steal table focus or discard a preserved multi-row
  selection.

## Testing

### Policy and menu tests

- visibility and enablement matrices for empty, single, multiple, directory,
  file, package, symbolic-link, editing, running-operation, same-destination,
  read-only, unknown, and writable selections;
- stable group order, separators, submenu order, titles, identifiers, and
  shortcuts;
- right-click inside versus outside the existing selection;
- AppKit menu and menu-bar routes derive from the same policy.

### Snapshot and routing tests

- stable visible-order capture and exact source identities;
- active-pane switch and opposite-pane navigation after invocation cannot
  redirect an action;
- source and destination replacement rejection;
- Quick Look routes through the existing coordinator;
- Open With compatible-app ordering, selected-app capture, materialization,
  cancellation, and no-launch failure paths;
- other-pane folder navigation and file parent-and-selection behavior;
- Finder reveal and every path-copy representation without byte reads.

### Mutation tests

- Copy and Move to Other Pane queue the captured destination and reuse conflict,
  cancellation, retry, recovery, and Undo behavior;
- Duplicate handles files, directories, packages, symbolic links, collisions,
  source mutation, partial failure, stable outcomes, and conservative Undo;
- New Folder with Selection validates names, creates exclusively, moves in
  order, cancels before and during mutation, rolls back completely, escalates
  blocked rollback, selects on success, and performs all-or-nothing Undo;
- File Provider scoped-access balance, read-only refusal, and one-shot denial.

### Performance and manual checks

- Context-menu construction and policy evaluation stay within one event-loop
  turn for a 10,000-row pane and do not perform content reads.
- The complete Swift package suite and `script/build_and_run.sh --verify` remain
  automated release gates.
- Manual verification covers menu icons and ordering, keyboard navigation,
  VoiceOver reading order, Finder reveal, compatible app launch, and live
  OneDrive opposite-pane operations.

## Delivery Order

1. Shared policy, snapshot capture, Quick Look, Show in Finder, and Copy Path
2. Open With and Open in Other Pane
3. Opposite-pane Copy and Move
4. Duplicate
5. New Folder with Selection transaction and Undo
6. Documentation, full verification, and manual provider/accessibility matrix

Each stage must keep existing context-menu actions and the complete test suite
green. No stage is published as complete while its required safety or manual
claims remain unverified.
