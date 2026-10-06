# Preview 11 release candidate verification

Date: 2026-10-06. Candidate: **Pengrid 1.3.0, build 13**, arm64, macOS 15+.

## Local checks

| Check | Result |
| --- | --- |
| `./script/package_release.sh --unsigned` | PASS; full tests and production build ran before app/DMG publication. |
| Swift Testing | **2,055 tests in 131 suites**, 98.581 seconds, PASS. |
| Production build | PASS, 58.72 seconds; Xcode 27.0 (27A266a). |
| `/bin/bash script/tests/package_release_contract_tests.sh` | PASS, exit 0. |
| Shell syntax and `git diff --check` | PASS. |
| Documentation links | 83 local links/images across 12 documents, PASS before this record was added. |
| App signature and DMG checksum | PASS; ad-hoc signature, no Developer ID or notarization. |
| Bundled icon and third-party notice | Byte-for-byte match to repository files. |
| App metadata | Version 1.3.0, build 13, minimum macOS 15.0; English/Korean localizations declared. |

The DMG SHA-256 is:

```text
f301912da63e127e644988e82f4948db17bdfe09f4333585cb262e7b94aa27b1
```

The packaged executable SHA-256 is:

```text
3201b9a7211fd6cbfe834b024c4e22cc6ecf2548e39c4436ba959a28ea6eaf3e
```

Rerun from the repository with full Xcode and the macOS 26+ SDK:

```bash
./script/package_release.sh --unsigned
/bin/bash script/tests/package_release_contract_tests.sh
codesign --verify --deep --strict dist/release/Pengrid.app
hdiutil verify dist/release/Pengrid.dmg
shasum -a 256 dist/release/Pengrid.dmg
```

## Presentation and limits

Native sample-data checks covered horizontal/vertical shelf layouts, retained
search/category/selection, selected-card scrolling, appearance settings and
Korean menus. Four unretouched screenshots are documented in
[screenshot provenance](../images/README.md). The sample presentation host did
not import the user's clipboard, personal files or signed-in cloud account.

This is not full physical-pointer hover, multi-display, signed-in File Provider,
VoiceOver or external/case-sensitive-volume qualification. Those checks were
not newly run for this candidate. Some dialog/error/workspace labels remain
English. Eleven existing SwiftPM fixture warnings and the existing minizip C
integer-conversion warning remain. They did not fail these checks.

GitHub checks and public download verification happen after publication; their
status must be read from the corresponding PR/run and release, not inferred
from this local record. This unsigned mode did not produce a new ZIP asset.

The first [PR CI run](https://github.com/pmh10401/Pengrid/actions/runs/37400824668)
failed at test compilation: Xcode 26.3 could not infer the compound arithmetic
inside the four-card width assertion. The independently derived minimum remains
992 points; a typed local constant now separates arithmetic from `#expect`.
No assertion was removed and no production app, resource or packaging input
changed. CI must pass on this test-only correction before merge and release.

The next [PR CI run](https://github.com/pmh10401/Pengrid/actions/runs/37401666083)
compiled but exposed four test assumptions. Its 1024-point display legitimately
clamps a full-width shelf rather than moving it by 24/32 points. Native reveal
and move-notification tests now wait for their actual state and check screen
bounds, rather than assuming a free-floating window or an 80 ms deadline.
The session debounce test now checks for no save before its real 300 ms boundary;
its old 180 ms sleep resumed after 324 ms on the loaded runner. No production
logic or packaging input changed; these are test-only portability corrections.
