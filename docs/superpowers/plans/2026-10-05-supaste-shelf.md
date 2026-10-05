# Supaste-inspired Top Shelf Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans for task execution. Steps use checkbox syntax for tracking.

**Goal:** Pengrid 상단에서 파일·텍스트·이미지를 수동 보관, 검색, 다시 복사/드래그하고 파일 작업 진행률을 본다. 보관 기간은 사용자가 선택한다.
**Architecture:** 앱 소유 store와 단일 NSPanel, 명시적 pasteboard 경계, 직렬화된 로컬 snapshot 저장. 기존 작업 엔진/검색 분석기를 재사용한다.
**Tech Stack:** macOS 15+, Swift 6, SwiftUI, AppKit, ImageIO, Swift Testing. 새 의존성 없음.
**Spec:** `docs/superpowers/specs/2026-10-05-supaste-shelf-design.md`

## Global Constraints

- 기본 OFF, 기본 `Clear on Quit`; `Keep Between Launches`는 명시적 선택만 가능하다.
- 자동 수집/네트워크/키 입력 주입 없음. 일반 클립보드는 사용자가 UI에서 가져오기/Copy를 누를 때만 접근한다.
- 최대 50항목, 텍스트 256KiB, 단일 프레임 PNG/TIFF 이미지 인코딩 16MiB/40MP, 합계 64MiB. 파일 URL은 16KiB 이하 참조뿐이다.
- Copy-only drag, Clear/OFF/종료가 원본 파일이나 시스템 클립보드를 변경하지 않는다.
- main과 기존 WIP를 보존하고 이 worktree만 수정한다. commit/push마다 Ponytail review 및 gate 승인을 별도로 실행한다.
- 수행 방식은 기존 사용자 지시대로 root가 설계·핵심 통합, Luna가 경계가 명확한 구현을 담당한다. 승인된 범위의 단계별 재승인은 반복하지 않는다.

## Review Focus

1. 다른 앱의 복사로 입력 세대가 바뀌었을 때 다른 내용을 저장하지 않기(Task 2).
2. 선택한 파일이 있는 주창으로 보관함 Delete/Paste가 새지 않기(Task 4).
3. Clear/옵션 변경 후 오래된 비동기 저장이 자료를 되살리지 않기(Task 3).
4. 손상·거대한 이미지나 로컬 symlink를 복원하지 않기(Task 1/3).
5. 앱 종료와 쓰기가 겹쳐도 실패를 숨기거나 마지막 기록을 잃지 않기(Task 3/4).

## Task 1: Value model, limits, search (Luna)

**Files:** `Sources/BloomFileManager/Models/ShelfItem.swift`, `Tests/BloomFileManagerTests/ShelfItemTests.swift`.
**Interfaces:** `ShelfContentKind` file/text/image; `ShelfImageFormat` png/tiff; `ShelfContent` file(URL)/text(String)/image(Data, ShelfImageFormat); `ShelfItem(id: UUID = UUID(), content: ShelfContent, createdAt: Date = Date())` Codable/Sendable/Equatable/Identifiable. Properties `id`, `content`, `createdAt`, `kind`, bounded `displayName`, and `byteCount`. `ShelfItem.validatedAddition(_:to:) throws -> [ShelfItem]` validates the complete input before mutation, rejects duplicate UUIDs, and ignores exact file-URL duplicates. `ShelfItem.search(_:query:kind:) -> [ShelfItem]` uses the existing analyzer; callers run it off-main. `ShelfItemError` is a `LocalizedError` consumer-facing error type.
- [x] `ShelfItemTests` covers 51st item/oversized text/corrupt and multiframe images, duplicate file URLs, encoded round-trip, initials/literal/punctuation/type filtering, bounded display names, restored duplicate IDs, and malformed/non-local file URLs.
- [x] Test-first shell check recorded; the Task 1 RED was a missing-type compile failure, not an assertion-level RED.
- [x] Implemented the model and validation/search behavior.
- [x] Final focused run passed: 50 tests in 8 suites, including `ShelfItemTests`, clipboard, persistence, store, panel, and settings checks.

## Task 2: Manual pasteboard boundary (root)

**Files:** `Sources/BloomFileManager/Services/ShelfClipboard.swift`, `Tests/BloomFileManagerTests/ShelfClipboardTests.swift`.
**Interfaces:** `ShelfClipboard.read(from:expectedChangeCount:) async throws -> [ShelfItem]`, `write(_:to:) throws`, `writer(for:) throws -> any NSPasteboardWriting`, and `thumbnail(for:) -> CGImage?`. Native file URL/string/PNG/TIFF writers are eager, with no shelf-lifetime callback.
- [x] Named-board tests cover type priority, concealed/transient contents, changed generation, invalid mixed file URLs, write/read round-trip, bounded thumbnails, and clipboard independence after removal.
- [x] Implemented local decoding and downsampling; failures do not mutate existing entries, and writes validate before clearing while checking the Bool write result.
- [x] Final targeted run GREEN. Tests use named boards and do not use the real general clipboard.

## Task 3: Store, retention, disk snapshot (root)

**Files:** `Sources/BloomFileManager/Stores/ShelfStore.swift`, `Sources/BloomFileManager/Stores/ShelfPersistence.swift`, `Tests/BloomFileManagerTests/ShelfStoreTests.swift`, `Tests/BloomFileManagerTests/ShelfPersistenceTests.swift`.
**Interfaces:** `ShelfRetention` clearOnQuit/keepBetweenLaunches. `ShelfPersisting: Sendable` provides async-throwing `load()`, `save(_:)`, and `remove()`; `ShelfPersistence` is an actor with an injected exact root URL. `ShelfStore` is a main-actor observable with injected `any ShelfPersisting`, entries, filtered entries, query/kind, settings, errors, pending save/restore state, input/cancellation generations, serial chained persistence tasks, and `prepareForTermination() async -> Bool`.
- [x] Tests cover default no persistence, retained restart, invalid/version/count/byte/symlink rejection, private permissions and unrelated files, failed save/erase, canceled import/search generations, pending restore invalidation, and canceled saves before a latest remove.
- [x] Implemented the binary Codable snapshot with atomic writing, private own directory (0700)/file (0600), no symlink following, safe user errors, opt-in restore validation, serial save/delete ordering, awaited termination preparation, and generation invalidation.
- [x] Final targeted run GREEN against uniquely created temporary directories and UserDefaults suites.

## Task 4: Panel and application integration (root)

**Files:** `Sources/BloomFileManager/Support/ShelfPanelController.swift`, `Sources/BloomFileManager/Views/ShelfView.swift` (contains `ShelfSettingsView`), `Sources/BloomFileManager/App/BloomFileManagerApp.swift`, existing command/settings/AX support, `Tests/BloomFileManagerTests/ShelfPanelTests.swift`, and termination tests.
- [x] Tests cover one panel, safe placement on negative/small/notched screens, workspace-command isolation, modal veto, copy-only native drop behavior, retention settings, and termination save/failure boundaries.
- [x] Implemented the nonactivating auxiliary panel and narrow pasteboard drag source/target with stable item IDs, bounded thumbnails, keyboard-accessible search/filter/Copy/Remove/Clear, and screen-change relocation.
- [x] Bound existing `FileOperationController` progress to the small view subtree and kept conflict/password/recovery controls in the main window; no new engine or polling was added.
- [x] Added the app-owned store/controller, Top Shelf settings/menu commands, isolated panel routing, and optional termination preparation.
- [x] Isolated UI bundle verification confirmed retention-option switching, Korean search input, Escape, and Command-W; the installed Pengrid app was left running.
- [ ] Do not mark the following as verified: actual cross-app drag, save-failure alert presentation, or multi-monitor hardware placement.

## Task 5: Safe regressions, docs, review and merge

**Files:** `Tests/BloomFileManagerTests/DropIntentTests.swift`, `README.md`, `README.ko.md`, `docs/user-guide.md`, `docs/user-guide.ko.md`, and `Sources/BloomFileManager/Support/HelpCatalog.swift`.
- [x] Replaced the legacy test's real clipboard dependence with an `NSTextView` test subclass using native selection commands on a named board while retaining responder-command assertions.
- [x] Package contract checks PASS. After correcting the old two-tab expectation and adding the native drop regression, the final full run passed: 2,019 tests in 131 suites, 154.538 seconds.
- [x] Documented retention/privacy, manual **Import Clipboard**, search limitations, copy-only drag, progress scope, and unavailable image file-export destinations in the README, user guides, and Help catalog. Released DMG claims remain separate from this source work.
- [x] Independent whole-branch correctness review and follow-up review passed after fixes for restore/quit ordering, failed-restore retry, symlink traversal, off-main decoding, and command isolation.
- [x] Ponytail review passed; the feature was committed, pushed, and attached as PR #18.
- [ ] CI and merge are not complete. The first CI run exposed an Xcode 16.4 test-stub isolation mismatch; the existing compatibility-conformance pattern was restored for verification.
- [ ] Merge ancestry verification and recoverable cleanup of this feature's managed worktree/generated build files are not complete.

## Execution ledger

- 2026-10-05: Top Shelf implementation, README EN/KO, user guides EN/KO, and Help catalog are complete. Named-pasteboard isolation for the legacy test is complete.
- 2026-10-05: Task 1's RED evidence was a missing-type compile failure only; it is not recorded as an assertion-level RED.
- 2026-10-05: Package contract checks PASS. The first full Swift Testing run covered 2,018 tests; one existing-tab expectation (three actual tabs versus two expected) failed. The expectation was fixed; the focused 50-test run and final 2,019-test full regression run passed.
- Verification commands: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --enable-swift-testing --no-parallel --disable-sandbox`; `/bin/bash script/tests/package_release_contract_tests.sh`. Final suite logs remain outside the worktree at `/tmp/pengrid-shelf-final-full-tests.log` and `/tmp/pengrid-shelf-package-contracts.log` for this local run.
- 2026-10-05: Isolated UI bundle checks confirmed retention-option switching, Korean search input, Escape, and Command-W while leaving the installed Pengrid app running.
- 2026-10-05: PR #18 contains the reviewed feature commit `d35d879`. CI run `37253728849` failed at compilation because the macOS 15 SDK needs `@preconcurrency NSDraggingInfo` on the main-actor-only test stub. The annotation matches the existing FavoriteDrop test pattern; production code is unchanged.
- 2026-10-05: After restoring the SDK compatibility annotation, all five `ShelfPanelTests` passed locally (0.673 seconds). The newer local SDK reports the annotation as redundant; it is retained for the supported CI SDK.
- 2026-10-05: Actual cross-app drag, save-failure alert presentation, and multi-monitor hardware behavior remain unverified. CI, merge, and archive/cleanup remain pending at this commit.
- Ruling: user already specified root + simple Luna execution and no per-step reapproval; proceed through approved tasks without another procedural approval loop.
