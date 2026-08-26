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
        for id in ["helpWindow", "helpSearch", "helpTopicList", "helpDetail", "helpLanguage", "helpNoResults", "helpExternalError", "helpResultCount", "helpDetailTitle", "helpClearSearch", "helpUserGuideAction", "helpReleasesAction"] {
            #expect(source.contains("AccessibilityIdentifiers.\(id)"))
        }
        #expect(source.contains("AccessibilityIdentifiers.helpTopic(topic.id)"))
    }

    @Test func helpViewUsesAnExplicitSearchFieldAndReportsVisibleResults() throws {
        let source = try source(named: "Views/HelpView.swift")
        #expect(source.contains("TextField(copy.searchPrompt, text: $query)"))
        #expect(source.contains(".accessibilityIdentifier(AccessibilityIdentifiers.helpSearch)"))
        #expect(source.contains("Text(copy.resultCount(results.count))"))
        #expect(source.contains("AccessibilityIdentifiers.helpResultCount"))
        #expect(!source.contains(".searchable("))
    }

    @Test func helpViewPlacesLanguageControlInToolbarAndMarksContentHeaders() throws {
        let source = try source(named: "Views/HelpView.swift")
        #expect(source.contains(".toolbar"))
        #expect(source.contains("ToolbarItem(placement: .automatic)"))
        #expect(source.contains(".accessibilityAddTraits(.isHeader)"))
        #expect(!source.contains("ForEach(Array(topic.sections.enumerated()), id: \\.offset)"))
        #expect(!source.contains("ForEach(Array(section.paragraphs.enumerated()), id: \\.offset)"))
        #expect(!source.contains("ForEach(Array(section.bulletItems.enumerated()), id: \\.offset)"))
        #expect(!source.contains("ForEach(Array(shortcuts.enumerated()), id: \\.offset)"))
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

    @Test func helpCommandUsesStandardMenuShortcutAndSingletonSceneID() throws {
        let commands = try source(named: "Support/PengridHelpCommands.swift")
        #expect(commands.contains("CommandGroup(replacing: .help)"))
        #expect(commands.contains("Button(\"Pengrid Help\")"))
        #expect(commands.contains(".keyboardShortcut(\"?\", modifiers: .command)"))
        #expect(commands.components(separatedBy: ".keyboardShortcut(\"?\"").count - 1 == 1)
        #expect(commands.contains("openWindow(id: PengridHelpScene.id)"))
        #expect(commands.contains("static let id = \"pengrid-help\""))
    }

    @Test func appRegistersOneHelpWindowAndInstallsCommandsForEveryScene() throws {
        let app = try source(named: "App/BloomFileManagerApp.swift")
        #expect(app.contains("Window(\"Pengrid Help\", id: PengridHelpScene.id)"))
        #expect(app.contains("HelpView()"))
        #expect(app.contains(".defaultSize(width: 860, height: 620)"))
        #expect(app.components(separatedBy: "PengridHelpCommands()").count - 1 == 3)
        #expect(!app.contains("WindowGroup(\"Pengrid Help\""))
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
