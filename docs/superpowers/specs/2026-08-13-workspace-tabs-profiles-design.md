# Workspace Tabs and Profiles Design

Date: 2026-08-13
Status: Approved for implementation by explicit user request

## Objective

Let users keep several independent dual-pane workspaces open as tabs and save a
left/right folder pair as a reusable named profile. Restore open tabs and the active
tab on relaunch without persisting volatile UI or operation authority.

## Runtime ownership

`WorkspaceState` remains one dual-pane runtime. It does not recursively own other
workspaces. A new `WorkspaceSessionState` owns ordered tab runtimes, the active tab ID,
and named profiles. `WorkspaceRuntimeFactory` creates each child with fresh listing and
monitor dependencies while all file-operation, cloud, preview, comparison, and storage
services remain application-owned.

Each tab has a stable `WorkspaceTabID`, two paths, independent sorts, split ratio,
active pane, pane history, filter, selection, and scroll state. Only paths, sorts, split
ratio, and active-pane ID are persisted. Selection, filters, history, previews,
comparison rows, Storage Inspector state, pending dialogs, operation queues, and
Undo/Redo recipes are process-local and are not serialized.

## Profiles

A `WorkspaceProfile` is a named immutable dual-pane descriptor. Saving a profile
captures the active tab's committed left/right paths, sorts, and split ratio. Opening a
profile creates a new tab; it never mutates an existing tab silently. Rename and delete
change the profile record only. Duplicate names are rejected after trimmed,
case-insensitive comparison. Paths are shown to the user because folder-pair selection
is the feature's purpose.

## Persistence and migration

`workspace.session.v2` stores a versioned envelope containing ordered tab descriptors,
the active tab ID, and profiles. Loading prefers v2. If it is absent, valid
`workspace.snapshot.v1` data migrates to one active tab; otherwise Home/Downloads form
the first tab. Every pane path is validated independently through the current directory
restore policy. Malformed tabs are repaired per pane, unknown active IDs fall back to
the first valid tab, and an empty tab list is repaired to one default tab.

The v1 record is not deleted. A v2 write is encoded completely before replacing the
UserDefaults value. Child workspaces report committed descriptor changes to the session
owner; a debounced save coalesces navigation, sort, and divider changes. Application
termination flushes every child divider debounce and the session envelope.

## Lifecycle and safety

- New Tab duplicates the active tab's descriptor but starts with empty selection and
  history.
- Close Tab selects the next tab, or the previous tab when closing the last position.
- The last remaining tab cannot be closed; Close Tab resets it to the default descriptor
  only through an explicit separate command, not implicitly.
- A tab cannot close while a running or queued file operation is bound to its runtime.
- Switching or closing stops comparison, Storage Inspector, Smart Search presentation,
  folder/system preview, pending synchronization review, inline editing, and pending
  trash confirmation associated with the departing tab.
- Get Info may remain open because its request is an immutable captured snapshot.
- Closing a tab invalidates transient reversal entries bound to that runtime.

## Presentation

A compact keyboard-accessible tab bar appears above the dual-pane split. It shows a
privacy-safe title derived from both folder basenames, an active state, a close button,
and a New Tab button. The Window menu provides New Tab, Close Tab, Next Tab, Previous
Tab, Save Workspace as Profile, and Open Profile. Profile management supports rename
and delete.

Shortcuts:

- New Tab: Command-T
- Close Tab: Command-W when no modal/editor owns it
- Next Tab: Control-Tab
- Previous Tab: Control-Shift-Tab

## Excluded

- Reopening tabs in separate windows.
- Persisting navigation history, selection, search text, operation history, Undo/Redo,
  preview, comparison, or Storage Inspector state.
- Per-profile cloud credentials or direct OAuth accounts.
- Automatic profile updates when a tab later navigates.

## Verification

Model and migration tests cover stable IDs, v1 migration, malformed v2, independent
pane repair, ordering, and profile validation. Session tests prove tab isolation,
snapshot routing, close gating, and deterministic selection. UI tests cover shortcuts,
accessibility, switching teardown, and relaunch restoration. The full Swift suite,
release build, and bundle verification remain final gates.
