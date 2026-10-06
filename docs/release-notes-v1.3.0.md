# Pengrid 1.3.0

[한국어](#한국어) · [English](#english)

![Pengrid notch shelf](https://raw.githubusercontent.com/pmh10401/Pengrid/v1.3.0/docs/images/notch-shelf.png)

## 한국어

무료 macOS 파일 관리자 Pengrid **1.3.0 정식 릴리스·빌드 14**입니다.
Apple Silicon과 macOS 15 이상을 지원합니다.

> GitHub 정식 배포이며 **ad-hoc 서명**입니다. Developer ID 서명과 Apple
> 공증을 받지 않았으므로 Gatekeeper가 실행을 차단할 수 있습니다.
> macOS 보안 기능을 끄지 마세요.

### 제공하는 기능

- **움직이는 노치 보관함:** 하드웨어 노치 숨김, 스프링 기반 테두리 이동,
  위·아래 가로 갤러리와 좌·우 세로 카드, 검색과 항목 개수 표시,
  글래스 스타일, 파일·텍스트·이미지 수동 클립보드 가져오기.
- **파일 관리:** 듀얼 패널, 작업공간 탭·프로필·세션 복원,
  한글 초성 검색, 선택적 Spotlight 내용 검색, Space 미리보기,
  한국어 메뉴·우클릭 명령과 한·영 오프라인 도움말.
- **안전한 작업:** 진행률·대기열·취소·지원되는 Undo/Redo, 일괄 이름 변경,
  ZIP·TAR 계열 압축과 암호 ZIP, 검토 후 단방향 동기화,
  선택적 SHA-256 전송 내용 검증과 Storage Inspector.

Preview 11의 앱 기능 코드를 그대로 정식 채널에 배포합니다. 빌드 번호를
14로 올리고 README·기능 안내·배포 문서·다운로드 링크를 갱신했습니다.
기존 설정과 내부 저장 식별자는 유지합니다.

### 설치와 검증

이 릴리스의 `Pengrid.dmg`와 `SHA256SUMS.txt`를 같은 폴더에 내려받으세요.

```bash
shasum -a 256 -c SHA256SUMS.txt
```

DMG를 열어 `Pengrid.app`을 Applications로 복사하세요.
보관함은 **설정 > 노치 보관함 > 노치 보관함 사용**으로 켭니다.
클립보드는 직접 가져올 때만 읽으며, 종료 시 비우기가 기본값입니다.
보관함 항목을 제거해도 원본 파일은 지워지지 않습니다.

[검증 기록](https://github.com/pmh10401/Pengrid/blob/main/docs/verification/v1.3.0-release-check.md) ·
[상세 기능 안내](https://github.com/pmh10401/Pengrid/blob/main/docs/user-guide.ko.md) ·
[제한 사항](https://github.com/pmh10401/Pengrid/blob/main/docs/current-limitations.ko.md)

### 알려진 제한

리퀴드 글래스는 macOS 26 이상에서 적용하며, 이전 macOS와 투명도 줄이기에서는
검정으로 표시합니다. 일부 대화상자·오류 메시지는 영어로 남아 있습니다.
7z·RAR·직접 Google/Microsoft OAuth·자동 업데이트는 제공하지 않습니다.
실제 포인터의 모든 호버·다중 화면 상황, 로그인된 Drive·OneDrive,
VoiceOver 및 외장·대소문자 구분 볼륨 검사를 이번 빌드에서 새로 실시한 것은
아닙니다. 정식 채널 표시는 이 미검증 항목이나 Apple 신뢰 검증을 완료로
바꾸지 않습니다.

## English

Free **Pengrid 1.3.0, build 14**, published as a stable GitHub release for
Apple Silicon Macs running macOS 15 or later.

**This DMG is ad-hoc signed, not Developer ID signed or Apple-notarized.**
Gatekeeper may block it; do not disable macOS security controls.

The release includes the movable hardware-notch shelf, spring-based border
movement, horizontal/portrait cards, manual clipboard import, native glass,
and Korean menus. Dual-pane workspaces, tabs/profiles, Korean-initial search,
optional indexed Spotlight content search, Space previews, native Help,
queued file operations, protected ZIP, review-first synchronization and
optional SHA-256 transferred-content verification remain included.

Application feature code is unchanged from Preview 11. Build 14 updates bundle
metadata, bilingual documentation and stable download links without changing
stored identities or settings.

Download `Pengrid.dmg` and `SHA256SUMS.txt` together and run the checksum
command above. Open the DMG and copy the app to Applications. Enable
**Settings > Top Shelf > Enable Top Shelf** to use the optional shelf.
Clipboard import is manual and Clear on Quit is the default.

Glass requires macOS 26+; older macOS and Reduce Transparency use solid black.
Some dialogs/errors remain English. 7z, RAR, direct provider OAuth and automatic
updates are not shipped. Full physical-pointer/multi-display, signed-in cloud,
VoiceOver and external/case-sensitive-volume checks were not newly performed.
Stable-channel status does not close these manual qualification gates.

[Verification](https://github.com/pmh10401/Pengrid/blob/main/docs/verification/v1.3.0-release-check.md) ·
[Feature guide](https://github.com/pmh10401/Pengrid/blob/main/docs/user-guide.md) ·
[Limitations](https://github.com/pmh10401/Pengrid/blob/main/docs/current-limitations.md)
