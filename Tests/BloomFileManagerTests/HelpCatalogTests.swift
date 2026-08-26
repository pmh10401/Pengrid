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
}
