# Pengrid 1.3.0 Developer Preview 10

[한국어](#한국어) · [English](#english)

## 한국어

무료 macOS 파일 관리자 Pengrid 1.3.0 **빌드 12**입니다.
Apple Silicon과 macOS 15 이상이 필요합니다.

### 주요 변경

- **Top Shelf:** 기본값이 꺼진 수동 보관함에 파일 참조, 텍스트, 정적 PNG/TIFF
  이미지를 보관합니다. Settings에서 켜거나 Shelf 메뉴를 사용하세요.
- **노치 갤러리:** 접힌 상태에는 호버 위치를 알려 주는 작은 손잡이만 남기고
  큰 원 아이콘 3개는 숨깁니다. 항목 개수는 펼친 갤러리에서 표시합니다. 포인터를 올리면
  키보드 포커스를 빼앗지 않고 펼쳐지고, 벗어나면 0.45초 후 접힙니다.
  클릭하거나 Keep Shelf Open을 선택하면 열린 상태를 유지합니다.
- **검색과 카드:** 한글 초성 검색, All / Files / Text / Images 개수 탭,
  가로 미리보기 카드와 방향키 선택을 제공합니다. 검색창 안에서는 방향키가
  텍스트 편집에 사용됩니다. 필터로 숨겨진 항목은 선택에서 해제됩니다.
- **클립보드와 안전한 보관:** Import Clipboard를 직접 눌렀을 때만 읽습니다.
  Copy와 복사 전용 드래그를 지원하며, 항목 제거와 비움은 원본을 삭제하지
  않습니다. 자동 수집, OCR 및 전역 단축키는 제공하지 않습니다.
- **보관 정책과 진행률:** 종료 시 비움이 기본이며 설정에서 세션 간 보관을
  선택할 수 있습니다. 실행·대기 중 작업, 복구 필요 또는 최근 실패가 있을 때
  기존 작업 센터의 상태를 보여 줍니다. 보관함을 닫아도 작업은 취소되지 않습니다.
- **닫은 탭 다시 열기:** Window > Reopen Closed Workspace Tab 또는
  Command-Shift-T로 현재 세션에서 최근 닫은 탭 최대 10개를 다시 엽니다.
  폴더·정렬·분할·활성 패널만 복원하며 선택이나 파일 작업은 재실행하지 않습니다.

### 검증 및 제한

- 기능 후보의 전체 자동 테스트 2,029개, 스위트 131개가 통과했습니다.
  Shelf 및 빌드 번호 관련 검사 53개, 스위트 5개도 통과했습니다.
- 로컬 UI에서 검색·유형 필터·카드 선택·방향키 이동·비움과 개수 표시를
  확인했습니다. 이는 모든 입력기나 접근성 시나리오의 검증을 의미하지 않습니다.
- 설치본의 작은 손잡이와 펼침·접힘 화면은 컴퓨터 제어 도구로 확인했습니다.
  호버 진입·이탈은 네이티브 이벤트 테스트로 확인했으며, 실제 포인터만 이동한
  순수 호버 수동 검증은 수행하지 않았습니다.
- 실제 로그인된 Google Drive·OneDrive, VoiceOver 및 외장/대소문자 구분
  볼륨의 수동 검증은 이번 후보에서 수행하지 않았습니다.
- 기존 테스트 자료 11개의 SwiftPM 미등록 경고가 남아 있습니다.
- DMG는 **ad-hoc 서명**이며 Developer ID 서명과 Apple 공증을 받지 않았습니다.
  Gatekeeper가 차단할 수 있습니다. macOS 보안 기능을 끄지 마세요.

### 설치

GitHub 릴리스에서 `Pengrid.dmg`와 `SHA256SUMS.txt`를 같은 폴더에 받습니다.
`shasum -a 256 -c SHA256SUMS.txt`로 확인한 뒤 DMG 안의 `Pengrid.app`을
Applications로 복사하세요. 앱 설정과 사용자 파일은 앱 번들과 별개입니다.

## English

Free Pengrid 1.3.0 **build 12** for Apple Silicon Macs running macOS 15 or later.

- **Optional manual Top Shelf:** store file references, text, and static PNG/TIFF
  images. Off by default; enable it in Settings or use the Shelf menu.
- **Hover notch gallery:** a slim collapsed hover handle instead of three large
  circle icons, category counts in the expanded gallery, focus-preserving hover
  expansion, a 0.45-second leave grace period, and click-to-pin behavior.
- **Search-first cards:** Korean-initial search, counted category capsules,
  horizontal previews, and arrow-key selection outside the search field.
  Filtering clears selection when the selected item is no longer visible.
- **Explicit clipboard import:** reads only when Import Clipboard is pressed.
  Copy and copy-only drag are supported. Remove and Clear never delete originals.
  There is no automatic sampling, OCR, or global hotkey.
- **Retention and progress:** clear-on-quit is the default; optional persistence
  is configurable. Active/queued operations and recovery/failure notices reuse
  the existing operation center. Closing the shelf does not cancel work.
- **Reopen closed workspace tabs:** Window > Reopen Closed Workspace Tab
  (Command-Shift-T) restores up to ten recent closes in the current session.
  It restores layout, not selections, Undo state, or file operations.

Validation: the feature candidate passed 2,029 tests in 131 suites. A focused
run of 53 Shelf and bundle-version checks in five suites also passed.
Local search, categories, card selection,
arrow navigation, Clear, and counters were checked. This does not establish full
IME, signed-in cloud-provider, VoiceOver, or external/case-sensitive-volume
coverage. Eleven existing SwiftPM unhandled-fixture warnings remain.
The installed handle and expanded/collapsed UI were checked through computer
control. Hover entry/exit passed native-event tests; physical pointer-only hover
validation was not performed.

The DMG is **ad-hoc signed, not Developer ID signed or notarized**; Gatekeeper
may block it. Do not disable macOS security controls. Download `Pengrid.dmg` and
`SHA256SUMS.txt`, run `shasum -a 256 -c SHA256SUMS.txt`, then copy the app to
Applications. Existing settings and user files are separate from the app bundle.
