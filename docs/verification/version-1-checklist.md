# Bloom version 1 verification checklist

Verification date: 2026-07-21 (Asia/Seoul)

Host used for automated evidence: Apple Silicon Mac (Apple M2, 16 GB), macOS 26.5.2. The product deployment target remains macOS 15 or later.

Folder comparison and directional transfer are version 1.1 work. Their evidence and
remaining gates are recorded separately in the
[version 1.1 verification checklist](version-1.1-checklist.md). The version 1 evidence
below is retained unchanged.

Status notation:

- `[x] AUTOMATED PASS` means a repeatable test, build, or read-only inspection passed on the dated host.
- `[x] STATIC SOURCE WIRING PASS` means the requested modifier is referenced by the intended view source; it does not prove the runtime macOS accessibility tree or VoiceOver behavior.
- `[ ] MANUAL UNAVAILABLE` means the scenario was not honestly observable in this environment. It is a release-validation item for Task 6, not a pass.
- Simulated filesystem evidence is named as such and is not presented as a physical-device test.

## Navigation, pane ownership, and failure recovery

- [x] **AUTOMATED PASS — 2026-07-21:** left and right histories remain independent (`FilePaneStateTests/backAndForwardRestoreNavigationHistory`, `WorkspaceStateTests/panesNavigateWithoutSharingHistory`).
- [x] **AUTOMATED PASS — 2026-07-21:** active-pane command routing targets only the active pane (`WorkspaceCommandTests/commandSelectionUsesOnlyTheActivePane`, `WorkspaceStateTests/activePaneTracksExplicitActivation`).
- [x] **AUTOMATED PASS — 2026-07-21:** a simulated listing/permission failure retains the prior usable listing and selection (`DirectoryReconciliationTests/refreshErrorPreservesThePriorListingAndSelection`, `failedMonitorRefreshKeepsTheLastUsableListingAndMonitor`).
- [ ] **MANUAL UNAVAILABLE — 2026-07-21:** deny access to a real protected folder, confirm the inline copy and recovery action, then restore access. The deterministic error path is covered, but no protected user folder was modified for this run.
- [x] **AUTOMATED PASS — 2026-07-21:** missing or changed sources become per-item failures and unrelated items retain exact outcomes (`FileTransferTests/multiItemFailureSkipAndCancelProduceExactOutcomesProgressAndLogCounts`, `changedSourceIdentityIsNotRemovedAfterCommittedCrossVolumeCopy`).
- [x] **AUTOMATED PASS — 2026-07-21:** partial results expose succeeded, failed, and skipped counts (`FileOperationControllerTests/operationStatusSummaryCountsEveryOutcomeForAccessibility`).
- [x] **AUTOMATED PASS — 2026-07-21:** simulated destructive directory events finish the listing monitor once and preserve reconciliation safety (`DirectoryReconciliationTests/destructiveDirectoryEventYieldsOnceThenFinishesAndCloses(change:)`).
- [ ] **MANUAL UNAVAILABLE — 2026-07-21:** remove a physical external volume during listing and confirm Home recovery. `/Volumes` contained only the startup disk and Time Machine local-snapshot entries; no removable data volume was available.
- [x] **AUTOMATED PASS (SIMULATED VOLUMES) — 2026-07-21:** copy interruption and cross-volume source preservation (`FileTransferTests/cancellationAfterCrossVolumeCopyCleansDestinationAndPreservesSource`, `failedPostCommitVerificationPreservesCommittedDestinationAndSource`).
- [ ] **MANUAL UNAVAILABLE — 2026-07-21:** remove a physical external volume during copy and inspect the final UI result. No removable data volume was available.

## File operations and conflict recovery

- [x] **AUTOMATED PASS (SIMULATED VOLUME IDS) — 2026-07-21:** same-volume move uses the native move path without copy-capacity preflight (`FileTransferTests/nativeSameVolumeMoveDoesNotPerformCopyCapacityPreflight`).
- [x] **AUTOMATED PASS (SIMULATED VOLUME IDS) — 2026-07-21:** cross-volume move verifies the copy before removing the source (`FileTransferTests/crossVolumeMoveRemovesSourceOnlyAfterVerifiedCopy`).
- [ ] **MANUAL UNAVAILABLE — 2026-07-21:** execute same-volume and physical cross-volume drag moves in the launched UI. Service sequencing is automated; a removable data volume and physical drag pass were unavailable.
- [x] **AUTOMATED PASS — 2026-07-21:** Replace, Keep Both, Skip, and Cancel behavior is covered across `FileTransferTests` and `FileOperationControllerTests`.
- [x] **AUTOMATED PASS — 2026-07-21:** Apply to All reuses a decision for remaining conflicts and resets for the next operation (`applyToAllReusesDecisionWithoutAnotherSheet`, `applyToAllDecisionResetsBetweenCompletedOperations`).
- [ ] **MANUAL UNAVAILABLE — 2026-07-21:** inspect conflict-sheet focus order, wording, buttons, and Apply to All with VoiceOver. The identifier constant and its static source wiring are checked; live assistive-technology presentation was unavailable.
- [x] **AUTOMATED PASS — 2026-07-21:** cancellation cleans only operation-owned temporary output and preserves committed/public or externally replaced items (`cancellationAfterDirectCopyCleansDestinationAndPreservesSource`, `cleanupRefusesExternalReplacementAtStagingPathAndSurfacesFailure`, `partialCopyCleanupNeverAdoptsExternalReplacementIdentity`).
- [x] **AUTOMATED PASS — 2026-07-21:** cancellation at pre-commit and post-commit boundaries reports the correct outcome and source/destination ownership (`cancellationAtTheDestinationIdentityGateNeverPresentsAConflict`, `copyCancellationAfterPublicCommitReturnsSuccess`, `moveCancellationAfterPublicCommitPreservesSourceAndDestination`).

## Favorites and relaunch

- [x] **AUTOMATED PASS — 2026-07-21:** add, exact-URL duplicate rejection, ordered persistence, reorder, and remove are covered by `FavoritesStoreTests` and `FavoriteDropTests`.
- [x] **AUTOMATED PASS — 2026-07-21:** removing a favorite does not touch its folder or contents (`FavoritesStoreTests/removingFavoriteDoesNotTouchReferencedFolderOrContents`).
- [x] **AUTOMATED PASS — 2026-07-21:** unavailable favorites remain visible with warning state and never navigate either pane (`unresolvedFavoriteRemainsVisibleWithWarningAfterRestore`, `unavailableFavoriteNeverNavigatesEitherPane`).
- [x] **AUTOMATED PASS — 2026-07-21:** persisted favorites and pane workspace values restore through replacement-store/workspace tests, which model relaunch (`favoritesPersistOrderAndDoNotDuplicateExactURLs`, `restoredValuesInitializeAReplacementWorkspaceLikeRelaunch`).
- [ ] **MANUAL UNAVAILABLE — 2026-07-21:** add by context menu and rail drop, reorder, remove, quit, and relaunch the packaged app while visually confirming row order and warning affordances.

## Accessibility and keyboard

- [x] **AUTOMATED MODEL PASS — 2026-07-21:** identifier constants are fixed at `placesRail`, `favoritesSection`, `leftPane`, `rightPane`, `operationStatus`, and `conflictSheet` (`accessibilityIdentifiersRemainStable`).
- [x] **STATIC SOURCE WIRING PASS — 2026-07-21:** `accessibilityModifiersAreStaticallyWiredIntoViews` reads the actual view sources and confirms those constants are referenced by `PlacesRailView`, `FilePaneView`, `OperationStatusView`, and `ConflictResolutionSheet`. This is not a runtime AX-tree assertion.
- [x] **AUTOMATED MODEL PASS — 2026-07-21:** the pane presentation model produces descriptive side labels and `Active pane`/`Inactive pane` values (`paneAccessibilityPresentationNamesSideAndActiveState`).
- [x] **STATIC SOURCE WIRING PASS — 2026-07-21:** `FilePaneView` statically wires the pane presentation label/value to its accessibility modifiers. Actual runtime exposure and whether active state is announced independently of color remain part of the VoiceOver manual gate below.
- [x] **AUTOMATED MODEL PASS — 2026-07-21:** favorite availability and operation-result presentation models produce descriptive strings (`favoriteAccessibilityLabelsDescribeAvailability`, `operationStatusSummaryCountsEveryOutcomeForAccessibility`).
- [x] **STATIC SOURCE WIRING PASS — 2026-07-21:** source inspection confirms `.accessibilityHidden(true)` is wired for the pane outline, navigation chevrons, and favorite status image. Runtime element suppression and retained control labels remain manual AX checks.
- [ ] **MANUAL UNAVAILABLE — 2026-07-21:** VoiceOver reading order, rotor grouping, live focus movement, labels, values, conflict sheet, and operation status announcement. The prior Computer Use/System Events accessibility query timed out or returned no usable response, so it is not counted as evidence.
- [x] **AUTOMATED PASS — 2026-07-21:** command policy, AppKit lifecycle, text-responder routing, rename requests, and drag/drop routing are covered by `WorkspaceCommandTests` and `FileTableViewLifecycleTests`.
- [ ] **MANUAL UNAVAILABLE — 2026-07-21:** complete keyboard-only pass for pane activation, navigation, selection, Return/F2 rename, Space Quick Look, copy/paste, Delete/Command-Delete, conflict resolution, and favorites. Physical key-equivalent delivery and Quick Look visuals cannot be asserted by the shell test host.

## Appearance and motion

- [x] **AUTOMATED PASS — 2026-07-21:** source/build inspection confirms semantic SwiftUI/AppKit colors and materials compile without a fixed Light-only root background.
- [ ] **MANUAL UNAVAILABLE — 2026-07-21:** Increased Contrast visual inspection for pane outline, text, dividers, selection, warnings, and conflict controls.
- [x] **AUTOMATED MODEL PASS — 2026-07-21:** the motion presentation policy returns no nonessential animation when Reduce Motion is requested (`reduceMotionDisablesOnlyNonessentialAnimation`).
- [x] **STATIC SOURCE WIRING PASS — 2026-07-21:** source inspection confirms `WorkspaceView` reads `accessibilityReduceMotion` and sets `transaction.animation = nil` through that policy; AppKit divider positioning and table selection contain no explicit animation call. Runtime environment propagation and system-level behavior are not asserted.
- [ ] **MANUAL UNAVAILABLE — 2026-07-21:** toggle Reduce Motion while moving the divider and selection to confirm no unexpected system animation remains.
- [ ] **MANUAL UNAVAILABLE — 2026-07-21:** Light Mode pixel inspection.
- [ ] **MANUAL UNAVAILABLE — 2026-07-21:** Dark Mode pixel inspection.
- [ ] **MANUAL UNAVAILABLE — 2026-07-21:** prior screen-capture attempts returned black/no image, so pane contents and active outline still require a user-visible visual pass.

## 10,000-item performance matrix

- [x] **AUTOMATED PASS — 2026-07-21:** `tenThousandItemsArriveProgressivelyAndCompletely` yielded more than one batch, exactly 10,000 items total, and a first batch of 256.
- [x] **BASELINE — 2026-07-21:** `/usr/bin/time -p swift test --filter tenThousandItemsArriveProgressivelyAndCompletely` completed with test body `2.421 s`; process totals were `real 3.62`, `user 1.35`, `sys 2.01`. This is a local observation, not a unit-test threshold.
- [ ] **MANUAL UNAVAILABLE — 2026-07-21:** live table scrolling responsiveness while batches arrive.
- [ ] **MANUAL UNAVAILABLE — 2026-07-21:** sort all four columns with 10,000 visible rows and observe responsiveness/header state.
- [x] **AUTOMATED PASS — 2026-07-21:** navigate-away cancellation rejects stale batches and terminates stalled listing streams (`cancellingNavigationStopsActiveLoadAndRejectsLateBatch`, `releasingPaneDuringStalledNavigationCancelsTheListingStream`).
- [ ] **MANUAL UNAVAILABLE — 2026-07-21:** navigate away from a live 10,000-item load and visually confirm immediate interaction in the destination.
- [ ] **MANUAL UNAVAILABLE — 2026-07-21:** observe packaged-app memory before, during, and after 10,000-row load, scroll, sort, and navigation. The timed test includes the Swift test process and is not valid UI memory evidence.

## Build and release-validation gate

- [ ] **RELEASE BLOCKER:** Full Xcode is not selected with `xcode-select`; release tooling must be rerun after selecting the installed Xcode developer directory.
- [ ] **RELEASE BLOCKER:** No `Developer ID Application` signing identity has been verified on this Mac.
- [ ] **RELEASE BLOCKER:** No usable `notarytool` keychain profile has been verified on this Mac.
- [ ] **RELEASE BLOCKER:** The signed, notarized, stapled, and Gatekeeper-assessed release run has not been executed.

- [x] **AUTOMATED PASS — 2026-07-21:** `swift test` completed with 190 tests passed and zero failures after final review fixes.
- [x] **AUTOMATED PASS — 2026-07-21:** `./script/build_and_run.sh --verify` exited 0; the post-review-fix `pgrep -x BloomFileManager` returned PID 29292.
- [x] **AUTOMATED PASS — 2026-07-21:** `./script/package_release.sh --unsigned` produced an arm64-only, ad-hoc-signed app with valid plist version `1.0.0 (1)`, deployment target 15.0, and no App Sandbox entitlement.
- [x] **AUTOMATED PASS — 2026-07-21:** packaged `Info.plist` passed `plutil -lint` and reports minimum system version 15.0.
- [x] **AUTOMATED PASS — 2026-07-21:** `git diff --check` reported no whitespace errors.
- [ ] **MANUAL RELEASE BLOCKER — 2026-07-21:** complete the unchecked physical UI, VoiceOver, appearance, external-volume, and memory-observation scenarios above before describing version 1 as fully validated for release.

## Deferred minor experience items

- [ ] Quick Look should follow live selection changes while its panel remains open.
- [ ] Restore each directory's prior scroll position when navigating back and forward.
- [ ] Complete the optional toolbar beyond the current pane-local controls.
