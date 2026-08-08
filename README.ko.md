# Pengrid

**한국어** · [English](README.md)

Pengrid는 macOS용 무료 오픈소스 듀얼 패널 파일 관리자입니다. 빠른 키보드
탐색, 재귀 검색, 안전한 파일 작업 큐, 폴더 미리보기, 압축 도구, 디렉터리
비교 및 저장 공간 분석을 하나의 작업 공간에서 제공합니다.

기존 버전과의 호환성을 위해 Swift 패키지, 실행 파일, 소스 모듈, 번들 식별자
및 기존 설정 저장 위치의 내부 이름은 `BloomFileManager`로 유지합니다.

## 다운로드

현재 배포 버전은
[Pengrid 1.3.0 Developer Preview 5](https://github.com/pmh10401/Pengrid/releases/tag/v1.3.0-developer-preview.5)입니다.
Preview 4의 암호 보호 ZIP과 파일 관리 기능을 유지하면서 대규모 폴더 로딩,
패널 필터, 정렬 및 취소 성능을 개선했습니다.

- [Pengrid.dmg 다운로드](https://github.com/pmh10401/Pengrid/releases/download/v1.3.0-developer-preview.5/Pengrid.dmg)
- 앱 버전: **1.3.0 (빌드 7)**
- 요구 사항: **Apple Silicon Mac, macOS 15 이상**
- 검증 결과: **80개 스위트의 자동 테스트 1,223개 통과**
- DMG SHA-256:
  `3db4c0bd18b7001fe93d83ea92baf7928527d393bc5310e4ba40f7e9d75148e6`

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
- [릴리스 및 패키징 안내서](docs/release.ko.md)
- [Developer Preview 5 릴리스 노트](docs/release-notes-v1.3.0-developer-preview.5.md#한국어)
- [버전 1.3 압축 검증 기록](docs/verification/version-1.3-archive-checklist.md)
- [Smart Search 검증 기록](docs/verification/2026-08-04-smart-search.md)
- [폴더 미리보기 검증 기록](docs/verification/2026-08-04-folder-preview.md)
- [Storage Inspector 검증 기록](docs/verification/storage-inspector-checklist.md)

Pengrid는 계속 개발 중입니다. 아직 실행하지 않은 후보별 수동 검증 항목은
검증 문서에 `NOT RUN`으로 남아 있습니다.
