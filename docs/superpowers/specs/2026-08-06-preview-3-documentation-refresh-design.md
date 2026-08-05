# Pengrid Developer Preview 3 documentation refresh design

Date: 2026-08-06 (Asia/Seoul)

## Goal

Bring Pengrid's current-facing documentation into agreement with the published
`v1.3.0-developer-preview.3` release without rewriting historical verification
records. Provide equivalent English and Korean user documentation. A reader
should be able to find the current download, understand each major feature and
its limits, verify the DMG checksum, and recognize that the artifact is ad-hoc
signed and not Apple-notarized.

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

## Documentation structure

User-facing material is bilingual:

- `README.md` and `README.ko.md` provide equivalent download, quick-start,
  requirement, trust, and feature-summary information.
- `docs/user-guide.md` and `docs/user-guide.ko.md` provide equivalent,
  detailed feature and safety documentation.
- `docs/release.md` and `docs/release.ko.md` provide equivalent current
  packaging and distribution instructions.

Each paired document links to its counterpart at the top. English remains the
repository default because GitHub displays `README.md` automatically. Korean
readers can reach the full Korean version in one click. Technical verification
checklists remain in English as candidate-specific engineering records.

## Scope

### README

Update `README.md` and add `README.ko.md` so the download section prominently
links directly to the Preview 3 release and DMG. Add a compact release snapshot
containing the version, build, platform requirement, checksum, and unsigned trust
warning. Summarize the four user-facing additions represented by this release:

1. safe operation center and conservative undo;
2. accessible archive progress and bounded parallel preparation;
3. recursive Smart Search with Korean initial-consonant matching;
4. Space-key folder contents preview with system Quick Look retained for other
   selections.

Move long behavioral explanations into the paired user guides. Keep concise
summaries and links in both README files so the landing pages remain easy to
scan.

### Detailed user guides

Create `docs/user-guide.md` and `docs/user-guide.ko.md`. Both documents
describe the same behavior and limits in detail:

1. dual-pane navigation, independent history, sorting, selection restoration,
   and pane-local Command-F filtering;
2. recursive Smart Search, Korean initial-consonant and mixed-clause matching,
   metadata filters, saved searches, result actions, identity revalidation, and
   non-materialization of cloud-only content;
3. Space-key folder contents preview, system Quick Look routing, selection
   updates, metadata-only folder listing, and unavailable cloud metadata;
4. the single-worker file-operation queue, reordering, pause checkpoints,
   cancellation cleanup, recovery review, bounded session history, safe retry,
   and mutation-owned conservative undo;
5. ZIP and TAR-family creation and extraction, aliases, collision behavior,
   bounded parallel staging, indeterminate native encoding, progress phases,
   cancellation, and unsupported formats;
6. Google Drive and OneDrive File Provider integration, including what Pengrid
   discovers through macOS and when macOS may materialize data;
7. Storage Inspector scope, duplicate verification, privacy boundaries, and
   Trash-only cleanup;
8. directory comparison, copy and move safety, accessibility behavior, keyboard
   commands, current platform constraints, and known release limitations.

The guides explain user-visible outcomes before internal safety rationale. They
must not promise background indexing, file-content search, direct provider OAuth,
per-byte archive progress, password archives, 7z/RAR support, permanent deletion,
or Apple notarization.

### Release guide

Add a current published Developer Preview section near the top of
`docs/release.md`, and add an equivalent Korean `docs/release.ko.md`. Record
the release link, tag, candidate commit, build, automated evidence, checksum,
and trust classification. Retain the signed and notarized workflow as an
optional future path, but do not describe it as a current release blocker for
the explicitly unsigned free Developer Preview. Manual physical checks remain
open and must not be converted to passes.

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

## Historical-record policy

Do not edit prior version checklists, implementation plans, or design specs
merely because they mention older releases. Their dates and candidate-specific
facts are intentional history. Only current-facing statements that falsely
claim no compiled preview exists, or that point users to Preview 2 as the latest
download, are stale. The Naver blog draft is explicitly outside this refresh
and remains unchanged.

## Validation

After editing:

1. run `git diff --check`;
2. inspect every changed Markdown diff;
3. search the selected current-facing files for Preview 2 links and source-only
   distribution claims;
4. confirm all local Markdown link targets exist;
5. compare each English/Korean pair for matching headings, release facts,
   feature coverage, limitations, links, commands, and checksum;
6. query the GitHub Preview 3 release and compare its asset digest with the
   documented SHA-256;
7. confirm only the intended documentation files changed and that the Naver
   blog draft is untouched.

No product rebuild is required because this work changes documentation only.
The completed documentation commit is pushed to `main` after validation.
