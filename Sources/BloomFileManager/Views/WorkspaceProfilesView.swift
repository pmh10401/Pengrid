import SwiftUI

enum WorkspaceProfilePresentation {
    static func folderNames(for descriptor: WorkspaceDescriptor) -> String {
        "\(WorkspaceTabPresentation.basename(for: URL(filePath: descriptor.leftPath))) ⇄ \(WorkspaceTabPresentation.basename(for: URL(filePath: descriptor.rightPath)))"
    }

    static func pathText(for descriptor: WorkspaceDescriptor) -> String {
        "\(descriptor.leftPath) ⇄ \(descriptor.rightPath)"
    }

    static func accessibilityLabel(for profile: WorkspaceProfileRecord) -> String {
        "Workspace profile \(profile.name). Folders: \(folderNames(for: profile.descriptor))."
    }
}

struct WorkspaceProfilesView: View {
    let session: WorkspaceSessionState
    let teardown: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var newProfileName = ""
    @State private var profileNames = [WorkspaceProfileID: String]()
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Workspace Profiles")
                .font(.headline)

            HStack {
                TextField("Profile name", text: $newProfileName)
                Button("Save Active Workspace") {
                    saveActiveProfile()
                }
                .disabled(newProfileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier(WorkspaceSessionAccessibilityIdentifiers.saveProfile)
            }

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .accessibilityLabel("Profile error")
            }

            List {
                ForEach(session.profiles, id: \.id) { profile in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            TextField(
                                "Profile name",
                                text: Binding(
                                    get: { profileNames[profile.id] ?? profile.name },
                                    set: { profileNames[profile.id] = $0 }
                                )
                            )
                            .accessibilityIdentifier(WorkspaceSessionAccessibilityIdentifiers.profile(profile.id))

                            Spacer()

                            Button("Rename") {
                                rename(profile)
                            }
                            .accessibilityIdentifier(WorkspaceSessionAccessibilityIdentifiers.renameProfile(profile.id))
                            .accessibilityLabel("Rename workspace profile \(profile.name)")

                            Button("Open") {
                                if WorkspaceTabCommandActions.openProfile(
                                    profile.id,
                                    in: session,
                                    isModalPresented: true,
                                    isTextEditing: false,
                                    allowsCurrentModalOwner: true,
                                    teardown: teardown
                                ) {
                                    dismiss()
                                }
                            }
                            .accessibilityIdentifier(WorkspaceSessionAccessibilityIdentifiers.openProfile(profile.id))
                            .accessibilityLabel("Open workspace profile \(profile.name)")

                            Button("Delete", role: .destructive) {
                                _ = WorkspaceTabCommandActions.deleteProfile(
                                    profile.id,
                                    in: session,
                                    isModalPresented: true,
                                    isTextEditing: false,
                                    allowsCurrentModalOwner: true
                                )
                            }
                            .accessibilityIdentifier(WorkspaceSessionAccessibilityIdentifiers.deleteProfile(profile.id))
                            .accessibilityLabel("Delete workspace profile \(profile.name)")
                        }

                        Text(WorkspaceProfilePresentation.folderNames(for: profile.descriptor))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(WorkspaceProfilePresentation.pathText(for: profile.descriptor))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    .accessibilityLabel(WorkspaceProfilePresentation.accessibilityLabel(for: profile))
                }
            }
            .accessibilityIdentifier(WorkspaceSessionAccessibilityIdentifiers.manageProfiles)

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier(WorkspaceSessionAccessibilityIdentifiers.done)
            }
        }
        .padding(20)
        .frame(minWidth: 440, minHeight: 280)
        .accessibilityIdentifier(WorkspaceSessionAccessibilityIdentifiers.profilesSheet)
    }

    private func saveActiveProfile() {
        do {
            guard try WorkspaceTabCommandActions.saveActiveProfile(
                named: newProfileName,
                in: session,
                isModalPresented: true,
                isTextEditing: false,
                allowsCurrentModalOwner: true
            ) != nil else { return }
            newProfileName = ""
            errorMessage = nil
        } catch {
            errorMessage = "A unique profile name is required."
        }
    }

    private func rename(_ profile: WorkspaceProfileRecord) {
        do {
            guard try WorkspaceTabCommandActions.renameProfile(
                profile.id,
                to: profileNames[profile.id] ?? profile.name,
                in: session,
                isModalPresented: true,
                isTextEditing: false,
                allowsCurrentModalOwner: true
            ) else { return }
            profileNames[profile.id] = nil
            errorMessage = nil
        } catch {
            errorMessage = "A unique profile name is required."
        }
    }
}
