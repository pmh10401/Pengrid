# Pengrid 1.3.0 Developer Preview 7

[한국어](#한국어) · [English](#english)

## English

Developer Preview 7 expands Pengrid into a persistent multi-workspace file
manager and adds identity-checked inspection, indexed-content search, stronger
Undo/Redo, and review-first one-way folder synchronization.

### Workspace tabs and profiles

- Keep several independent dual-pane workspaces open in tabs.
- Save named folder-pair profiles and open them as new tabs without changing
  the current workspace.
- Restore tab folders, sort order, split position, active pane, and profiles
  across launches. Transient selection, filters, history, previews, and
  operation state are intentionally not restored.
- Tab switching and closing respect modal sheets, text editing, and active or
  queued file operations.

### Get Info and optional indexed-content search

- **Command-I** opens a nonmodal, read-only inspector for the captured
  selection. It reports metadata without changing names, tags, permissions,
  dates, ownership, or extended attributes.
- SHA-256 remains an explicit action for one eligible regular file.
- Smart Search can optionally query already-indexed literal file content via
  Spotlight. The option is off by default, creates no Pengrid index, provides
  no snippets, and never downloads a cloud-only file merely to search it.
- Filename and relative-path search retains Korean initial-consonant and mixed
  query support.

### Review-first one-way folder synchronization

- Compare complete left and right folder snapshots, then review a deterministic
  left-to-right or right-to-left plan before confirming it.
- The review reports Copy, Replace, Move to Trash, and Skip counts using only
  folder basenames and relative item paths.
- Unsafe roots, symbolic links, packages, special entries, type conflicts,
  unavailable items, and stale fingerprints fail closed.
- Synchronization is exclusive, non-retryable, and not Undoable. Cancellation
  rolls back only identity-proven owned changes; uncertain cleanup reports
  Recovery Needed and blocks the queue for review.
- Destination-only entries move to Trash. Pengrid does not permanently delete
  pre-existing user data.

### Undo/Redo and operation safety

- Undo and Redo use bounded per-workspace stacks and revalidate identities and
  fingerprints before each inverse mutation.
- Overlapping work invalidates stale reversal records instead of guessing.
- Duplicate, selection enclosure, archive, Trash, and folder-sync cancellation
  paths retain or restore only entries whose ownership can still be proven.

### Install and trust notice

1. Download `Pengrid.dmg` from this release.
2. Optionally verify the SHA-256 value below.
3. Open the DMG and copy `Pengrid.app` to `Applications`.

Requirements: Apple Silicon Mac, macOS 15 or later.

This free DMG is ad-hoc signed. It is not Developer ID signed or notarized, so
macOS Gatekeeper may block it. Download only from this GitHub release and use
Finder's contextual **Open** action only if you understand and accept the
warning. Pengrid does not ask you to disable macOS security controls.

### Verification

- App version: 1.3.0 (build 9)
- Packaged source commit: `c0fd61b4af8a42749d6870747eb6de4fc7ec5026`
- 1,645 automated tests passed in 110 suites
- Release packaging contract tests and arm64 production build passed
- App and mounted-DMG signatures, bundle version, architecture, resources,
  native linkage, and DMG checksum passed
- The packaged app was installed as `/Applications/Pengrid.app`, verified as
  build 9, and launched from that exact path
- DMG SHA-256:
  `d7060401f05bbaac7f1d64b76d5bce6b93708c75644c8c3737698e8a3144fd73`

Local folder-sync dry reviews, cancellation/rollback, active-tab close gating,
and review-sheet VoiceOver received partial manual verification. Completed
left-to-right/right-to-left synchronization, Recovery Needed acknowledgement,
signed-in Google Drive/OneDrive execution, unavailable-provider behavior,
physical removable/case-sensitive volume tests, and the remaining archive
interoperability matrix are still `NOT RUN`. Google Drive and OneDrive use
macOS File Provider; Pengrid does not include a direct Google or Microsoft
OAuth/API client.

## 한국어

Developer Preview 7은 Pengrid를 여러 작업 공간을 유지하는 파일 관리자로
확장하고, 동일성을 검사하는 정보 보기, 색인 내용 검색, 강화된 Undo/Redo 및
검토 우선 단방향 폴더 동기화를 추가합니다.

### 작업 공간 탭과 프로필

- 서로 독립된 듀얼 패널 작업 공간을 여러 탭에 열어 둘 수 있습니다.
- 이름 있는 폴더 쌍 프로필을 저장하고 현재 작업 공간을 바꾸지 않은 채 새
  탭으로 열 수 있습니다.
- 앱을 다시 실행하면 탭 폴더, 정렬, 분할 위치, 활성 패널 및 프로필을
  복원합니다. 선택, 필터, 기록, 미리보기 및 작업 상태는 복원하지 않습니다.
- 모달 시트, 텍스트 편집 및 실행 중이거나 대기 중인 파일 작업이 있으면 탭
  이동과 닫기를 안전하게 제한합니다.

### Get Info와 선택 가능한 색인 내용 검색

- **Command-I**는 캡처한 선택 항목의 읽기 전용 비모달 검사기를 엽니다.
  이름, 태그, 권한, 날짜, 소유권 또는 확장 속성을 변경하지 않습니다.
- SHA-256은 적격 일반 파일 하나에서 명시적으로 실행할 때만 계산합니다.
- Smart Search는 선택적으로 Spotlight가 이미 색인한 일반 문자열 내용을
  검색합니다. 기본값은 꺼짐이며 Pengrid 색인이나 스니펫을 만들지 않고,
  검색만을 위해 클라우드 전용 파일을 내려받지 않습니다.
- 파일명과 상대 경로 검색은 한글 초성 및 혼합 쿼리를 계속 지원합니다.

### 검토 우선 단방향 폴더 동기화

- 좌우 폴더의 전체 스냅샷을 비교한 뒤 왼쪽→오른쪽 또는 오른쪽→왼쪽 계획을
  확인하고 실행합니다.
- 검토 시트는 폴더 이름과 상대 경로만 사용해 Copy, Replace, Move to Trash 및
  Skip 수를 표시합니다.
- 안전하지 않은 루트, 심볼릭 링크, 패키지, 특수 항목, 종류 충돌, 사용할 수
  없는 항목 및 오래된 지문은 변경 전에 차단합니다.
- 동기화는 배타적이며 다시 시도하거나 Undo할 수 없습니다. 취소는 동일성이
  확인된 이 작업 소유 변경만 롤백합니다. 정리를 확신할 수 없으면 Recovery
  Needed를 표시하고 검토할 때까지 큐를 막습니다.
- 대상에만 있는 항목은 휴지통으로 이동하며 기존 사용자 데이터를 영구
  삭제하지 않습니다.

### Undo/Redo와 작업 안전성

- Undo와 Redo는 작업 공간별 제한된 스택을 사용하고 각 역변경 전에 동일성과
  지문을 다시 검사합니다.
- 겹치는 새 작업은 오래된 역변경 기록을 추측해서 사용하지 않고 무효화합니다.
- Duplicate, 선택 항목 폴더화, 압축, Trash 및 폴더 동기화 취소 경로는 소유권을
  계속 증명할 수 있는 항목만 정리하거나 복원합니다.

### 설치 및 신뢰 안내

1. 이 릴리스에서 `Pengrid.dmg`를 다운로드합니다.
2. 필요하면 아래 SHA-256 값을 확인합니다.
3. DMG를 열고 `Pengrid.app`을 `Applications` 폴더로 복사합니다.

요구 사항: Apple Silicon Mac, macOS 15 이상.

이 무료 DMG는 ad-hoc 방식으로 서명되어 있습니다. Developer ID 서명과 Apple
공증을 받지 않았으므로 macOS Gatekeeper가 실행을 차단할 수 있습니다. 이
GitHub 릴리스에서만 다운로드하고 경고를 이해하고 동의하는 경우에만 Finder의
컨텍스트 **열기**를 사용하세요. Pengrid는 macOS 보안 기능을 끄도록 요구하지
않습니다.

### 검증

- 앱 버전: 1.3.0 (빌드 9)
- 패키징 소스 커밋: `c0fd61b4af8a42749d6870747eb6de4fc7ec5026`
- 110개 스위트의 자동 테스트 1,645개 통과
- 릴리스 패키징 계약 테스트와 arm64 프로덕션 빌드 통과
- 앱과 마운트한 DMG의 서명, 번들 버전, 아키텍처, 리소스, 네이티브 링크 및
  DMG 체크섬 통과
- 패키징 앱을 `/Applications/Pengrid.app`에 설치하고 빌드 9와 해당 경로의
  실행을 확인
- DMG SHA-256:
  `d7060401f05bbaac7f1d64b76d5bce6b93708c75644c8c3737698e8a3144fd73`

로컬 폴더 동기화 dry review, 취소/롤백, 활성 작업 탭 닫기 차단 및 검토 시트
VoiceOver에는 부분 수동 검증이 있습니다. 완료된 양방향 실행, Recovery Needed
확인, 로그인된 Google Drive/OneDrive 실행, 사용할 수 없는 provider 항목,
실제 이동식/대소문자 구분 볼륨 및 남은 압축 호환성 검사는 아직 `NOT RUN`입니다.
Google Drive와 OneDrive는 macOS File Provider를 사용하며 Pengrid는 Google 또는
Microsoft OAuth/API 직접 클라이언트를 포함하지 않습니다.
