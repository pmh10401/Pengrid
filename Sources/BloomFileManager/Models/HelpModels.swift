import Foundation

enum HelpLanguage: String, CaseIterable, Sendable {
    case korean = "ko"
    case english = "en"

    static func resolve(storedCode: String, preferredLanguages: [String]) -> Self {
        if let storedLanguage = Self(rawValue: storedCode) {
            return storedLanguage
        }

        guard let preferredLanguage = preferredLanguages.first else {
            return .english
        }

        return preferredLanguage == "ko" || preferredLanguage.hasPrefix("ko-")
            ? .korean
            : .english
    }
}

enum HelpTopicID: String, CaseIterable, Sendable {
    case gettingStarted
    case dualPaneNavigation
    case search
    case fileOperations
    case archives
    case cloudLocations
    case shortcuts
    case troubleshooting
}

struct HelpSection: Equatable, Sendable {
    let heading: String
    let paragraphs: [String]
    let bulletItems: [String]
}

struct HelpShortcut: Equatable, Sendable {
    let keys: String
    let action: String
}

struct HelpTopic: Identifiable, Equatable, Sendable {
    let id: HelpTopicID
    let title: String
    let summary: String
    let sections: [HelpSection]
    let shortcuts: [HelpShortcut]
    let externalDestination: HelpExternalDestination?
}

enum HelpExternalDestination: String, CaseIterable, Sendable {
    case userGuide
    case releases

    func url(for language: HelpLanguage) -> URL {
        switch self {
        case .userGuide:
            switch language {
            case .korean:
                Self.userGuideKoreanURL
            case .english:
                Self.userGuideEnglishURL
            }
        case .releases:
            Self.releasesURL
        }
    }

    func buttonTitle(for language: HelpLanguage) -> String {
        switch self {
        case .userGuide:
            switch language {
            case .korean:
                "사용자 안내서 열기"
            case .english:
                "Open User Guide"
            }
        case .releases:
            switch language {
            case .korean:
                "릴리스 보기"
            case .english:
                "View Releases"
            }
        }
    }

    private static let userGuideEnglishURL = URL(string: "https://github.com/pmh10401/Pengrid/blob/main/docs/user-guide.md")!
    private static let userGuideKoreanURL = URL(string: "https://github.com/pmh10401/Pengrid/blob/main/docs/user-guide.ko.md")!
    private static let releasesURL = URL(string: "https://github.com/pmh10401/Pengrid/releases")!
}

struct HelpPresentationCopy: Equatable, Sendable {
    let windowTitle: String
    let searchPrompt: String
    let languageLabel: String
    let noResultsTitle: String
    let noResultsMessage: String
    let clearSearch: String
    let openOnlineGuide: String
    let internetRequired: String
    let externalOpenFailedTitle: String
    let externalOpenFailedMessage: String

    static func value(for language: HelpLanguage) -> Self {
        switch language {
        case .korean:
            Self(
                windowTitle: "Pengrid 도움말",
                searchPrompt: "도움말 검색",
                languageLabel: "언어",
                noResultsTitle: "일치하는 도움말 없음",
                noResultsMessage: "검색어와 일치하는 도움말 항목이 없습니다.",
                clearSearch: "검색 지우기",
                openOnlineGuide: "온라인 안내서 열기",
                internetRequired: "온라인 안내서와 릴리스 페이지를 열려면 인터넷 연결이 필요합니다.",
                externalOpenFailedTitle: "링크를 열 수 없음",
                externalOpenFailedMessage: "Pengrid에서 온라인 도움말 링크를 열지 못했습니다. 인터넷 연결을 확인한 후 다시 시도해 주세요."
            )
        case .english:
            Self(
                windowTitle: "Pengrid Help",
                searchPrompt: "Search Help",
                languageLabel: "Language",
                noResultsTitle: "No Matching Help Topics",
                noResultsMessage: "No help topics match your search.",
                clearSearch: "Clear Search",
                openOnlineGuide: "Open Online Guide",
                internetRequired: "Online guides and release pages require an internet connection.",
                externalOpenFailedTitle: "Unable to Open Link",
                externalOpenFailedMessage: "Pengrid could not open the online help link. Check your internet connection and try again."
            )
        }
    }
}
