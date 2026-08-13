<p align="center">
  <img src="Assets/Pengrid/AppIcon-1024.png" width="160" alt="Pengrid 앱 아이콘">
</p>

<h1 align="center">Pengrid</h1>

<p align="center">
  <strong>빠르고 키보드 친화적인 macOS용 듀얼 패널 파일 관리자입니다.</strong><br>
  <strong>한국어</strong> · <a href="README.md">English</a>
</p>

Pengrid는 두 패널 탐색, 재귀 검색, 미리보기, 대기열 기반 파일 작업, 압축,
디렉터리 비교 및 저장 공간 분석을 하나로 묶은 무료 오픈 소스 macOS 앱입니다.

## 다운로드

현재 릴리스는
[Pengrid 1.3.0 Developer Preview 6](https://github.com/pmh10401/Pengrid/releases/tag/v1.3.0-developer-preview.6)입니다.

- [Pengrid.dmg 다운로드](https://github.com/pmh10401/Pengrid/releases/download/v1.3.0-developer-preview.6/Pengrid.dmg)
- 버전: **1.3.0 (빌드 8)**
- 요구 사항: **Apple Silicon Mac, macOS 15 이상**
- 검증: **92개 스위트의 자동 테스트 1,407개 통과**
- DMG SHA-256:
  `ece6212bd5f80d21bc64ef2059839db8a79a416b3706b140b1c4155dbe801b32`

DMG를 연 다음 `Pengrid.app`을 `Applications` 폴더로 복사하세요.

> **Developer Preview 신뢰 안내**
>
> 이 무료 DMG는 ad-hoc 방식으로 서명되어 있습니다. Developer ID 서명과
> Apple 공증을 받지 않았으므로 macOS Gatekeeper가 실행을 차단할 수 있습니다.
> 이 저장소의 GitHub 릴리스 페이지에서만 내려받고, 경고의 의미를 이해하고
> 동의하는 경우에만 진행하세요. Pengrid는 macOS 보안 기능을 끄도록 요구하지
> 않습니다.

파일 검증과 로컬 패키징 방법은 [릴리스 가이드](docs/release.ko.md)를
참고하세요.

## Pengrid를 선택하는 이유

- **작업 맥락 유지:** 여러 Finder 창 대신 독립된 두 패널에서 탐색하고,
  명령을 시작할 때 캡처한 출발지와 목적지 사이에서 파일을 전송합니다.
- **키보드 중심 작업:** 검색, 필터, 미리보기, 복제, 경로 복사 및 일반적인
  파일 작업을 macOS 데스크톱 단축키로 빠르게 실행합니다.
- **복구 가능한 작업 우선:** 대기열의 변경 작업은 파일 식별자를 다시
  확인하고 진행률과 취소 정리를 제공합니다. Retry와 Undo는 캡처한 상태가
  여전히 안전할 때만 제시합니다.

## 주요 기능

### 두 패널에서 탐색하고 관리하기

각 패널은 탐색 기록, 선택, 정렬 및 파일명 필터를 독립적으로 유지합니다.
복사, 이동, Open in Other Pane 및 검토된 디렉터리 비교 전송은 명령 시작 시
캡처한 패널과 목적지를 사용합니다.

### 여러 작업 공간을 준비해 두기

작업 공간 탭으로 서로 독립된 두 패널 폴더 쌍을 여러 개 열어 둘 수 있습니다.
**Command-T**는 활성 탭의 저장된 배치를 복사해 새 탭을 열고, **Command-W**는
실행 중이거나 대기 중인 파일 작업이 없을 때 활성 탭을 닫습니다.
**Control-Tab** / **Control-Shift-Tab**으로 탭을 이동합니다. 탭 제목에는 전체
경로가 아닌 두 패널의 현재 폴더 이름만 표시됩니다.

탭 막대에서 이름 있는 작업 공간 프로필을 저장한 뒤 Profiles 메뉴에서 열면
현재 탭을 바꾸지 않고 새 탭을 만듭니다. 세션은 폴더, 정렬, 분할 위치, 활성
패널 및 프로필만 복원하며, 선택, 필터, 기록, 미리보기, 검색과 작업 상태는
의도적으로 복원하지 않습니다.

### 파일을 빠르게 찾기

Smart Search는 파일명과 상대 경로를 재귀적으로 검색합니다. 일반 텍스트,
한글 초성, 혼합 쿼리, 파일 종류, 확장자, 크기 및 수정일 필터를 지원하며,
검색 조건을 저장해 다시 열 수 있습니다. 기본값이 꺼진 **Search indexed file
contents** 필터는 Spotlight가 이미 색인한 내용만 사용하며 온라인 전용 파일을
내려받지 않습니다. 내용 범위를 사용할 수 없거나 초성 검색이라 건너뛴 경우도
표시합니다.

### 작업 흐름을 유지하며 미리보고 실행하기

**Space**를 누르면 폴더의 바로 아래 항목을 미리보거나 파일, 패키지,
심볼릭 링크 및 다중 선택을 시스템 Quick Look으로 엽니다. 컨텍스트 메뉴에는
Open, Open With, Open in Other Pane, Show in Finder, Copy Path, Duplicate,
New Folder with Selection, 이름 변경, 압축 및 Trash가 포함됩니다.

Preview 6는 실행 전에 화면에 보이는 선택을 캡처하므로 이후 탐색이나 선택
변경이 작업 목적지를 몰래 바꾸지 못합니다. 정확한 선택 및 기능 판정 규칙은
[릴리스 노트](docs/release-notes-v1.3.0-developer-preview.6.md)를 참고하세요.

**Command-I** 또는 행 컨텍스트 메뉴의 **Get Info**는 캡처한 선택 항목의
읽기 전용 비모달 검사기를 엽니다. 하나의 항목 메타데이터나 여러 항목 요약을
표시하며, 디렉터리 크기는 재귀 합계가 아닌 항목 자체의 크기입니다. SHA-256은
적격 일반 파일 하나에서 명시적으로 버튼을 눌렀을 때만 계산하며, 온라인 전용
파일은 그때 macOS 다운로드가 필요할 수 있습니다.

### 더 안전하게 파일 작업 실행하기

복사, 이동, Trash, 이름 변경, 새 폴더, 압축 및 Undo 작업은 하나의 순서 있는
작업 센터를 공유합니다. 작업은 진행률과 안전한 취소 지점을 제공하며, 일괄
이름 변경과 New Folder with Selection 같은 독점 트랜잭션은 단계적 게시와
보수적인 롤백 검사를 사용합니다.

### 압축 파일 만들고 풀기

**ZIP**, **TAR**, **TAR.GZ/TGZ**, **TAR.BZ2/TBZ/TBZ2** 및
**TAR.XZ/TXZ**를 만들고 풀 수 있습니다. 준비, 인코딩 및 마무리 단계를
구분해 진행 상황을 표시합니다. 소스 빌드는 AES-256 암호 보호 ZIP을 만들고
지원되는 AES 및 ZipCrypto 항목도 읽습니다.

### 클라우드 위치와 접근성 도구 사용하기

Google Drive와 OneDrive는 macOS File Provider를 통해 표시됩니다. 메타데이터
검색과 폴더 미리보기는 의도적인 콘텐츠 다운로드를 피하며, 바이트를 읽는
작업은 macOS에 온라인 전용 항목 다운로드를 요청할 수 있습니다. 디렉터리
비교, Storage Inspector, 키보드 탐색, VoiceOver 레이블, Reduce Motion 및
개인정보를 노출하지 않는 상태 텍스트도 제공합니다.

## 주요 단축키

| 단축키 | 작업 |
| --- | --- |
| **Space** | 폴더 미리보기 또는 시스템 Quick Look |
| **Command-F** | 활성 패널 필터 |
| **Command-Shift-F** | 활성 패널에서 Smart Search 시작 |
| **Command-I** | 캡처한 선택 항목의 Get Info |
| **Command-T** | 새 작업 공간 탭 |
| **Command-W** | 안전할 때 활성 작업 공간 탭 닫기 |
| **Control-Tab** | 다음 작업 공간 탭 |
| **Control-Shift-Tab** | 이전 작업 공간 탭 |
| **Command-D** | 캡처한 선택 항목 복제 |
| **Option-Command-C** | 화면 순서대로 전체 경로 복사 |

Batch Rename과 나머지 컨텍스트 작업은 File Operations 메뉴 또는 행의
컨텍스트 메뉴에서 사용할 수 있습니다.

## 클라우드 및 안전 범위

- Pengrid는 macOS File Provider를 통해 클라우드 루트를 검색하며 직접 Google 또는 Microsoft OAuth를 구현하지 않습니다.
- 파일 가용성, 쓰기 기능 및 다운로드는 설치된 제공자와 macOS가 제어합니다.
- 암호 보호 ZIP은 파일명이나 중앙 디렉터리 메타데이터를 숨기지 않습니다.
  암호는 저장하지 않으며 복구할 수 없습니다.
- 7z, RAR, 암호 보호 TAR, Developer ID 서명 및 공증은 이 Developer
  Preview에 포함되지 않습니다.
- 실행하지 않은 수동 검증은 검증 문서에 `NOT RUN`으로 명시합니다.

자세한 동작, 안전 규칙 및 제한 사항은
[기능 가이드](docs/user-guide.ko.md)와
[현재 제한 사항](docs/current-limitations.md)을 참고하세요.

## 소스에서 빌드하기

```bash
git clone https://github.com/pmh10401/Pengrid.git
cd Pengrid
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --enable-swift-testing --no-parallel \
  --filter BloomFileManagerTests
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  ./script/build_and_run.sh --verify
open dist/Pengrid.app
```

개발 앱은 `dist/Pengrid.app`에 생성됩니다. 호환성을 위해 Swift 패키지,
실행 파일, 소스 모듈, 번들 식별자 및 기존 저장 위치의 내부 이름은
`BloomFileManager`로 유지합니다.

## 문서

- [상세 기능 가이드](docs/user-guide.ko.md)
- [Developer Preview 6 릴리스 노트](docs/release-notes-v1.3.0-developer-preview.6.md)
- [릴리스 및 패키징 가이드](docs/release.ko.md)
- [아키텍처 설명](docs/architecture.md)
- [현재 제한 사항](docs/current-limitations.md)
- [검증 기록](docs/verification/)

Pengrid는 계속 개발 중입니다. 기여와 재현 가능한 문제 보고를 환영합니다.
