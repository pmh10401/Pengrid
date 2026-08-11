# Pengrid 1.3.0 Developer Preview 6

[한국어](#한국어) · [English](#english)

## English

Developer Preview 6 expands Pengrid's file-row and menu-bar productivity tools
while preserving the captured identity, no-overwrite, cancellation, recovery,
and conservative Undo rules used by the operation center.

### New file context actions

- **Quick Look** keeps Space and routes folders through Pengrid's metadata-only
  folder preview while files, packages, links, and multiple selections use
  system Quick Look.
- **Open With**, **Open in Other Pane**, **Show in Finder**, and **Copy Path**
  use the ordered selection captured when the command is invoked.
- **Copy to Other Pane** and **Move to Other Pane** retain the captured
  destination even if either pane navigates later.
- **Copy Full Path** uses Option-Command-C. Name, parent path, and file URL are
  also available without replacing ordinary file-URL Copy behavior.

### Safe Duplicate and selection enclosure

- **Duplicate** uses Command-D, extension-preserving Keep Both names, exclusive
  no-overwrite publication, progress, cancellation, and identity-checked Undo.
- **New Folder with Selection** transactionally creates a validated folder,
  moves two or more sibling items, rolls back in reverse order on failure, and
  reports Recovery Needed instead of deleting an uncertain item.
- Post-publication and post-move cancellation windows are tracked explicitly.
  Undo rechecks identity and fingerprints immediately before each mutation.

### Menu parity and accessibility

- The file-row context menu and **File Operations** menu share one policy and
  router, including active or queued exclusive-operation state.
- Right-click inside a selection preserves it; right-click outside selects the
  clicked row before the command snapshot is built.
- Accessibility values report selection count, destination, disabled reason,
  progress, and bounded outcomes without exposing absolute paths.

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

- App version: 1.3.0 (build 8)
- Packaged source commit: `cd24295bbe60390047985d4577b151aaaa74ad7c`
- 1,407 automated tests passed in 92 suites
- Release packaging contract tests and arm64 production build passed
- Ad-hoc signature, DMG checksum, mounted-app validation, local installation,
  and launch checks passed
- DMG SHA-256:
  `ece6212bd5f80d21bc64ef2059839db8a79a416b3706b140b1c4155dbe801b32`

Manual Finder, Open With, Full Keyboard Access, VoiceOver, and signed-in
OneDrive File Provider checks remain `NOT RUN`. Direct Google or Microsoft
OAuth/API clients are not included.

## 한국어

Developer Preview 6는 파일 작업 센터의 캡처된 동일성, 덮어쓰기 방지, 취소,
복구 및 보수적인 Undo 규칙을 유지하면서 파일 행과 메뉴 막대의 생산성 기능을
확장합니다.

### 새로운 파일 컨텍스트 작업

- **Quick Look**은 Space를 유지합니다. 폴더는 Pengrid의 메타데이터 전용 폴더
  미리보기를 사용하고 파일, 패키지, 링크 및 여러 선택은 시스템 Quick Look을
  사용합니다.
- **Open With**, **Open in Other Pane**, **Show in Finder**, **Copy Path**는 명령
  실행 시 캡처한 표시 순서의 선택을 사용합니다.
- **Copy to Other Pane**과 **Move to Other Pane**은 이후 두 패널을 탐색하더라도
  캡처한 대상 폴더를 유지합니다.
- **Copy Full Path**는 Option-Command-C를 사용하며 이름, 부모 경로, 파일 URL도
  기존 파일 URL Copy 동작을 바꾸지 않고 제공합니다.

### 안전한 Duplicate와 선택 항목 폴더화

- **Duplicate**는 Command-D, 확장자를 보존하는 Keep Both 이름, 배타적이며
  덮어쓰지 않는 게시, 진행률, 취소 및 동일성 검사 Undo를 사용합니다.
- **New Folder with Selection**은 검증된 폴더를 트랜잭션 방식으로 만들고 같은
  부모의 항목 두 개 이상을 이동합니다. 실패 시 역순으로 롤백하며 불확실한
  항목을 삭제하는 대신 Recovery Needed를 보고합니다.
- 게시 직후와 이동 직후의 취소 구간을 명시적으로 추적하고, Undo는 각 변경
  직전에 동일성과 지문을 다시 확인합니다.

### 메뉴 일치와 접근성

- 파일 행 컨텍스트 메뉴와 **File Operations** 메뉴가 실행 중이거나 대기 중인
  배타 작업 상태를 포함해 하나의 정책과 라우터를 공유합니다.
- 선택 안을 오른쪽 클릭하면 전체 선택을 유지하고, 선택 밖을 오른쪽 클릭하면
  명령 스냅샷을 만들기 전에 해당 행을 선택합니다.
- 접근성 값은 절대 경로를 노출하지 않고 선택 수, 대상, 비활성 이유, 진행률 및
  제한된 결과를 알립니다.

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

- 앱 버전: 1.3.0 (빌드 8)
- 패키징 소스 커밋: `cd24295bbe60390047985d4577b151aaaa74ad7c`
- 92개 스위트의 자동 테스트 1,407개 통과
- 릴리스 패키징 계약 테스트와 arm64 프로덕션 빌드 통과
- ad-hoc 서명, DMG 체크섬, 마운트 앱, 로컬 설치 및 실행 검증 통과
- DMG SHA-256:
  `ece6212bd5f80d21bc64ef2059839db8a79a416b3706b140b1c4155dbe801b32`

Finder, Open With, Full Keyboard Access, VoiceOver 및 로그인된 OneDrive File
Provider 수동 검증은 아직 `NOT RUN`입니다. Google 또는 Microsoft 직접
OAuth/API 클라이언트는 포함하지 않습니다.
