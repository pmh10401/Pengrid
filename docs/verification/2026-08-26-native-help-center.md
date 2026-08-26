# Native Help Center Verification — 2026-08-26

## Scope

This record covers the bilingual documentation for Pengrid's native Help
window: the **Help > Pengrid Help** command and **Command-?** shortcut, the
eight bundled topics, explicit Korean/English selection, cross-language literal
and Hangul-initial search, no-result recovery, and the two kinds of allowlisted
online destinations. It records Task 6 evidence only. Task 7 owns the complete
suite, release build, app launch, and manual UI checks.

## Automated Verification

Command:

```text
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcrun swift test --enable-swift-testing --no-parallel --filter 'HelpCatalogTests|HelpPresentationTests|AccessibilityPresentationTests'
```

Observed result:

- Exit status: `0`.
- The XCTest compatibility target reported `0` selected tests, `0` failures,
  in `0.002` seconds.
- Swift Testing reported `37` tests in `2` suites, `0` failures, in `0.272`
  seconds. `HelpCatalogTests` and `HelpPresentationTests` passed, along with
  the selected accessibility presentation tests.
- The build emitted the existing warning about 11 unhandled fixture resources;
  it did not fail the run.
- No full-suite result is claimed here.

Documentation checks run for this record:

- `32` local Markdown links in `README.md`, `README.ko.md`,
  `docs/user-guide.md`, and `docs/user-guide.ko.md` resolved successfully;
  `0` were missing.
- The two Help guide destinations resolve to the existing repository files
  `docs/user-guide.md` and `docs/user-guide.ko.md`.
- English/Korean guide sections were reviewed for matching opening, search
  examples, language persistence, eight-topic coverage, offline/online
  boundaries, and no-result recovery.

## Release Build

`NOT RUN` — the release configuration build is owned by Task 7. No release
build, packaging, installation, signing, notarization, or DMG claim was made
for this documentation task.

## Manual Checks

The following Task 7 checks remain `NOT RUN` in this record:

- Help > Pengrid Help opens one window.
- Command-? opens or focuses the same window without duplicates.
- The native Help UI works at 860×620 and at its minimum size.
- Korean/English switching preserves the selected topic and persists after
  reopening.
- English, Korean, Korean-initial, and mixed queries find their expected
  topics.
- No-result recovery clears the query.
- Search, topic list, language, detail, and error regions are keyboard reachable
  and expose meaningful VoiceOver text.
- Light and Dark appearances remain readable; Dynamic Type does not clip; and
  Reduce Motion introduces no unexpected animation.
- Bundled topics remain visible while offline.
- An allowlisted link opens the exact GitHub target online, and a rejected open
  shows bounded feedback.

## Known Boundaries

- The eight Help topics and their search text are bundled with the app. The
  native Help view adds no runtime content fetch, workspace/File Provider
  inspection, or OAuth flow.
- The user-guide and releases buttons leave Pengrid for the exact allowlisted
  GitHub HTTPS destinations and require an internet connection. If the browser
  open is rejected, the view reports bounded local feedback; the bundled topics
  remain available.
- Full-suite verification, release build verification, and all app-level manual
  checks are intentionally deferred to Task 7. The focused result above must
  not be read as a full-suite PASS.
