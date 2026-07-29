# Finder에 펭귄의 재치를 더하다 — macOS 파일 관리자 Pengrid 개발기

mac에서 파일을 옮기고 비교하는 일은 생각보다 자주 두 창을 오갑니다. 한쪽에는 정리할 폴더를, 다른 쪽에는 옮길 위치를 두고 싶다는 작은 불편에서 Pengrid를 시작했습니다. Finder에 익숙한 흐름은 지키면서도, 두 폴더를 한눈에 보며 판단하는 속도를 더하고 싶었습니다.

두 폴더를 함께 보며 이동과 비교의 맥락을 놓치지 않는 경험을 먼저 다듬고 있습니다. Pengrid는 아직 방향을 함께 다듬는 **developer preview(개발자 미리보기)**로, 실제 파일 정리 습관에서 무엇이 편하고 무엇이 불안한지 차분히 확인하며 만들고 있습니다.

> 이미지: `Assets/Pengrid/AppIcon-1024.png`
>
> Pengrid — Finder의 친숙함에 펭귄의 개성을 더한 파일 관리자

## Pengrid라는 이름

Pengrid는 `penguin`과 `grid`를 합친 이름입니다. 두 패널을 마주 보며 파일을 정리하는 작업대에 펭귄의 개성을 더했습니다. 내부 호환성을 위해 프로젝트의 일부 이름은 BloomFileManager로 남아 있지만, 사용자에게는 Pengrid라는 이름으로 다가가려 합니다.

## Finder처럼 익숙하고, 두 창으로 빠르게

두 패널은 단순히 화면을 나눈 기능이 아닙니다. 원본과 목적지를 함께 보며 복사·이동 전의 맥락을 유지하게 해 주는 작업대입니다. Finder에서 익힌 탐색 방식은 낯설지 않게 두고, 반복해서 창을 바꾸는 시간을 줄이는 데 집중했습니다.

## Google Drive와 OneDrive도 macOS 방식으로

Google Drive와 OneDrive가 macOS에 제공하는 File Provider 위치를 Pengrid의 탐색 흐름에서 발견해 보여 줍니다. File Provider는 클라우드 저장소를 macOS 파일 시스템처럼 다루도록 돕는 운영체제 기능입니다.

이 단계는 Google 또는 Microsoft의 직접 OAuth/API 연동이 아니라, macOS가 제공하는 위치와 규칙을 따르는 방식입니다. Pengrid가 각 서비스의 계정 자격 증명을 요구하지 않습니다. 온라인에만 있는 파일은 실제 바이트가 필요한 작업 전에 내려받도록 하여, 파일 상태를 모르고 처리하는 일을 피합니다.

## Storage Inspector

디스크를 정리할 때는 무엇이 큰지보다 무엇을 지워도 되는지가 더 어렵습니다. Storage Inspector는 필요할 때만 실행하는 작업 공간으로, 큰 파일과 오래 손대지 않은 파일, 확인된 중복 파일을 살펴볼 수 있게 합니다.

백그라운드에서 모든 파일을 계속 훑지 않고, 로컬 폴더와 직접 연결한 볼륨을 대상으로 진행합니다. 클라우드에만 있는 내용, 심볼릭 링크, 패키지는 무리하게 분석하지 않습니다.

## 안전한 중복 파일 정리

중복으로 보이는 파일은 완전히 확인된 경우에만 한 그룹으로 묶고, 사용자가 검토해 고른 항목만 macOS 휴지통으로 보냅니다. 처리 직전에도 파일의 정체성을 다시 확인하고, 적어도 한 복사본은 남기도록 설계했습니다.

그래도 중요한 파일 정리는 언제나 사용자의 최종 판단이 필요합니다. Pengrid는 빠른 정리보다 되돌릴 수 있는 흐름과 확인 가능한 선택을 우선하려 합니다.

## 현재 검증 상태

2026-07-29 기준 자동 검증에서 **551 tests in 41 suites**를 통과했고, arm64 개발 빌드도 확인했습니다. 이는 개발 환경에서의 자동화된 근거이며, 실제 저장장치·대용량 파일·연결 해제와 재연결·휴지통·접근성·화면 모양에 대한 물리 수동 확인은 아직 남아 있습니다.

또한 Developer ID 서명, Apple 공증, 스테이플링, Gatekeeper 검사는 아직 실행하지 않았습니다. 그래서 지금은 미리 빌드한 앱을 배포하지 않으며, 정식 배포 판단으로 받아들여서는 안 됩니다.

## GitHub에서 소스 내려받기

Pengrid 소스는 현재 [GitHub 저장소](https://github.com/pmh10401/Pengrid)에 공개되어 있습니다. 가장 최근 검토한 소스 아카이브는 [main.zip](https://github.com/pmh10401/Pengrid/archive/refs/heads/main.zip)입니다.

Apple Silicon과 macOS 15 이상, 전체 Xcode가 준비된 환경에서 아래 두 명령으로 검증할 수 있습니다.

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --disable-sandbox --no-parallel
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  ./script/build_and_run.sh --verify
```

## 앞으로의 계획

개발자 미리보기 기간에는 두 패널 탐색, File Provider 위치 처리, Storage Inspector의 판단 흐름을 실제 사용 경험으로 검토하겠습니다. 배포 가능한 앱을 이야기하기 전에는 서명과 공증, 스테이플링, Gatekeeper 검사, 그리고 남은 수동 확인을 각각 다시 거칠 계획입니다.

사용 중 불편했던 탐색 흐름이나 파일 정리에서 망설였던 순간이 있다면 [GitHub Issues](https://github.com/pmh10401/Pengrid/issues)를 통해 알려 주세요. Pengrid가 더 조심스럽고 유용한 파일 관리자가 되는 데 큰 도움이 됩니다.
