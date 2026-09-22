# Pengrid 1.3.0 Developer Preview 9

[한국어](#한국어) · [English](#english)

## 한국어

무료 macOS 파일 관리자 Pengrid 1.3.0 **빌드 11**입니다.
Apple Silicon과 macOS 15 이상이 필요합니다.

### 주요 변경

- **도움말 센터:** Help > Pengrid Help 또는 Command-?로 여는 네이티브 창에
  오프라인 주제 8개를 제공합니다. 한국어·영어 전환과 두 언어 통합 검색,
  한글 초성·혼합 검색, 기능 설명과 단축키를 지원합니다.
- **이름 패턴으로 선택:** Edit > Select by Name… 또는 Option-Command-S에서
  `*.pdf`, `보고서_?.xlsx`처럼 현재 활성 패널의 표시 이름을 비교합니다.
  `*`는 0개 이상, `?`는 한 글자 단위(grapheme)와 일치합니다. 대소문자를
  구분하지 않으며 한글 조합·분해 표기를 같은 것으로 처리합니다.
- 일치 개수를 미리 보여 주고 확정 시 선택을 교체합니다. 빈 입력은 적용할 수
  없으며, 취소하면 기존 선택이 유지됩니다. 목록이 바뀌면 오래된 결과 적용을
  거부합니다. 재귀 검색이나 파일 내용 수정은 하지 않습니다.
- **입력 개선:** 패턴·경로·필터 등 작업 공간 텍스트 편집 중 Command-A로
  전체 텍스트를 선택합니다. 파일 행 선택용 Option-Command-A와 구분됩니다.
  도움말 검색창에서도 복사·붙여넣기·전체 선택을 사용할 수 있습니다.
- **개발 환경 호환성:** SwiftPM의 native와 swiftbuild 양쪽에서 현재 테스트
  번들을 사용하며, 격리 테스트의 Xcode 라이브러리 경로를 보존합니다.

### 검증 및 제한

- 전체 자동 테스트: 126개 스위트, 1,971개 테스트 통과. 별도 환경이 필요한
  벤치마크·File Provider·APFS 테스트 7개는 건너뛰었습니다.
- native 빌드 방식의 관련 격리/전송 테스트 76개도 통과했습니다.
- 패턴 입력의 한글·이모지 교체, Command-A, 취소 및 포커스 복원을 로컬에서
  확인했습니다. 이를 모든 입력기나 VoiceOver 검증으로 해석하지 않습니다.
- 로그인된 Google Drive·OneDrive, 실제 VoiceOver 및 외장/대소문자 구분
  볼륨의 수동 검증은 이번 릴리스에서 수행하지 않았습니다.
- 기존 테스트 자료 11개의 SwiftPM 미등록 경고는 남아 있습니다.
- Command-?가 macOS 도움말 메뉴의 검색을 먼저 열면 **Pengrid Help** 항목을
  선택하세요. 설치본에서는 메뉴 항목으로 도움말 창을 여는 동작을 확인했습니다.
- 이 DMG는 **ad-hoc 서명**이며 Developer ID 서명과 Apple 공증을 받지
  않았습니다. Gatekeeper가 차단할 수 있으며 보안 기능을 끄도록 요구하지 않습니다.

### 설치

GitHub 릴리스에서 `Pengrid.dmg`와 `SHA256SUMS.txt`를 받아 같은 폴더에 둡니다.
`shasum -a 256 -c SHA256SUMS.txt`로 확인한 뒤 DMG 안의 `Pengrid.app`을
Applications로 복사하세요. 앱 설정과 사용자 파일은 앱 번들과 별개입니다.

## English

Free Pengrid 1.3.0 **build 11** for Apple Silicon Macs running macOS 15 or later.

- **Native Help:** Help > Pengrid Help (Command-?) provides eight offline topics,
  Korean/English switching, bilingual search, Korean-initial and mixed queries,
  feature guidance, and shortcuts.
- **Select by Name:** Edit > Select by Name… (Option-Command-S) matches full
  visible basenames in the active, unfiltered pane using `*` and `?`. Matching
  ignores case and respects Korean canonical equivalence and grapheme boundaries.
  Live counts precede selection replacement. Empty input is disabled, cancel
  preserves selection, and changed listings reject stale application. No
  recursive search or file-content mutation is performed.
- **Text editing:** Command-A selects all text in workspace editing sessions;
  Option-Command-A remains the separate visible-file selection command.
  Copy, Paste, and Select All also work in the standalone Help search field.
- **SwiftPM compatibility:** isolated tests resolve their loaded bundle under
  both native and swiftbuild, preserving Xcode library paths across the shell.

Validation: 1,971 tests in 126 suites passed; seven environment-dependent tests
were skipped. Another 76 related tests passed with the native build system.
Local pattern replacement, Korean/emoji text, Command-A, cancellation, and focus
restoration were checked. These checks do not establish full IME or VoiceOver
coverage. Signed-in Google Drive/OneDrive, live VoiceOver, and external or
case-sensitive volume scenarios were not run. Eleven existing unhandled-fixture
warnings remain.
If Command-? opens the macOS Help menu search, choose **Pengrid Help** there.
Opening the Help window through its menu item was verified in the installed app.

The DMG is **ad-hoc signed, not Developer ID signed or notarized**. Gatekeeper
may block it. Do not disable macOS security controls. Download `Pengrid.dmg` and
`SHA256SUMS.txt` from this release, run `shasum -a 256 -c SHA256SUMS.txt`, then
copy the app to Applications. Existing settings and user files are separate
from the application bundle.
