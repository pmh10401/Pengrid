import Testing
@testable import BloomFileManager

@Suite("File operations settings presentation")
struct FileOperationsSettingsPresentationTests {
    @Test func menusFollowTheFirstPreferredLanguageAndKeepEnglishFallback() {
        #expect(AppText.text("Shelf", preferredLanguages: ["ko-KR", "en"]) == "보관함")
        #expect(AppText.text("Dark Glass", preferredLanguages: ["ko"]) == "어두운 글래스")
        #expect(AppText.text("Copy", preferredLanguages: ["en", "ko"]) == "Copy")
        #expect(AppText.text("Copy", preferredLanguages: ["ja"]) == "Copy")
        #expect(AppText.text("Copy", preferredLanguages: []) == "Copy")
        #expect(AppText.text("unknown title", preferredLanguages: ["ko"]) == "unknown title")
        #expect(AppText.text("%@, %ld items", preferredLanguages: ["ko"]) == "%@, %ld개")
    }

    @Test func settingsTabsKeepFileOperationsBeforeCloudLocations() {
        #expect(PengridSettingsTab.allCases.map(\.title) == [
            "File Operations",
            "Cloud Locations",
            "Top Shelf"
        ])
        #expect(PengridSettingsTab.fileOperations.systemImage == "arrow.left.arrow.right")
        #expect(PengridSettingsTab.cloudLocations.systemImage == "externaldrive.badge.icloud")
        #expect(PengridSettingsTab.topShelf.systemImage == "tray.full")
    }

    @Test func verificationToggleUsesStableLabelValuesAndIdentifier() {
        #expect(FileOperationsSettingsPresentation.toggleLabel
            == "Verify transferred file contents before publishing")
        #expect(FileOperationsSettingsPresentation.value(isEnabled: false) == "Off")
        #expect(FileOperationsSettingsPresentation.value(isEnabled: true) == "On")
        #expect(AccessibilityIdentifiers.fileOperationsSettings
            == "fileOperationsSettings")
        #expect(AccessibilityIdentifiers.verifyTransferredContents
            == "verifyTransferredContents")
    }

    @Test func verificationHelpExplainsCostAvailabilityAndProgressWeighting() {
        let help = FileOperationsSettingsPresentation.help

        #expect(help.contains("extra elapsed time"))
        #expect(help.contains("read I/O"))
        #expect(help.contains("provider makes them locally available"))
        #expect(help.contains("byte-weighted"))
        #expect(help.contains("file-weighted"))
    }
}
