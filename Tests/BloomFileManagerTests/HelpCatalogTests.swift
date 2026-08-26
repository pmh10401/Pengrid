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

    @Test func onlyRelevantTopicsExposeAllowlistedOnlineDestinations() throws {
        let topics = HelpCatalog.topics(for: .english)
        #expect(try #require(topics.first { $0.id == .gettingStarted }).externalDestination == .userGuide)
        #expect(try #require(topics.first { $0.id == .troubleshooting }).externalDestination == .releases)
        #expect(topics.filter { ![.gettingStarted, .troubleshooting].contains($0.id) }.allSatisfy { $0.externalDestination == nil })
    }
}
