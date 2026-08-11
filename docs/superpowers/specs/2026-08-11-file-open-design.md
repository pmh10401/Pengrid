# File Open Design

**Date:** 2026-08-11  
**Status:** Approved by the standing instruction to use the recommended option and proceed without routine approval prompts

## Context

Pengrid already has one safe opening pipeline, `WorkspaceOpenActions`. Double-clicking a row and choosing **Open** from the application menu use that pipeline. It navigates into ordinary directories, opens files and packages through macOS, and materializes cloud-backed items after identity checks.

The file-table context menu does not expose **Open**, so the capability is easy to miss and right-click workflows cannot use it.

## Goal

Make opening selected files a complete, discoverable file-manager action without adding an independent execution path.

## Considered Approaches

1. Keep only double-click and Command-O. This has no implementation cost but does not solve discoverability or right-click workflows.
2. Execute Unix binaries and scripts directly. This is powerful but introduces command arguments, working-directory rules, terminal output, executable permissions, quarantine, and substantial security risk.
3. Reuse the existing safe open pipeline from every file-table entry point. This keeps behavior consistent and is the selected approach.

## Interaction Design

- Double-click continues to open the clicked row.
- **Command-O** continues to open the active pane selection.
- The file-table context menu adds **Open** as its first selection action.
- Right-clicking an unselected row selects it before building the menu, matching existing context-menu behavior.
- If several rows are selected, **Open** passes the whole stable table-order selection to one opening request.
- Text editing disables **Open**, consistent with other workspace commands.

## Behavior

- Ordinary directory: navigate within the active pane.
- Regular file: ask macOS to open it with its default application.
- Application or document package: open it externally through macOS rather than navigating into its bundle.
- Cloud-backed file or package: acquire scoped access, capture identity, materialize with purpose `.open`, verify the returned identity-preserving request, and then open it.
- Arbitrary shell execution, command arguments, elevated privileges, and an **Open With** chooser are out of scope.

## Components

- `FileTableView` adds an optional multi-item open callback for context-menu selection while preserving its existing single-item double-click callback.
- `FilePaneView` maps both callbacks to a shared helper that invokes `WorkspaceOpenActions` once.
- `WorkspaceOpenActions` remains the single authority for navigation, cloud preparation, and external opening.

## Failure and Safety Boundaries

- No external open occurs if scoped access, identity capture, cloud materialization, cancellation, or identity-preserving validation fails.
- The menu is disabled while text editing is active or there is no selection.
- This change does not invoke files as child processes and does not bypass macOS quarantine or Gatekeeper.

## Tests

- A file-table lifecycle test proves that the context menu contains an enabled **Open** item and sends the current selection in stable row order.
- A text-editing test proves that the item is disabled while editing.
- Existing double-click, Command-O, cloud materialization, scoped access, package, and directory-navigation tests remain green.
- Run the focused tests first, then the complete Swift package suite and the project build-and-run verification entry point.
