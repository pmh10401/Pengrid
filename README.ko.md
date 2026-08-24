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
[Pengrid 1.3.0 Developer Preview 7](https://github.com/pmh10401/Pengrid/releases/tag/v1.3.0-developer-preview.7)입니다.

- [Pengrid.dmg 다운로드](https://github.com/pmh10401/Pengrid/releases/download/v1.3.0-developer-preview.7/Pengrid.dmg)
- 버전: **1.3.0 (빌드 9)**
- 요구 사항: **Apple Silicon Mac, macOS 15 이상**
- 검증: **110개 스위트의 자동 테스트 1,645개 통과**
- DMG SHA-256:
  `d7060401f05bbaac7f1d64b76d5bce6b93708c75644c8c3737698e8a3144fd73`

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

### 집중 명령으로 이동하고 파일을 만들고 선택하기

> 이 절의 생산성 작업 흐름은 현재 소스 트리를 설명합니다. 이 기능이 기존
> Developer Preview 7 DMG에 포함되어 있다는 뜻은 아닙니다.

**Command-P**를 누르면 현재 scene에만 연결된 열거형 기반의 타입 안전 **Quick Go…** 팔레트가
열립니다. 후보는 안전한 고정 명령(**Create Folder**, **Create File**, **Show
Filter**, **Smart Search**), 활성 패널의 현재·뒤로·앞으로 위치, 사용할 수 있는
즐겨찾기, 작업 공간 프로필 및 저장된 검색입니다. 매칭은 정규화된 텍스트와
Pengrid의 기존 한글 초성(Hangul-initial) 지원을 함께 사용합니다. 팔레트는
스크립트를 실행하거나 색인을 크롤링하거나 파일 콘텐츠를 materialize하지 않습니다.

**New Empty File**은 **Option-Command-N**을 사용합니다. 캡처한 부모 디렉터리
동일성에 묶인 일반 파일을 배타적·덮어쓰기 없는 작업으로 만듭니다. 패널을 새로
고친 뒤 새 행을 선택하고 인라인 이름 변경을 시작합니다. 보수적인 Undo는 새
파일의 정확한 동일성과 지문이 바뀌지 않은 동안에만 제공합니다.
이미 불러온 형제 항목과 이름이 겹치면 `New File 2`, `New File 3`처럼 이름을
정합니다. 배타적 공개 시점에만 발생하는 아직 보지 못한 경쟁 충돌은 덮어쓰지 않고 실패합니다.

활성 패널의 현재 표시 항목, 즉 필터링되지 않은 행만
**Select All Visible** (**Option-Command-A**), **Invert Selection**
(**Option-Command-I**), **Select Same Extension** (**Option-Command-E**)의
대상입니다. 패널 필터나 텍스트 편집이 활성화된 동안에는 이 명령들이
비활성화됩니다. Select Same Extension은 표시된 일반 파일 하나를 정확히
선택하고 실제 확장자가 있어야 사용할 수 있습니다.

새 파일 및 고급 선택 명령의 상호작용 아이디어는
[Nimble Commander](https://github.com/mikekazakov/nimble-commander)에서,
Command-P 실행기의 아이디어는 [Shuffle](https://github.com/WizenPainter/shuffle)와
[F2 Commander](https://github.com/candidtim/f2-commander)에서 동작을
연구했습니다. 이는 동작 참고일 뿐이며 Pengrid가 코드를 복사한 것은 아닙니다.

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

Pengrid는 실행 전에 화면에 보이는 선택을 캡처하므로 이후 탐색이나 선택
변경이 작업 목적지를 몰래 바꾸지 못합니다. 정확한 선택 및 기능 판정 규칙은
[릴리스 노트](docs/release-notes-v1.3.0-developer-preview.7.md)를 참고하세요.

**Command-I** 또는 행 컨텍스트 메뉴의 **Get Info**는 캡처한 선택 항목의
읽기 전용 비모달 검사기를 엽니다. 하나의 항목 메타데이터나 여러 항목 요약을
표시하며, 디렉터리 크기는 재귀 합계가 아닌 항목 자체의 크기입니다. SHA-256은
적격 일반 파일 하나에서 명시적으로 버튼을 눌렀을 때만 계산하며, 온라인 전용
파일은 그때 macOS 다운로드가 필요할 수 있습니다.

### 더 안전하게 파일 작업 실행하기

복사, 이동, Trash, 이름 변경, 새 폴더, 압축, Undo 및 검토된 폴더 동기화
작업은 하나의 순서 있는 작업 센터를 공유합니다. 작업은 진행률과 안전한 취소
지점을 제공하며, 일괄 이름 변경, New Folder with Selection, 한 방향 폴더
동기화 같은 독점 트랜잭션은 단계적 게시와 보수적인 롤백 검사를 사용합니다.
동기화는 다시 시도할 수 없고, 완료 후 Undo로 되돌리지 않습니다.

> 전송 내용 검증은 현재 소스 트리에 구현되어 있지만, 공개된 Developer Preview
> 7 DMG에는 포함되어 있지 않습니다.

소스 빌드에는 기본값이 꺼진 **File Operations** 설정 **Verify transferred file
contents before publishing**이 있습니다. 이 설정을 켜면 복사, Duplicate, 다른
볼륨으로 이동, 검토된 동기화의 복사·교체 작업에서 비공개 스테이징 결과를 게시하기
전에 일반 파일 데이터를 SHA-256으로 비교합니다. 링크를 따라가지 않고 재귀 트리
구조와 심볼릭 링크 payload도 확인합니다. 진행률은 바이트 가중 백분율과 파일
개수 기준 진행을 함께 표시합니다.

### 압축 파일 만들고 풀기

**ZIP**, **TAR**, **TAR.GZ/TGZ**, **TAR.BZ2/TBZ/TBZ2** 및
**TAR.XZ/TXZ**를 만들고 풀 수 있습니다. 준비, 인코딩 및 마무리 단계를
구분해 진행 상황을 표시합니다. 소스 빌드는 AES-256 암호 보호 ZIP을 만들고
지원되는 AES 및 ZipCrypto 항목도 읽습니다.

### 클라우드 위치와 접근성 도구 사용하기

Google Drive와 OneDrive는 macOS File Provider를 통해 표시됩니다. 메타데이터
검색과 폴더 미리보기는 의도적인 콘텐츠 다운로드를 피하며, 바이트를 읽는
작업은 macOS에 온라인 전용 항목 다운로드를 요청할 수 있습니다. 디렉터리
비교와 검토된 한 방향 폴더 동기화, Storage Inspector, 키보드 탐색,
VoiceOver 레이블, Reduce Motion 및 개인정보를 노출하지 않는 상태 텍스트도
제공합니다.

## 주요 단축키

| 단축키 | 작업 |
| --- | --- |
| **Space** | 폴더 미리보기 또는 시스템 Quick Look |
| **Command-F** | 활성 패널 필터 |
| **Command-Shift-F** | 활성 패널에서 Smart Search 시작 |
| **Command-P** | 현재 scene의 Quick Go… 팔레트 열기 |
| **Command-I** | 캡처한 선택 항목의 Get Info |
| **Command-T** | 새 작업 공간 탭 |
| **Command-W** | 안전할 때 활성 작업 공간 탭 닫기 |
| **Control-Tab** | 다음 작업 공간 탭 |
| **Control-Shift-Tab** | 이전 작업 공간 탭 |
| **Command-D** | 캡처한 선택 항목 복제 |
| **Option-Command-N** | 새 빈 파일을 만들고 인라인 이름 변경 시작 |
| **Option-Command-A** | 활성 패널의 표시 행 모두 선택 |
| **Option-Command-I** | 활성 패널의 표시 선택 반전 |
| **Option-Command-E** | 같은 확장자의 표시 행 선택 |
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
- Finder 태그 편집은 향후 작업입니다. 선택 가능한 전송 내용 검증은 현재 소스에
  있지만 Developer Preview 7 DMG에는 없습니다. 리소스 포크, 확장 속성, ACL,
  소유권, 플래그, 생성일, 하드 링크 관계 및 sparse allocation은 검증 범위에서
  제외합니다.
- 실행하지 않은 수동 검증은 검증 문서에 `NOT RUN`으로 명시합니다.

자세한 동작, 안전 규칙 및 제한 사항은
[기능 가이드](docs/user-guide.ko.md)와
[현재 제한 사항](docs/current-limitations.ko.md)을 참고하세요.

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
- [Developer Preview 7 릴리스 노트](docs/release-notes-v1.3.0-developer-preview.7.md)
- [릴리스 및 패키징 가이드](docs/release.ko.md)
- [아키텍처 설명](docs/architecture.md)
- [현재 제한 사항](docs/current-limitations.ko.md)
- [전송 내용 검증 기록](docs/verification/transfer-content-verification.ko.md)
- [검증 기록](docs/verification/)

Pengrid는 계속 개발 중입니다. 기여와 재현 가능한 문제 보고를 환영합니다.
