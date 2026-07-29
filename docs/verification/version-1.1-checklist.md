# Pengrid version 1.1 verification checklist

Verification record opened: 2026-07-22 (Asia/Seoul)

This checklist covers folder comparison and directional transfer. Evidence types are
kept separate so an automated fixture or source inspection is never presented as a
physical macOS, storage-device, accessibility, signing, or notarization pass.

Status notation:

- `[x] AUTOMATED PASS` means the named repeatable command or deterministic test passed
  on the recorded date. Simulated and in-memory volume evidence is identified as such.
- `[x] STATIC-SOURCE PASS` means source wiring was inspected; it does not prove runtime
  UI, accessibility-tree, storage-device, signing, or Gatekeeper behavior.
- `[ ] AUTOMATED PENDING` means the final command has not yet been recorded here.
- `[ ] MANUAL NOT RUN` means the physical scenario has not been performed and remains a
  release gate.
- `[ ] RELEASE BLOCKER` means required distribution credentials or external validation
  are unavailable or have not been exercised against the candidate.

## Automated evidence

- [x] **AUTOMATED PASS — 2026-07-22:** a fresh `/tmp` scratch, nonparallel Swift test run
  completed with 351 tests passed, zero failures, in 33.403 seconds after the Space Quick
  Look regression fix.
- [x] **AUTOMATED PASS — 2026-07-22:** `./script/build_and_run.sh --verify` exited zero,
  process 20739 was confirmed by exact name and then stopped; no `BloomFileManager`
  process remained.
- [x] **AUTOMATED PASS — 2026-07-22:** the package release contract suite passed. Unsigned
  packaging completed after its nonparallel 351-test gate. The packaged plist reports exact
  version `1.1.0` and build `2`; `lipo` reported exactly `arm64`, `plutil -lint` reported
  `OK`, and strict `codesign` verification reported the app valid on disk and satisfying its
  designated requirement. The packaged arm64 executable SHA-256 is
  `f6e9dd20af390ccc751086a59d9a52231add1b9f235c2d82b61fb9d8302b31ef`. This ad-hoc
  signature is not Developer ID.
- [x] **AUTOMATED PASS — 2026-07-22:** an AppKit event-routing regression test proves that
  an unmodified Space key received by the focused file table invokes the Quick Look menu
  equivalent before `NSTableView` consumes the event.
- [x] **AUTOMATED PASS (IN-MEMORY/TEMPORARY FIXTURES) — 2026-07-22:** tests cover
  shallow and recursive comparison, hidden-item toggling, symbolic link target comparison
  without traversal, opaque package enumeration, Unicode/case Name Conflict behavior,
  background and explicit checksum progress/cancellation, and bounded checksum concurrency.
- [x] **AUTOMATED PASS (IN-MEMORY/TEMPORARY FIXTURES) — 2026-07-22:** tests cover
  live create, rename, and delete reconciliation; simulated volume disconnect/reconnect;
  directional copy conflict decisions; and confirmed one-sided directional move.
- [x] **AUTOMATED PASS (TEMPORARY FILESYSTEM) — 2026-07-22:** tests cover missing
  relative-parent creation, no-follow ancestor validation, per-item failure cleanup, and
  preservation of non-owned or identity-changed directories.
- [x] **AUTOMATED PASS (IN-MEMORY SCALE FIXTURE) — 2026-07-22:** the 50,000-item
  comparison case checks progressive publication, responsive cancellation, and stable
  selection; large-file checksum tests check streaming reads and a concurrency high-water
  of exactly two. These are not physical-disk responsiveness or memory-observation passes.

## File Provider automated evidence

- [x] **AUTOMATED PASS — 2026-07-29:** the complete nonparallel suite passed all 444
  tests in 33 suites with zero failures in 35.399 seconds after the Cloud Locations
  settings surface. Coverage includes discovery, persistence, manual bookmark removal,
  materialization gates, cancellation, identity revalidation, accessibility presentation,
  and privacy-safe operation status.
- [x] **AUTOMATED PASS — 2026-07-29:** `./script/build_and_run.sh --verify` rebuilt the
  Pengrid development bundle, completed its exact process launch check, and exited zero.

## Static-source evidence

- [x] **STATIC-SOURCE PASS — 2026-07-22:** comparison rows expose text, icon, and
  accessibility value in addition to color; quick and checksum-verified results have
  distinct descriptions.
- [x] **STATIC-SOURCE PASS — 2026-07-22:** comparison filters, subfolder and hidden-item
  toggles, verification actions, directional copy/move actions, disabled reasons, and move
  confirmation are assigned stable accessibility presentation or identifiers.
- [x] **STATIC-SOURCE PASS — 2026-07-22:** operation status keeps the count summary and
  the **Details** control as separate accessibility elements. Details use a typed, validated
  comparison-relative path only when identified-transfer metadata safely disambiguates a
  duplicate basename. Generic results never infer paths from absolute URLs and fall back to
  basenames when metadata is absent; the summary remains path-free.
- [x] **STATIC-SOURCE PASS — 2026-07-22:** source honors Reduce Motion for nonessential
  comparison transitions and uses semantic system colors/materials for Light/Dark Mode and
  Increased Contrast compatibility. Runtime appearance remains manual evidence.

## File Provider physical manual evidence

- [ ] **MANUAL NOT RUN — 2026-07-29:** verify current Google Drive, OneDrive, Dropbox,
  and one additional File Provider implementation for discovery, provider and availability
  presentation, navigation, hide, unhide, rescan, and relaunch restoration.
- [ ] **MANUAL NOT RUN — 2026-07-29:** verify multiple accounts for each available
  provider remain distinct and stable across rescan and relaunch without exposing account
  labels or complete cloud paths in status text or logs.
- [ ] **MANUAL NOT RUN — 2026-07-29:** verify offline mode, provider app termination,
  disconnect, reconnect, provider removal, and subsequent rescan while unavailable
  locations remain visible and unsafe navigation stays disabled.
- [ ] **MANUAL NOT RUN — 2026-07-29:** open, Quick Look, checksum, copy, and move
  online-only files; verify a large download, cancellation, insufficient local storage,
  provider permission failure, and recovery never dispatch a downstream operation early.
- [ ] **MANUAL NOT RUN — 2026-07-29:** replace or externally change an online-only item
  during materialization and confirm identity revalidation blocks stale open, preview,
  checksum, transfer, and source removal.
- [ ] **MANUAL NOT RUN — 2026-07-29:** remove a manually added location in Settings and
  confirm Pengrid forgets only its bookmark record while the selected folder and all of its
  contents remain unchanged; confirm discovered-location removal is represented only by
  Hide and never deletes a provider root.
- [ ] **MANUAL NOT RUN — 2026-07-29:** use VoiceOver and Full Keyboard Access to inspect
  visible and hidden sections, provider, availability, Rescan, Hide, Unhide, and Remove
  Manual Location; verify focus order and Command-R behavior.
- [ ] **MANUAL NOT RUN — 2026-07-29:** inspect the Cloud sidebar, settings form, progress,
  failures, and confirmation surfaces with Increased Contrast, Reduce Motion, Light Mode,
  and Dark Mode.

## Physical manual evidence

### Comparison sources and namespace behavior

- [x] **MANUAL PASS — 2026-07-22 18:52 KST:** the exact unsigned candidate displayed an
  aligned local comparison row, preserved selection, exposed both side paths and the
  metadata-changed status, and enabled the applicable directional actions. This narrow pass
  does not cover recursive enumeration, filter changes, or cancellation.
- [ ] **MANUAL NOT RUN — 2026-07-22:** perform shallow and recursive compare on two local
  folders and confirm progressive aligned rows, counts, filters, selection, and cancellation.
- [ ] **MANUAL NOT RUN — 2026-07-22:** repeat shallow and recursive compare with a physical
  external volume; confirm navigation and selection stay responsive during enumeration.
- [ ] **MANUAL NOT RUN — 2026-07-22:** compare on a physical case-sensitive volume with
  case-only names and Unicode-equivalent names; confirm Name Conflict rows are never paired
  or made actionable.
- [ ] **MANUAL NOT RUN — 2026-07-22:** toggle hidden items with `.DS_Store`, compare a
  symbolic link by target without following it, and confirm a Finder package remains opaque.

### Checksum, monitoring, and scale

- [ ] **MANUAL NOT RUN — 2026-07-22:** observe background checksum progress for equal-size,
  different-date files and explicit Verify Selected/Verify All progress and cancellation.
- [ ] **MANUAL NOT RUN — 2026-07-22:** create, rename, and delete items in both roots while
  comparison is active; confirm targeted live reconciliation and stable selection.
- [ ] **MANUAL NOT RUN — 2026-07-22:** disconnect and reconnect a physical external volume
  during enumeration and checksum verification; confirm stale rows remain visible, actions
  disable, and retry uses the reconnected root identity.
- [ ] **MANUAL NOT RUN — 2026-07-22:** compare a physical 50,000-item tree and observe first
  results, scrolling, selection, navigation, cancellation latency, CPU, and memory.
- [ ] **MANUAL NOT RUN — 2026-07-22:** verify large files on local and external storage;
  observe bounded memory, at most two active checksums, progress, cancellation, and recovery.

### Directional copy and move

- [ ] **MANUAL NOT RUN — 2026-07-22:** exercise directional copy left-to-right and
  right-to-left for one-sided, content-changed, metadata-changed, and type-conflict rows.
- [ ] **MANUAL NOT RUN — 2026-07-22:** exercise Replace, Keep Both, Skip, Cancel, and Apply
  to All for directional copy conflicts and inspect succeeded/failed/skipped/cancelled details.
- [ ] **MANUAL NOT RUN — 2026-07-22:** copy and move recursive children whose relative
  destination parents are missing; confirm parents are created without flattening and only
  operation-owned empty parents are cleaned after failure or cancellation.
- [ ] **MANUAL NOT RUN — 2026-07-22:** confirm directional move is offered only for
  one-sided selections, always presents confirmation, and never silently omits an ineligible
  item from a mixed selection.
- [ ] **MANUAL NOT RUN — 2026-07-22:** perform same-volume and physical cross-volume moves;
  confirm copy verification precedes source removal across volumes and only the selected
  source child is removed.
- [ ] **MANUAL NOT RUN — 2026-07-22:** disconnect a physical external volume during copy
  and move; inspect partial outcomes, destination cleanup, source preservation, and recovery.

### Accessibility and appearance

- [x] **MANUAL PASS — 2026-07-22 18:52 KST:** VoiceOver was enabled on the exact candidate.
  The comparison workspace exposed toolbar order, left/right folder labels, row-side and
  status descriptions, disabled reasons, selection count, and verification controls through
  the accessibility hierarchy. VoiceOver was restored to off. Audible speech content,
  throttled progress announcements, confirmation sheets, and operation-result Details remain
  covered by the comprehensive pending scenario below.
- [ ] **MANUAL NOT RUN — 2026-07-22:** use VoiceOver to inspect toolbar order, row path and
  side/status descriptions, quick versus verified wording, disabled reasons, throttled
  progress announcements, move confirmation, operation summary, and separate Details menu.
- [x] **MANUAL PASS — 2026-07-22 18:54 KST:** with Full Keyboard Access enabled, Tab focus
  reached Copy Left to Right, Copy Right to Left, Verify Selected Contents, and Verify All
  Contents in order. In the file panes, Up/Down selection, Return/F2 rename, Command-O folder
  open, and Space Quick Look were exercised; Quick Look displayed the selected file contents.
  Full Keyboard Access was restored to off.
- [ ] **MANUAL NOT RUN — 2026-07-22:** complete the workflow with Full Keyboard Access:
  enter/exit compare, select/filter/toggle/verify, copy, resolve conflicts, confirm move, and
  restore focus to the previously active pane.
- [x] **MANUAL PASS — 2026-07-22 18:54 KST:** Light Mode and Dark Mode were applied to the
  exact candidate's comparison view. Paths, selected-row status, enabled/disabled actions,
  selection count, and toolbar controls remained readable in both appearances. The system
  appearance was restored to Automatic.
- [ ] **MANUAL NOT RUN — 2026-07-22:** inspect Increased Contrast and Reduce Motion, and
  exercise banners and confirmation sheets in all required appearances.

## Distribution release blockers

- [ ] **RELEASE BLOCKER — 2026-07-22:** no valid Developer ID Application identity has been
  used to sign this exact version 1.1 candidate with hardened runtime and secure timestamp.
- [ ] **RELEASE BLOCKER — 2026-07-22:** Apple notarization has not accepted this exact
  candidate through a verified `notarytool` keychain profile.
- [ ] **RELEASE BLOCKER — 2026-07-22:** the accepted ticket has not been stapled to this
  candidate and validated with `stapler validate`.
- [ ] **RELEASE BLOCKER — 2026-07-22:** Gatekeeper has not accepted this exact candidate
  through `spctl --assess --type execute`.
- [ ] **RELEASE BLOCKER — 2026-07-22:** every unchecked physical manual scenario above must
  have dated evidence before version 1.1 is described as fully validated for distribution.
