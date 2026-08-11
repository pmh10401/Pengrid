# Pengrid 직접 배포 안내서

**한국어** · [English](release.md) · [README](../README.ko.md)

Pengrid는 macOS 15 이상을 실행하는 Apple Silicon Mac에 직접 배포합니다.
App Sandbox entitlement를 사용하지 않습니다. 실행 파일명과 호환성에 영향을
주는 내부 식별자는 `BloomFileManager`로 유지합니다.

## 현재 게시된 Developer Preview

현재 무료 바이너리 릴리스는
[Pengrid 1.3.0 Developer Preview 6](https://github.com/pmh10401/Pengrid/releases/tag/v1.3.0-developer-preview.6)입니다.

- DMG: [Pengrid.dmg](https://github.com/pmh10401/Pengrid/releases/download/v1.3.0-developer-preview.6/Pengrid.dmg)
- 태그: `v1.3.0-developer-preview.6`
- 패키징한 소스 커밋: `c508592b439743688fe0dc0c447c4c495355f8f4`
- 앱 버전: `1.3.0`, 빌드 `8`
- 플랫폼: Apple Silicon, macOS 15 이상
- 자동 검증: 92개 스위트의 테스트 1,406개 통과
- 패키징: 릴리스 계약 테스트와 arm64 프로덕션 빌드 통과
- 파일 검사: 앱 서명, DMG 체크섬, 마운트된 앱의 빌드 번호, 로컬 설치, 실행,
  검증 통과. GitHub 자산 digest와 공개 재다운로드 비교는 게시 후 진행
- DMG SHA-256:
  `d17bf6a9e37240629e6d309429e260c0c67bb9d71a3ebc30de349ece69f491c9`

Preview 6는 캡처된 선택을 사용하는 컨텍스트 작업, 반대쪽 패널 전송,
Duplicate 및 선택 항목을 새 폴더로 묶는 트랜잭션 기능을 추가한 릴리스입니다.
같은 패키징 앱을 `/Applications/Pengrid.app`에 설치하고 빌드 8을 확인한 뒤
정상적으로 실행했습니다.

이 파일은 ad-hoc 방식으로 서명되었으며 Developer ID 서명과 Apple 공증을
받지 않았습니다. 따라서 `spctl --assess --type execute`의 Developer ID
배포 심사에서 예상대로 거부됩니다. 서명된 공개 릴리스가 아니라 unsigned
Developer Preview임을 명확히 표시해 배포합니다. 아직 `NOT RUN`인 실제 File
Provider, 이동식 볼륨, 대소문자 구분 볼륨, 키보드 및 접근성 검사는 저장소의
검증 문서에 그대로 기록되어 있습니다.

## 버전 1.3 릴리스 게이트

버전 1.3은 **ZIP**, **TAR**, **TAR.GZ/TGZ**,
**TAR.BZ2/TBZ/TBZ2** 및 **TAR.XZ/TXZ** 압축과 해제를 제공합니다. 새 TAR
계열 파일은 `.tar`, `.tar.gz`, `.tar.bz2`, `.tar.xz` 표준 확장자를
사용하고 짧은 형식은 압축 해제 입력으로 인식합니다.

안전한 스테이징 게시, 여러 항목 압축, 클라우드 File Provider 접근, 선택한
심볼릭 링크 보존, 취소 정리 및 VoiceOver용 압축 상태를 포함합니다. 여러
원본을 압축할 때 병렬 처리는 비공개 통합 디렉터리로 복사하는 준비 단계에만
적용합니다. 작업자 수는 최대 4개이며 프로세서 수 또는 원본 수를 넘지
않습니다. 실제 압축과 압축 해제 명령은 하나의 네이티브 작업입니다.

암호로 보호된 ZIP은 아래 소스 기능 경계에 포함되지만 암호로 보호된 TAR, RAR
및 7z는 지원하지 않습니다. 필요한 자동·정적 검증과 실제 수동 검증 결과는
[`docs/verification/version-1.3-archive-checklist.md`](verification/version-1.3-archive-checklist.md)에
기록합니다.

## 암호로 보호된 ZIP 릴리스 기능 경계

Preview 4에서 만드는 암호 보호 ZIP은 **AES-256만** 사용합니다. 현재 안전
정책을 통과하고 Store 또는 Deflate 방식인 항목은 AES-128, AES-192, AES-256 및
ZipCrypto를 읽습니다. ZIP 파일명, 크기, 시각 및 중앙 디렉터리 메타데이터는
그대로 보이므로 암호화는 파일명 개인정보 보호가 아닙니다. 암호는 저장하거나
복구하지 않으며 실패한 시도 뒤에는 새 요청으로 다시 묻습니다.

위험하거나 잘못된 구조, traversal 또는 크기 제한을 넘는 압축 파일은 fail
closed로 거부합니다. 남은 임시 항목의 소유권을 증명할 수 없으면 복구 검토를
위해 보존하고 큐 진행은 명시적인 계속 선택 전까지 기다립니다. 리소스 포크,
ACL 및 확장 속성은 보장하지 않습니다. Finder와 Archive Utility는 AES ZIP을
열지 못할 수 있습니다. 타사 호환성은 커밋된 자동 fixture로만 나타내며 실제
Finder, Archive Utility, Windows 또는 WinZip 검사를 의미하지 않습니다. 7z,
RAR 및 암호로 보호된 TAR은 지원하지 않습니다. 이 무료 Developer Preview에는
Developer ID 서명과 공증을 수행하지 않았습니다.

## 버전 1.2 릴리스 게이트

버전 1.2는 패널별 파일명 필터, 탐색 기록, 세션 복원 및 선택을 따라가는 Quick
Look을 도입했습니다. 당시 검증 기록은
[`docs/verification/version-1.2-checklist.md`](verification/version-1.2-checklist.md)에
보존되어 있습니다.

로컬·외장·대소문자 구분 볼륨, 비교 및 전송 중 연결 해제와 재연결, 큰 파일,
VoiceOver, Full Keyboard Access, 대비 증가, 동작 줄이기, 라이트 모드 및
다크 모드는 실제 환경에서 별도 확인해야 합니다. 자동 fixture와 소스 검사는
이 검증을 대신하지 않습니다.

선택적 서명 배포 게이트는 정확한 후보를 유효한 Developer ID Application
인증서로 서명하고 Apple 공증 승인을 받은 뒤 티켓을 staple·검증하고
Gatekeeper 심사를 통과할 때까지 열려 있습니다. 이는 unsigned Developer
Preview임을 명확히 표시한 무료 패키지 배포를 막지 않습니다. unsigned 파일을
서명된 공개 릴리스라고 설명해서는 안 됩니다.

## 로컬 unsigned 패키지와 Developer Preview

Apple Silicon Mac에서는 Command Line Tools만으로 로컬 패키징을 수행할 수
있습니다.

```bash
./script/package_release.sh --unsigned
codesign --verify --deep --strict --verbose=2 dist/release/Pengrid.app
otool -L dist/release/Pengrid.app/Contents/MacOS/BloomFileManager
cmp THIRD_PARTY_NOTICES.md \
  dist/release/Pengrid.app/Contents/Resources/THIRD_PARTY_NOTICES.md
file dist/release/Pengrid.app/Contents/MacOS/BloomFileManager
plutil -p dist/release/Pengrid.app/Contents/Info.plist
codesign -dvvv --entitlements :- dist/release/Pengrid.app
hdiutil verify dist/release/Pengrid.dmg
```

앱과 DMG는 로컬 검사를 위해 ad-hoc 방식으로 서명됩니다. Developer ID
배포 파일이 아니므로 Gatekeeper가 Developer ID 파일로 승인할 것으로 기대하면
안 됩니다. GitHub의 unsigned **Developer Preview**는 사전 릴리스 제목과
설명에 이 신뢰 경고를 명확히 표시할 때만 게시합니다.

일반 로컬 작업 공간에서 `dist/release/Pengrid.app`은 실제 앱 디렉터리입니다.
저장소가 File Provider가 관리하는 Documents 폴더 아래에 있다면 스크립트는
현재 사용자 캐시의 버전별 실제 번들을 가리키는 심볼릭 링크를 대신 만듭니다.
Finder 메타데이터가 반복해서 붙어 서명이 무효화되는 일을 방지하기 위한
동작입니다.

교체가 성공한 뒤에는 정규 경로와 파일시스템 동일성으로 직접 소유한 캐시
버전임을 증명할 수 있을 때만 이전 버전을 제거합니다. 외부 심볼릭 링크의
대상은 제거하지 않습니다. 캐시를 삭제하면 로컬 앱 링크가 끊어질 수 있으며
패키징 스크립트를 다시 실행하면 복구됩니다. signed ZIP은 항상 독립된
파일이며 캐시 심볼릭 링크를 포함하지 않습니다.

unsigned 모드는 `Pengrid.app`과 `Pengrid.dmg`을 ad-hoc 서명하고
교체합니다. `Pengrid.zip`은 만들거나 교체하지 않으며 기존 ZIP을 의도적으로
보존합니다. 그 ZIP은 이전 signed 릴리스에서 생긴 파일일 수 있습니다. signed
모드는 앱, ZIP 및 DMG를 모두 만듭니다. unsigned 실행 뒤 남은 ZIP을 최신
실행이 만든 파일처럼 배포하면 안 됩니다.

## 선택적 signed 및 notarized 패키지

서명된 릴리스를 만들려면 전체 Xcode를 설치하고 라이선스에 동의한 뒤 활성
개발자 디렉터리로 선택합니다.

```bash
sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -license accept
xcodebuild -version
xcrun --find notarytool
xcrun --find stapler
```

로그인 키체인에 `Developer ID Application` 인증서를 설치합니다. 인증서나
자격 증명 값을 이슈 또는 빌드 로그에 붙이지 말고 유효한 서명 identity의
존재만 확인합니다.

```bash
security find-identity -p codesigning -v
```

Apple의 앱 전용 암호를 사용해 키체인 프로필을 한 번 만듭니다. 자격 증명 값은
저장소 밖에 보관합니다.

```bash
export NOTARY_PROFILE='BloomNotary'
read -r APPLE_ID
read -r TEAM_ID
read -rs APP_SPECIFIC_PASSWORD
xcrun notarytool store-credentials "$NOTARY_PROFILE" \
  --apple-id "$APPLE_ID" \
  --team-id "$TEAM_ID" \
  --password "$APP_SPECIFIC_PASSWORD"
unset APPLE_ID TEAM_ID APP_SPECIFIC_PASSWORD
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE"
```

인증서의 정확한 표시 이름과 프로필 이름을 설정하고 signed 릴리스 명령을
실행합니다.

```bash
export DEVELOPER_ID_APPLICATION='Developer ID Application: Example Name (TEAMID1234)'
export NOTARY_PROFILE='BloomNotary'
./script/package_release.sh --signed
```

signed 모드는 테스트나 빌드 전에 정확한 Developer ID Application identity와
`notarytool history` 키체인 프로필을 확인합니다. 이어서 테스트와 arm64
릴리스 빌드, Hardened Runtime 및 secure timestamp 서명, 비공개
`ditto --keepParent` 제출 파일 생성과 구조화된 `Accepted` 공증 결과를
요구합니다.

공증이 승인되면 비공개 앱에 티켓을 staple하고 검증합니다. 최종 ZIP을 다시
만들어 별도로 압축 해제·검사하고 DMG를 생성·검증한 뒤에만 공개 앱, ZIP,
DMG를 트랜잭션 방식으로 교체합니다. 실패, 명시적 종료, 인터럽트 또는 종료
시그널이 발생하면 동일성을 확인한 롤백을 수행하고 기존 공개 파일을 그대로
유지합니다.

최종 파일은 다음 명령으로 검증합니다.

```bash
codesign --verify --deep --strict --verbose=2 dist/release/Pengrid.app
codesign -dvvv --entitlements :- dist/release/Pengrid.app
xcrun stapler validate dist/release/Pengrid.app
spctl --assess --type execute --verbose=4 dist/release/Pengrid.app
ditto -x -k dist/release/Pengrid.zip /tmp/pengrid-release-inspection
hdiutil verify dist/release/Pengrid.dmg
```

`spctl`은 승인된 Developer ID 출처를 보고해야 합니다. entitlement 출력에
`com.apple.security.app-sandbox`가 포함되면 안 됩니다.

## 거부된 공증 제출 복구

스크립트는 필수 필드를 읽기 전에 `submission.json`과
`submission.plist`를 사용자별 비공개 진단 디렉터리에 저장합니다. 실패하면
그 경로를 출력합니다. 올바른 제출 ID가 있는 거부 결과에서는
`notary-log.json`도 다운로드합니다.

무작정 다시 제출하지 말고 해당 ID의 정보와 로그를 확인합니다.

```bash
xcrun notarytool info SUBMISSION_ID --keychain-profile "$NOTARY_PROFILE"
xcrun notarytool log SUBMISSION_ID --keychain-profile "$NOTARY_PROFILE" notarization-log.json
```

`notarization-log.json`에 보고된 서명, 번들 또는 Hardened Runtime 문제를
모두 수정하고 `./script/package_release.sh --signed`를 다시 실행합니다.
실패한 트랜잭션 뒤에 이전 공개 앱을 따로 staple하지 마세요. 성공한 재실행이
승인된 정확한 후보를 staple하고 검증합니다.

성공한 실행의 티켓 검증 명령은 다음과 같습니다.

```bash
xcrun stapler validate dist/release/Pengrid.app
```

## 파일 형식과 물리 볼륨 제한

전송 엔진은 일반 파일, 디렉터리 및 심볼릭 링크를 지원합니다. 장치 노드,
소켓, FIFO 및 기타 특수 파일시스템 항목은 일반 데이터처럼 복사하지 않고
항목별 실패로 보고합니다.

실제 물리 볼륨 사이의 이동은 수동 릴리스 검사가 필요합니다. 자동 테스트는
시뮬레이션한 볼륨 식별자만 사용할 수 있으므로 실제 장치 연결 해제, 재연결 및
중간 실패를 완전히 대신할 수 없습니다.
