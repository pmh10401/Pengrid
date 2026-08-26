import Foundation

enum HelpCatalog {
    static func topics(for language: HelpLanguage) -> [HelpTopic] {
        switch language {
        case .korean:
            koreanTopics
        case .english:
            englishTopics
        }
    }

    static func topic(id: HelpTopicID, language: HelpLanguage) -> HelpTopic? {
        topics(for: language).first { $0.id == id }
    }

    private static let koreanTopics: [HelpTopic] = [
        HelpTopic(
            id: .gettingStarted,
            title: "시작하기",
            summary: "Pengrid를 안전하게 설치하고 듀얼 패널과 미리보기로 첫 작업을 시작합니다.",
            sections: [
                HelpSection(
                    heading: "설치와 첫 실행",
                    paragraphs: [
                        "Pengrid는 macOS 15 이상을 실행하는 Apple Silicon Mac을 지원합니다. DMG를 열고 Pengrid.app을 Applications 폴더로 복사하세요.",
                        "Developer Preview DMG는 ad-hoc 서명만 되어 있고 Developer ID 서명이나 공증을 받지 않았습니다. Gatekeeper가 실행을 막을 수 있으며, Pengrid는 macOS 보안 기능을 끄라고 안내하지 않습니다."
                    ],
                    bulletItems: [
                        "경고가 나타나면 다운로드한 릴리스 출처와 파일을 확인한 뒤 사용 여부를 직접 결정하세요."
                    ]
                ),
                HelpSection(
                    heading: "듀얼 패널과 미리보기",
                    paragraphs: [
                        "두 패널을 동시에 탐색합니다. 패널을 클릭하거나 탐색하면 활성 패널이 바뀌고, 명령은 별도로 지정되지 않는 한 활성 패널의 선택을 사용합니다.",
                        "Space는 일반 폴더 하나의 읽기 전용 내용 미리보기를 열고, 파일·패키지·심볼릭 링크 또는 여러 항목은 macOS Quick Look으로 엽니다."
                    ],
                    bulletItems: [
                        "폴더 내용 미리보기는 항목을 변경하지 않으며 클라우드 자식 항목의 바이트를 의도적으로 내려받지 않습니다. 파일 Quick Look은 provider에 materialization을 요청할 수 있습니다."
                    ]
                )
            ],
            shortcuts: [
                HelpShortcut(keys: "Space", action: "폴더 미리보기 또는 시스템 Quick Look")
            ],
            externalDestination: .userGuide
        ),
        HelpTopic(
            id: .dualPaneNavigation,
            title: "듀얼 패널 탐색",
            summary: "패널별 기록과 필터를 유지하면서 탭, 프로필, 비교 및 검토 우선 동기화를 사용합니다.",
            sections: [
                HelpSection(
                    heading: "활성 패널과 탐색 기록",
                    paragraphs: [
                        "각 패널은 현재 폴더, 뒤로·앞으로 기록, 정렬, 선택, 세션 중 다시 방문한 폴더의 선택·스크롤 위치, 파일명 필터를 독립적으로 유지합니다.",
                        "복사·이동·다른 패널에서 열기 명령은 실행할 때 캡처한 원본과 대상 패널을 사용하므로 나중에 탐색하거나 선택을 바꿔도 대상이 바뀌지 않습니다."
                    ],
                    bulletItems: [
                        "Command-[와 Command-]는 뒤로·앞으로, Command-Up Arrow는 상위 폴더, Command-L은 위치 편집입니다."
                    ]
                ),
                HelpSection(
                    heading: "탭과 작업 공간 프로필",
                    paragraphs: [
                        "Command-T는 현재 탭의 폴더 쌍, 정렬, 분할 위치와 활성 패널을 복제한 새 작업 공간 탭을 엽니다. Command-W는 마지막 탭이 아니고 연결된 파일 작업이 없을 때만 탭을 닫습니다.",
                        "Control-Tab과 Control-Shift-Tab으로 탭을 이동합니다. 프로필은 이름 있는 재사용 배치이며, 프로필을 열면 기존 탭을 바꾸지 않고 새 탭을 만듭니다."
                    ],
                    bulletItems: [
                        "재시작 후 작업 공간 배치는 복원되지만 선택, 필터, 기록, 미리보기, 검색과 파일 작업 상태는 복원하지 않습니다."
                    ]
                ),
                HelpSection(
                    heading: "비교와 검토 우선 동기화",
                    paragraphs: [
                        "Compare는 두 패널 루트를 상대 경로로 비교하고 한쪽에만 있는 항목, 메타데이터 차이, 이름 충돌과 내용 검증 대상을 보여 줍니다.",
                        "현재 비교 결과에서만 Sync Left to Right 또는 Sync Right to Left를 검토하고 확인할 수 있습니다. 한 방향 작업은 복사·교체와 대상 항목의 휴지통 이동을 단계적으로 수행하며, 양방향 병합이나 완료 후 Undo는 제공하지 않습니다."
                    ],
                    bulletItems: [
                        "검토가 오래되어 현재 비교가 아니거나 충돌·오류가 있으면 안전하지 않은 동기화가 비활성화됩니다."
                    ]
                )
            ],
            shortcuts: [
                HelpShortcut(keys: "Command-T", action: "새 작업 공간 탭"),
                HelpShortcut(keys: "Command-W", action: "안전할 때 활성 작업 공간 탭 닫기"),
                HelpShortcut(keys: "Control-Tab", action: "다음 작업 공간 탭"),
                HelpShortcut(keys: "Control-Shift-Tab", action: "이전 작업 공간 탭"),
                HelpShortcut(keys: "Command-[ / Command-]", action: "뒤로 / 앞으로"),
                HelpShortcut(keys: "Command-Up Arrow", action: "상위 폴더"),
                HelpShortcut(keys: "Command-L", action: "위치 편집")
            ],
            externalDestination: nil
        ),
        HelpTopic(
            id: .search,
            title: "검색과 초성",
            summary: "패널 필터, 재귀 Smart Search, 선택적 Spotlight 내용 검색과 한글 초성 검색을 구분합니다.",
            sections: [
                HelpSection(
                    heading: "패널 필터",
                    paragraphs: [
                        "Command-F는 활성 패널의 현재 폴더에서 이미 불러온 파일명만 즉시 필터링합니다. 재귀적으로 검색하거나 파일 내용을 읽거나 온라인 전용 파일을 내려받지 않습니다."
                    ],
                    bulletItems: [
                        "패널마다 독립된 필터와 결과 개수가 있습니다."
                    ]
                ),
                HelpSection(
                    heading: "Smart Search",
                    paragraphs: [
                        "Command-Shift-F는 활성 폴더를 시작점으로 파일명과 상대 경로를 재귀 검색합니다. 파일·폴더 유형, 확장자, 크기, 수정 날짜 필터를 조합하고 검색을 저장하거나 다시 열 수 있습니다.",
                        "일반 문자열은 대소문자와 악센트를 구분하지 않습니다. 혼합 검색은 모든 절이 일치해야 하며, 잘못된 필터 조합으로 무제한 변경 작업을 시작하지 않습니다."
                    ],
                    bulletItems: [
                        "검색 결과에서 Quick Look, 다른 패널에서 열기, 복사·이동과 휴지통 이동을 실행할 수 있으며 실행 직전에 항목 동일성을 다시 확인합니다."
                    ]
                ),
                HelpSection(
                    heading: "선택적 Spotlight 내용 검색과 한글 초성",
                    paragraphs: [
                        "Search indexed file contents는 기본적으로 꺼져 있는 선택 기능입니다. 이미 Spotlight가 색인한 내용만 일반 이름·경로 결과에 합치며 파일 바이트를 직접 읽거나 File Provider 다운로드를 강제하지 않습니다.",
                        "provider 위치나 아직 색인되지 않은 위치의 내용 범위는 불완전할 수 있습니다. 한글 초성 또는 초성이 섞인 검색어에서는 내용 검색을 건너뛸 수 있다고 표시합니다.",
                        "예를 들어 ㅍㄱ는 파일관리와 일치할 수 있고, ㅍㄱ report는 초성 조건과 report 조건을 모두 요구합니다."
                    ],
                    bulletItems: [
                        "Spotlight 오류나 시간 초과가 발생해도 이름·경로 검색 결과는 유지됩니다."
                    ]
                )
            ],
            shortcuts: [
                HelpShortcut(keys: "Command-F", action: "활성 패널 필터"),
                HelpShortcut(keys: "Command-Shift-F", action: "활성 패널에서 Smart Search 시작")
            ],
            externalDestination: nil
        ),
        HelpTopic(
            id: .fileOperations,
            title: "파일 작업과 작업 센터",
            summary: "작업 센터의 순서·진행·충돌·취소와 전송 검증, 보수적인 Undo를 이해합니다.",
            sections: [
                HelpSection(
                    heading: "작업 센터와 충돌",
                    paragraphs: [
                        "복사, Duplicate, 이동, 이름 변경, 폴더 만들기, 휴지통, 압축·해제와 Undo는 하나의 단일 작업자 큐에서 순서대로 실행됩니다. 제출할 때 원본과 대상 동일성을 캡처하고, 대기 중 교체된 항목은 실패 처리합니다.",
                        "기존 항목을 덮어쓰지 않는 작업은 Keep Both 방식으로 사용 가능한 이름을 선택합니다. 권한 거부는 한 번 보고하고 반복 프롬프트를 만들지 않습니다."
                    ],
                    bulletItems: [
                        "휴지통은 확인 후 이동과 즉시 이동을 제공하며 영구 삭제는 제공하지 않습니다."
                    ]
                ),
                HelpSection(
                    heading: "진행, 취소와 복구",
                    paragraphs: [
                        "대기 중인 작업을 취소하면 변경 전에 큐에서 제거됩니다. 실행 중인 취소는 안전한 지점에서 중단하고 소유한 임시 항목을 정리합니다.",
                        "정리할 항목의 소유권을 증명할 수 없으면 Pengrid는 불확실한 데이터를 지우지 않고 Recovery Needed로 남깁니다. 사용자가 Continue Queue를 선택하기 전에는 뒤의 대기 작업을 재개하지 않습니다."
                    ],
                    bulletItems: [
                        "Retry는 이미 성공한 항목을 다시 실행하지 않도록 전체 의도를 재생할 수 있을 때만 제공됩니다."
                    ]
                ),
                HelpSection(
                    heading: "전송 내용 검증",
                    paragraphs: [
                        "Settings > File Operations에서 Verify transferred file contents before publishing을 켤 수 있으며 기본값은 꺼짐입니다. 복사, Duplicate, 볼륨 간 이동과 검토된 한 방향 동기화의 복사·교체를 private staging에서 SHA-256으로 확인합니다.",
                        "디렉터리 구조와 심볼릭 링크 페이로드도 확인하고, 파일 진행률은 바이트 가중치와 파일 개수를 함께 보여 줍니다. 최대 두 파일 쌍을 동시에 해시하며 검증 불일치·읽기 오류·취소는 게시를 막습니다."
                    ],
                    bulletItems: [
                        "리소스 포크, 확장 속성, ACL, 소유권, 플래그, 생성일, 하드 링크 관계와 sparse allocation은 검증 범위가 아닙니다."
                    ]
                ),
                HelpSection(
                    heading: "보수적인 Undo",
                    paragraphs: [
                        "Undo는 Pengrid가 만든 변경의 정확한 동일성과 no-follow 지문이 그대로이고 원래 경로가 비어 있을 때만 활성화됩니다. 외부 교체, 내용 변경, 누락 또는 소유권 불확실성이 있으면 새 항목을 덮어쓰거나 수정된 출력을 삭제하지 않습니다.",
                        "완료된 폴더 동기화는 non-retryable이며 Undo 대상이 아닙니다."
                    ],
                    bulletItems: []
                )
            ],
            shortcuts: [
                HelpShortcut(keys: "Command-D", action: "캡처한 선택 항목 Duplicate"),
                HelpShortcut(keys: "Delete / Command-Delete", action: "확인 후 / 즉시 휴지통으로 이동")
            ],
            externalDestination: nil
        ),
        HelpTopic(
            id: .archives,
            title: "압축 파일",
            summary: "지원되는 ZIP·TAR 계열 형식, 제한된 병렬 준비, 진행 단계와 암호 ZIP 경계를 설명합니다.",
            sections: [
                HelpSection(
                    heading: "지원 형식",
                    paragraphs: [
                        "Pengrid는 ZIP, TAR, TAR.GZ/TGZ, TAR.BZ2/TBZ/TBZ2, TAR.XZ/TXZ를 만들고 해제합니다. 선택한 항목과 대상은 실행 전에 확인되며 압축 파일과 해제 대상은 기존 항목을 덮어쓰지 않습니다."
                    ],
                    bulletItems: [
                        "7z, RAR와 암호 보호 TAR는 지원하지 않습니다."
                    ]
                ),
                HelpSection(
                    heading: "진행과 취소",
                    paragraphs: [
                        "여러 원본을 선택하면 일반 형식의 private aggregate staging 준비 단계만 최대 네 작업으로 제한된 병렬 처리를 사용합니다. 일반 형식의 실제 압축·해제는 하나의 macOS ditto 또는 tar 프로세스로 실행됩니다.",
                        "진행은 파일 준비, 인코딩·해제, 게시 단계로 나뉘며 native 도구가 안정적인 바이트 총량을 제공하지 않는 단계는 indeterminate일 수 있습니다. 취소는 전 과정에서 가능하고, 임시 출력 정리를 증명할 수 없으면 Recovery Needed 검토를 요구합니다."
                    ],
                    bulletItems: [
                        "진행률과 항목 수는 작업 센터에서 확인할 수 있습니다."
                    ]
                ),
                HelpSection(
                    heading: "암호 보호 ZIP",
                    paragraphs: [
                        "소스 빌드는 AES-256 암호 보호 ZIP을 만들 수 있습니다. 읽기는 안전 정책과 Store 또는 Deflate 조건을 통과한 AES-128·AES-192·AES-256 및 ZipCrypto 항목을 지원합니다.",
                        "파일명·크기·시각 같은 ZIP 중앙 디렉터리 메타데이터는 암호화해 숨기지 않습니다. 암호는 현재 요청에만 보관하고 저장·복구·노출하지 않습니다."
                    ],
                    bulletItems: [
                        "잘못된 암호, 손상 데이터, 안전하지 않은 경로와 제한 초과는 실패로 처리합니다."
                    ]
                )
            ],
            shortcuts: [],
            externalDestination: nil
        ),
        HelpTopic(
            id: .cloudLocations,
            title: "클라우드 위치",
            summary: "macOS File Provider를 통해 Google Drive와 OneDrive를 사용하고 수동 위치의 가용성을 확인합니다.",
            sections: [
                HelpSection(
                    heading: "File Provider 위치",
                    paragraphs: [
                        "Google Drive와 OneDrive는 macOS에 등록된 File Provider 루트로 발견되어 표시됩니다. Pengrid에는 Google 또는 Microsoft 계정에 직접 연결하는 OAuth/API 클라이언트가 없으며 자격 증명을 묻지 않습니다.",
                        "Cloud Locations 설정에서 선택한 폴더는 security-scoped bookmark를 사용하는 수동 위치로 추가할 수 있습니다. 수동 위치를 잊어도 파일과 폴더를 삭제하지 않습니다."
                    ],
                    bulletItems: [
                        "Cloud Locations 설정에서 다시 검색, 숨기기·표시, 수동 위치 제거를 관리할 수 있습니다."
                    ]
                ),
                HelpSection(
                    heading: "로컬 가용성과 다운로드",
                    paragraphs: [
                        "파일명·경로 메타데이터 검색과 폴더 미리보기는 로컬에 노출된 정보만 사용하고 온라인 전용 자식 항목을 의도적으로 materialize하지 않습니다.",
                        "열기, Quick Look, 복사·이동, 비교 내용 확인, 압축·해제와 전송 검증처럼 바이트가 필요한 작업은 macOS 또는 설치된 provider에 온라인 전용 항목을 materialize하도록 요청할 수 있습니다. 로컬 바이트나 쓰기 capability를 제공하지 않는 위치는 읽기 전용·알 수 없음으로 표시하고 변경 작업을 비활성화합니다."
                    ],
                    bulletItems: [
                        "provider가 메타데이터를 충분히 제공하지 않으면 결과를 추측하지 않고 unavailable 또는 실패로 보고합니다."
                    ]
                ),
                HelpSection(
                    heading: "접근 범위",
                    paragraphs: [
                        "필요한 작업 동안에만 scoped access를 유지하고, 로컬 파일과 같은 identity 검사를 적용합니다. 온라인 전용 파일의 바이트가 필요하면 macOS 접근 프롬프트나 provider 상태에 따라 작업이 대기하거나 실패할 수 있습니다."
                    ],
                    bulletItems: [
                        "Pengrid는 File Provider 계정 화면이나 직접 OAuth 흐름을 대신하지 않습니다."
                    ]
                )
            ],
            shortcuts: [
                HelpShortcut(keys: "Command-R", action: "Cloud Locations 다시 검색")
            ],
            externalDestination: nil
        ),
        HelpTopic(
            id: .shortcuts,
            title: "키보드 단축키",
            summary: "현재 소스와 사용자 안내서에 정의된 주요 탐색·검색·파일 작업 단축키입니다.",
            sections: [
                HelpSection(
                    heading: "탐색과 보기",
                    paragraphs: [],
                    bulletItems: [
                        "Command-O — 선택 항목 열기",
                        "Space — 폴더 미리보기 또는 Quick Look",
                        "Command-I — 캡처한 선택 항목 Get Info",
                        "Command-T / Command-W — 새 탭 / 안전할 때 탭 닫기",
                        "Control-Tab / Control-Shift-Tab — 다음 / 이전 탭",
                        "Command-[ / Command-] — 뒤로 / 앞으로",
                        "Command-Up Arrow — 상위 폴더",
                        "Command-L — 위치 편집"
                    ]
                ),
                HelpSection(
                    heading: "검색과 선택",
                    paragraphs: [],
                    bulletItems: [
                        "Command-F — 활성 패널 필터",
                        "Command-Shift-F — Smart Search",
                        "Command-P — Quick Go… 팔레트",
                        "Option-Command-A — 표시 행 모두 선택",
                        "Option-Command-I — 표시 선택 반전",
                        "Option-Command-E — 같은 확장자의 표시 행 선택"
                    ]
                ),
                HelpSection(
                    heading: "파일 작업",
                    paragraphs: [],
                    bulletItems: [
                        "Command-C / Command-V — 복사 / 붙여넣기",
                        "Command-D — Duplicate",
                        "Option-Command-N — 새 빈 파일 만들기",
                        "Option-Command-C — 화면 순서대로 전체 경로 복사",
                        "Command-Shift-N — 새 폴더",
                        "Command-Control-R — 일괄 이름 변경",
                        "Delete / Command-Delete — 확인 후 / 즉시 휴지통으로 이동"
                    ]
                )
            ],
            shortcuts: [],
            externalDestination: nil
        ),
        HelpTopic(
            id: .troubleshooting,
            title: "문제 해결과 개인정보",
            summary: "Gatekeeper, 권한·provider 가용성, 복구 검토와 개인정보를 확인하고 재현 가능한 문제를 보고합니다.",
            sections: [
                HelpSection(
                    heading: "실행·접근 문제",
                    paragraphs: [
                        "Gatekeeper가 ad-hoc 서명 앱의 실행을 차단할 수 있습니다. Pengrid는 보안 기능을 비활성화하라고 하지 않습니다. 릴리스 페이지의 파일과 서명 안내를 확인하세요.",
                        "파일 또는 폴더 접근이 필요할 때 macOS 권한·접근 프롬프트가 표시될 수 있습니다. 취소하거나 권한이 거부되면 Pengrid는 안전하게 작업을 중단하고 다시 허가를 반복 요청하지 않습니다."
                    ],
                    bulletItems: [
                        "수동 위치 bookmark가 오래되었거나 provider가 오프라인이면 Cloud Locations에서 다시 검색하고 위치 가용성을 확인하세요."
                    ]
                ),
                HelpSection(
                    heading: "복구와 provider 가용성",
                    paragraphs: [
                        "작업 센터에 Recovery Needed가 나타나면 확인되지 않은 임시 항목을 직접 삭제하지 말고 내용을 검토한 뒤 Continue Queue를 선택하세요. 충돌·동일성 변경·쓰기 불가 위치는 작업을 실패시킬 수 있습니다.",
                        "File Provider의 online-only 항목은 바이트가 필요한 순간에만 materialize될 수 있습니다. 충분한 로컬 바이트나 쓰기 capability가 없으면 다시 시도해도 성공하지 않을 수 있습니다."
                    ],
                    bulletItems: [
                        "완료된 검토 우선 폴더 동기화는 Retry나 Undo로 재실행하지 않습니다."
                    ]
                ),
                HelpSection(
                    heading: "개인정보와 온라인 링크",
                    paragraphs: [
                        "작업 센터·VoiceOver 상태에는 안전한 항목 이름과 요약만 표시하고 절대 부모 경로, 검색어, 파일 내용이나 암호를 저장·발표하지 않습니다. 도움말 본문은 오프라인으로 제공되며 파일 시스템, File Provider 상태를 읽거나 네트워크 요청을 하지 않습니다.",
                        "사용자 안내서와 릴리스 페이지 링크를 열 때 인터넷 연결이 필요합니다. macOS가 브라우저 열기를 거부하면 Pengrid는 제한된 오류를 표시하고 자동 재시도하지 않습니다. 재현 가능한 문제는 릴리스 페이지의 안내에 따라 보고하세요."
                    ],
                    bulletItems: [
                        "온라인 페이지가 열리지 않아도 오프라인 도움말의 여덟 항목은 계속 사용할 수 있습니다."
                    ]
                )
            ],
            shortcuts: [],
            externalDestination: .releases
        )
    ]

    private static let englishTopics: [HelpTopic] = [
        HelpTopic(
            id: .gettingStarted,
            title: "Getting Started",
            summary: "Install Pengrid safely, then begin with its dual panes and read-only previews.",
            sections: [
                HelpSection(
                    heading: "Install and launch",
                    paragraphs: [
                        "Pengrid supports Apple Silicon Macs running macOS 15 or later. Open the DMG and copy Pengrid.app to Applications.",
                        "The Developer Preview DMG is ad-hoc signed, not Developer ID signed, and not notarized. Gatekeeper may block it; Pengrid does not ask you to disable macOS security controls."
                    ],
                    bulletItems: [
                        "If macOS shows a warning, verify the release source and artifact before deciding whether to continue."
                    ]
                ),
                HelpSection(
                    heading: "Dual panes and preview",
                    paragraphs: [
                        "Browse two panes at once. Clicking or navigating makes a pane active, and commands use that pane's selection unless their name says otherwise.",
                        "Space opens a read-only Pengrid preview for one ordinary folder; files, packages, symbolic links, and multiple selections use system Quick Look."
                    ],
                    bulletItems: [
                        "Folder-contents preview does not mutate entries or intentionally download cloud children; system Quick Look may ask the provider to materialize a file."
                    ]
                )
            ],
            shortcuts: [
                HelpShortcut(keys: "Space", action: "Folder preview or system Quick Look")
            ],
            externalDestination: .userGuide
        ),
        HelpTopic(
            id: .dualPaneNavigation,
            title: "Dual-Pane Navigation",
            summary: "Keep pane-local history and filters while using tabs, profiles, comparison, and reviewed synchronization.",
            sections: [
                HelpSection(
                    heading: "Active pane and history",
                    paragraphs: [
                        "Each pane keeps its current folder, Back/Forward history, sort order, selection, session-local remembered selection and scroll position, and filename filter.",
                        "Copy, move, and Open in Other Pane capture their source and destination pane when invoked, so later navigation or selection changes cannot redirect the operation."
                    ],
                    bulletItems: [
                        "Command-[ and Command-] go Back and Forward; Command-Up Arrow goes to the parent folder; Command-L edits the location."
                    ]
                ),
                HelpSection(
                    heading: "Tabs and workspace profiles",
                    paragraphs: [
                        "Command-T opens a new workspace tab with the active tab's folder pair, sort order, split position, and active pane. Command-W closes a tab only when it is not the last and has no bound file work.",
                        "Control-Tab and Control-Shift-Tab move between tabs. A profile is a named reusable layout; opening one creates a new tab without changing the existing tab."
                    ],
                    bulletItems: [
                        "On restart, layout state is restored, but selection, filters, history, previews, searches, and file-operation state are not."
                    ]
                ),
                HelpSection(
                    heading: "Comparison and reviewed synchronization",
                    paragraphs: [
                        "Compare aligns the two pane roots by relative path and shows one-sided items, metadata differences, name conflicts, and content-verification candidates.",
                        "When the comparison is current, review and confirm Sync Left to Right or Sync Right to Left. The one-way transaction stages copies and replacements and moves destination-only items to Trash; it has no bidirectional merge and is not Undoable after completion."
                    ],
                    bulletItems: [
                        "Stale comparison data, conflicts, or errors disable unsafe synchronization."
                    ]
                )
            ],
            shortcuts: [
                HelpShortcut(keys: "Command-T", action: "New workspace tab"),
                HelpShortcut(keys: "Command-W", action: "Close the active workspace tab when safe"),
                HelpShortcut(keys: "Control-Tab", action: "Next workspace tab"),
                HelpShortcut(keys: "Control-Shift-Tab", action: "Previous workspace tab"),
                HelpShortcut(keys: "Command-[ / Command-]", action: "Back / Forward"),
                HelpShortcut(keys: "Command-Up Arrow", action: "Parent folder"),
                HelpShortcut(keys: "Command-L", action: "Edit location")
            ],
            externalDestination: nil
        ),
        HelpTopic(
            id: .search,
            title: "Search and Korean Initials",
            summary: "Use pane filtering, recursive Smart Search, optional Spotlight content search, and Hangul-initial matching for the right scope.",
            sections: [
                HelpSection(
                    heading: "Pane filter",
                    paragraphs: [
                        "Command-F immediately filters filenames already loaded in the active pane's current folder. It is not recursive, does not read content, and does not download online-only files."
                    ],
                    bulletItems: [
                        "Each pane has its own filter and result count."
                    ]
                ),
                HelpSection(
                    heading: "Smart Search",
                    paragraphs: [
                        "Command-Shift-F recursively searches filenames and relative paths from the active folder. Combine file/folder type, extension, size, and modified-date filters, and save or reopen a query.",
                        "Ordinary text is case- and diacritic-insensitive. Mixed queries require every clause to match, and invalid filter combinations do not start an unrestricted mutation."
                    ],
                    bulletItems: [
                        "Results can launch Quick Look, Open in Other Pane, copy or move, and Move to Trash; each action revalidates the captured item identity."
                    ]
                ),
                HelpSection(
                    heading: "Optional Spotlight content and initials",
                    paragraphs: [
                        "Search indexed file contents is an opt-in feature and is off by default. It merges only content already indexed by Spotlight with name/path results; it never reads file bytes or forces File Provider materialization.",
                        "Provider-backed or not-yet-indexed locations can have incomplete coverage. Korean-initial or mixed-initial queries visibly skip indexed content.",
                        "For example, ㅍㄱ can match 파일관리, and ㅍㄱ report requires both the Hangul-initial and report clauses."
                    ],
                    bulletItems: [
                        "Spotlight errors or timeouts preserve local name/path results and report that indexed content was unavailable."
                    ]
                )
            ],
            shortcuts: [
                HelpShortcut(keys: "Command-F", action: "Filter the active pane"),
                HelpShortcut(keys: "Command-Shift-F", action: "Open Smart Search from the active pane")
            ],
            externalDestination: nil
        ),
        HelpTopic(
            id: .fileOperations,
            title: "File Operations and Operation Center",
            summary: "Understand queue order, progress, conflicts, cancellation, transfer verification, and conservative Undo.",
            sections: [
                HelpSection(
                    heading: "Operation Center and conflicts",
                    paragraphs: [
                        "Copy, Duplicate, move, rename, folder creation, Trash, archive work, and Undo share one single-worker queue. Source and destination identities are captured at submission; a replacement while queued fails closed.",
                        "Operations that do not overwrite existing entries use Keep Both naming to choose an available destination. A permission denial is reported once rather than causing a prompt loop."
                    ],
                    bulletItems: [
                        "Move to Trash supports confirmation and immediate commands; Pengrid does not permanently delete user files."
                    ]
                ),
                HelpSection(
                    heading: "Progress, cancellation, and recovery",
                    paragraphs: [
                        "Cancelling queued work removes it before mutation. Cancelling active work stops at a safe point, rolls back owned changes, and cleans up owned temporary files.",
                        "If ownership cannot be proven, Pengrid preserves the uncertain item and reports Recovery Needed. Waiting work does not resume until you choose Continue Queue after review."
                    ],
                    bulletItems: [
                        "Retry is offered only when replaying the complete intent cannot repeat an item that already succeeded."
                    ]
                ),
                HelpSection(
                    heading: "Transferred-content verification",
                    paragraphs: [
                        "Enable Verify transferred file contents before publishing in Settings > File Operations; it is off by default. Copy, Duplicate, cross-volume move, and copy/replace actions in reviewed one-way synchronization are checked with SHA-256 in private staging.",
                        "Directory structure and symbolic-link payloads are checked too. Progress combines byte-weighted percentage with a file count, and at most two file pairs are hashed concurrently. Mismatch, read failure, or cancellation prevents publication."
                    ],
                    bulletItems: [
                        "Resource forks, extended attributes, ACLs, ownership, flags, creation dates, hard-link relationships, and sparse allocation are outside the verification scope."
                    ]
                ),
                HelpSection(
                    heading: "Conservative Undo",
                    paragraphs: [
                        "Undo is enabled only while Pengrid's exact mutation identity and no-follow fingerprint remain unchanged and the original path is empty (unoccupied). A replacement, content change, missing item, or uncertain ownership never overwrites a later item or removes modified output.",
                        "Completed reviewed folder synchronization is non-retryable and is not exposed as Undo."
                    ],
                    bulletItems: []
                )
            ],
            shortcuts: [
                HelpShortcut(keys: "Command-D", action: "Duplicate the captured selection"),
                HelpShortcut(keys: "Delete / Command-Delete", action: "Move to Trash with confirmation / immediately")
            ],
            externalDestination: nil
        ),
        HelpTopic(
            id: .archives,
            title: "Archives",
            summary: "Learn the supported ZIP/TAR formats, bounded parallel preparation, progress phases, and protected ZIP limits.",
            sections: [
                HelpSection(
                    heading: "Supported formats",
                    paragraphs: [
                        "Pengrid creates and extracts ZIP, TAR, TAR.GZ/TGZ, TAR.BZ2/TBZ/TBZ2, and TAR.XZ/TXZ. Selected sources and destinations are checked before work starts, and archive outputs are published without overwriting an existing entry."
                    ],
                    bulletItems: [
                        "7z, RAR, and password-protected TAR are not supported."
                    ]
                ),
                HelpSection(
                    heading: "Progress and cancellation",
                    paragraphs: [
                        "For multiple sources, only preparation for the ordinary formats uses bounded parallel staging (up to four workers). Ordinary-format encoding and extraction each remain one native macOS ditto or tar process.",
                        "Progress has preparation, encoding or extraction, and publishing phases. Native tools may provide indeterminate byte totals during encoding; cancellation remains available throughout, and uncertain cleanup becomes Recovery Needed for review."
                    ],
                    bulletItems: [
                        "The Operation Center shows the current phase and item progress."
                    ]
                ),
                HelpSection(
                    heading: "Password-protected ZIP",
                    paragraphs: [
                        "Source builds can create AES-256 password-protected ZIP files. Reading accepts AES-128, AES-192, AES-256, and ZipCrypto entries using Store or Deflate when they pass the safety policy.",
                        "ZIP filenames, sizes, timestamps, and other central-directory metadata remain visible. Passwords are held for the active request only and are never saved, recovered, or exposed."
                    ],
                    bulletItems: [
                        "Wrong passwords, damaged data, unsafe paths, and limit violations fail closed."
                    ]
                )
            ],
            shortcuts: [],
            externalDestination: nil
        ),
        HelpTopic(
            id: .cloudLocations,
            title: "Cloud Locations",
            summary: "Use Google Drive and OneDrive through macOS File Provider, and understand manual locations and local availability.",
            sections: [
                HelpSection(
                    heading: "File Provider locations",
                    paragraphs: [
                        "Google Drive and OneDrive appear as File Provider roots registered with macOS. Pengrid has no direct Google or Microsoft OAuth/API client and does not ask for those account credentials.",
                        "A folder selected in Cloud Locations settings can be added as a manual location using a security-scoped bookmark. Forgetting a manual location does not delete its files or folders."
                    ],
                    bulletItems: [
                        "Cloud Locations settings can rescan, hide or show locations, and remove a manual location."
                    ]
                ),
                HelpSection(
                    heading: "Local availability and materialization",
                    paragraphs: [
                        "Name/path metadata search and folder preview use information already exposed locally and do not intentionally materialize online-only children.",
                        "Opening, Quick Look, copy or move, content comparison, archive operations, and transfer verification may ask macOS or the installed provider to materialize an online-only item. A location without readable local bytes or writable capability is reported as read-only or unavailable and disables mutation."
                    ],
                    bulletItems: [
                        "When a provider cannot expose enough metadata, Pengrid reports unavailable or failed instead of inventing results."
                    ]
                ),
                HelpSection(
                    heading: "Scoped access",
                    paragraphs: [
                        "Scoped access is held only for work that needs it, with the same identity checks used for local files. A byte-dependent operation can wait for a macOS access prompt or provider state, or fail when local materialization is unavailable."
                    ],
                    bulletItems: [
                        "Pengrid does not replace the provider's account UI or implement a direct OAuth flow."
                    ]
                )
            ],
            shortcuts: [
                HelpShortcut(keys: "Command-R", action: "Rescan Cloud Locations")
            ],
            externalDestination: nil
        ),
        HelpTopic(
            id: .shortcuts,
            title: "Keyboard Shortcuts",
            summary: "Primary navigation, search, and file-operation shortcuts verified in the current source and guide.",
            sections: [
                HelpSection(
                    heading: "Navigation and view",
                    paragraphs: [],
                    bulletItems: [
                        "Command-O — Open selected item",
                        "Space — Folder preview or Quick Look",
                        "Command-I — Get Info for the captured selection",
                        "Command-T / Command-W — New tab / close tab when safe",
                        "Control-Tab / Control-Shift-Tab — Next / previous tab",
                        "Command-[ / Command-] — Back / Forward",
                        "Command-Up Arrow — Parent folder",
                        "Command-L — Edit location"
                    ]
                ),
                HelpSection(
                    heading: "Search and selection",
                    paragraphs: [],
                    bulletItems: [
                        "Command-F — Filter the active pane",
                        "Command-Shift-F — Smart Search",
                        "Command-P — Quick Go… palette",
                        "Option-Command-A — Select all visible rows",
                        "Option-Command-I — Invert the visible selection",
                        "Option-Command-E — Select visible rows with the same extension"
                    ]
                ),
                HelpSection(
                    heading: "File operations",
                    paragraphs: [],
                    bulletItems: [
                        "Command-C / Command-V — Copy / Paste",
                        "Command-D — Duplicate",
                        "Option-Command-N — Create a new empty file",
                        "Option-Command-C — Copy full paths in visible order",
                        "Command-Shift-N — New folder",
                        "Command-Control-R — Batch Rename",
                        "Delete / Command-Delete — Move to Trash with confirmation / immediately"
                    ]
                )
            ],
            shortcuts: [],
            externalDestination: nil
        ),
        HelpTopic(
            id: .troubleshooting,
            title: "Troubleshooting and Privacy",
            summary: "Check Gatekeeper, permissions, provider availability, recovery review, and privacy before reporting a reproducible issue.",
            sections: [
                HelpSection(
                    heading: "Launch and access problems",
                    paragraphs: [
                        "Gatekeeper can block an ad-hoc signed app. Pengrid does not tell you to disable security controls; verify the release artifact and signing guidance instead.",
                        "macOS access prompts can appear when a file or folder must be read or changed. If access is cancelled or denied, Pengrid fails safely and does not create a prompt loop."
                    ],
                    bulletItems: [
                        "If a manual bookmark is stale or a provider is offline, rescan Cloud Locations and check the location's availability."
                    ]
                ),
                HelpSection(
                    heading: "Recovery and provider availability",
                    paragraphs: [
                        "When the Operation Center reports Recovery Needed, review the uncertain temporary item rather than deleting it yourself, then choose Continue Queue. Conflicts, identity changes, and read-only locations can fail an operation.",
                        "File Provider online-only items may materialize only when a byte-dependent action begins. A retry cannot make a provider with no available local bytes or write capability writable."
                    ],
                    bulletItems: [
                        "Completed reviewed folder synchronization is not retried or undone."
                    ]
                ),
                HelpSection(
                    heading: "Privacy and online links",
                    paragraphs: [
                        "Operation Center and VoiceOver status use safe item names and summaries; Pengrid does not persist or announce absolute parent paths, search queries, file contents, or passwords. Help content is offline and does not inspect workspace or File Provider state or make network requests.",
                        "The user guide and releases page require an internet connection. If macOS rejects opening the browser, Pengrid shows a bounded error and does not retry automatically. Follow the releases guidance to report a reproducible issue."
                    ],
                    bulletItems: [
                        "The eight offline topics remain available even when an online page cannot be opened."
                    ]
                )
            ],
            shortcuts: [],
            externalDestination: .releases
        )
    ]
}

extension HelpCatalog {
    static func search(_ query: String, displaying language: HelpLanguage) -> [HelpTopic] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return topics(for: language)
        }

        let plan = SmartSearchTextAnalyzer.queryPlan(for: query)
        guard !plan.clauses.isEmpty else { return [] }

        return HelpTopicID.allCases.compactMap { id in
            guard let displayTopic = topic(id: id, language: language),
                  let englishTopic = HelpCatalog.topic(id: id, language: .english),
                  SmartSearchTextAnalyzer.match(
                      plan: plan,
                      filename: englishTopic.title,
                      relativePath: searchText(for: id)
                  ) != nil
            else { return nil }
            return displayTopic
        }
    }

    static func reconciledSelection(current: HelpTopicID?, results: [HelpTopic]) -> HelpTopicID? {
        guard let current else { return results.first?.id }
        return results.contains { $0.id == current } ? current : results.first?.id
    }

    private static func searchText(for id: HelpTopicID) -> String {
        HelpLanguage.allCases.flatMap { language -> [String] in
            guard let topic = topic(id: id, language: language) else { return [] }
            var fields = [topic.title, topic.summary]
            for section in topic.sections {
                fields.append(section.heading)
                fields.append(contentsOf: section.paragraphs)
                fields.append(contentsOf: section.bulletItems)
            }
            for shortcut in topic.shortcuts {
                fields.append(shortcut.keys)
                fields.append(shortcut.action)
            }
            if let destination = topic.externalDestination {
                fields.append(destination.rawValue)
            }
            return fields
        }
        .joined(separator: " ")
    }
}
