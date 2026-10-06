# Pengrid 1.3.0 Developer Preview 11

[한국어](#한국어) · [English](#english)

![Pengrid notch shelf](https://raw.githubusercontent.com/pmh10401/Pengrid/v1.3.0-developer-preview.11/docs/images/notch-shelf.png)

## 한국어

무료 macOS 파일 관리자 Pengrid **1.3.0, 빌드 13**입니다.
Apple Silicon과 macOS 15 이상을 지원합니다.

### 이번 업데이트

- **하드웨어 노치에 숨기기:** 카메라 노치가 있는 화면에서 접힌 보관함은
  손잡이와 그림자 없이 숨겨집니다. 마우스를 올리면 그 아래로 펼쳐집니다.
- **테두리를 따라 이동:** 여섯 점 손잡이를 옮기면 작은 노치 표식이 스프링
  움직임으로 화면 테두리와 모서리를 따라갑니다. 놓으면 붙고 펼쳐지며,
  카메라 노치 근처에 놓으면 다시 연결됩니다. Escape로 이동을 취소합니다.
- **가로·세로 배치:** 위·아래는 가로 갤러리, 왼쪽·오른쪽은 세로 카드입니다.
  카드만 스크롤되고 검색·분류·클립보드·진행률은 고정됩니다. 위치를 바꿔도
  검색어·분류·선택을 유지하며 선택 카드가 보이도록 스크롤합니다.
- **글래스 스타일:** 리퀴드 글래스·어두운 글래스·검정을 선택하고 설정을
  보관합니다. 글래스는 macOS 26 이상에서 적용하며 이전 macOS나 투명도
  줄이기 사용 시에는 검정으로 표시합니다. 동작 줄이기도 지원합니다.
- **한국어 메뉴:** 앱 메뉴, 파일 우클릭 메뉴와 보관함 설정·버튼·안내를
  첫 번째 macOS 선호 언어에 따라 한국어 또는 영어로 표시합니다.
- **소개와 안내 개선:** 한글·영문 README, 상세 안내, 제한 사항과 배포 안내를
  최신화했습니다. 실제 구성 요소와 예시 데이터로 촬영한 소개 이미지 4장을 추가했습니다.

### 사용과 설치

DMG를 열어 `Pengrid.app`을 Applications로 복사하세요.
**설정 > 노치 보관함 > 노치 보관함 사용**을 켜면 새 보관함을 사용할 수 있습니다.
파일·텍스트·이미지를 직접 추가하거나 **클립보드 가져오기**를 선택하세요.
클립보드는 자동으로 수집하지 않으며, 항목 제거는 원본 파일을 삭제하지 않습니다.

`Pengrid.dmg`와 `SHA256SUMS.txt`를 같은 폴더에 내려받아 확인할 수 있습니다.

```bash
shasum -a 256 -c SHA256SUMS.txt
```

### 검증과 제한

- 기능 후보의 자동 테스트 **2,055개·131개 스위트**가 통과했습니다.
- 예시 데이터의 실제 UI에서 가로·세로 배치, 검색·분류·선택 유지,
  선택 카드 스크롤, 글래스 설정과 한국어 메뉴를 확인했습니다.
- 실제 포인터만 사용하는 모든 호버·다중 화면 상황, 로그인된 Drive·OneDrive,
  VoiceOver 및 외장·대소문자 구분 볼륨은 이번 후보에서 새로 검증하지 않았습니다.
- 일부 대화상자·오류·작업공간 레이블은 영어로 표시됩니다.
- 기존 SwiftPM 테스트 자료 경고 11개가 남아 있습니다.
- DMG는 **ad-hoc 서명**이며 **Developer ID 서명과 Apple 공증을 받지
  않았습니다**. Gatekeeper가 실행을 차단할 수 있습니다. macOS 보안 기능을 끄지 마세요.

[상세 기능 안내](https://github.com/pmh10401/Pengrid/blob/main/docs/user-guide.ko.md) ·
[현재 제한 사항](https://github.com/pmh10401/Pengrid/blob/main/docs/current-limitations.ko.md)

## English

Free Pengrid **1.3.0, build 13** for Apple Silicon Macs running macOS 15 or later.

- **Hardware-notch hiding:** the collapsed shelf disappears inside a supported
  camera cutout; hover reveals the gallery underneath.
- **Border movement:** drag the six-dot grip around display edges and corners.
  The compact marker follows with a spring and settles before reopening. Release
  near the camera notch to dock again; Escape cancels.
- **Horizontal and portrait layouts:** top/bottom use horizontal cards;
  left/right use upright vertical cards. Controls stay fixed while cards scroll.
  Edge changes preserve query, category and selection, with selected-card scrolling.
- **Native glass styles:** persisted Liquid Glass, Dark Glass and Solid Black.
  Glass requires macOS 26+; older versions and Reduce Transparency use black.
  Reduce Motion disables shelf animations.
- **Korean menus:** menu-bar commands, file context menus and shelf controls/settings
  follow the first preferred macOS language, with English fallback.
- **Refreshed presentation:** bilingual README, feature/limitations/release guides,
  and four real native screenshots with sample data.

Copy the app from the DMG to Applications. Enable **Settings > Top Shelf >
Enable Top Shelf**. Import is manual, removal keeps original files, and
Clear on Quit remains the default retention policy.

The feature candidate passed **2,055 tests in 131 suites**. Native sample-data
checks covered both layouts, retained search/category/selection, selected-card
scrolling, appearance settings and Korean menus. This does not establish full
physical-pointer hover, multi-display, signed-in cloud-provider, VoiceOver or
external/case-sensitive-volume coverage. Some dialogs/errors/workspace labels
remain English; eleven existing SwiftPM fixture warnings remain.

This DMG is **ad-hoc signed, not Developer ID signed or notarized**.
Gatekeeper may block it. Do not disable macOS security controls.
Download `Pengrid.dmg` and `SHA256SUMS.txt`, run the checksum command above,
then copy the app to Applications.

[Feature guide](https://github.com/pmh10401/Pengrid/blob/main/docs/user-guide.md) ·
[Limitations](https://github.com/pmh10401/Pengrid/blob/main/docs/current-limitations.md)
