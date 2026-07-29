import SwiftUI

struct StorageInspectorSidebarView: View {
    let storage: StorageAnalysisStore

    var body: some View {
        List {
            Section("Analysis") {
                ForEach(StorageAnalysisSection.allCases, id: \.rawValue) { section in
                    Button {
                        storage.section = section
                    } label: {
                        Label(
                            StorageInspectorPresentation.sectionTitle(section),
                            systemImage: StorageInspectorPresentation.sectionSymbol(section)
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(StorageInspectorPresentation.sectionTitle(section))
                    .accessibilityValue(
                        storage.section == section ? "Selected" : "Not selected"
                    )
                    .accessibilityIdentifier(
                        AccessibilityIdentifiers.storageInspectorSection(section)
                    )
                }
            }
        }
        .listStyle(.sidebar)
        .accessibilityIdentifier(AccessibilityIdentifiers.storageInspectorSidebar)
    }
}
