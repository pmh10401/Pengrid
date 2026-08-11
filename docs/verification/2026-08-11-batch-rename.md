# Batch rename verification — 2026-08-11

Status: **AUTOMATED PASS / MANUAL GUI NOT RUN**

This record applies to branch `codex/safe-operation-center` after the safe batch
rename implementation. It is source verification, not evidence that the feature
is present in the published Developer Preview 5 DMG.

## Automated evidence

### Focused workflow coverage

Command:

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --enable-swift-testing --no-parallel \
  --filter 'BatchRename|CloudLocationsStoreTests|FileOperationUndoServiceTests|WorkspaceCommandPolicyTests|WorkspaceCommandTests|FileTableViewLifecycleTests|OperationStatusViewTests|AccessibilityPresentationTests'
```

Result: **PASS — 206 tests in 10 suites, 6.459 seconds.**

Covered behavior includes:

- literal find/replace, prefix, suffix, sequence, and extension preservation;
- invalid names, duplicates, sibling collisions, swaps, and three-item cycles;
- source identity drift and destination creation after preview;
- cancellation during staging and publishing, rollback, and recovery-needed
  escalation;
- immutable-plan retry, live-filesystem Undo after relocation metadata changes,
  and conservative two-phase Undo;
- parent replacement, reserved temporary-name collision, publication identity
  drift, mutation during Undo publication, and one-shot scoped-access denial;
- discovery capability preservation plus live directory-writability gating;
- active-pane visible-order capture, menu and context-menu routing;
- latest-only preview publication and one scoped-access failure without retry;
- accessible validation, phase labels, keyboard contracts, Reduce Motion, and
  parent-path privacy.

The 10,000-row preview completed in **0.487 seconds** against the **5-second**
regression ceiling in this focused run.

### Complete product suite

Command:

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --enable-swift-testing --no-parallel \
  --filter BloomFileManagerTests
```

Result: **PASS — 1,282 tests in 85 suites, 81.822 seconds.**

### Release configuration

Command:

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift build -c release
```

Result: **PASS — production executable linked in 41.63 seconds.**

SwiftPM emitted the existing warning for 11 ProtectedZIP fixture files that are
consumed by tests but are not declared as target resources. The warning did not
fail compilation or testing.

### Development app bundle

Command:

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  ./script/build_and_run.sh --verify
```

Result: **PASS.** `dist/Pengrid.app` was built, ad-hoc signed, validated on disk,
and satisfied its designated requirement.

## Manual GUI matrix

The session did not expose the UI-control interface required by the local
Computer Use procedure. The following claims therefore remain **NOT RUN** and
must not be inferred from automated tests:

| Check | Status |
| --- | --- |
| Open Batch Rename from a real row context menu | NOT RUN |
| Inspect preview layout and submit entirely by keyboard | NOT RUN |
| Observe final selection after a live rename | NOT RUN |
| Exercise visible cancel/rollback on a large real selection | NOT RUN |
| VoiceOver reading order and spoken phase announcements | NOT RUN |
| OneDrive File Provider capability and permission-denial behavior | NOT RUN |

Automated live-filesystem tests do verify contents, names, swap/cycle behavior,
rollback, and absence of reserved temporary names. They do not replace the six
UI and provider checks above.
