# Pengrid Developer Preview 3 documentation refresh design

Date: 2026-08-06 (Asia/Seoul)

## Goal

Bring Pengrid's current-facing documentation into agreement with the published
`v1.3.0-developer-preview.3` release without rewriting historical verification
records. A reader should be able to find the current download, understand the
main features and platform requirements, verify the DMG checksum, and recognize
that the artifact is ad-hoc signed and not Apple-notarized.

## Source of truth

The update records these already verified release facts:

- Release: `Pengrid 1.3.0 Developer Preview 3`
- Tag: `v1.3.0-developer-preview.3`
- Candidate commit: `5ec4c8789bf7a101b2fbdfd3cb80ccbf062a3bc6`
- App version: `1.3.0`, build `5`
- Platform: Apple Silicon, macOS 15 or later
- Automated result: 851 tests in 66 suites
- DMG SHA-256:
  `1a0498c45ecc13ba57f2a4f8553ef1b0f760cca004cef2d46307780c6b29f0df`
- Trust state: ad-hoc signed, not Developer ID signed, not notarized, and
  expected to be rejected by Gatekeeper's Developer ID assessment

The GitHub release page and its uploaded asset digest are authoritative for the
public download. Repository checklists remain authoritative for manual checks
that have not been run.

## Scope

### README

Update `README.md` so the download section prominently links directly to the
Preview 3 release and DMG. Add a compact release snapshot containing the version,
build, platform requirement, checksum, and unsigned trust warning. Summarize the
four user-facing additions represented by this release:

1. safe operation center and conservative undo;
2. accessible archive progress and bounded parallel preparation;
3. recursive Smart Search with Korean initial-consonant matching;
4. Space-key folder contents preview with system Quick Look retained for other
   selections.

Keep detailed feature sections as the canonical behavior descriptions and avoid
duplicating their implementation details in the download section.

### Release guide

Add a current published Developer Preview section near the top of
`docs/release.md`. Record the release link, tag, candidate commit, build,
automated evidence, checksum, and trust classification. Retain the signed and
notarized workflow as an optional future path, but do not describe it as a
current release blocker for the explicitly unsigned free Developer Preview.
Manual physical checks remain open and must not be converted to passes.

### Version 1.3 verification

Append a dated Preview 3 automated-evidence entry to
`docs/verification/version-1.3-archive-checklist.md`. Preserve the build 4,
625-test, and earlier phase-progress entries as historical evidence. The new
entry records the exact candidate commit, build 5, 851 tests in 66 suites,
release contract result, arm64 build, DMG verification, mounted bundle
verification, published asset digest, and expected Gatekeeper rejection.

The release-gate wording will distinguish:

- published unsigned Developer Preview status, which is complete; and
- signed/notarized distribution and outstanding physical-manual checks, which
  remain uncompleted.

### Naver blog draft

Update `docs/blog/2026-07-29-pengrid-naver-blog.md` from its earlier
source-only status to the current downloadable Developer Preview. Add a concise
feature overview, requirements, release link, checksum verification command,
and a plain-language warning that macOS may block the app because it is not
Developer ID signed or notarized. Do not instruct readers to remove quarantine
attributes or otherwise bypass macOS security controls.

## Historical-record policy

Do not edit prior version checklists, implementation plans, or design specs
merely because they mention older releases. Their dates and candidate-specific
facts are intentional history. Only current-facing statements that falsely
claim no compiled preview exists, or that point users to Preview 2 as the latest
download, are stale.

## Validation

After editing:

1. run `git diff --check`;
2. inspect every changed Markdown diff;
3. search current-facing files for Preview 2 links and source-only distribution
   claims;
4. confirm all local Markdown link targets exist;
5. query the GitHub Preview 3 release and compare its asset digest with the
   documented SHA-256;
6. confirm only the intended documentation files changed.

No product rebuild is required because this work changes documentation only.
The completed documentation commit is pushed to `main` after validation.
