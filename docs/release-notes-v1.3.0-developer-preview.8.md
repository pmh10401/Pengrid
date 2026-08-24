# Pengrid 1.3.0 Developer Preview 8 — Pre-merge candidate notes

[한국어](#한국어) · [English](#english)

> **Candidate status:** These notes describe a locally verified, disposable
> build 10 candidate from an unmerged worktree. Developer Preview 8 has not been
> published. The public commit, asset, download verification, and DMG SHA-256
> remain intentionally pending until one DMG is built from the exact merged
> commit.

## English

Developer Preview 8 adds optional SHA-256 content verification before Pengrid
publishes transferred files. The feature is designed to detect a changed or
unreadable source, copy mismatch, changed staging entry, unsupported tree, or
cancellation without replacing a pre-existing destination with unverified
content.

### Verified transfer pipeline

- Enable **Verify transferred file contents before publishing** in the **File
  Operations** Settings tab. It is off by default.
- Each queued operation captures the setting once. Changing Settings later does
  not silently change a waiting job or its Retry.
- Copy, Duplicate, cross-volume move, and reviewed one-way folder
  synchronization Copy/Replace actions use private staging, SHA-256 comparison,
  receipt revalidation, and only then publication.
- A same-volume move transfers no bytes, so it records a bounded **No byte
  transfer** result instead of hashing an existing-entry rename.
- One operation verifies at most two file pairs concurrently. This adds useful
  parallelism without allowing a large transfer to saturate storage with
  unbounded readers.

### Trees, progress, and scope

- Directory and package roots are traversed recursively. Relative structure and
  item kinds must match.
- Regular-file data forks are compared with SHA-256. Symbolic-link payloads are
  compared without following their targets.
- The operation is limited to 250,000 descendants per root and depth 256. A
  limit breach fails closed; Pengrid does not publish an unverified fallback.
- Progress is byte-weighted across reads from both sides of each pair. The
  adjacent count is file-weighted, so the percentage and file count may advance
  at different rates. Zero-byte-only trees still reach determinate completion.
- Resource forks, extended attributes, ACLs, ownership, flags, creation dates,
  hard-link relationships, sparse allocation, and archive creation/extraction
  output are outside this content-verification claim.

### Failure handling and privacy

- A mismatch, read error, identity change, unsupported entry, scope overflow,
  or cancellation prevents publication. The original source and a pre-existing
  destination remain unchanged.
- Pengrid removes only private staging whose identity and operation ownership it
  can revalidate. Uncertain cleanup becomes **Recovery Needed** and pauses queue
  advancement for review.
- Operation Center retains only bounded status, verified-file count, and one
  operation-wide logical-byte aggregate for the current app session. It does
  not persist hashes, per-file sizes, path lists, or underlying errors.
- Status and VoiceOver text use sanitized basenames and formatted aggregates,
  not absolute parent paths, digests, or raw byte totals.

### File Provider boundary

Google Drive and OneDrive continue to integrate through macOS File Provider;
Pengrid does not contain a direct Google or Microsoft OAuth/API client. Both
source and staged bytes must be locally readable during verification. macOS or
the installed provider may materialize an online-only source. Signed-in Google
Drive and OneDrive behavior remains a manual release gate and is not inferred
from local APFS tests.

### Build and package reliability

- Candidate version: 1.3.0 (build 10).
- Architecture: Apple Silicon arm64.
- If `DEVELOPER_DIR` is unset while `xcode-select` still points to Command Line
  Tools, the local build and package scripts select the installed full Xcode at
  `/Applications/Xcode.app/Contents/Developer`. This preserves Swift Testing
  support during release validation.

### Install and trust notice

When a merged-commit DMG is published:

1. Download `Pengrid.dmg` only from the Pengrid GitHub release.
2. Compare it with the SHA-256 value published for that exact asset.
3. Open the DMG and copy `Pengrid.app` to `Applications`.

Requirements: Apple Silicon Mac, macOS 15 or later.

The planned free DMG is ad-hoc signed, not Developer ID signed, and not
notarized. Gatekeeper may block it. Use Finder's contextual **Open** action only
if you understand and accept the warning. Pengrid does not ask you to disable
macOS security controls.

### Pre-merge verification evidence

- Focused safety regression: 383 tests in 12 suites passed in 4.874 seconds.
- Complete nonparallel regression: 1,931 tests in 123 suites passed twice, in
  86.066 and 85.441 seconds, around a successful arm64 Release build.
- After strengthening the full-Xcode fallback contract in response to
  independent review, another complete run passed 1,931 tests in 123 suites in
  93.051 seconds.
- The complete unsigned packaging run passed its own nonparallel 1,931-test,
  123-suite gate in 86.978 seconds before building and validating the app and
  DMG.
- Private APFS integration: five tests in one suite passed in 0.048 seconds,
  with no residual image attachment or harness temporary root.
- The disposable app reports identifier `com.minho.BloomFileManager`, version
  1.3.0, build 10, and arm64-only architecture.
- Strict deep code-sign verification passed with the expected ad-hoc signature.
  The source icon and third-party notice match the packaged resources, the DMG
  passed `hdiutil verify`, and its read-only mounted app tree matches the local
  packaged app. Gatekeeper rejection was expected and observed.
- Google Drive, OneDrive, and live VoiceOver checks are **MANUAL NOT RUN**.
- Exact merged-commit packaging, public CI, installation, GitHub publication,
  unauthenticated redownload comparison, and the public DMG SHA-256 are **NOT
  RUN**. No checksum from this disposable candidate is a release checksum.

## 한국어

Developer Preview 8은 Pengrid가 전송한 파일을 게시하기 전에 선택적으로 SHA-256
내용 검증을 수행하는 기능을 추가합니다. 원본 변경·읽기 실패, 복사 불일치,
스테이징 변경, 지원하지 않는 트리 또는 취소를 감지하면 검증되지 않은 내용으로
기존 대상을 교체하지 않도록 설계했습니다.

### 검증 전송 흐름

- 설정의 **File Operations** 탭에서 **Verify transferred file contents before
  publishing**을 켭니다. 기본값은 꺼짐입니다.
- 큐에 들어간 작업은 설정을 한 번 캡처합니다. 나중에 설정을 바꿔도 대기 중인
  작업과 Retry 정책이 몰래 바뀌지 않습니다.
- 복사, Duplicate, 다른 볼륨으로 이동, 검토된 한 방향 폴더 동기화의 Copy/Replace
  작업은 비공개 스테이징, SHA-256 비교, 검증 영수증 재확인을 거친 뒤 게시합니다.
- 같은 볼륨 이동은 바이트를 전송하지 않으므로 기존 항목의 이름 공간 이동을
  해시하지 않고 제한된 **No byte transfer** 결과를 기록합니다.
- 한 작업은 파일 쌍을 최대 두 개까지 병렬로 검증합니다. 유용한 병렬성은
  제공하되 많은 reader가 저장 장치를 무제한 점유하지 않도록 제한합니다.

### 트리, 진행률 및 범위

- 디렉터리와 패키지 루트를 재귀적으로 순회하며 상대 구조와 항목 종류가
  일치해야 합니다.
- 일반 파일의 데이터 포크는 SHA-256으로 비교합니다. 심볼릭 링크는 대상을
  따라가지 않고 링크 payload를 비교합니다.
- 루트 하나당 하위 항목 250,000개와 깊이 256으로 제한합니다. 한도를 넘으면
  안전하게 실패하며 검증하지 않은 게시로 대체하지 않습니다.
- 진행률은 파일 쌍 양쪽에서 읽은 바이트를 기준으로 가중합니다. 옆의 개수는 파일
  수 기준이므로 백분율과 파일 개수의 진행 속도가 다를 수 있습니다. 0바이트
  파일만 있는 트리도 결정적 완료 상태에 도달합니다.
- 리소스 포크, 확장 속성, ACL, 소유권, 플래그, 생성일, 하드 링크 관계, sparse
  allocation 및 압축 생성·해제 결과는 내용 검증을 완료했다고 주장하는 범위에서
  제외합니다.

### 실패 처리와 개인정보 보호

- 불일치, 읽기 오류, 동일성 변경, 지원하지 않는 항목, 범위 초과 또는 취소가
  발생하면 게시하지 않습니다. 원본과 기존 대상은 그대로 유지합니다.
- Pengrid는 동일성과 작업 소유권을 다시 확인할 수 있는 비공개 스테이징만
  제거합니다. 안전한 정리를 확신할 수 없으면 **Recovery Needed**로 전환하고
  검토할 때까지 큐 진행을 멈춥니다.
- Operation Center에는 현재 앱 세션 동안 제한된 상태, 검증 파일 수, 작업 단위
  논리 바이트 합계만 남깁니다. 해시, 파일별 크기, 경로 목록 또는 내부 오류를
  디스크에 저장하지 않습니다.
- 상태와 VoiceOver 문구는 정리한 기본 이름과 사람이 읽을 수 있는 합계를
  사용하며 절대 상위 경로, digest 또는 원시 바이트 수를 표시하지 않습니다.

### File Provider 경계

Google Drive와 OneDrive는 계속 macOS File Provider를 통해 연결합니다. Pengrid에는
Google 또는 Microsoft OAuth/API 직접 클라이언트가 없습니다. 검증 중에는 원본과
스테이징 바이트를 모두 로컬에서 읽을 수 있어야 합니다. 온라인 전용 원본은 macOS
또는 설치된 provider가 materialize할 수 있습니다. 로그인된 Google Drive와
OneDrive 동작은 수동 릴리스 게이트로 남아 있으며 로컬 APFS 테스트 결과로 대신하지
않습니다.

### 빌드·패키지 안정성

- 후보 버전: 1.3.0(빌드 10).
- 아키텍처: Apple Silicon arm64.
- `DEVELOPER_DIR`가 없고 `xcode-select`가 Command Line Tools를 가리키더라도 로컬
  빌드·패키지 스크립트는 설치된 전체 Xcode인
  `/Applications/Xcode.app/Contents/Developer`를 선택합니다. 릴리스 검증 중 Swift
  Testing 지원이 사라지는 문제를 막습니다.

### 설치 및 신뢰 안내

병합 커밋으로 만든 DMG가 공개되면 다음 순서로 설치합니다.

1. Pengrid GitHub 릴리스에서만 `Pengrid.dmg`를 다운로드합니다.
2. 해당 자산에 공개된 SHA-256과 다운로드 파일을 비교합니다.
3. DMG를 열고 `Pengrid.app`을 `Applications` 폴더로 복사합니다.

요구 사항: Apple Silicon Mac, macOS 15 이상.

무료로 제공할 예정인 DMG는 ad-hoc 방식으로 서명하며 Developer ID 서명과 Apple
공증을 받지 않습니다. Gatekeeper가 차단할 수 있습니다. 경고를 이해하고 동의하는
경우에만 Finder의 컨텍스트 **열기**를 사용하세요. Pengrid는 macOS 보안 기능을
끄도록 요구하지 않습니다.

### 병합 전 검증 근거

- 전송 안전성 집중 회귀검증: 테스트 383개와 스위트 12개를 4.874초에 통과.
- 전체 비병렬 회귀검증: arm64 Release 빌드 전후로 테스트 1,931개와 스위트
  123개를 두 번 통과했으며 각각 86.066초와 85.441초가 걸림.
- 독립 리뷰에 따라 전체 Xcode fallback 계약을 강화한 뒤에도 전체 테스트
  1,931개와 스위트 123개를 93.051초에 다시 통과함.
- 전체 unsigned 패키징 실행도 앱과 DMG를 빌드·검증하기 전에 자체 비병렬
  테스트 1,931개와 스위트 123개를 86.978초에 통과함.
- 비공개 APFS 통합: 0.048초에 테스트 5개와 스위트 1개를 통과했으며 연결된
  이미지나 하네스 임시 루트가 남지 않음.
- 일회성 앱의 식별자는 `com.minho.BloomFileManager`, 버전은 1.3.0, 빌드는 10,
  아키텍처는 arm64 전용임.
- 예상한 ad-hoc 서명으로 strict deep 코드 서명 검증을 통과함. 원본 아이콘과
  제3자 고지문이 패키징 리소스와 같고, DMG가 `hdiutil verify`를 통과했으며 읽기
  전용으로 마운트한 앱 트리가 로컬 패키징 앱과 같음. Gatekeeper 거부를 예상했고
  실제로 확인함.
- Google Drive, OneDrive 및 실제 VoiceOver 검사는 **MANUAL NOT RUN**.
- 정확한 병합 커밋 패키징, 공개 CI, 설치, GitHub 공개, 인증 없는 재다운로드 비교
  및 공개 DMG SHA-256은 **NOT RUN**. 이 일회성 후보의 checksum은 릴리스
  checksum이 아님.
