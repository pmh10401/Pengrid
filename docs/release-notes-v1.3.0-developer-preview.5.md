# Pengrid 1.3.0 Developer Preview 5

[한국어](#한국어) · [English](#english)

## English

Developer Preview 5 focuses on responsiveness and cancellation safety when
browsing and filtering large folders. It retains Preview 4's dual-pane file
management, Korean initial-consonant Smart Search, Space-key folder preview,
archive progress, protected ZIP, comparison, Storage Inspector, and macOS File
Provider integration.

### Faster large-folder navigation

- Publishes directory entries progressively and enriches metadata in bounded
  batches instead of repeating work on the visible path.
- Keeps accepted pane projections and identity indexes so repeated reads,
  selection restoration, rename routing, and table updates avoid redundant
  scans.
- Uses incremental AppKit table updates with measured fallbacks for cases where
  a full reload is safer.
- In the retained 10,000-entry verification, complete loading fell from about
  1.09 seconds to a 0.55-second median. This is automated fixture evidence, not
  a guarantee for every disk or cloud provider.

### Pane-filter and sorting improvements

- Reuses exact active-order snapshots and safely narrows eligible ASCII query
  extensions while keeping localized Korean and Unicode matching exact.
- Uses bounded parallel traversal only for sufficiently large numeric queries;
  every result is checked against the unchanged filter-and-sort oracle.
- Sort changes can reuse the accepted visible subset, while token-gated warm-up
  work starts only after the matching table application finishes.
- Obsolete projection workers are cancelled before cancellation accounting;
  stale results cannot replace newer rows.

The canonical release benchmark contains 48 isolated scenarios and 1,920 raw
samples. All 267 policy-v3 hard gates passed. One relative p95 advisory and
three stretch-target misses remain documented; all absolute latency, exactness,
cancellation, worker-drain, subset-sort, and RSS hard gates passed. The timing
boundary ends after production table application and is not visual-paint time.

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

- App version: 1.3.0 (build 7)
- Packaged source commit: `f380a6454eedfaffb90af1db73b1436dce4d014d`
- 1,223 automated tests passed in 80 suites
- Release packaging contract tests and arm64 production build passed
- Ad-hoc signature, DMG checksum, mounted-app validation, local installation,
  and launch checks passed
- GitHub asset digest and byte-for-byte public redownload passed
- Pane-search performance policy-v3: 267/267 hard gates passed
- DMG SHA-256:
  `3db4c0bd18b7001fe93d83ea92baf7928527d393bc5310e4ba40f7e9d75148e6`

Still pending for release validation: fresh-download Gatekeeper behavior, live
VoiceOver observations, visual-paint latency, and live Google Drive/OneDrive
metadata-only browsing. Direct Google or Microsoft OAuth/API clients are not
included.

## 한국어

Developer Preview 5는 대규모 폴더를 탐색하고 필터링할 때의 반응성과 취소
안전성을 집중적으로 개선했습니다. Preview 4의 듀얼 패널 파일 관리, 한글 초성
Smart Search, Space 키 폴더 미리보기, 압축 진행 상태, 암호 보호 ZIP, 디렉터리
비교, Storage Inspector 및 macOS File Provider 연동은 그대로 제공합니다.

### 더 빨라진 대규모 폴더 탐색

- 디렉터리 항목을 점진적으로 표시하고 제한된 배치로 메타데이터를 보강해 화면에
  보이는 경로의 반복 작업을 줄였습니다.
- 승인된 패널 projection과 동일성 인덱스를 유지해 반복 읽기, 선택 복원, 이름
  변경 라우팅 및 테이블 갱신에서 불필요한 전체 검색을 피합니다.
- AppKit 테이블을 점진적으로 갱신하며 전체 reload가 더 안전한 경우에는 측정된
  fallback을 사용합니다.
- 보존된 10,000개 항목 자동 검증에서 전체 로딩은 약 1.09초에서 중앙값
  0.55초로 줄었습니다. 이는 고정 fixture의 자동 측정이며 모든 디스크나
  클라우드 provider에 대한 보장은 아닙니다.

### 패널 필터와 정렬 개선

- 정확한 active-order snapshot을 재사용하고, 허용되는 ASCII 검색어 확장만
  안전하게 좁혀 한글과 Unicode의 localized matching 정확성을 유지합니다.
- 충분히 큰 숫자 검색에만 제한된 병렬 순회를 사용하며 모든 결과를 기존
  filter-and-sort oracle과 비교합니다.
- 정렬 변경은 승인된 현재 결과 집합을 재사용할 수 있고, token으로 보호되는
  warm-up은 해당 테이블 적용이 끝난 뒤에만 시작합니다.
- 오래된 projection worker는 취소 계측 전에 먼저 취소하며, stale 결과가 새
  결과를 덮어쓸 수 없습니다.

정식 릴리스 benchmark는 48개 독립 시나리오와 1,920개 원시 샘플을 포함합니다.
정책-v3 하드 게이트 267/267개를 모두 통과했습니다. 상대 p95 주의 1건과
stretch 목표 미달 3건은 문서에 그대로 남겼으며, 절대 지연 시간, 정확성, 취소,
worker drain, subset sort 및 RSS 하드 게이트는 모두 통과했습니다. 측정 경계는
실제 테이블 적용 완료까지이며 시각적 paint 시간은 아닙니다.

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

- 앱 버전: 1.3.0 (빌드 7)
- 패키징한 소스 커밋: `f380a6454eedfaffb90af1db73b1436dce4d014d`
- 80개 스위트의 자동 테스트 1,223개 통과
- 릴리스 패키징 계약 테스트와 arm64 프로덕션 빌드 통과
- ad-hoc 서명, DMG 체크섬, 마운트 앱 검사, 로컬 설치 및 실행 검사 통과
- GitHub 자산 digest 및 공개 재다운로드 바이트 비교 통과
- 패널 검색 성능 정책-v3: 하드 게이트 267/267 통과
- DMG SHA-256:
  `3db4c0bd18b7001fe93d83ea92baf7928527d393bc5310e4ba40f7e9d75148e6`

릴리스 검증에서 아직 남은 항목은 새로 다운로드한 파일의 Gatekeeper 동작,
실제 VoiceOver 관찰, 시각적 paint 시간 및 실제 Google Drive/OneDrive의
메타데이터 전용 탐색입니다. Google 또는 Microsoft OAuth/API 직접 클라이언트는
포함하지 않습니다.
