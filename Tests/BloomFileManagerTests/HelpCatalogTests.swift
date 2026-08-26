import Foundation
import Testing
@testable import BloomFileManager

@Suite struct HelpCatalogTests {
    @Test func explicitLanguageWinsAndSystemFallbackIsDeterministic() {
        #expect(HelpLanguage.resolve(storedCode: "ko", preferredLanguages: ["en-US"]) == .korean)
        #expect(HelpLanguage.resolve(storedCode: "en", preferredLanguages: ["ko-KR"]) == .english)
        #expect(HelpLanguage.resolve(storedCode: "", preferredLanguages: ["ko-KR"]) == .korean)
        #expect(HelpLanguage.resolve(storedCode: "invalid", preferredLanguages: ["fr-FR"]) == .english)
        #expect(HelpLanguage.resolve(storedCode: "", preferredLanguages: []) == .english)
    }

    @Test func externalDestinationsAreExactAllowlistedHTTPSURLs() {
        #expect(HelpExternalDestination.userGuide.url(for: .english).absoluteString == "https://github.com/pmh10401/Pengrid/blob/main/docs/user-guide.md")
        #expect(HelpExternalDestination.userGuide.url(for: .korean).absoluteString == "https://github.com/pmh10401/Pengrid/blob/main/docs/user-guide.ko.md")
        #expect(HelpExternalDestination.releases.url(for: .english).absoluteString == "https://github.com/pmh10401/Pengrid/releases")
        for destination in HelpExternalDestination.allCases {
            for language in HelpLanguage.allCases {
                let url = destination.url(for: language)
                #expect(url.scheme == "https")
                #expect(url.host == "github.com")
                #expect(!destination.buttonTitle(for: language).isEmpty)
            }
        }
    }

    @Test func presentationCopyIsCompleteInBothLanguages() {
        for language in HelpLanguage.allCases {
            let copy = HelpPresentationCopy.value(for: language)
            #expect(!copy.windowTitle.isEmpty)
            #expect(!copy.searchPrompt.isEmpty)
            #expect(!copy.resultCount(8).isEmpty)
            #expect(!copy.resultCount(1).isEmpty)
            #expect(!copy.externalOpenFailedMessage.isEmpty)
        }
    }

    @Test func catalogHasTheSameCompleteStableTopicSetInBothLanguages() throws {
        let expected = HelpTopicID.allCases
        for language in HelpLanguage.allCases {
            let topics = HelpCatalog.topics(for: language)
            #expect(topics.map(\.id) == expected)
            #expect(Set(topics.map(\.id)).count == expected.count)
            for topic in topics {
                #expect(!topic.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                #expect(!topic.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                #expect(!topic.keywords.isEmpty)
                #expect(topic.keywords.allSatisfy {
                    !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                })
                #expect(!topic.sections.isEmpty)
                #expect(topic.sections.allSatisfy { !$0.heading.isEmpty && (!$0.paragraphs.isEmpty || !$0.bulletItems.isEmpty) })
                #expect(HelpCatalog.topic(id: topic.id, language: language) == topic)
            }
        }
    }

    @Test func catalogCoversApprovedProductCapabilities() {
        let ko = String(describing: HelpCatalog.topics(for: .korean))
        let en = String(describing: HelpCatalog.topics(for: .english)).lowercased()
        for term in ["듀얼", "초성", "작업 센터", "Undo", "암호", "Google Drive", "OneDrive", "개인정보"] { #expect(ko.contains(term)) }
        for term in ["dual", "initial", "operation center", "undo", "password", "google drive", "onedrive", "privacy"] { #expect(en.contains(term)) }
    }

    @Test func conservativeUndoRequiresAnEmptyOriginalPathInBothLanguages() throws {
        let korean = try #require(HelpCatalog.topic(id: .fileOperations, language: .korean))
        let english = try #require(HelpCatalog.topic(id: .fileOperations, language: .english))
        #expect(String(describing: korean).contains("원래 경로가 비어 있을 때"))
        #expect(String(describing: english).contains("original path is empty (unoccupied)"))
    }

    @Test func onlyRelevantTopicsExposeAllowlistedOnlineDestinations() throws {
        let topics = HelpCatalog.topics(for: .english)
        #expect(try #require(topics.first { $0.id == .gettingStarted }).externalDestination == .userGuide)
        #expect(try #require(topics.first { $0.id == .troubleshooting }).externalDestination == .releases)
        #expect(topics.filter { ![.gettingStarted, .troubleshooting].contains($0.id) }.allSatisfy { $0.externalDestination == nil })
    }

    @Test func blankSearchReturnsEveryTopicInStableOrder() {
        #expect(HelpCatalog.search("  \n", displaying: .english).map(\.id) == HelpTopicID.allCases)
    }

    @Test func searchIndexesBothLanguagesAndReturnsDisplayLanguageCopy() throws {
        let englishUI = HelpCatalog.search("암호 보호", displaying: .english)
        #expect(englishUI.map(\.id) == [.archives])
        #expect(try #require(englishUI.first).title == HelpCatalog.topic(id: .archives, language: .english)?.title)
        let koreanUI = HelpCatalog.search("privacy", displaying: .korean)
        #expect(koreanUI.map(\.id) == [.troubleshooting])
        #expect(try #require(koreanUI.first).title == HelpCatalog.topic(id: .troubleshooting, language: .korean)?.title)
    }

    @Test func koreanInitialAndMixedQueriesReuseSmartSearchSemantics() {
        #expect(HelpCatalog.search("ㅇㅎ", displaying: .korean).map(\.id).contains(.archives))
        let mixedResults = HelpCatalog.search("ㅇㄷ operation", displaying: .english).map(\.id)
        #expect(mixedResults.contains(.fileOperations))
        #expect(!mixedResults.contains(.search))
    }

    @Test func literalSearchUsesCaseAndDiacriticFolding() {
        #expect(HelpCatalog.search("CLOUD", displaying: .english).map(\.id).contains(.cloudLocations))
        #expect(HelpCatalog.search("prívacy", displaying: .english).map(\.id) == [.troubleshooting])
    }

    @Test func keywordOnlyQueriesFindTheirTopicsAcrossDisplayLanguages() {
        for displayLanguage in HelpLanguage.allCases {
            #expect(HelpCatalog.search("onboarding", displaying: displayLanguage).map(\.id) == [.gettingStarted])
            #expect(HelpCatalog.search("보관", displaying: displayLanguage).map(\.id) == [.archives])
        }
    }

    @Test func privacyCopyScopesHelpAndSmartSearchPersistenceTruthfully() throws {
        for language in HelpLanguage.allCases {
            let search = try #require(HelpCatalog.topic(id: .search, language: language))
            let privacy = try #require(HelpCatalog.topic(id: .troubleshooting, language: language))
            let text = [search, privacy]
                .flatMap { topic in
                    [topic.title, topic.summary] + topic.sections.flatMap { section in
                        [section.heading] + section.paragraphs + section.bulletItems
                    }
                }
                .joined(separator: " ")
            switch language {
            case .korean:
                #expect(text.contains("도움말 창의 현재 검색어와 선택만"))
                #expect(text.contains("명시적으로 저장할 때만"))
                #expect(text.contains("검색어·필터·루트 구성"))
                #expect(text.contains("안전한 기본 이름·개수·상태"))
            case .english:
                #expect(text.contains("Only the Help window's current query and selection"))
                #expect(text.contains("only when you explicitly save it"))
                #expect(text.contains("query, filters, and root configuration"))
                #expect(text.contains("safe basenames, counts, and status"))
            }
        }
    }

    @Test func noMatchAndSelectionReconcileDeterministically() {
        #expect(HelpCatalog.search("definitely-no-such-help-topic", displaying: .english).isEmpty)
        let results = HelpCatalog.search("cloud", displaying: .english)
        #expect(HelpCatalog.reconciledSelection(current: .cloudLocations, results: results) == .cloudLocations)
        #expect(HelpCatalog.reconciledSelection(current: .archives, results: results) == results.first?.id)
        #expect(HelpCatalog.reconciledSelection(current: .archives, results: []) == nil)
    }

}
