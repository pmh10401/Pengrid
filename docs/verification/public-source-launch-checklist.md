# Public Source Launch Checklist

Evidence date: 2026-07-30 (Asia/Seoul)

This checklist records the private-first evidence available before its own
evidence-only commit. A commit cannot contain its own object ID, its own push CI
result, or checks performed after a later visibility change. Those post-commit
gates must be completed without rewriting history and recorded in the private
launch report before the repository is treated as safely public.

## CLEAN SOURCE IDENTITY

- Approved private source tree:
  `7070ce98c3ad0206dd06bcc3f210dd6f3ef6d4af`
- Clean parentless root commit:
  `57496e87842f1dd499bd293520609687736c679a`
- Root tree: 138 tracked files, 24 tree objects, and 138 blob objects.
- Pre-evidence reachable revision count: 1.
- Post-evidence reachable revision count: 2 by construction: the clean root
  plus the evidence-only commit containing this checklist. A second isolated
  fetch must confirm that count before the visibility gate opens.
- Advertised-ref snapshot before the evidence commit:

  ```text
  57496e87842f1dd499bd293520609687736c679a	refs/heads/main
  ```

- Snapshot SHA-256:
  `292541654868e0cca4978b76a7128f5f925af3fcf217948a2e4842dec0715a21`
- Ref counts: 1 head, 0 tags, 0 pull-request heads, 0 pull-request merge
  refs, and 0 unknown refs. Remote `HEAD` resolves to `refs/heads/main`.

## PRIVATE REACHABLE-HISTORY AUDIT

Every advertised ref was fetched into a new isolated bare repository. The
audit covered every fetched reachable revision, tree path, blob, and commit
object rather than relying on the publishing checkout's local refs.

- Credential-shaped blob findings: 0.
- Sensitive historical filename findings: 0.
- Blobs above 10 MiB: 0.
- Separate private router-project source or history findings: 0.
- Superseded repository-link findings: 0.
- Absolute local home-path findings: 0.
- Tracked generated-output findings: 0.
- Commit-metadata findings: 0.
- Unexpected binary findings: 0. The only binary assets are the two approved
  Pengrid icon files, and both match the approved source blobs.
- Full object integrity: pass; `git fsck --full --strict` exited 0. Its only
  diagnostic was the expected notice that the isolated audit repository's own
  `HEAD` was unborn; every fetched audit ref and reachable object verified.

## SOURCE AND CI VERIFICATION

- Local full nonparallel suite:
  `swift test --disable-sandbox --no-parallel` passed 551 tests in 41 suites
  in 35.327 seconds.
- Local development-app verification:
  `./script/build_and_run.sh --verify` exited 0 and produced an arm64 Mach-O
  executable.
- First private push CI:
  [run 30499548865](https://github.com/pmh10401/Pengrid/actions/runs/30499548865),
  commit `57496e87842f1dd499bd293520609687736c679a`, event `push`,
  conclusion `success`. The `Swift test and app verification` job and both
  `Run Swift tests` and `Verify app launch` steps succeeded.
- The evidence-commit push necessarily occurs after this file is committed.
  Its exact CI run must conclude successfully before the second ref audit and
  visibility change; the launch report is the authoritative post-commit
  record.

## REPOSITORY AND ANONYMOUS STATE

- Evidence-time repository visibility: `PRIVATE`.
- Default branch: `main`.
- Repository description:
  `Pengrid — a dual-pane macOS file manager with File Provider cloud locations and Storage Inspector`
- Private-first anonymous checks returned HTTP 404 for the repository page,
  source archive, and raw README, confirming that the source was not exposed
  before the remaining gates.
- Authenticated Releases API count: 0.
- After the second private CI and complete two-revision ref audit pass, the
  public gate still requires unauthenticated HTTP 200 for the repository,
  archive redirect plus body, archive integrity, raw README markers, a full
  advertised-ref snapshot with zero pull refs, and an empty Releases API.
  These post-public results cannot be embedded in this immutable pre-public
  evidence commit and must be recorded in the launch report.

## NO PREBUILT RELEASE

- No GitHub Release exists.
- No prebuilt app or generated `dist` output is tracked.
- Locally built or ad-hoc signed artifacts are development artifacts. They may
  trigger macOS trust warnings and are not the signed public release.
- Google Drive and OneDrive support remains macOS File Provider integration,
  not direct Google or Microsoft OAuth/API integration.

## REMAINING RELEASE BLOCKERS

Every `MANUAL NOT RUN`, `MANUAL UNAVAILABLE`, and `RELEASE BLOCKER` item in
`storage-inspector-checklist.md`, `version-1-checklist.md`, and
`version-1.1-checklist.md` remains blocking and is incorporated here by
reference. In particular:

- Select and verify the full Xcode release toolchain, a valid Developer ID
  Application identity, and a usable `notarytool` keychain profile.
- Sign the exact release candidate with hardened runtime and secure timestamp;
  obtain Apple notarization acceptance; staple and validate the ticket; and
  obtain Gatekeeper acceptance for that exact candidate.
- Rerun unsigned packaging against the exact final candidate. Prior local
  ad-hoc packaging is not release evidence and must not be distributed.
- Complete Storage Inspector physical checks on local APFS and directly
  attached storage, including a real 100,000-file tree, disconnect/reconnect
  during every scan and hash stage, Quick Look and Finder actions, real Trash
  outcomes and recovery, protected roots, accessibility, keyboard use, and
  all required appearances.
- Complete File Provider checks with current Google Drive, OneDrive, Dropbox,
  an additional provider, multiple accounts, offline/provider lifecycle,
  online-only materialization and cancellation, identity replacement,
  bookmark removal, accessibility, keyboard use, and all required appearances.
- Complete file-manager physical UI checks for protected-folder denial,
  listing/copy disconnect recovery, same- and cross-volume drag moves,
  conflict handling, favorites persistence, VoiceOver, keyboard-only use,
  Light and Dark Mode, Increased Contrast, Reduce Motion, 10,000-row
  responsiveness, navigation, sorting, and memory observation.
- Complete comparison checks on local, external, and case-sensitive volumes,
  including hidden items, links and packages, checksum progress, live changes,
  disconnect/reconnect, physical 50,000-item scale, large files, every
  directional copy/move and conflict outcome, missing-parent handling,
  same- and cross-volume semantics, accessibility, keyboard use, and all
  required appearances.

No source publication result is signing, notarization, stapling, Gatekeeper,
physical-device, accessibility, appearance, or end-user distribution evidence.
