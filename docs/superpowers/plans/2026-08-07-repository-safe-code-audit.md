# Repository-Wide Safe Code Audit Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce a reviewable, evidence-backed manifest of Pengrid declarations that can be deleted or consolidated after the large-directory optimization, without misclassifying compatibility, runtime-dispatched, persistence, or safety code.

**Architecture:** Treat static reference counts as candidate discovery only. Cross-check every candidate against compiler/index results, selectors and callbacks, Codable/persistence keys, tests, and safety boundaries; the output is an exact deletion manifest from which a separate file-specific removal plan is written.

**Tech Stack:** Swift 6.1, Swift Package Manager, Xcode index/build diagnostics, `rg`, `git`, shell read-only inspection, Swift Testing, macOS 15.

## Global Constraints

- Execute this plan only after the large-directory optimization's full suite and release build pass.
- Prefix every `xcrun swift` command with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.
- Run tests with `--disable-sandbox --no-parallel`.
- Reference-count output never authorizes deletion by itself.
- Do not delete Codable keys, legacy decoders, compatibility overloads, selectors, SwiftUI/AppKit callbacks, command routing, reflection targets, File Provider access, file identity checks, Undo, recovery, archive safety, or protected ZIP code without separate direct evidence.
- Classify each symbol as exactly one of `proven-unused`, `duplicate`, `compatibility`, `safety-boundary`, `runtime-dispatched`, `live-large-file`, or `test-support`.
- A `proven-unused` row requires zero non-declaration references plus compiler/index, runtime-dispatch, persistence, and test review.
- A `duplicate` row requires named equivalent authority and tests proving that consolidation preserves behavior.
- This audit does not mutate production code. Its approved manifest is the input to a later file-specific deletion plan.
- Preserve unrelated worktree changes and stage only the audit report.

---

## File Structure

- Modify: `docs/verification/2026-08-07-large-directory-navigation.md`: retain the high-level audit handoff from the optimization.
- Create: `docs/verification/2026-08-07-repository-safe-code-audit.md`: exact inventory method, classified candidates, evidence, and deletion-plan input.
- Inspect: `Sources/BloomFileManager/**/*.swift`: production declarations and references.
- Inspect: `Tests/BloomFileManagerTests/**/*.swift`: direct use, compatibility expectations, selectors, and safety coverage.
- Inspect: `Package.swift`, `.github/workflows/ci.yml`, `README.md`, `README.ko.md`, `docs/**/*.md`, and `script/**/*`: build/runtime/documented entry points.

### Task 1: Freeze the verified baseline and source inventory

**Files:**
- Create: `docs/verification/2026-08-07-repository-safe-code-audit.md`
- Inspect: `Package.swift`
- Inspect: `Sources/BloomFileManager/**/*.swift`
- Inspect: `Tests/BloomFileManagerTests/**/*.swift`

**Interfaces:**
- Consumes: completed optimization verification and current `HEAD`.
- Produces: an immutable audit baseline containing commit, test count, release-build result, file sizes, and declaration inventory commands.

- [ ] **Step 1: Confirm the prerequisite branch state**

Run:

```bash
git status --short --branch
git log -1 --oneline --decorate
rg -n '^## Completion Gate|PASS|FAIL' docs/verification/2026-08-07-large-directory-navigation.md
```

Expected: no uncommitted production changes, and the optimization verification has independently passing full-suite and release-build rows.

- [ ] **Step 2: Re-run the baseline gates**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --disable-sandbox --no-parallel
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift build --disable-sandbox -c release
```

Expected: both commands exit 0. Record exact test/suite counts, duration, warnings, commit hash, macOS, and Swift version.

- [ ] **Step 3: Capture source-size and declaration inventories**

Run and paste complete outputs into collapsible or fenced sections in the audit report:

```bash
find Sources/BloomFileManager -name '*.swift' -print0 | xargs -0 wc -l | sort -nr
rg -n --pcre2 '^\s*(?:(?:private|fileprivate|internal|public|open)\s+)?(?:final\s+)?(?:class|struct|enum|actor|protocol|typealias|func|var|let)\s+[A-Za-z_][A-Za-z0-9_]*' Sources/BloomFileManager -g '*.swift'
rg -n 'legacy|compatib|deprecated|@objc|#selector|CodingKeys|decodeIfPresent|NSClassFromString|perform\(' Sources Tests -g '*.swift'
```

Do not truncate the stored command output. The report may summarize it in the main table but must preserve the raw inventory below.

- [ ] **Step 4: Create the report schema**

Use these sections and table columns exactly:

```markdown
# Repository-Wide Safe Code Audit

## Verified Baseline
## Inventory Commands and Raw Output
## Candidate Classification

| ID | Declaration | File:line | Classification | Non-declaration references | Runtime/persistence review | Relevant tests | Equivalent authority | Decision |
|---|---|---|---|---:|---|---|---|---|

## Proven Deletion Manifest
## Duplicate Consolidation Manifest
## Protected Compatibility and Safety Code
## Large Live Files
## Required Follow-Up Tests
```

- [ ] **Step 5: Commit the baseline inventory**

```bash
git add docs/verification/2026-08-07-repository-safe-code-audit.md
git commit -m "docs: inventory repository cleanup candidates"
```

### Task 2: Classify every candidate with direct evidence

**Files:**
- Modify: `docs/verification/2026-08-07-repository-safe-code-audit.md`
- Inspect: every source/test/document path referenced by a candidate.

**Interfaces:**
- Consumes: Task 1 raw declaration inventory.
- Produces: fully classified rows and exact deletion/consolidation manifests.

- [ ] **Step 1: Calculate exact-name reference evidence**

For each declaration name `NAME`, run all three searches and record commands plus results in its row or evidence note:

```bash
rg -n -w 'NAME' Sources/BloomFileManager Tests/BloomFileManagerTests -g '*.swift'
rg -n -w 'NAME' Package.swift .github README.md README.ko.md docs script
git log -S'NAME' --oneline --all -- Sources Tests
```

Count the declaration separately from non-declaration references. For overloads, inspect every signature and call-site argument labels; name count alone is not a classification.

- [ ] **Step 2: Review runtime and persistence reachability**

For every row with zero direct callers, explicitly search and record:

```bash
rg -n '@objc|#selector|Selector\(|NSSelectorFromString|perform\(|NotificationCenter|commands|CommandGroup' Sources Tests -g '*.swift'
rg -n 'Codable|CodingKeys|encode\(|decode\(|decodeIfPresent|UserDefaults|PropertyList|JSON' Sources Tests -g '*.swift'
rg -n 'NSViewRepresentable|NSApplicationDelegate|NSTableViewDelegate|NSTableViewDataSource|QLPreviewPanelDataSource|QLPreviewPanelDelegate' Sources Tests -g '*.swift'
```

If the symbol is reachable through any runtime protocol, selector, decoded field, command, notification, SwiftUI scene, or AppKit delegate, classify it `runtime-dispatched` or `compatibility`, not unused.

- [ ] **Step 3: Review safety-sensitive ownership**

Any candidate in `FileOperationController`, `FileOperationService`, `FileOperationUndoService`, `FileSystemAccess`, cloud scoped access/materialization, recovery journals, archive/protected ZIP, termination coordination, or identity models must list its safety responsibility and focused test suites. Classify it `safety-boundary` unless an approved replacement has the same authority and direct tests.

- [ ] **Step 4: Prove duplicate candidates**

For a `duplicate` row, record:

- both exact declarations and files;
- the selected surviving authority;
- semantic differences in normalization, error handling, identity, cancellation, and cloud behavior;
- every caller that will route to the survivor; and
- focused tests that already cover the survivor plus tests required before consolidation.

If any semantic difference remains, classify the row `live-large-file`, not duplicate.

- [ ] **Step 5: Populate exact manifests**

`Proven Deletion Manifest` contains only rows with declaration path, line, containing type, exact symbol/signature, and required post-delete tests. `Duplicate Consolidation Manifest` contains both source and destination signatures plus caller files. If either manifest has no qualifying row, write `No candidate met the evidence threshold in this audit.` rather than weakening the threshold.

- [ ] **Step 6: Review protected code explicitly**

Add named rows for `legacyTransfer`, Smart Search legacy decoding, archive compatibility overloads, Codable persistence keys, AppKit selectors, and task-lifecycle cancellation. Record why each remains. This prevents later cleanup work from repeatedly treating the word `legacy` or a zero direct-call callback as deletion evidence.

- [ ] **Step 7: Commit the classified audit**

```bash
git add docs/verification/2026-08-07-repository-safe-code-audit.md
git commit -m "docs: classify safe cleanup candidates"
```

### Task 3: Validate the manifest and hand off exact deletion planning

**Files:**
- Modify: `docs/verification/2026-08-07-repository-safe-code-audit.md`
- Inspect: files named by both manifests.

**Interfaces:**
- Consumes: Task 2 manifests.
- Produces: an approved, file-specific input for `superpowers:writing-plans`; no production mutation.

- [ ] **Step 1: Re-run searches for manifest rows**

Repeat exact-name, argument-label, selector, Codable, and history searches for every manifest row from a clean `HEAD`. Confirm report line numbers against `nl -ba FILE`. Remove any row whose evidence changed.

- [ ] **Step 2: Map focused and full validation for each row**

Every manifest row must name at least one focused test command and the final full-suite command. A production declaration with no focused coverage receives a new characterization-test task in the later deletion plan before its removal task.

- [ ] **Step 3: Review file boundaries**

For each `live-large-file`, document responsibility groups that can move without widening `private` access. Do not propose a split whose only mechanism is converting private state into unrestricted internal state.

- [ ] **Step 4: Mark manifest readiness**

Add one of these exact decisions:

```markdown
Audit decision: READY FOR FILE-SPECIFIC DELETION PLAN
```

or

```markdown
Audit decision: NO SAFE GLOBAL DELETION CANDIDATE
```

The first decision requires at least one fully evidenced manifest row. The second is a valid result and preserves the touched-path cleanup already completed by the optimization plan.

- [ ] **Step 5: Run documentation consistency and commit**

```bash
rg -n 'proven-unused|duplicate|compatibility|safety-boundary|runtime-dispatched|live-large-file|test-support' docs/verification/2026-08-07-repository-safe-code-audit.md
git diff --check
git add docs/verification/2026-08-07-repository-safe-code-audit.md
git commit -m "docs: finalize safe cleanup manifest"
```

- [ ] **Step 6: Invoke file-specific planning only when ready**

When the decision is `READY FOR FILE-SPECIFIC DELETION PLAN`, invoke `superpowers:writing-plans` again. That plan must name every production/test file and symbol from the manifests, use characterization RED/GREEN cycles, keep unrelated rows in separate commits, and finish with the full suite and release build. When the decision reports no safe global candidate, stop without deleting compatibility or safety code.

## Completion Gate

- The optimization full suite and release build were reverified before auditing.
- Raw inventories and commands are preserved.
- Every candidate has exactly one classification and direct evidence.
- Runtime, Codable, callback, selector, command, and safety reachability were reviewed.
- Protected compatibility and safety code is named explicitly.
- Deletion and duplicate manifests contain exact signatures and test commands or explicitly state that none qualified.
- Production code is unchanged by this audit.
- The final decision authorizes an exact deletion plan or safely records that no global candidate qualifies.
