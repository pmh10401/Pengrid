import Testing
@testable import BloomFileManager

@Suite("File operations settings presentation")
struct FileOperationsSettingsPresentationTests {
    @Test func settingsTabsKeepFileOperationsBeforeCloudLocations() {
        #expect(PengridSettingsTab.allCases.map(\.title) == [
            "File Operations",
            "Cloud Locations"
        ])
        #expect(PengridSettingsTab.fileOperations.systemImage == "arrow.left.arrow.right")
        #expect(PengridSettingsTab.cloudLocations.systemImage == "externaldrive.badge.icloud")
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
