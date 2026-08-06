# Pengrid 1.3.0 Developer Preview 4

[한국어](#한국어) · [English](#english)

## English

Developer Preview 4 is the first published Pengrid DMG with password-protected
ZIP creation and extraction. It also carries forward the dual-pane workspace,
safe operation queue, Korean initial-consonant Smart Search, Space-key folder
preview, archive progress, directory comparison, Storage Inspector, and macOS
File Provider integration for Google Drive and OneDrive.

### Protected ZIP

- Creates password-protected ZIP archives using AES-256 only.
- Reads AES-128, AES-192, AES-256, and ZipCrypto entries using Store or Deflate
  when the archive passes Pengrid's safety policy.
- Prompts again after an incorrect password and does not save or recover
  passwords.
- Shows authenticated byte progress without exposing passwords or absolute
  parent paths in operation status.
- Rejects traversal, unsafe link topology, unsupported compression/encryption,
  malformed archives, more than 100,000 entries, and capacity-limit violations
  before publishing output.
- Keeps uncertain cleanup residue for explicit recovery review instead of
  silently deleting an item it can no longer prove it owns.

ZIP filenames, sizes, timestamps, and other central-directory metadata remain
visible; encryption is not filename privacy. Finder and Archive Utility may not
open AES ZIP files. Live Finder, Archive Utility, Windows, and WinZip
interoperability are not claimed by this preview.

### Other file-manager features

- Two independently navigable panes with history, sorting, selection, and
  pane-local filtering.
- Recursive Smart Search with Korean initial-consonant matching, metadata
  filters, saved searches, and identity-revalidated result actions.
- Space-key one-level folder preview; files and multiple selections continue to
  use system Quick Look.
- Ordered, pausable and cancellable copy, move, Trash, rename, new-folder,
  archive, extraction, retry, and conservative undo workflows.
- ZIP and TAR-family creation/extraction with bounded parallel preparation and
  visible preparation, encoding, and finishing phases.
- Google Drive and OneDrive discovery through macOS File Provider. Direct
  Google or Microsoft OAuth/API clients are not included.

### Install and trust notice

1. Download `Pengrid.dmg` from this release.
2. Verify its SHA-256 value if desired.
3. Open the DMG and copy `Pengrid.app` to `Applications`.

Requirements: Apple Silicon Mac, macOS 15 or later.

This free DMG is ad-hoc signed. It is not Developer ID signed or notarized, so
macOS Gatekeeper may block it. Download only from this GitHub release and use
Finder's contextual **Open** action only if you understand and accept the
warning. Pengrid does not ask you to disable macOS security controls.

### Verification

- App version: 1.3.0 (build 6)
- Packaged source commit: `9ae22293b498fde487f1f92ff7b05a917125621e`
- 1,059 automated tests passed in 77 suites
- Release packaging contract tests passed
- arm64 release build, ad-hoc signature, DMG verification, read-only mount,
  mounted-app signature/build, notice-byte comparison, local installation, and
  launch checks passed
- DMG SHA-256:
  `700f4dac87e07b76809d06b3ee5c237a7126550663a087ddc9a9547f9669c585`

Still not run: live third-party AES-ZIP interoperability, live Google Drive or
OneDrive materialization with user credentials, fresh-download Gatekeeper,
Developer ID/notarization, live VoiceOver observations, and large-archive
performance benchmarks.

## 한국어

Developer Preview 4는 암호로 보호된 ZIP 생성과 압축 해제를 처음 포함해
배포하는 Pengrid DMG입니다. 듀얼 패널 작업 공간, 안전한 작업 큐, 한글 초성
Smart Search, Space 키 폴더 미리보기, 압축 진행 상태, 디렉터리 비교, Storage
Inspector, Google Drive와 OneDrive의 macOS File Provider 연동도 함께 제공합니다.

### 암호 보호 ZIP

- 암호 보호 ZIP은 AES-256 방식으로만 생성합니다.
- Pengrid 안전 정책을 통과한 Store 또는 Deflate 항목에 대해 AES-128,
  AES-192, AES-256 및 ZipCrypto 압축 해제를 지원합니다.
- 잘못된 암호 뒤에는 새 암호를 다시 요청하며 암호를 저장하거나 복구하지
  않습니다.
- 암호나 절대 상위 경로를 상태 문구에 노출하지 않고 인증된 바이트 진행 상태를
  표시합니다.
- traversal, 위험한 링크 구조, 지원하지 않는 압축·암호화, 손상된 파일,
  100,000개 초과 항목 및 용량 제한 위반은 결과를 게시하기 전에 거부합니다.
- 정리 대상의 소유권을 증명할 수 없으면 임의로 삭제하지 않고 명시적인 복구
  검토 대상으로 보존합니다.

ZIP 파일명, 크기, 시각 및 중앙 디렉터리 메타데이터는 보이므로 암호화는 파일명
개인정보 보호가 아닙니다. Finder와 Archive Utility는 AES ZIP을 열지 못할 수
있으며 이 프리뷰는 실제 Finder, Archive Utility, Windows 또는 WinZip 호환성을
보장하지 않습니다.

### 그 밖의 파일 관리자 기능

- 탐색 기록, 정렬, 선택 및 패널별 필터가 독립적인 두 개의 파일 패널
- 한글 초성, 메타데이터 조건, 저장 검색 및 결과 동일성 재검증을 지원하는 재귀
  Smart Search
- Space 키 한 단계 폴더 미리보기와 파일·다중 선택용 시스템 Quick Look
- 순서를 조정하고 일시 정지·취소할 수 있는 복사, 이동, 휴지통, 이름 변경,
  새 폴더, 압축, 압축 해제, 재시도 및 보수적 되돌리기 작업
- 제한된 병렬 준비와 준비·인코딩·마무리 상태를 표시하는 ZIP 및 TAR 계열 도구
- macOS File Provider를 통한 Google Drive와 OneDrive 발견. Google 또는
  Microsoft OAuth/API 직접 클라이언트는 포함하지 않습니다.

### 설치 및 신뢰 안내

1. 이 릴리스에서 `Pengrid.dmg`를 다운로드합니다.
2. 필요하면 SHA-256 값을 확인합니다.
3. DMG를 열고 `Pengrid.app`을 `Applications` 폴더로 복사합니다.

요구 사항: Apple Silicon Mac, macOS 15 이상.

이 무료 DMG는 ad-hoc 방식으로 서명되어 있습니다. Developer ID 서명과 Apple
공증을 받지 않았으므로 macOS Gatekeeper가 실행을 차단할 수 있습니다. 이
GitHub 릴리스에서만 다운로드하고 경고를 이해하고 동의하는 경우에만 Finder의
컨텍스트 메뉴 **열기**를 사용하세요. Pengrid는 macOS 보안 기능을
비활성화하라고 요구하지 않습니다.

### 검증 결과

- 앱 버전: 1.3.0 (빌드 6)
- 패키징한 소스 커밋: `9ae22293b498fde487f1f92ff7b05a917125621e`
- 77개 스위트의 자동 테스트 1,059개 통과
- 릴리스 패키징 계약 테스트 통과
- arm64 릴리스 빌드, ad-hoc 서명, DMG 검증, 읽기 전용 마운트, 마운트 앱의
  서명·빌드 번호, notice 바이트 비교, 로컬 설치 및 실행 검사 통과
- DMG SHA-256:
  `700f4dac87e07b76809d06b3ee5c237a7126550663a087ddc9a9547f9669c585`

아직 실행하지 않은 검사는 실제 타사 AES ZIP 호환성, 사용자 자격 증명을 사용한
Google Drive·OneDrive materialization, 새로 다운로드한 파일의 Gatekeeper,
Developer ID·공증, 실제 VoiceOver 관찰 및 대용량 압축 성능 측정입니다.
