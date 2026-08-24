# 전송 내용 검증

**한국어** · [English](transfer-content-verification.md)

**소스 상태:** 현재 소스 트리에 구현되어 있습니다. 마지막으로 공개한 Developer
Preview 7 DMG에는 이 기능이 **포함되어 있지 않습니다**. 병합 전 빌드 10 앱과 DMG
일회성 후보는 로컬 자동 검증과 패키지 검사를 통과했지만 배포 산출물은 아닙니다.
병합된 소스로 새 후보를 빌드하고 검증한 뒤 공개해야만 배포 기능으로 간주합니다.

## 동작 계약

### 선택 정책과 적용 작업

설정의 **File Operations** 탭에는 **Verify transferred file contents before
publishing** 토글이 있으며 기본값은 꺼짐입니다. 작업을 큐에 넣을 때 설정을
캡처하므로 대기 중 설정을 바꾸더라도 해당 작업과 Retry는 원래 정책을 유지합니다.
사용자가 켤 수 있는 정책은 `.sha256(maxConcurrentPairs: 2)` 하나뿐이며, 한 작업이
동시에 해시하는 파일 쌍은 최대 두 개입니다.

검증은 복사, Duplicate, 다른 볼륨으로 이동, 검토된 한 방향 폴더 동기화의
복사·교체 작업에 적용됩니다. 같은 볼륨의 이동은 바이트 복사가 아니라 기존 항목의
이름 공간 이동입니다. 따라서 해시하지 않고 제한된 **No byte transfer** 결과를
기록합니다.

### 데이터와 트리 범위

Pengrid는 복사 전에 원본을 캡처하고, 동일성에 묶인 비공개 스테이징 디렉터리로
복사하고, 스테이징을 검증하고, 검증 영수증을 다시 확인한 뒤에만 결과를
게시합니다. 디렉터리와 패키지 루트는 재귀적으로 순회하며 상대 구조와 항목 종류가
일치해야 합니다. 일반 파일은 데이터 포크를 SHA-256으로 비교하고, 심볼릭 링크는
대상을 따라가지 않고 링크 payload를 비교합니다.

manifest 예산은 전송 루트 하나당 하위 항목 250,000개, 최대 하위 깊이 256입니다.
검증이 켜진 상태에서 한도를 넘으면 안전하게 실패하며, 검증하지 않은 게시로
대체하지 않습니다.

리소스 포크, 확장 속성, ACL, 소유권, 플래그, 생성일, 하드 링크 관계, sparse
allocation, 압축 생성·해제 결과는 검증 범위에서 제외합니다. UI와 문서는 이러한
메타데이터까지 검증했다고 표현하지 않습니다.

### 진행률, 실패 및 개인정보 보호

백분율은 파일 쌍 양쪽에서 읽기를 마친 논리 바이트를 기준으로 가중합니다. 옆의
파일 개수는 파일 수를 기준으로 하므로 두 지표의 진행 속도가 다를 수 있습니다.
일반 파일이 모두 0바이트인 트리는 파일 개수를 사용해 결정적 진행률이 100%에
도달하도록 합니다.

내용 불일치, 읽기 실패, 원본 또는 스테이징 변경, 지원하지 않는 항목, 범위 초과,
취소가 발생하면 게시하지 않습니다. 원본과 기존 대상은 그대로 유지합니다.
Pengrid 소유임을 다시 확인한 스테이징만 제거합니다. 안전한 정리나 롤백을 증명할
수 없으면 **Recovery Needed**로 전환하고 자동 큐 진행을 멈춰 검토하게 합니다.

작업 센터 기록은 현재 앱 세션 동안 제한된 상태, 검증한 파일 수, 작업 단위 논리
바이트 합계만 보관하고 합계를 사람이 읽을 수 있게 표시합니다. 디스크에는 저장하지
않습니다. 진단 시스템 로그는 같은 원시 집계 값을 `verifiedLogicalBytes`로
기록합니다. 두 경계 모두 파일별 크기·digest, 경로, 상대 트리 목록 및 내부 오류를
포함하지 않습니다. 상태와 VoiceOver 텍스트에는 절대 상위 경로나 해시 대신 정리한
기본 이름과 사람이 읽을 수 있는 합계를 사용하며 원시 숫자는 알리지 않습니다.

File Provider 검증은 작업 중 원본과 스테이징 바이트를 로컬에서 읽을 수 있어야
합니다. 온라인 전용 원본은 macOS 또는 설치된 provider가 다시 materialize할 수
있습니다. Google Drive와 OneDrive를 실제로 확인하기 전에는 provider 동작을
검증했다고 주장하지 않습니다.

영수증 재검증은 파일시스템 게시 호출 전 마지막 await 단계입니다. 마지막 검증과
`rename` 또는 교체 syscall 사이의 짧은 경쟁 구간을 줄이지만 없애지는 못합니다.
UI와 문서에서 이를 원자적 콘텐츠 잠금이라고 표현하지 않습니다.

## Automated evidence

아래 근거는 2026년 8월 24~25일 KST에 커밋
`aeb3ee43070313230466d9b7255dabe8132ed2fe`와 현재 후보 변경분을 기반으로 한 Task 9
작업 트리에서 기록했습니다. 병합 전 후보 근거이며 병합된 후보 커밋, 설치된 앱,
공개 자산 및 릴리스 checksum을 완료했다고 주장하지 않습니다. 로컬 DMG는 일회성
검증 산출물이므로 SHA-256을 의도적으로 기록하지 않습니다.
이 한·영 provenance 문구를 추가하기 전, 검토를 마친 Task 9 스테이징 스냅샷의
diff SHA-256은
`bf94c1874348d6d295cb9767ffc70e4e0644ace03d578b8596c95cd03bb8ca7e`입니다.

| 검사 | 결과 | 근거 |
| --- | --- | --- |
| 전송 안전성 집중 회귀검증 | PASS | 전송 검증, 파일 전송·변경, 폴더 동기화 트랜잭션, 작업 컨트롤러, 클라우드 scoped access 및 Operation Center 필터의 테스트 383개와 스위트 12개를 4.874초에 통과했습니다. |
| 작업 트리 전체 회귀검증 | PASS | `swift test --enable-swift-testing --no-parallel`를 두 번 실행해 매번 테스트 1,931개와 스위트 123개를 통과했으며 각각 86.066초와 85.441초가 걸렸습니다. 독립 리뷰 수정 후에도 같은 테스트 1,931개와 스위트 123개를 93.051초에 다시 통과했습니다. 이 작업 트리 실행들에는 마운트한 APFS 테스트 루트를 제공하지 않아 opt-in 테스트 5개를 skipped로 기록했습니다. |
| 작업 트리 arm64 Release 빌드 | PASS | 두 전체 회귀검증 사이에 `swift build -c release --arch arm64`가 성공했습니다. 병합 전 작업 트리 컴파일 근거이며 이후 병합 커밋으로 만들 DMG 근거가 아닙니다. |
| 기본 비활성 통합 스위트 | PASS | `PENGRID_TRANSFER_APFS_ROOT`가 없으면 `TransferVerificationAPFSTests` 5개를 skipped로 기록합니다. |
| 빌드·패키지 계약 | PASS | 빌드 10 기대값을 통과했습니다. 실행형 probe로 두 스크립트가 `DEVELOPER_DIR` 미설정 시 첫 Swift 호출에 설치된 전체 Xcode 경로를 전달하고 사용자가 지정한 값은 보존함을 확인했습니다. `xcode-select`가 Command Line Tools를 가리켜도 릴리스 테스트 단계에서 Swift Testing 지원이 사라지지 않습니다. 전체 unsigned 패키지 명령도 내부 테스트 1,931개와 스위트 123개를 86.978초에 통과한 뒤 앱과 DMG를 빌드했습니다. |
| 안전한 셸 하네스 계약 | PASS | `/bin/bash script/tests/verify_transfer_content_contract_tests.sh`가 성공, Swift 실패 정리, 잘못된 plist·장치·이미지·마운트, mount point·정리 루트·무작위 attach 캡처 치환, 부분 연결, attach 실행 직전 취소, detach 대상 검증, 실제로 막힌 attach·Swift 자식 신호 처리, detach 정리 중 반복 신호 및 TERM을 무시하는 하위 프로세스를 다루는 20개 테스트를 통과했습니다. |
| APFS 파일시스템 통합 스위트 | PASS | `/bin/bash script/verify_transfer_content.sh`가 비공개 APFS sparse 이미지를 만들고 마운트한 뒤 0.048초에 테스트 5개와 스위트 1개를 통과했습니다. 정리 후 연결된 이미지와 하네스 임시 루트가 남지 않았습니다. 실제 마운트한 APFS 파일시스템 테스트이며 물리 매체 검증을 뜻하지 않습니다. |
| 일회성 unsigned 앱과 DMG | PASS | 로컬 후보는 버전 1.3.0(빌드 10), 식별자 `com.minho.BloomFileManager`, arm64 전용입니다. 예상한 ad-hoc 서명으로 strict deep 코드 서명 검증을 통과했습니다. 아이콘과 제3자 고지문은 원본 자산과 바이트 단위로 같고, `hdiutil verify`를 통과했으며 읽기 전용으로 마운트한 DMG의 앱 트리가 패키징 앱과 같습니다. Developer ID가 없는 후보를 Gatekeeper가 예상대로 거부했습니다. 로컬 checksum을 공개 checksum으로 사용하지 않습니다. |
| 중첩 트리 복사 | PASS | 중첩된 일반 파일 두 개를 게시 전에 검증했습니다. |
| 다른 볼륨으로 이동 | PASS | 결정적 검증 게이트에서 원본이 남아 있었고 검증된 게시가 끝난 뒤에만 제거했습니다. |
| 심볼릭 링크 루트 | PASS | 대상을 따라가지 않고 링크 payload를 복사하고 비교했습니다. |
| 검증 중 취소 | PASS | 원본을 보존하고 대상 게시를 막고 소유한 스테이징을 제거했습니다. |
| 영수증 변조 | PASS | 영수증 재검증 전 스테이징을 제자리에서 바꾸자 원본과 기존 대상을 보존하고 소유한 스테이징만 제거했습니다. |

하네스는 `mktemp -d`, `hdiutil attach -plist`, 보조 검증용 허용 목록
`/dev/disk[0-9]+(s[0-9]+)*`, 정확한 canonical 이미지 경로, 임시 루트의 엄격한
하위 mount point, 마운트 파일시스템 동일성 검사 및 멱등 정리 trap을 사용합니다.
attach plist는 무작위 이름의 파일을 truncate하지 않는 비공개 파일 디스크립터로
연 뒤 inode를 검사하고 즉시 unlink하여 캡처하고, 그 내용을 셸 메모리로 읽습니다.
`hdiutil info -plist` 출력은 바로 셸 메모리에 둡니다. 어느 흐름도 예측 가능한 plist
경로를 사용하지 않습니다. 테스트 실행 전과 detach 전에 이미지, mount point,
파일시스템 및 장치 동일성을 다시 검사하며 재사용될 수 있는 장치 이름 대신 검증한
비공개 mount point로 detach합니다. detach 후에는 동일성이 일치한 임시 루트를 작업
디렉터리로 연 뒤 파일시스템 경계를 넘지 않고 `.` 아래만 삭제합니다. 삭제 대상으로
`/`, 홈 디렉터리 또는 작업 공간 루트를 사용하지 않습니다. attach와 Swift는
관리되는 프로세스 그룹에서 실행합니다. INT 또는 TERM을 받으면 활성 그룹에 TERM을
전달하고, 그룹 리더를 회수한 뒤 제한된 시간 동안 TERM, 필요한 경우 KILL로 남은
하위 프로세스를 정리합니다. attach 실행 직전에 받은 신호는 attach를 시도했다고
표시하지 않습니다. 그룹이 남아 있으면 파일시스템 정리를 시작하지 않고 안전하게
실패합니다. EXIT 정리가 시작된 뒤의 INT와 TERM은 무시하므로 detach 또는 동일성
기반 삭제를 중간에 끊지 못합니다.

## Static-source evidence

| 불변 조건 | 소스 근거 |
| --- | --- |
| 안전한 기본값과 정책 캡처 | `TransferVerificationPreference`는 기본 꺼짐이며 `FileOperationController`는 큐 작업과 Retry에 불변 정책 하나를 캡처합니다. |
| 파일 쌍 상한 | 사용자 활성 정책은 정확히 `.sha256(maxConcurrentPairs: 2)`이며 내부 작업자도 1~2개로 제한합니다. |
| 게시 전 순서 | `FileOperationService`와 `FolderSynchronizationTransactionService`는 비공개 스테이징을 검증하고 영수증을 다시 확인한 뒤 게시합니다. |
| 재귀 no-follow 범위 | `TransferVerificationManifest`는 descriptor 기반 순회, 일반 파일 reader, `readlinkat`을 사용하며 심볼릭 링크를 따라가지 않습니다. |
| manifest 한도 | 운영 한도는 하위 항목 250,000개와 깊이 256입니다. |
| 제한된 진행률과 기록 | 바이트 가중 백분율, 파일 가중 개수, 집계된 제한 정보만 표시합니다. |
| 개인정보 보호 | typed logging에는 작업 단위 원시 논리 바이트 합계와 제한된 개수가 있지만 파일별 크기·digest, 원시 트리, 절대 경로 및 내부 오류는 없습니다. 접근성 표현은 집계 값을 변환해 표시하고 원시 숫자를 알리지 않습니다. |
| 복구 | 동일성을 확인한 정리에 실패하면 불확실한 항목을 지우지 않고 Recovery Needed를 전달합니다. |

## Physical manual evidence

| 시나리오 | 상태 | 확인할 내용 |
| --- | --- | --- |
| 로컬 바이트가 있는 Google Drive File Provider | **MANUAL NOT RUN** | 검증을 켠 복사와 다른 볼륨 이동의 성공, 진행률, 반복 materialization 프롬프트 부재를 확인합니다. |
| 온라인 전용 또는 evicted Google Drive 바이트 | **MANUAL NOT RUN** | provider materialization 또는 제한된 실패가 검증하지 않은 게시 없이 동작하는지 기록합니다. |
| 로컬 바이트가 있는 OneDrive File Provider | **MANUAL NOT RUN** | 검증을 켠 복사와 다른 볼륨 이동에서 원본과 대상 동작을 확인합니다. |
| 온라인 전용 또는 evicted OneDrive 바이트 | **MANUAL NOT RUN** | materialization 또는 제한된 실패와 정리 동작을 기록합니다. |
| VoiceOver 설정과 진행률 | **MANUAL NOT RUN** | 토글 값, 단계 알림, 증가하는 10% bucket, 파일 개수, 별도로 탐색 가능한 Cancel 버튼을 확인합니다. |
| VoiceOver 완료 기록 | **MANUAL NOT RUN** | 검증 성공·바이트 없음·혼합 실패 문구에 절대 경로, digest, 원시 바이트 합계가 없는지 확인합니다. |

## Release gate

- **PASS:** 현재 소스 구현, 셸 계약, APFS 파일시스템 통합 스위트.
- **PASS:** 집중·전체 회귀검증, arm64 Release 빌드, 일회성 빌드 10 앱·DMG 검사 및
  로컬 후보와 공개 Developer Preview 7 DMG를 구분한 문서.
- **NOT RUN:** 정확한 병합 커밋 패키징, 공개 CI, 설치, GitHub 릴리스 공개,
  공개 자산 재다운로드 및 공개 자산 checksum. 병합 후 릴리스 절차에서 수행하며
  일회성 병합 전 checksum으로 대신하지 않습니다.
- **MANUAL NOT RUN:** Google Drive, OneDrive, 실제 VoiceOver 관찰. 실제로
  수행할 때까지 이 상태를 유지하며 자동 APFS 결과로 대신하지 않습니다.
