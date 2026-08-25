# Pengrid 1.3.0 Developer Preview 8 — Release notes

[한국어](#한국어) · [English](#english)

> **Published status:** Developer Preview 8 is available from the
> [GitHub release](https://github.com/pmh10401/Pengrid/releases/tag/v1.3.0-developer-preview.8).
> The app was packaged from merged commit
> `8866bd0d080d1e11f47f85f7b42f4e4fb14109b3`. The public DMG SHA-256 is
> `fa5b27b9cede4d053af37ff3a1f672c42083ea59652fe518675ed4f28730b5c5`.

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

- Release version: 1.3.0 (build 10).
- Architecture: Apple Silicon arm64.
- If `DEVELOPER_DIR` is unset while `xcode-select` still points to Command Line
  Tools, the local build and package scripts select the installed full Xcode at
  `/Applications/Xcode.app/Contents/Developer`. This preserves Swift Testing
  support during release validation.

### Install and trust notice

To install the published DMG:

1. Download `Pengrid.dmg` only from the Pengrid GitHub release.
2. Compare it with the SHA-256 value published for that exact asset.
3. Open the DMG and copy `Pengrid.app` to `Applications`.

Requirements: Apple Silicon Mac, macOS 15 or later.

The free DMG is ad-hoc signed, not Developer ID signed, and not
notarized. Gatekeeper may block it. Use Finder's contextual **Open** action only
if you understand and accept the warning. Pengrid does not ask you to disable
macOS security controls.

### Release verification evidence

- Pull request [#15](https://github.com/pmh10401/Pengrid/pull/15) merged as
  `8866bd0d080d1e11f47f85f7b42f4e4fb14109b3`; the public `main` CI run passed.
- One exact-commit unsigned packaging run passed 1,931 tests in 123 suites in
  86.644 seconds, built the arm64 Release product, and produced the app and DMG.
  The artifact was not repackaged after validation.
- Private APFS integration passed five tests in one suite in 0.047 seconds with
  no residual image attachment or mount.
- The published app reports identifier `com.minho.BloomFileManager`, version
  1.3.0, build 10, and arm64-only architecture. Strict deep ad-hoc signature,
  canonical icon and notices, native linkage, DMG verification, and mounted app
  tree checks passed. Gatekeeper rejection was expected and observed.
- The exact packaged app was installed and launched from
  `/Applications/Pengrid.app`.
- The uploaded GitHub asset digest and an unauthenticated public redownload
  matched SHA-256
  `fa5b27b9cede4d053af37ff3a1f672c42083ea59652fe518675ed4f28730b5c5`.
  The redownload was byte-for-byte identical to the validated local DMG.
- Google Drive, OneDrive, and live VoiceOver checks remain **MANUAL NOT RUN**.

## 한국어

> **공개 상태:** Developer Preview 8은
> [GitHub 릴리스](https://github.com/pmh10401/Pengrid/releases/tag/v1.3.0-developer-preview.8)에서
> 받을 수 있습니다. 병합 커밋
> `8866bd0d080d1e11f47f85f7b42f4e4fb14109b3`에서 패키징했으며, 공개 DMG의
> SHA-256은
> `fa5b27b9cede4d053af37ff3a1f672c42083ea59652fe518675ed4f28730b5c5`입니다.

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

- 릴리스 버전: 1.3.0(빌드 10).
- 아키텍처: Apple Silicon arm64.
- `DEVELOPER_DIR`가 없고 `xcode-select`가 Command Line Tools를 가리키더라도 로컬
  빌드·패키지 스크립트는 설치된 전체 Xcode인
  `/Applications/Xcode.app/Contents/Developer`를 선택합니다. 릴리스 검증 중 Swift
  Testing 지원이 사라지는 문제를 막습니다.

### 설치 및 신뢰 안내

공개된 DMG는 다음 순서로 설치합니다.

1. Pengrid GitHub 릴리스에서만 `Pengrid.dmg`를 다운로드합니다.
2. 해당 자산에 공개된 SHA-256과 다운로드 파일을 비교합니다.
3. DMG를 열고 `Pengrid.app`을 `Applications` 폴더로 복사합니다.

요구 사항: Apple Silicon Mac, macOS 15 이상.

무료 DMG는 ad-hoc 방식으로 서명했으며 Developer ID 서명과 Apple
공증을 받지 않습니다. Gatekeeper가 차단할 수 있습니다. 경고를 이해하고 동의하는
경우에만 Finder의 컨텍스트 **열기**를 사용하세요. Pengrid는 macOS 보안 기능을
끄도록 요구하지 않습니다.

### 릴리스 검증 근거

- Pull request [#15](https://github.com/pmh10401/Pengrid/pull/15)를
  `8866bd0d080d1e11f47f85f7b42f4e4fb14109b3`으로 병합했고 공개 `main` CI가
  통과했습니다.
- 정확한 병합 커밋에서 unsigned 패키징을 한 번 실행해 86.644초에 테스트
  1,931개와 스위트 123개를 통과하고 arm64 Release 앱과 DMG를 만들었습니다.
  검증 후 산출물을 다시 패키징하지 않았습니다.
- 비공개 APFS 통합은 0.047초에 테스트 5개와 스위트 1개를 통과했으며 연결된
  이미지나 마운트가 남지 않았습니다.
- 공개 앱의 식별자는 `com.minho.BloomFileManager`, 버전은 1.3.0, 빌드는 10,
  아키텍처는 arm64 전용입니다. strict deep ad-hoc 서명, 원본 아이콘과 고지문,
  네이티브 연결, DMG 및 마운트 앱 트리 검사가 통과했습니다. Gatekeeper 거부는
  예상했고 실제로 확인했습니다.
- 정확한 패키징 앱을 `/Applications/Pengrid.app`에 설치하고 실행했습니다.
- GitHub 업로드 자산 digest와 인증 없는 공개 재다운로드가 SHA-256
  `fa5b27b9cede4d053af37ff3a1f672c42083ea59652fe518675ed4f28730b5c5`와
  일치했습니다. 재다운로드 파일은 검증한 로컬 DMG와 바이트 단위로 같았습니다.
- Google Drive, OneDrive 및 실제 VoiceOver 검사는 **MANUAL NOT RUN**입니다.
