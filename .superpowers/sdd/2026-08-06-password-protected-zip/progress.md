# SDD ledger — plan: docs/superpowers/plans/2026-08-06-password-protected-zip.md

Setup: existing linked worktree on `codex/safe-operation-center`.
Baseline: 851 tests in 66 suites passed; two pre-existing `@preconcurrency` warnings in drag-test stubs.
Pre-flight plan conflict scan: clean.
Task 1: platform resolution — local `ZLIB_COMPAT`/`HAVE_PDIR`; SDK-supported `memset_s` plus volatile fallback preserves the secure-clear contract where public `explicit_bzero` is unavailable.
Task 1: reviewer cannot verify RED→GREEN chronology/full-suite execution from a static diff; controller resolved from the report's exact commands and captured RED/GREEN/full-suite outputs.
Task 1: complete (commits 856d2f5..87b3912, review clean)
Carry to Task 12: align design/implementation documentation with the reviewed macOS secure-clear implementation.
Task 2: minor (deferred): remove unused duplicate concise `PENGRID_ZIP_*` status aliases; retain the single `PENGRID_ZIP_STATUS_*` public spelling unless a later client proves a need.
Task 2: reviewer cannot verify unchanged vendor bytes or TDD chronology from this task diff; controller resolved vendor provenance from Task 1's clean review and TDD execution from the Task 2 report evidence.
Task 2: fix round 1/5 (2 addressed, 1 open — overflow and racing-second-teardown regression tests are not yet load-bearing; commits 0a16c6b..5a445b2)
Task 2: fix round 2/5 (1 addressed, 0 open — ZIP64 overflow and deterministic second-teardown regressions covered; commits 5a445b2..b2d364d)
Task 2: complete (commits 87b3912..b2d364d, review clean; 1 deferred minor)
Task 3: minor (deferred): `.invalidLength` overlaps `.tooShort`/`.tooLong`; remove it or define and test a non-overlapping invariant before prompt integration.
Task 3: minor (deferred): locale selection should use `Locale.language.languageCode`, including keyword-bearing Korean locale identifiers.
Task 3: fix round 1/5 (2 addressed, 0 open — protected construction fails closed and engine setup/launch errors are closed/localized; commits eadd96c..c3226c4)
Task 3: complete (commits b2d364d..c3226c4, review clean; 2 deferred minors)
Task 4: minor (deferred): add deterministic reverse-removal-order verification; current focused tests verify cleanup results but not exact call order.
Task 4: fix round 1/5 (2 addressed, 0 open — verification throws now clean output/prepared sources and cleanup failures require recovery; commits 4e44b28..84e08b1)
Task 4: complete (commits c3226c4..84e08b1, review clean; 1 deferred minor)
Task 5: minor (deferred): prefer `MZ_ZIP64_AUTO` over forced ZIP64 for tiny entries unless a fixture-specific force path is isolated.
Task 5: minor (deferred): duplicate/open the source directory with an independent open-file description so enumeration cannot advance the caller descriptor position.
Task 5: minor (deferred): normalize pre/post-call and callback cancellation to the same `ProtectedZIPError.cancelled` semantics.
Task 5: fix round 1/5 (3 addressed, 3 open — HMAC context zeroization, strict final progress pacing, and load-bearing auth/metadata/mutation tests remain; commits 591ea66..8e2e7fb)
Task 5: fix round 2/5 (core auth/footer handling and 10 Hz implementation addressed; 3 open — error-path crypto zeroization, load-bearing final-boundary assertion, and absolute mtime assertion; commits 8e2e7fb..85e094d)
Task 5: fix round 3/5 (3 addressed, 0 open — immediate crypto error cleanup and load-bearing final-progress/mtime assertions; commits 85e094d..e0e08b6)
Task 5: complete (commits 84e08b1..e0e08b6, review approved; 3 deferred minors)
Task 6: minor (deferred): enforce the hard 100,000-entry ceiling in the exported C API instead of trusting the supplied limit.
Task 6: minor (deferred): normalize already-cancelled Swift calls to stable `ProtectedZIPError.cancelled` rather than raw `CancellationError`.
Task 6: minor (deferred): add exact compile/run commands for the temporary AES-128/192 fixture generator to the fixture README.
Task 6: minor (deferred): replace or wrap the vendor ZipCrypto reader so derived key state is securely cleared on close/delete.
Task 6: minor (deferred): eliminate SwiftPM unhandled-fixture warnings without weakening fixture loading.
Task 6: initial review (6 Important open — symlink progress, cleanup ownership/recovery, stable root FD, mode/mtime preservation, AES 1...1024 passwords, complete password-free link preflight; commit e0e08b6..85a8092)
Task 6: fix round 1/5 (3 resolved — symlink progress/auth, owned FDs/root identity, AES password boundaries; 3 Important open — post-create identity-failure recovery, depth-ordered directory metadata, oversized-initial-progress deadlock; link-preflight and false-size extraction coverage also incomplete; commits 85a8092..ed363f1)
Task 6: fix round 2/5 (post-create recovery, depth-ordered metadata, symlink/false-size coverage resolved; 1 Important open — representable initial progress is signaled before async cancellation callback, reintroducing completion-before-cancel race; commits ed363f1..fc6c9d1)
Task 6: fix round 3/5 (1 addressed, 0 open — one-shot progress gate preserves cancellation boundary and oversized-value escape; commits fc6c9d1..0ddfe05)
Task 6: complete (commits e0e08b6..0ddfe05, review approved; 5 deferred minors)
Task 7: initial review (4 Important open — stale-sheet cross-submit, pending lifecycle/deinit completion, load-bearing boundary/race/view secrecy tests, extraction AES-warning model; commit 0ddfe05..f1d1714)
Task 7: fix round 1/5 (3 resolved — stale-submit isolation, exact-once lifecycle/races, creation-only AES warning; 1 Important open — load-bearing live form boundary/Return and sentinel-bearing accessibility/stored-state tests; commits f1d1714..a2b3c07)
Task 7: fix round 2/5 (live form/secrecy coverage resolved; 1 Important open — accessibility projection speaks stale/generic English label instead of current localized validation state; commits a2b3c07..6a3cdb7)
Task 7: fix round 3/5 (1 addressed, 0 open — prior-attempt and current validation VoiceOver messages localized and independent; commits 6a3cdb7..1321335)
Task 7: complete (commits 0ddfe05..1321335, review approved)
Task 8: minor (planned with fix round 1): extraction diagnostics must use the source archive basename, not the destination directory basename.
Task 8: initial review (3 Important open — cleanup failure masked by cancellation, post-publication cleanup loses success/undo state, mandatory security-gate tests not load-bearing; commit 1321335..0260aea)
Task 8: fix round 1/5 (cleanup precedence and basename resolved; 2 Important open — combined post-publication+prepared cleanup shadows public metadata, remaining router/retry/cancellation/staged-identity tests not load-bearing; commits 0260aea..b4712e9)
Task 8: fix round 2/5 (combined cleanup metadata and five load-bearing gaps resolved; 1 Important open — actual mixed router test does not populate/assert safe-relative-path metadata; commits b4712e9..92f16af)
Task 8: minor (deferred): replace coordinator-test polling sleep with a deterministic prompt-activation continuation/event signal.
Task 8: fix round 3/5 (safe-relative-path cross-route merge coverage resolved with real-service result decoration; commits 92f16af..cfb661c)
Task 8: complete (commits 1321335..cfb661c, review approved; 1 deferred minor)
Task 9: initial review (1 Important open — defaulted three-argument compression API breaks typed references to the prior two-argument method; commit cfb661c..1bd8c23)
Carry to Task 10: make the operation-center Pause control visibly unavailable while `.waitingForPassword`; Task 9 controller semantics already no-op correctly.
Task 9: fix round 1/5 (legacy two-argument compression overload restored with compile-bearing typed-reference coverage; commits 1bd8c23..f3e4519)
Task 9: complete (commits cfb661c..f3e4519, review approved; controller-to-real-service staging cleanup remains a documented evidence limitation covered separately by Task 8)
Task 10: initial review (2 Important open — password sheet can be displaced/cancelled or stale-dismiss a newer request; AppKit menu tests are source-substring checks rather than live NSMenu/selector coverage; commit f3e4519..08bf97d)
Task 10: fix round 1/5 (modal identity/lifecycle resolved; 1 Important test gap open — live NSMenu test lacks disabled-policy parity and full format/TAR submenu absence assertions; commits 08bf97d..0362367)
Task 10: fix round 2/5 (live NSMenu disabled-policy parity and recursive submenu exclusion coverage resolved; commits 0362367..33e5500)
Task 10: complete (commits f3e4519..33e5500, review approved; live window/VoiceOver focus handoff remains a manual verification limit)
Task 11: initial review (2 Important open — mid-entry cancellation gates async delivery rather than native writer checkpoint; recovery test does not identify exact retained reservation or prove queued work blocks/resumes; commit 33e5500..e9c9416)
Task 11: minors planned with fix round 1 — record candidate tree/arm64 correctly, assert distinct ArchiveSecret object identities, document cache-dependent SwiftPM fixture warning inventory.
Task 11: fix round 1/5 (native checkpoint cancellation, exact recovery artifact/queue resumption, and minors resolved; 1 Important test gap open — lifecycle clears gate before operation completion, so one-shot behavior is not load-bearing; commits e9c9416..d48906c)
Task 11: fix round 2/5 (gate remains armed through completion, but release stays set so broken consumed guard still passes; 1 Important one-shot observability gap remains; commits d48906c..15cbcf1)
Task 11: fix round 3/5 (native one-shot candidate/entry counters make consumed guard load-bearing; commits 15cbcf1..e79d112)
Task 11: complete (commits 33e5500..e79d112, review approved; live external/provider/UI checks remain explicitly NOT RUN)
Task 12: initial review (2 Important open — notice backend provenance is inaccurate; package/local contracts do not prove internal cmp/otool execution and pre-publication ordering. Minors: close notice FDs earlier; distinguish historical Preview 3 guide scope; commit e79d112..e517656)
Task 12: fix round 1/5 (notice provenance, load-bearing cmp/otool/publication-order contracts, FD lifecycle, and guide scope resolved; commits e517656..e0e5e00)
Task 12: complete (commits e79d112..e0e5e00, review approved; release/publication and physical manual checks remain separate)
Final verification gate: HEAD e0e5e00; fresh full suite 1033/76 passed in 49.967s, package contract passed, build --verify/cmp/otool/codesign/bash syntax/diff/status passed.
Whole-feature final review (base 856d2f5..head e0e5e00): 4 Important open — ZipCrypto derived state not wiped; ArchiveSecret creates non-zeroized temporary byte arrays; protected writer lacks 100,000-entry creation cap; normal Quit can orphan plaintext extraction staging. No Critical.
Whole-feature final review Minors deferred pending Important fixes — redact/remove reflectable ArchivePasswordSubmission; make icon/notice resource publication exclusive rather than replacing rename.

Final review Important #3 (entry-count ceiling): harden protected ZIP creation
with a production-only 100,000-entry maximum. Directory enumeration rejects
the 100,001st candidate before path or symlink allocation, and the append
primitive repeats the guard before ownership transfer. The stable
`PENGRID_ZIP_STATUS_OVERFLOW` ABI maps to Swift `.entryCountOverflow`. A
dlsym-only in-memory probe exercises the real append path: the 100,000th append
passes and the 100,001st returns overflow. The compression-service regression
uses a one-shot overflow engine and proves no public archive or staging
residue. TDD RED/GREEN and mutation evidence are recorded in
`docs/verification/2026-08-06-password-protected-zip.md` and
`.superpowers/sdd/2026-08-06-password-protected-zip/final-fix-b-entry-count.md`.
Focused writer/service (44), broad ProtectedZIP (104), and full serial Swift
(1,048 tests in 76 suites) passed; build verification and package release
contract passed. (Commit pending.)
