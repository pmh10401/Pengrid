# Pengrid

**한국어** · [English](README.md)

Pengrid는 macOS용 무료 오픈소스 듀얼 패널 파일 관리자입니다. 빠른 키보드
탐색, 재귀 검색, 안전한 파일 작업 큐, 폴더 미리보기, 압축 도구, 디렉터리
비교 및 저장 공간 분석을 하나의 작업 공간에서 제공합니다.

기존 버전과의 호환성을 위해 Swift 패키지, 실행 파일, 소스 모듈, 번들 식별자
및 기존 설정 저장 위치의 내부 이름은 `BloomFileManager`로 유지합니다.

## 다운로드

현재 배포 버전은
[Pengrid 1.3.0 Developer Preview 6](https://github.com/pmh10401/Pengrid/releases/tag/v1.3.0-developer-preview.6)입니다.
기존의 대규모 폴더, 검색, 미리보기 및 압축 개선을 유지하면서 캡처된 선택을
사용하는 컨텍스트 작업, 안전한 반대쪽 패널 전송, Duplicate 및 선택 항목을
새 폴더로 묶는 트랜잭션 기능을 추가했습니다.

- [Pengrid.dmg 다운로드](https://github.com/pmh10401/Pengrid/releases/download/v1.3.0-developer-preview.6/Pengrid.dmg)
- 앱 버전: **1.3.0 (빌드 8)**
- 요구 사항: **Apple Silicon Mac, macOS 15 이상**
- 검증 결과: **92개 스위트의 자동 테스트 1,406개 통과**
- DMG SHA-256:
  `d17bf6a9e37240629e6d309429e260c0c67bb9d71a3ebc30de349ece69f491c9`

> **Developer Preview 신뢰 안내**
>
> 이 무료 DMG는 ad-hoc 방식으로 서명되어 있습니다. Developer ID 서명과
> Apple 공증을 받지 않았으므로 macOS Gatekeeper가 실행을 차단할 수
> 있습니다. 이 저장소의 GitHub 릴리스 페이지에서만 다운로드하고, 해당
> 경고의 의미를 이해하고 동의하는 경우에만 진행하세요. Pengrid는 macOS
> 보안 기능을 비활성화하라고 요구하지 않습니다.

다운로드 후 DMG를 열고 `Pengrid.app`을 `Applications` 폴더로 복사하세요.
파일 검증과 로컬 패키징 방법은 [릴리스 안내서](docs/release.ko.md)에서
확인할 수 있습니다.

## 주요 기능

### 듀얼 패널 작업 공간

서로 독립된 탐색 기록, 정렬, 선택 상태 및 패널별 파일명 필터를 이용해 두
폴더를 나란히 탐색할 수 있습니다. 복사와 이동 작업은 활성 패널과 반대쪽
패널 사이에서 수행됩니다.

### 한글 초성 검색을 지원하는 Smart Search

**Command-Shift-F**를 누르면 파일명과 상대 경로를 재귀적으로 검색합니다.
한글 초성, 일반 문자열, 혼합 조건을 함께 사용할 수 있으며 파일/폴더 종류,
확장자, 크기 및 수정 날짜로 결과를 제한할 수 있습니다. 검색 조건을 저장해
다시 열 수도 있습니다. 결과에서 파일 작업을 실행하기 전에는 검색 당시
기록한 파일의 동일성을 다시 확인합니다.

### Space 키 미리보기

일반 폴더 하나를 선택하고 **Space**를 누르면 한 단계의 하위 항목만 보여주는
Pengrid의 읽기 전용 폴더 미리보기가 열립니다. 파일, 패키지, 심볼릭 링크 및
여러 항목 선택에는 시스템 Quick Look을 그대로 사용합니다. 클라우드 폴더
미리보기는 현재 제공된 메타데이터만 읽으며 콘텐츠를 의도적으로 다운로드하지
않습니다.

### 컨텍스트 메뉴 생산성 기능 (Preview 6)

선택된 행을 오른쪽 클릭하면 전체 선택을 유지하고, 선택되지 않은 행을 오른쪽
클릭하면 먼저 그 행을 선택합니다. 명령은 나중의 패널·선택 상태가 아니라 이때
캡처한 선택을 표의 표시 순서대로 사용합니다. 컨텍스트 메뉴는 **Open** 다음에
**Quick Look**, **Open With**, **Open in Other Pane** 그룹, **Copy/Move to Other
Pane**, **Show in Finder**, **Copy Path** 그룹, 그리고 **New Folder**, **New Folder
with Selection**, 즐겨찾기, **Duplicate**, 이름 변경, 기존 복사/붙여넣기·압축
작업, 휴지통 순서를 유지합니다.

Quick Look은 **Space**를 그대로 사용합니다. Open With는 일반 파일, 패키지 또는
심볼릭 링크 하나에 제공되고, Open in Other Pane은 폴더 하나를 반대쪽 패널에서 열거나 폴더가
아닌 항목 하나를 캡처한 상위 폴더에서 동일성 일치 항목으로 선택합니다. Copy/Move
to Other Pane은 실행 시점에 캡처한 반대쪽 패널 폴더를 사용하므로 이후 탐색으로
작업 대상이 바뀌지 않습니다. Show in Finder는 바이트를 읽지 않고 캡처한 항목을
Finder에서 표시합니다. **Copy Path**에는 Full Path(**Option-Command-C**), Name,
Parent Path, File URL이 있고 표시 순서의 UTF-8 텍스트를 복사합니다. **Duplicate**는
**Command-D**로 실행하며 확장자를 보존한 **Keep Both** 이름과 덮어쓰지 않는
게시 방식을 사용합니다. **New Folder with Selection**은 같은 부모의 항목 두 개
이상을 받아 유효성 검사한 새 폴더로 트랜잭션 방식으로 이동합니다.

이 작업은 텍스트 편집 상태, 현재 쓰기 가능 여부, File Provider 기능, 진행률,
취소, 재시도, 복구 및 보수적인 Undo 규칙을 따릅니다. Quick Look과 Open With는
클라우드 항목을 materialize할 수 있지만 경로 복사, Finder 표시, 반대쪽 패널 탐색은
콘텐츠를 의도적으로 읽지 않습니다. 복사, 이동, Duplicate, 선택 항목 폴더화에는
현재 쓰기 가능한 로컬 파일 작업 위치가 필요합니다.

### 미리보기 우선 일괄 이름 변경 (Preview 6)

활성 패널에서 두 항목 이상을 선택한 뒤 **File Operations > Batch Rename…**
또는 행 컨텍스트 메뉴를 선택합니다. 일반 문자열 찾기/바꾸기, 접두사, 접미사,
안정된 선택 순서를 따르는 일련번호 규칙을 제공합니다. 일반 파일과 패키지의
확장자 및 `.tar.gz` 같은 알려진 복합 압축 확장자는 보존하고 편집 가능한 이름
부분만 변경합니다. 전체 미리보기에서 변경 없음, 잘못된 이름, 중복 및 같은
폴더의 기존 항목 충돌을 실제 변경 전에 확인할 수 있습니다.

실행은 같은 폴더 안에서 2단계 트랜잭션으로 처리하므로 이름 교환과 순환 변경도
지원합니다. 작업 센터는 임시 이동, 최종 게시 및 롤백 단계를 표시하며, 취소 시
안전함을 증명할 수 있으면 원래 이름으로 복구합니다. 재시도는 캡처한 불변 계획을
사용하고, 되돌리기는 최종 동일성·지문과 원래 이름의 사용 가능성이 모두 유지된
경우에만 제공합니다. 미리보기 경로에는 10,000개 행을 5초 이내에 처리하는 자동
회귀 기준이 있습니다.

### 안전한 파일 작업 센터

복사, 이동, 휴지통, 새 폴더, 이름 변경, 압축, 압축 해제 및 되돌리기를 하나의
순차 작업 큐에서 처리합니다. 대기 작업의 순서를 바꾸고, 안전한 체크포인트에서
일시 정지하거나 정리 절차와 함께 취소할 수 있습니다. 재시도와 되돌리기는
동일성 및 지문 검사를 통해 대체된 데이터를 덮어쓰거나 삭제하지 않는다고
확인되는 경우에만 제공됩니다.

### 진행률을 확인할 수 있는 압축

**ZIP**, **TAR**, **TAR.GZ/TGZ**, **TAR.BZ2/TBZ/TBZ2** 및
**TAR.XZ/TXZ** 파일을 만들고 풀 수 있습니다. 여러 항목을 준비하는 단계에서는
최대 4개의 제한된 작업자를 사용하지만 실제 압축 명령은 하나의 작업으로
실행됩니다. 신뢰할 수 없는 바이트 백분율을 만들어내는 대신 준비, 인코딩,
마무리 단계를 구분해 표시합니다.

### 암호로 보호된 ZIP

이 소스에서 만드는 암호 보호 ZIP은 **AES-256만** 사용합니다. 현재 안전 정책에
따라 Store 또는 Deflate 항목을 포함한 AES-128, AES-192, AES-256 및 ZipCrypto를
읽을 수 있습니다. ZIP 파일명과 중앙 디렉터리 메타데이터는 보입니다. 암호화는
파일명 개인정보 보호가 아닙니다. 암호는 저장하거나 복구하지 않으며, 실패한
시도 뒤에는 암호를 다시 묻습니다.

Finder와 Archive Utility는 AES ZIP을 열지 못할 수 있습니다. 저장소에는 타사
호환성에 대한 자동 fixture 증거만 있으며 실제 호환성을 주장하지 않습니다.
리소스 포크, ACL 및 확장 속성은 보장하지 않습니다. 안전하지 않거나 크기 제한을
넘는 압축 파일은 fail closed로 거부하며, 정리 소유권을 증명하지 못한 결과는
복구 검토를 위해 보존하고 큐는 명시적인 계속 선택 전까지 멈춥니다. 7z, RAR,
암호로 보호된 TAR, Developer ID 서명 및 공증은 지원하지 않습니다.

### Google Drive와 OneDrive

Pengrid는 macOS File Provider를 통해 Google Drive와 OneDrive 위치를
발견합니다. Google 또는 Microsoft OAuth를 직접 구현하지 않습니다.
메타데이터만 사용하는 검색과 폴더 미리보기는 온라인 전용 파일 내용을
의도적으로 내려받지 않습니다. 복사나 압축처럼 실제 내용을 읽는 작업에서는
macOS가 원본 다운로드를 요청할 수 있습니다.

### 디렉터리 비교, Storage Inspector 및 접근성

디렉터리 비교는 양쪽 항목을 정렬해 보여주고 동일성을 다시 확인한 뒤 검토된
전송을 실행합니다. Storage Inspector는 로컬 저장소에서 큰 파일, 오래된 파일,
정확히 같은 중복 파일을 점진적으로 찾아내며 명시적으로 선택한 항목만 휴지통으로
보냅니다. 키보드 접근, VoiceOver 레이블, 동작 줄이기 및 개인정보를 노출하지
않는 상태 문구를 지원합니다.

명령, 세부 동작, 안전 규칙과 현재 제한 사항은
[상세 기능 안내서](docs/user-guide.ko.md)를 참고하세요.

## 소스에서 빌드하기

저장소를 복제합니다.

```bash
git clone https://github.com/pmh10401/Pengrid.git
cd Pengrid
```

또는 [main 브랜치 소스 ZIP](https://github.com/pmh10401/Pengrid/archive/refs/heads/main.zip)을
다운로드할 수 있습니다.

전체 Xcode를 사용해 빌드하고 검증합니다.

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --enable-swift-testing --no-parallel \
  --filter BloomFileManagerTests
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  ./script/build_and_run.sh --verify
open dist/Pengrid.app
```

개발용 앱 번들은 `dist/Pengrid.app`에 생성됩니다. 실행 파일 경로는
`dist/Pengrid.app/Contents/MacOS/BloomFileManager`로 유지됩니다.

## 문서

- [상세 기능 안내서](docs/user-guide.ko.md)
- [아키텍처 안내](docs/architecture.md)
- [현재 제한 사항](docs/current-limitations.ko.md)
- [릴리스 및 패키징 안내서](docs/release.ko.md)
- [Developer Preview 6 릴리스 노트](docs/release-notes-v1.3.0-developer-preview.6.md#한국어)
- [버전 1.3 압축 검증 기록](docs/verification/version-1.3-archive-checklist.md)
- [Smart Search 검증 기록](docs/verification/2026-08-04-smart-search.md)
- [폴더 미리보기 검증 기록](docs/verification/2026-08-04-folder-preview.md)
- [일괄 이름 변경 검증 기록](docs/verification/2026-08-11-batch-rename.md)
- [파일 컨텍스트 작업 검증 기록](docs/verification/2026-08-11-file-context-actions.md)
- [Storage Inspector 검증 기록](docs/verification/storage-inspector-checklist.md)

Pengrid는 계속 개발 중입니다. 아직 실행하지 않은 후보별 수동 검증 항목은
검증 문서에 `NOT RUN`으로 남아 있습니다.
