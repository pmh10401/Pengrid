# Pengrid Developer Preview 3 Documentation Refresh Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish detailed, equivalent English and Korean documentation for Pengrid 1.3.0 Developer Preview 3 while preserving candidate-specific historical verification records.

**Architecture:** GitHub's default `README.md` stays a concise English landing page and links to a Korean equivalent. Paired English/Korean user guides contain detailed feature behavior, while paired release guides contain packaging and trust information; the engineering checklist receives an append-only Preview 3 evidence entry.

**Tech Stack:** GitHub-flavored Markdown, Git, GitHub CLI, shell-based link and release-metadata validation.

## Global Constraints

- The published release is `Pengrid 1.3.0 Developer Preview 3`, tag `v1.3.0-developer-preview.3`.
- The candidate commit is `5ec4c8789bf7a101b2fbdfd3cb80ccbf062a3bc6`.
- The app version is `1.3.0`, build `5`, for Apple Silicon on macOS 15 or later.
- The verified automated result is 851 tests in 66 suites.
- The DMG SHA-256 is `1a0498c45ecc13ba57f2a4f8553ef1b0f760cca004cef2d46307780c6b29f0df`.
- The DMG is ad-hoc signed, not Developer ID signed, not notarized, and expected to fail Gatekeeper's Developer ID assessment.
- Do not edit `docs/blog/2026-07-29-pengrid-naver-blog.md`.
- Do not rewrite older version checklists, plans, specs, or dated evidence.
- Do not recommend removing quarantine attributes or bypassing macOS security controls.
- English/Korean document pairs must contain equivalent facts, commands, limitations, and links.

---

### Task 1: Bilingual repository landing pages

**Files:**
- Modify: `README.md`
- Create: `README.ko.md`

**Interfaces:**
- Consumes: Preview 3 release facts from the design specification and the existing detailed behavior in `README.md`.
- Produces: concise English and Korean entry points linked to the detailed guides and release instructions created in later tasks.

- [ ] **Step 1: Restructure the English landing page**

Keep the project identity and source-build instructions. Add a top-level language
link to `README.ko.md`, direct links to the release page and DMG, the exact
version/build/platform/checksum, and a visible unsigned trust warning. Replace
long feature implementation passages with concise summaries of dual-pane
navigation, Smart Search, folder preview, safe operations, archives, cloud
locations, Storage Inspector, and accessibility. Link detailed behavior to
`docs/user-guide.md` and packaging details to `docs/release.md`.

- [ ] **Step 2: Create the equivalent Korean landing page**

Translate the same structure and facts into natural Korean. Link back to
`README.md`, to `docs/user-guide.ko.md`, and to `docs/release.ko.md`.
Keep command names, paths, shortcuts, tags, hashes, and URLs byte-for-byte
identical to the English version.

- [ ] **Step 3: Validate landing-page equivalence**

Run:

```bash
rg -n 'v1\.3\.0-developer-preview\.3|1a0498c45ecc13ba57f2a4f8553ef1b0f760cca004cef2d46307780c6b29f0df|851|66|build 5|빌드 5' README.md README.ko.md
rg -n 'developer-preview\.2|Developer Preview 2' README.md README.ko.md
git diff --check -- README.md README.ko.md
```

Expected: both files contain the Preview 3 facts; the Preview 2 search prints no
matches; diff check exits 0.

- [ ] **Step 4: Commit the landing pages**

```bash
git add README.md README.ko.md
git commit -m "docs: add bilingual preview 3 overview"
```

---

### Task 2: Detailed bilingual user guides

**Files:**
- Create: `docs/user-guide.md`
- Create: `docs/user-guide.ko.md`

**Interfaces:**
- Consumes: current behavior documented in the existing README and verification documents.
- Produces: canonical user-visible behavior and limitation descriptions linked from both README files.

- [ ] **Step 1: Write the English detailed guide**

Use matching sections for requirements and installation; dual-pane workspace;
navigation and Command-F; recursive Smart Search and Korean initial-consonant
matching; Space folder preview and Quick Look; operation queue, pause,
cancellation, recovery, retry, and conservative undo; archive formats and
progress phases; Google Drive and OneDrive File Provider behavior; directory
comparison; Storage Inspector; accessibility and keyboard behavior; and known
limitations.

For every feature, describe how the user invokes it, what appears, the relevant
safety behavior, and what the feature deliberately does not do. Explicitly
distinguish pane-local filename filtering from recursive Smart Search and
metadata-only cloud search from file-content search.

- [ ] **Step 2: Write the equivalent Korean detailed guide**

Mirror every English heading and technical fact in Korean. Preserve shortcut
notation, archive suffixes, progress labels, safety limits, and unsupported
capabilities. Use “초성 검색” for Korean initial-consonant matching and explain
the examples `ㅍㄱ` → `파일관리` and `ㅍㄱ report` as a two-clause match.

- [ ] **Step 3: Validate guide coverage and parity**

Run:

```bash
for term in 'Command-F' 'Command-Shift-F' 'ㅍㄱ' 'Space' 'ZIP' 'TAR.XZ' 'Google Drive' 'OneDrive' 'Storage Inspector' 'VoiceOver'; do
  rg -F --quiet "$term" docs/user-guide.md
  rg -F --quiet "$term" docs/user-guide.ko.md
done
rg -n 'background index|file-content|OAuth|password|7z|RAR|notar' docs/user-guide.md docs/user-guide.ko.md
git diff --check -- docs/user-guide.md docs/user-guide.ko.md
```

Expected: every required feature term exists in both guides; limitations are
explicit; diff check exits 0.

- [ ] **Step 4: Commit the user guides**

```bash
git add docs/user-guide.md docs/user-guide.ko.md
git commit -m "docs: add bilingual detailed user guide"
```

---

### Task 3: Bilingual current release guides

**Files:**
- Modify: `docs/release.md`
- Create: `docs/release.ko.md`

**Interfaces:**
- Consumes: the current release artifact facts and existing unsigned/signed packaging commands.
- Produces: equivalent English/Korean release, verification, and optional signing instructions.

- [ ] **Step 1: Add the published Preview 3 snapshot to the English guide**

Add language navigation and a “Current published Developer Preview” section near
the top. Include release and DMG links, tag, commit, version/build, platform,
test count, contract-test result, arm64 result, checksum, mounted-app validation,
and expected Gatekeeper rejection. Clarify that the free release deliberately
uses unsigned mode while signed/notarized packaging remains an optional future
distribution path.

- [ ] **Step 2: Create the equivalent Korean release guide**

Translate the complete current release guide, including local unsigned packaging,
File Provider-managed workspace behavior, preserved ZIP warning, optional
Developer ID/notary workflow, validation commands, rejected-submission recovery,
and special-file/cross-volume limitations. Preserve all commands and environment
variable names exactly.

- [ ] **Step 3: Validate release-guide facts**

Run:

```bash
for file in docs/release.md docs/release.ko.md; do
  rg -F --quiet 'v1.3.0-developer-preview.3' "$file"
  rg -F --quiet '5ec4c8789bf7a101b2fbdfd3cb80ccbf062a3bc6' "$file"
  rg -F --quiet '1a0498c45ecc13ba57f2a4f8553ef1b0f760cca004cef2d46307780c6b29f0df' "$file"
  rg -F --quiet './script/package_release.sh --unsigned' "$file"
  rg -F --quiet './script/package_release.sh --signed' "$file"
done
git diff --check -- docs/release.md docs/release.ko.md
```

Expected: exact release facts and both packaging paths appear in each guide;
diff check exits 0.

- [ ] **Step 4: Commit the release guides**

```bash
git add docs/release.md docs/release.ko.md
git commit -m "docs: document preview 3 release in English and Korean"
```

---

### Task 4: Append Preview 3 engineering evidence

**Files:**
- Modify: `docs/verification/version-1.3-archive-checklist.md`

**Interfaces:**
- Consumes: release command outputs and GitHub asset metadata.
- Produces: an append-only dated evidence record without changing older candidate results or unrun manual gates.

- [ ] **Step 1: Add the Preview 3 PASS entry**

Under automated evidence, append a 2026-08-06 entry for build 5 and candidate
`5ec4c8789bf7a101b2fbdfd3cb80ccbf062a3bc6`. Record 851 tests in 66 suites,
release contract checks, arm64 production build, ad-hoc signature verification,
DMG verification, mounted bundle build 5 verification, GitHub asset digest, and
the expected `spctl` rejection caused by missing Developer ID/notarization.

- [ ] **Step 2: Clarify the release gate**

Keep every manual item `NOT RUN`. State that the unsigned Developer Preview 3
publication gate passed, while physical-manual and Developer ID/notarization
gates remain uncompleted and must not be inferred from automated evidence.

- [ ] **Step 3: Verify historical evidence was preserved**

Run:

```bash
rg -n 'build 4|625 tests|651 tests|build 5|851 tests|66 suites|v1\.3\.0-developer-preview\.3' docs/verification/version-1.3-archive-checklist.md
git diff --check -- docs/verification/version-1.3-archive-checklist.md
```

Expected: both old and new candidate records remain; diff check exits 0.

- [ ] **Step 4: Commit the verification update**

```bash
git add docs/verification/version-1.3-archive-checklist.md
git commit -m "docs: record preview 3 release evidence"
```

---

### Task 5: Cross-document validation and publication

**Files:**
- Verify: `README.md`
- Verify: `README.ko.md`
- Verify: `docs/user-guide.md`
- Verify: `docs/user-guide.ko.md`
- Verify: `docs/release.md`
- Verify: `docs/release.ko.md`
- Verify: `docs/verification/version-1.3-archive-checklist.md`
- Verify unchanged: `docs/blog/2026-07-29-pengrid-naver-blog.md`

**Interfaces:**
- Consumes: all documentation tasks.
- Produces: verified bilingual documentation published on `main`.

- [ ] **Step 1: Confirm intended scope and clean Markdown**

```bash
git status -sb
git diff --check origin/main..HEAD
git diff --name-only origin/main..HEAD
```

Expected: only the design, plan, and intended documentation files are present;
the Naver blog draft is absent.

- [ ] **Step 2: Validate local Markdown targets**

Run a read-only script that extracts relative Markdown links from the six
current-facing English/Korean files, strips fragments, resolves paths relative
to each source file, and fails if a non-HTTP target does not exist.

Expected: zero missing local targets.

- [ ] **Step 3: Revalidate the published release metadata**

```bash
test "$(gh release view v1.3.0-developer-preview.3 --json assets -q '.assets[0].digest')" = 'sha256:1a0498c45ecc13ba57f2a4f8553ef1b0f760cca004cef2d46307780c6b29f0df'
test "$(gh release view v1.3.0-developer-preview.3 --json isDraft,isPrerelease -q '[.isDraft,.isPrerelease] | @tsv')" = $'false\ttrue'
```

Expected: both commands exit 0.

- [ ] **Step 4: Search for stale current-facing release claims**

```bash
rg -n 'developer-preview\.2|Developer Preview 2|build 4|625 tests|compiled app.*not|미리 빌드한 앱.*않' README.md README.ko.md docs/user-guide.md docs/user-guide.ko.md docs/release.md docs/release.ko.md
```

Expected: no matches. Historical checklist matches are intentionally excluded
from this current-facing search.

- [ ] **Step 5: Push the documentation commits**

```bash
git push origin HEAD:main
git status -sb
```

Expected: push succeeds and the local branch matches `origin/main` with no
uncommitted changes.
