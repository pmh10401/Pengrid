# Folder contents preview verification — 2026-08-04

## Status legend

- **PASS — automated:** a command completed successfully in this worktree.
- **PASS — structural/automatic:** source and focused automated tests prove the
  stated invariant, but this is not an observation of a live third-party
  provider.
- **NOT RUN:** an interactive observation was not attempted.
- **BLOCKED:** the check needs an unavailable interaction or provider fixture.

## Automated evidence

All commands below used `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` and exited 0.

| Status | Command | Result |
| --- | --- | --- |
| PASS — automated | `xcrun swift test --filter FolderPreview` | 26 tests in 6 suites passed; the provider smoke was skipped because its opt-in variable was absent. |
| PASS — automated | `xcrun swift test --filter FileSystemAccessTests` | 17 tests in 1 suite passed. |
| PASS — automated | `xcrun swift test --filter DirectoryListingServiceTests` | 2 tests passed. |
| PASS — automated | `xcrun swift test --filter WorkspaceCommand` | 19 tests in 1 suite passed. |
| PASS — automated | `xcrun swift test --filter CloudOperationGateTests` | 16 tests in 1 suite passed. |
| PASS — automated | `xcrun swift test --no-parallel` | 851 tests in 66 suites passed in 37.216 seconds. The opt-in provider smoke was explicitly skipped. |
| PASS — automated | `xcrun swift build -c release` | Production build exited 0. |
| PASS — automated | `./script/build_and_run.sh --verify` | Debug build exited 0, staged `dist/Pengrid.app`, launched it, and its `pgrep -x BloomFileManager` process check passed. |
| PASS — automated | `PENGRID_PROVIDER_PREVIEW_SMOKE=1 xcrun swift test --filter ProviderFolderPreviewSmokeTests` | 1 opt-in test passed in 0.046 seconds: direct read-only metadata snapshots against both discovered provider roots. |

The current default full-suite output contained no warning lines. An earlier
focused `FolderPreview` compile emitted the existing AppKit drag/drop fixture
warnings for `@preconcurrency` conformances in `FavoriteDropTests` and
`FileTableViewLifecycleTests`; no warning originated from the provider harness.

## Structural and automatic feature evidence

| Status | Evidence |
| --- | --- |
| PASS — structural/automatic | The coordinator routes exactly one ordinary non-package folder to the folder panel; files, packages, symbolic links, and multi-selection fall back to system Quick Look. The focused FolderPreview run covers coordinator routing and integration. |
| PASS — structural/automatic | The snapshot path reads only immediate directory entries from a no-follow descriptor, stages the complete result privately, and publishes it once after identity/generation validation. FolderPreview and FileSystemAccess tests cover sorted rows, replacement refusal, cancellation, and stale-result rejection. |
| PASS — structural/automatic | Preview visibility uses the pane baseline and includes hidden entries; `DirectoryListingServiceTests` verifies the baseline policy. |
| PASS — structural/automatic | Folder preview does not call `CloudMaterializing` or coordinated content reads. The folder route is metadata-only; no provider snapshot is inferred from this invariant. |
| PASS — structural/automatic | Failures map to the read-only unavailable copy: **“Folder contents are unavailable without downloading.”** Identity replacement maps to the distinct changed-folder message. |
| PASS — structural/automatic | The presentation exposes a read-only title, safe parent label, status, Name/Kind/Size/Modified columns, and accessibility status announcements; presentation/accessibility coverage is included in `FolderPreview`. |

## Local interactive and VoiceOver evidence

| Check | Status | Result |
| --- | --- | --- |
| Space on one ordinary folder shows only immediate children. | NOT RUN | No GUI/Computer Use interaction surface was available. |
| Space on a file, package, symbolic link, or multi-selection uses system Quick Look. | NOT RUN | No GUI/Computer Use interaction surface was available. |
| Repeated Space and Escape close preview and restore active-table focus. | NOT RUN | No GUI/Computer Use interaction surface was available. Automated routing/focus tests passed. |
| Space/Escape during rename, path edit, or filter edit affects the editor first. | NOT RUN | No GUI/Computer Use interaction surface was available. Automated command-policy tests passed. |
| A large folder shows progress and publishes one sorted snapshot. | NOT RUN | No GUI/Computer Use interaction surface was available. Automated model/snapshot tests passed. |
| Replacing a folder during enumeration shows no mixed rows and the changed message. | NOT RUN | No GUI/Computer Use interaction surface was available. Automated identity tests passed. |
| VoiceOver reads folder name, safe location, loading/item count, columns, rows, and errors. | NOT RUN | VoiceOver was not available for a manual pass. Accessibility identifiers/announcements have automated coverage. |

The scripted app-process check is not a substitute for those interactive observations.

## File Provider discovery and provider snapshots

Read-only discovery found both installed clients and their generic macOS File Provider roots:

| Provider | Client evidence | Root evidence | In-app folder snapshot |
| --- | --- | --- | --- |
| Google Drive | Google Drive 128.0 installed. | Google Drive File Provider root present. | PASS — automated direct metadata snapshot returned 5 entries. |
| OneDrive | OneDrive 26.134.0713 installed. | OneDrive File Provider root present. | PASS — automated direct metadata snapshot returned 21 entries. |

The committed `ProviderFolderPreviewSmokeTests` harness is reproducible from a
clean checkout on a host with Google Drive and OneDrive installed. It is skipped
unless `PENGRID_PROVIDER_PREVIEW_SMOKE=1` is set; the ordinary suite neither
discovers nor accesses provider roots. When enabled it uses
`LiveFileSystemAccess` and `LiveFolderPreviewListing` directly and prints only
the generic provider label plus its entry count. It is not a manual panel
observation. These results and the following limitations remain distinct:

| Check | Status | Limitation |
| --- | --- | --- |
| Google Drive metadata appears. | PASS — automated | The direct read-only snapshot returned 5 entries. The metadata-only path has no `CloudMaterializing` dependency. Online-only hydration/download state was not independently measured. |
| OneDrive metadata appears. | PASS — automated | The direct read-only snapshot returned 21 entries. The metadata-only path has no `CloudMaterializing` dependency. Online-only hydration/download state was not independently measured. |
| A provider that refuses descriptor-relative metadata shows the read-only unavailable state. | BLOCKED | Requires a provider fixture that actually refuses metadata. The unavailable-state mapping is structurally/automatically verified above. |
| Closing or changing selection cancels provider work and stale rows never appear. | BLOCKED | Requires an interactive provider-backed enumeration. Cancellation/stale-result behavior is structurally/automatically verified above. |

No account identifiers, private provider paths, or child item names were
printed to command output or recorded in committed evidence. Child names are
necessarily read in memory as directory-entry metadata by the snapshot API.

## Remaining manual release gates

There are no automated blockers. The local keyboard, actual system Quick Look,
VoiceOver, Google Drive, and OneDrive rows above must still be observed in the
running app before this feature can be claimed as fully manually verified.
