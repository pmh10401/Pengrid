import Foundation

// Menu and shelf copy follow the same Korean/English preference rule as Help.
enum AppText {
    static func text(_ english: String, preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        HelpLanguage.resolve(storedCode: "", preferredLanguages: preferredLanguages) == .korean
            ? korean[english] ?? english : english
    }

    static func format(_ english: String, _ arguments: CVarArg...) -> String {
        String(format: text(english), locale: Locale.current, arguments: arguments)
    }

    private static let korean: [String: String] = [
        "Shelf": "보관함", "Top Shelf": "노치 보관함",
        "Enable Top Shelf": "노치 보관함 사용", "Show Top Shelf": "보관함 보기", "Hide Top Shelf": "보관함 숨기기",
        "Show Shelf": "보관함 보기", "Hide Shelf": "보관함 숨기기", "Collapse Shelf": "보관함 접기",
        "Move Shelf": "보관함 이동", "Keep Shelf Open": "보관함 열린 상태 유지", "Open Pengrid": "Pengrid 열기",
        "Use Hardware Notch": "하드웨어 노치에 숨기기", "Reset Shelf Position": "보관함 위치 초기화",
        "Dock to Screen Edge": "화면 가장자리", "Top": "위쪽", "Right": "오른쪽", "Bottom": "아래쪽", "Left": "왼쪽",
        "Dock to %@ Edge": "%@ 가장자리에 배치",
        "Shelf Appearance": "보관함 디자인", "Liquid Glass": "리퀴드 글래스", "Dark Glass": "어두운 글래스", "Solid Black": "검정",
        "Liquid Glass follows this Mac’s appearance. Dark Glass stays dark. The folded notch stays black; macOS versions before 26 and Reduce Transparency use solid black.": "리퀴드 글래스는 Mac의 화면 모양을 따릅니다. 어두운 글래스는 항상 어둡게 표시됩니다. 접힌 노치, macOS 26 이전 버전, ‘투명도 줄이기’ 사용 시에는 검정으로 표시됩니다.",
        "Search…": "검색…", "Search shelf (including Korean initials)": "보관함 검색 (한글 초성 지원)",
        "Search filenames and text, including Korean initials": "파일 이름과 텍스트를 한글 초성으로도 검색합니다",
        "Shelf categories": "보관함 분류", "All": "전체", "Files": "파일", "Text": "텍스트", "Images": "이미지",
        "%@, %ld items": "%@, %ld개", "Open Top Shelf: %ld items": "노치 보관함 열기: %ld개",
        "Import Clipboard": "클립보드 가져오기", "Copy": "복사", "Clear…": "비우기…", "Clear Shelf": "보관함 비우기",
        "Clear all shelf items? Original files and the system clipboard will not be changed.": "보관함을 모두 비울까요? 원본 파일과 시스템 클립보드는 변경되지 않습니다.",
        "Restoring shelf…": "보관함 복원 중…", "Drop files, text, or images here": "파일·텍스트·이미지를 여기에 놓으세요",
        "No matching items": "일치하는 항목이 없습니다", "Clipboard is read only when you choose Import.": "클립보드는 ‘가져오기’를 선택할 때만 읽습니다.",
        "Cleared on quit · originals stay untouched": "종료 시 비움 · 원본 유지", "Kept on this Mac · originals stay untouched": "이 Mac에 보관 · 원본 유지",
        "When Pengrid quits": "Pengrid 종료 시", "Clear on Quit": "종료 시 비우기", "Keep Between Launches": "다음 실행에도 보관",
        "Updating shelf": "보관함 갱신 중", "Retry": "다시 시도", "Retry Storage": "저장 다시 시도",
        "Empty text": "빈 텍스트", "Remove from Shelf": "보관함에서 제거", "Remove from shelf (keep original)": "보관함에서만 제거 (원본 유지)",
        "Select this item, then Copy (⌘C). Use the arrow handle to drag a copy.": "항목을 선택한 뒤 복사(⌘C)하세요. 화살표 손잡이를 끌면 복사본을 전달합니다.",
        "Drag a copy": "복사본 끌기", "Drag a copy; use Copy for keyboard access": "복사본 끌기; 키보드로는 ‘복사’를 사용하세요",
        "Drag a copy. Text and images require a destination accepting their native type.": "복사본을 끕니다. 텍스트와 이미지는 해당 형식을 받는 대상에 놓으세요.",
        "File reference · copy only": "파일 참조 · 복사 전용",
        "Hover or click this handle to open the shelf.": "손잡이에 마우스를 올리거나 클릭하면 보관함이 열립니다.",
        "Hover or click to open Top Shelf. Drop files, text, or images here to keep them.": "마우스를 올리거나 클릭해 보관함을 여세요. 파일·텍스트·이미지를 놓아 보관할 수 있습니다.",
        "Shelf stays open until you collapse or hide it": "접거나 숨길 때까지 열린 상태를 유지합니다",
        "Keep the hover preview open": "마우스를 떼어도 보관함을 유지합니다",
        "Drag the grip along the screen border, including around corners. Release to dock; Escape cancels. Outside search, ⌥Arrow keys adjust along the edge. Right-click to choose an edge.": "손잡이를 화면 테두리와 모서리를 따라 끌어 옮기세요. 놓으면 배치되고 Escape로 취소합니다. 검색창 밖에서는 ⌥+방향키로 조정하고 우클릭으로 가장자리를 선택합니다.",
        "Hover over the camera notch to reveal the shelf. Drag the six-dot grip along any screen edge; it flows around corners and docks when released. Release near the camera notch to dock there again. Escape cancels a move.": "카메라 노치에 마우스를 올리면 보관함이 열립니다. 여섯 점 손잡이를 테두리와 모서리를 따라 끌고 놓으면 배치됩니다. 카메라 노치 근처에 놓으면 다시 붙으며 Escape로 이동을 취소합니다.",
        "Clear on Quit is the default. Keep Between Launches stores manually added text, images, and file references locally on this Mac. This storage is not encrypted by Pengrid or synced to the cloud.": "기본값은 ‘종료 시 비우기’입니다. ‘다음 실행에도 보관’은 직접 추가한 텍스트·이미지·파일 참조를 이 Mac에 저장합니다. Pengrid가 암호화하거나 클라우드에 동기화하지 않습니다.",
        "Switching to Clear on Quit removes the saved snapshot but keeps current shelf items until quit. Turning the shelf off clears its items. Original files and the system clipboard are never deleted.": "‘종료 시 비우기’로 바꾸면 저장된 스냅샷을 지우지만 현재 항목은 종료할 때까지 유지합니다. 보관함 사용을 끄면 항목을 비웁니다. 원본 파일과 시스템 클립보드는 삭제하지 않습니다.",
        "Recovery needs attention in Pengrid": "Pengrid에서 복구 상태를 확인하세요", "Operation progress": "작업 진행률",
        "Operation in progress": "작업 진행 중", "Last operation failed. Open Pengrid for details.": "최근 작업이 실패했습니다. Pengrid에서 내용을 확인하세요.",
        "No active file operation": "진행 중인 파일 작업이 없습니다", "%ld queued": "%ld개 대기 중",
        "Pengrid Help": "Pengrid 도움말", "Pengrid Settings": "Pengrid 설정",
        "New Folder": "새 폴더", "New Empty File": "새 빈 파일", "Open": "열기", "Open With": "다음으로 열기",
        "Quick Look": "훑어보기", "Get Info": "정보 가져오기", "Close Preview": "미리보기 닫기",
        "Rename": "이름 변경", "Rename with F2": "F2로 이름 변경", "Paste": "붙여넣기", "Select All": "모두 선택",
        "Select All Visible": "표시된 항목 모두 선택", "Invert Selection": "선택 반전", "Select Same Extension": "같은 확장자 선택",
        "Select by Name…": "이름으로 선택…", "Filter Files": "파일 필터", "Smart Search…": "스마트 검색…",
        "New Workspace Tab": "새 작업공간 탭", "Close Workspace Tab": "작업공간 탭 닫기", "Reopen Closed Workspace Tab": "닫은 작업공간 탭 다시 열기",
        "Next Workspace Tab": "다음 작업공간 탭", "Previous Workspace Tab": "이전 작업공간 탭",
        "Workspace Profiles": "작업공간 프로필", "Save Workspace as Profile…": "작업공간을 프로필로 저장…", "Manage Workspace Profiles…": "작업공간 프로필 관리…",
        "File Operations": "파일 작업", "Cloud Locations": "클라우드 위치", "Batch Rename…": "일괄 이름 변경…",
        "Compress to ZIP": "ZIP으로 압축", "Compress as Password-Protected ZIP…": "암호가 있는 ZIP으로 압축…",
        "Compress as…": "다른 형식으로 압축…", "Extract Archive": "압축 풀기", "Move to Trash…": "휴지통으로 이동…", "Move to Trash Immediately": "즉시 휴지통으로 이동",
        "Go": "이동", "Quick Go…": "빠른 이동…", "Back": "뒤로", "Forward": "앞으로", "Parent Folder": "상위 폴더", "Edit Location": "경로 입력",
        "Compare": "비교", "Compare Folders": "폴더 비교", "Exit Comparison": "비교 종료",
        "Verify Selected Contents": "선택한 내용 검증", "Verify All Contents": "모든 내용 검증",
        "Copy Left to Right": "왼쪽에서 오른쪽으로 복사", "Move Left to Right…": "왼쪽에서 오른쪽으로 이동…",
        "Copy Right to Left": "오른쪽에서 왼쪽으로 복사", "Move Right to Left…": "오른쪽에서 왼쪽으로 이동…",
        "Storage": "저장 공간", "Enter Storage Inspector": "저장 공간 분석 열기", "Exit Storage Inspector": "저장 공간 분석 닫기",
        "Choose Location…": "위치 선택…", "Start Scan": "분석 시작", "Cancel Scan": "분석 취소", "Scan Again": "다시 분석",
        "Open in Other Pane": "다른 패널에서 열기", "Copy to Other Pane": "다른 패널로 복사", "Move to Other Pane": "다른 패널로 이동",
        "Show in Finder": "Finder에서 보기", "Copy Path": "경로 복사", "Copy Full Path": "전체 경로 복사", "Copy Name": "이름 복사",
        "Copy Parent Path": "상위 폴더 경로 복사", "Copy File URL": "파일 URL 복사", "Duplicate": "복제", "Add to Favorites": "즐겨찾기에 추가",
        "New Folder with Selection (%ld Items)…": "선택한 %ld개 항목으로 새 폴더…"
    ]
}
