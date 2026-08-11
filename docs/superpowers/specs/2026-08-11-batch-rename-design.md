# Batch Rename Design

**Date:** 2026-08-11  
**Status:** Approved

## Context

Pengrid supports identity-checked single-item rename, operation history, conservative Undo, cloud-scoped access, and fail-closed file mutations. It does not provide a safe way to rename several selected items with one rule.

Batch rename must preserve those safety properties. A simple loop is insufficient because valid plans can exchange names (`A` to `B`, `B` to `A`), a later failure can otherwise leave a partially renamed directory, and the directory can change between preview and execution.

## Goal

Allow users to preview and safely rename two or more explicitly selected items in the active pane using one of three common rule families:

1. literal find and replace;
2. prefix and suffix;
3. base name and sequence number.

## Non-Goals

- Recursive rename of children inside selected folders
- Regular-expression replacement
- Date, case-conversion, or metadata-derived rules
- Direct or implicit extension changes
- Permanent overwrite of an existing entry
- Parallel filesystem mutation
- Direct Google Drive or OneDrive API calls

## Approaches Considered

### Independent sequential rename

Rename each item directly to its final name. This is small, but name exchanges and cycles fail, and a later error leaves a partial result that is difficult to explain or undo.

### Parallel rename

Run several final renames concurrently. The work occurs in one directory namespace, so concurrency adds collision races and rollback complexity with little practical speed benefit.

### Two-phase safe rename

Validate the complete plan, move each selected entry to a unique temporary name in the same directory, then publish every temporary entry to its final name. This handles exchanges and cycles, supports deterministic rollback, and matches Pengrid's safe-operation model. This is the selected approach.

## Scope and Selection Capture

- Batch rename is enabled for at least two selected items in the active pane.
- The selected items themselves are renamed. Selecting a directory does not include any child.
- Every selected item has the active pane's current directory as its parent.
- Invocation captures selected items in the current visible table order. That stable order drives sequence numbering and preview order.
- Invocation captures each source URL and `FileIdentity`. Selection changes after the sheet opens do not change the request.
- Text editing or an exclusive file operation disables invocation.

## Rename Rules

```swift
enum BatchRenameRule: Equatable, Sendable {
    case replace(find: String, replacement: String, caseSensitive: Bool)
    case decorate(prefix: String, suffix: String)
    case sequence(baseName: String, start: Int, width: Int)
}
```

### Find and replace

- `find` must not be empty.
- Replacement is literal, not regular expression syntax.
- Case-sensitive matching is the default. A visible toggle allows localized case-insensitive matching.
- All non-overlapping matches in the editable stem are replaced.

### Prefix and suffix

- At least one of `prefix` and `suffix` must be nonempty.
- Prefix and suffix are added to the editable stem.

### Sequence

- `baseName` must be nonempty after validation.
- `start` is a nonnegative integer.
- `width` is from 1 through 9.
- The generated stem is `baseName` followed by one space and the zero-padded number, for example `Holiday 001`.
- Numbers follow the captured visible table order.

## Extension Preservation

Extension changes are not exposed in the first version.

- Ordinary files preserve their existing suffix exactly, including letter case.
- A recognized compound archive suffix such as `.tar.gz`, `.tar.bz2`, or `.tar.xz` is preserved as one suffix. Recognized aliases retain the exact original spelling.
- Application and document packages preserve their registered package suffix.
- A leading-dot filename such as `.env` has no preserved extension; its whole name is the editable stem.
- Ordinary directories are treated as names, not documents. Their whole name is the editable stem even when it contains a period.
- Files without a suffix use their whole name as the editable stem.

The planner exposes the editable stem and preserved suffix in each preview entry so the UI can explain the result without reconstructing the rule.

## Planning and Validation

`BatchRenamePlanner` is a pure, Sendable component. It consumes the captured ordered items, the rule, and a sibling-name snapshot, then produces a `BatchRenamePlan` with one preview entry per source.

Each preview entry contains:

- source URL and captured identity;
- original display name;
- editable stem and preserved suffix;
- proposed final name and URL;
- validation status.

The planner rejects:

- empty names, `.`, `..`, NUL, `/`, or names rejected by `FilenameValidator`;
- a rule that changes no selected item;
- duplicate final names inside the selected set under the directory's effective filename semantics;
- a final name occupied by an unselected sibling;
- a final name whose collision status cannot be established safely.

Predictive validation improves the preview, but the transaction's exclusive no-overwrite filesystem operations are authoritative. A directory change after preview therefore fails closed rather than overwriting an entry.

## User Interface

### Entry points

- **File Operations > Batch Rename…**
- **Batch Rename…** in the file-table context menu

The command is enabled only when the active pane has at least two selected items, there is no text-editing session, and queue policy permits the request.

### Sheet

The sheet contains:

1. a rule-family picker;
2. controls for the selected rule;
3. a statement that file and package extensions are preserved;
4. a virtualized preview table with **Original Name**, **New Name**, and **Status** columns;
5. **Cancel** and **Rename N Items** buttons.

The submit button is disabled while planning, when no item changes, or when any preview row is invalid. Return submits only a valid plan. Escape cancels without mutation.

The preview uses the existing product language style and supports VoiceOver labels, values, row counts, validation reasons, keyboard traversal, Reduce Motion, and stable accessibility identifiers.

## Asynchronous Preview

- Rule edits create a new planning generation.
- String transformation runs off the main actor.
- Directory collision input is captured through the existing filesystem abstraction without reading file contents or materializing cloud bytes.
- Only the latest generation may publish preview rows or validation state.
- Cancellation and sheet dismissal invalidate pending work.
- The UI remains responsive while planning. On the verified development Mac, planning and validation for 10,000 selected items target completion within five seconds. Five seconds is a pragmatic ceiling, not a reason to compromise correctness or add unsafe parallel mutation.

## Transaction Execution

`BatchRenameTransactionService` performs one sequential, cancellation-aware transaction:

1. Acquire scoped access for the parent and all selected sources.
2. Revalidate the parent, every source entry identity, the final-name collision set, and the complete plan.
3. Generate reserved temporary basenames containing a transaction UUID and stable index. Prove that every temporary name is unoccupied.
4. Stage each source to its temporary name using identity-checked, no-overwrite rename operations.
5. Publish each temporary entry to its final name using identity-checked, no-overwrite rename operations.
6. Capture final identities and fingerprints for history and Undo.
7. Refresh the pane once and select the final URLs.

Temporary and final mutations are sequential. The service never follows a symbolic link as a directory and never replaces an existing entry.

## Cancellation, Failure, and Rollback

- Before the first mutation, cancellation returns a cancelled result without filesystem changes.
- During staging or publication, cancellation enters rollback instead of abandoning temporary names.
- Rollback reverses published final names to their reserved temporary names, then restores every temporary name to its original name in reverse order.
- Each rollback step revalidates identity and uses no-overwrite semantics.
- A complete rollback reports cancellation or failure with the original directory restored.
- External interference that prevents complete rollback produces per-item recovery outcomes and a **Recovery Needed** job state. Pengrid does not delete or overwrite the interfering item.
- Error messages use basenames and relative context, never unrelated absolute paths.

## Operation Center, Retry, and Undo

- The transaction appears as one `.rename` job titled **Rename N Items**.
- Progress reports staging and publishing with completed and total item counts. Rollback is an explicit stage.
- Retry reuses the immutable captured plan but performs the full preflight again. If an original identity or name is no longer valid, retry fails closed.
- Undo is available only when every final entry still has the captured identity and fingerprint and every original name is free.
- Undo uses the same two-phase transaction in reverse. If any precondition fails, no Undo mutation starts.

## Cloud and Permission Boundaries

- Batch rename does not read file contents and does not intentionally materialize cloud bytes.
- File Provider items may participate only when Pengrid has scoped access, stable identity, and local file-operation capability for the location.
- Unknown or read-only provider capability disables submission with a clear validation reason.
- Direct OAuth/API credentials are not requested or used.
- Repeated macOS permission prompts are not treated as a retry mechanism. A denied or unavailable scope fails the request once and returns control to the user.

## Components and Ownership

- `Models/BatchRenameModels.swift`: rule, captured request, preview entry, plan, validation status
- `Services/BatchRenamePlanner.swift`: pure transformation and predictive validation
- `Services/BatchRenameTransactionService.swift`: identity-checked two-phase mutation, rollback, and reverse transaction
- `Stores/BatchRenameModel.swift`: sheet generation, draft state, asynchronous planning, and submission handoff
- `Views/BatchRenameView.swift`: accessible sheet and virtualized preview
- `Stores/FileOperationController.swift`: queue integration, progress, retry, Undo recipe, and pane completion callback
- `Support/WorkspaceCommands.swift` and `Views/AppKit/FileTableView.swift`: menu policy and entry points

These boundaries keep rule transformation testable without AppKit or filesystem dependencies and keep mutation logic independent of the sheet lifecycle.

## Testing

### Planner tests

- literal case-sensitive and localized case-insensitive replacement;
- prefix, suffix, and combined decoration;
- sequence ordering, start, and width boundaries;
- Korean, composed and decomposed Unicode, emoji, hidden dotfiles, extensionless files, ordinary dotted directories, packages, and compound archive suffixes;
- no-op rules, invalid names, duplicate outputs, unselected sibling collisions, and uncertain collision semantics;
- cancellation and stale generation rejection;
- 10,000-item preview performance with a five-second ceiling on the development Mac.

### Transaction tests

- ordinary batch rename;
- two-item exchange and three-item cycle;
- final-name and temporary-name collision refusal;
- source identity replacement before staging and before publication;
- cancellation before mutation, during staging, and during publication;
- complete rollback and externally blocked rollback with recovery outcomes;
- symbolic-link and parent replacement refusal;
- File Provider scoped-access balance without materialization;
- retry preflight and conservative reverse two-phase Undo.

### Presentation and integration tests

- command and context-menu enablement;
- immutable selection capture and visible-order numbering;
- sheet validation, default action, cancel action, focus, VoiceOver, and Reduce Motion;
- operation-center title, phases, progress, retry, recovery, and Undo state;
- pane refresh and final selection after success;
- existing single-item inline rename remains unchanged.

The full Swift package suite and `script/build_and_run.sh --verify` remain release gates.
