import SwiftUI

enum PengridSettingsTab: CaseIterable, Equatable, Sendable {
    case fileOperations
    case cloudLocations

    var title: String {
        switch self {
        case .fileOperations: "File Operations"
        case .cloudLocations: "Cloud Locations"
        }
    }

    var systemImage: String {
        switch self {
        case .fileOperations: "arrow.left.arrow.right"
        case .cloudLocations: "externaldrive.badge.icloud"
        }
    }
}

enum FileOperationsSettingsPresentation {
    static let toggleLabel = "Verify transferred file contents before publishing"
    static let help = "Verification reads the source and transferred copy, "
        + "which adds extra elapsed time and read I/O. Cloud files are verified "
        + "only when the provider makes them locally available. The percentage "
        + "is byte-weighted, while the completed count is file-weighted."

    static func value(isEnabled: Bool) -> String {
        isEnabled ? "On" : "Off"
    }
}

struct FileOperationsSettingsView: View {
    @Bindable var preference: TransferVerificationPreference

    var body: some View {
        Form {
            Section {
                Toggle(
                    FileOperationsSettingsPresentation.toggleLabel,
                    isOn: $preference.isEnabled
                )
                .accessibilityIdentifier(
                    AccessibilityIdentifiers.verifyTransferredContents
                )
                .accessibilityValue(
                    FileOperationsSettingsPresentation.value(
                        isEnabled: preference.isEnabled
                    )
                )
                .help(FileOperationsSettingsPresentation.help)
            } header: {
                Text("Transfer Verification")
            } footer: {
                Text(FileOperationsSettingsPresentation.help)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 620, minHeight: 420)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityIdentifiers.fileOperationsSettings)
        .accessibilityLabel("File Operations settings")
    }
}
