# Pengrid README Product Landing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the long English and Korean feature manuals in the repository root with concise, release-accurate product landing pages.

**Architecture:** Both README files will share the same section order and release facts while using natural copy for each language. The root README will explain the product and link into the existing user guide, release notes, architecture, limitations, and verification documents for detailed behavior.

**Tech Stack:** GitHub-flavored Markdown, repository PNG asset, shell-based documentation checks, Git

## Global Constraints

- Current release is Pengrid 1.3.0 Developer Preview 6, app version 1.3.0 build 8.
- Published verification is 1,407 automated tests in 92 suites.
- Published DMG SHA-256 is `ece6212bd5f80d21bc64ef2059839db8a79a416b3706b140b1c4155dbe801b32`.
- Requirements remain Apple Silicon and macOS 15 or later.
- The DMG is ad-hoc signed, not Developer ID signed, and not notarized.
- Google Drive and OneDrive integration uses macOS File Provider; Pengrid has no direct Google or Microsoft OAuth client.
- Reuse `Assets/Pengrid/AppIcon-1024.png`; create no new binary asset or external badge dependency.
- English and Korean READMEs must have equivalent section coverage and valid repository-relative links.

---

### Task 1: English Product Landing Page

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: the published Preview 6 release facts and existing detailed documents
- Produces: the canonical English section order and product terminology mirrored by Task 2

- [ ] **Step 1: Record the current long-form structure**

```bash
rg -n '^#{1,3} ' README.md
test "$(wc -l < README.md)" -gt 180
```

Expected: the file has separate long-form feature sections and is longer than 180 lines.

- [ ] **Step 2: Replace the English README with the approved landing structure**

Write these sections in this exact order:

```markdown
<p align="center"><img src="Assets/Pengrid/AppIcon-1024.png" width="160" alt="Pengrid app icon"></p>
<h1 align="center">Pengrid</h1>
<p align="center"><strong>A fast, keyboard-friendly dual-pane file manager for macOS.</strong><br><a href="README.ko.md">한국어</a> · <strong>English</strong></p>
## Download
## Why Pengrid
## What You Can Do
### Navigate and manage two panes
### Find files quickly
### Preview and act without losing context
### Run safer file operations
### Create and extract archives
### Work with cloud locations and accessibility tools
## Essential Shortcuts
## Cloud and Safety Boundaries
## Build from Source
## Documentation
```

Keep the download URL, release URL, version, build, platform, test count, checksum, and trust notice verbatim. Summarize behavior in short paragraphs and bullets; link detailed rules to `docs/user-guide.md` and the Preview 6 release notes.

- [ ] **Step 3: Verify the English contract**

```bash
rg -n 'Assets/Pengrid/AppIcon-1024.png|v1.3.0-developer-preview.6|1,407|ece6212bd5f80d21bc64ef2059839db8a79a416b3706b140b1c4155dbe801b32|ad-hoc|not notarized|File Provider|does not implement direct Google or Microsoft OAuth' README.md
test "$(wc -l < README.md)" -lt 180
```

Expected: every release and boundary string is present, and the README is shorter than the previous 196-line version.

- [ ] **Step 4: Commit the English landing page**

```bash
git add README.md
git commit -m "docs: reshape English README as product landing"
```

---

### Task 2: Korean Product Landing Page

**Files:**
- Modify: `README.ko.md`

**Interfaces:**
- Consumes: the canonical section order and product terminology from Task 1
- Produces: a natural Korean landing page with equivalent coverage

- [ ] **Step 1: Record the current Korean long-form structure**

```bash
rg -n '^#{1,3} ' README.ko.md
test "$(wc -l < README.ko.md)" -gt 180
```

Expected: the Korean README mirrors the old detailed structure and is longer than 180 lines.

- [ ] **Step 2: Replace the Korean README with the matching landing structure**

Use natural Korean under this exact section order:

```markdown
<p align="center"><img src="Assets/Pengrid/AppIcon-1024.png" width="160" alt="Pengrid 앱 아이콘"></p>
<h1 align="center">Pengrid</h1>
<p align="center"><strong>빠르고 키보드 친화적인 macOS용 듀얼 패널 파일 관리자입니다.</strong><br><strong>한국어</strong> · <a href="README.md">English</a></p>
## 다운로드
## Pengrid를 선택하는 이유
## 주요 기능
### 두 패널에서 탐색하고 관리하기
### 파일을 빠르게 찾기
### 작업 흐름을 유지하며 미리보고 실행하기
### 더 안전하게 파일 작업 실행하기
### 압축 파일 만들고 풀기
### 클라우드 위치와 접근성 도구 사용하기
## 주요 단축키
## 클라우드 및 안전 범위
## 소스에서 빌드하기
## 문서
```

Keep the same release facts and warnings as the English README. Translate naturally, preserve application command names, and link to `docs/user-guide.ko.md`, `docs/release.ko.md`, and the bilingual release notes.

- [ ] **Step 3: Verify the Korean contract**

```bash
rg -n 'Assets/Pengrid/AppIcon-1024.png|v1.3.0-developer-preview.6|1,407|ece6212bd5f80d21bc64ef2059839db8a79a416b3706b140b1c4155dbe801b32|ad-hoc|공증|File Provider|직접 Google 또는 Microsoft OAuth' README.ko.md
test "$(wc -l < README.ko.md)" -lt 180
```

Expected: every release and boundary string is present, and the Korean README is shorter than the previous 197-line version.

- [ ] **Step 4: Commit the Korean landing page**

```bash
git add README.ko.md
git commit -m "docs: reshape Korean README as product landing"
```

---

### Task 3: Cross-Language and Release Verification

**Files:**
- Verify: `README.md`
- Verify: `README.ko.md`
- Reference: `docs/release.md`
- Reference: `docs/release.ko.md`
- Reference: `docs/release-notes-v1.3.0-developer-preview.6.md`

**Interfaces:**
- Consumes: both completed landing pages and the published GitHub release
- Produces: a clean, internally consistent documentation change ready for review

- [ ] **Step 1: Verify headings and relative links**

```bash
rg -n '^#{1,3} ' README.md README.ko.md
python3 - <<'PY'
from pathlib import Path
import re

for name in ("README.md", "README.ko.md"):
    text = Path(name).read_text()
    for target in re.findall(r'\[[^]]+\]\(([^)]+)\)', text):
        if "://" not in target and not Path(target.split("#", 1)[0]).exists():
            raise SystemExit(f"broken relative link in {name}: {target}")
print("README relative links: PASS")
PY
```

Expected: both files have matching high-level coverage and every relative link resolves.

- [ ] **Step 2: Verify release facts and unsupported-claim boundaries**

```bash
for file in README.md README.ko.md; do
  rg -q 'v1.3.0-developer-preview.6' "$file"
  rg -q '1,407' "$file"
  rg -q 'ece6212bd5f80d21bc64ef2059839db8a79a416b3706b140b1c4155dbe801b32' "$file"
done
! rg -n 'Developer ID signed and notarized|직접 OAuth를 지원|direct OAuth support' README.md README.ko.md
```

Expected: both files carry identical release evidence and contain no unsupported signing or OAuth claim.

- [ ] **Step 3: Run final documentation hygiene checks**

```bash
rg -n 'TBD|TODO|Preview [0-5]|1,40[0-6]' README.md README.ko.md && exit 1 || true
git diff --check origin/main...HEAD
git status --short
```

Expected: the stale-value scan has no matches, `git diff --check` exits 0, and status lists no uncommitted README changes.
