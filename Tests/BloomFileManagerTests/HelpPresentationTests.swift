import Foundation
import Testing
@testable import BloomFileManager

@Suite struct HelpPresentationTests {
    @Test func helpViewUsesNativeSplitNavigationAndNoWebContent() throws {
        let source = try source(named: "Views/HelpView.swift")
        #expect(source.contains("NavigationSplitView"))
        #expect(source.contains("@AppStorage"))
        #expect(source.contains("@Environment(\\.openURL)"))
        #expect(source.contains("HelpCatalog.search"))
        #expect(source.contains("HelpCatalog.reconciledSelection"))
        #expect(!source.contains("WebView"))
        #expect(!source.contains("WKWebView"))
        #expect(!source.contains("URLSession"))
    }

    @Test func helpViewExposesStableAccessibleRegions() throws {
        let source = try source(named: "Views/HelpView.swift")
        for id in ["helpWindow", "helpSearch", "helpTopicList", "helpDetail", "helpLanguage", "helpNoResults", "helpExternalError"] {
            #expect(source.contains("AccessibilityIdentifiers.\(id)"))
        }
        #expect(source.contains("AccessibilityIdentifiers.helpTopic(topic.id)"))
    }

    @Test func rejectedExternalOpenProducesBoundedLocalFeedback() throws {
        let source = try source(named: "Views/HelpView.swift")
        #expect(source.contains("openURL(destination.url(for: language)) { accepted in"))
        #expect(source.contains("if accepted"))
        #expect(source.contains("externalErrorMessage = nil"))
        #expect(source.contains("externalOpenFailedMessage"))
        #expect(source.contains("externalErrorMessage"))
        #expect(!source.contains("ExternalOpenResult"))
    }
}

private func source(named relativePath: String) throws -> String {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let url = packageRoot
        .appending(path: "Sources/BloomFileManager", directoryHint: .isDirectory)
        .appending(path: relativePath)
    return try String(contentsOf: url, encoding: .utf8)
}
