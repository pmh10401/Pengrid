import SwiftUI

enum CloudLocationsSettingsAction: String, Hashable {
    case rescan
    case hide
    case unhide
    case removeManualLocation

    var title: String {
        switch self {
        case .rescan: "Rescan"
        case .hide: "Hide"
        case .unhide: "Unhide"
        case .removeManualLocation: "Remove Manual Location"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .rescan: "Rescan cloud locations"
        case .hide: "Hide from sidebar"
        case .unhide: "Unhide in sidebar"
        case .removeManualLocation: "Remove manual location"
        }
    }

    var help: String {
        switch self {
        case .rescan:
            "Find available File Provider locations again."
        case .hide:
            "Keep this location registered but hide it from the sidebar."
        case .unhide:
            "Show this location in the sidebar without rescanning."
        case .removeManualLocation:
            "Forget this manually added location. Files and folders are not deleted."
        }
    }

    var keyboardShortcut: String? {
        switch self {
        case .rescan: "Command-R"
        case .hide, .unhide, .removeManualLocation: nil
        }
    }
}

struct CloudLocationsSettingsSectionPresentation {
    let title: String
    let locations: [StorageLocation]
    let isHidden: Bool
    let accessibilityIdentifier: String
}

enum CloudLocationsSettingsPresentation {
    static func sections(
        visible: [StorageLocation],
        hidden: [StorageLocation]
    ) -> [CloudLocationsSettingsSectionPresentation] {
        [
            CloudLocationsSettingsSectionPresentation(
                title: "Visible Locations",
                locations: visible,
                isHidden: false,
                accessibilityIdentifier: AccessibilityIdentifiers.cloudSettingsVisible
            ),
            CloudLocationsSettingsSectionPresentation(
                title: "Hidden Locations",
                locations: hidden,
                isHidden: true,
                accessibilityIdentifier: AccessibilityIdentifiers.cloudSettingsHidden
            )
        ]
    }

    static func actions(
        for location: StorageLocation,
        isHidden: Bool
    ) -> [CloudLocationsSettingsAction] {
        var actions: [CloudLocationsSettingsAction] = [isHidden ? .unhide : .hide]
        if location.source == .manualBookmark {
            actions.append(.removeManualLocation)
        }
        return actions
    }
}

@MainActor
enum CloudLocationsSettingsActions {
    static func perform(
        _ action: CloudLocationsSettingsAction,
        for location: StorageLocation,
        in store: CloudLocationsStore
    ) throws {
        switch action {
        case .hide:
            try store.hide(location.id)
        case .unhide:
            try store.unhide(location.id)
        case .removeManualLocation:
            try store.removeManualLocation(location.id)
        case .rescan:
            assertionFailure("Rescan is asynchronous and handled by the settings view.")
        }
    }
}

struct CloudLocationsSettingsView: View {
    let cloudLocations: CloudLocationsStore

    @State private var isRescanning = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                Button {
                    rescan()
                } label: {
                    Label(
                        CloudLocationsSettingsAction.rescan.title,
                        systemImage: "arrow.clockwise"
                    )
                }
                .disabled(isRescanning)
                .keyboardShortcut("r", modifiers: .command)
                .accessibilityIdentifier(AccessibilityIdentifiers.cloudSettingsRescan)
                .accessibilityLabel(
                    CloudLocationsSettingsAction.rescan.accessibilityLabel
                )
                .help(CloudLocationsSettingsAction.rescan.help)
            } footer: {
                Text("Rescanning updates availability but never unhides a location.")
            }

            ForEach(settingsSections, id: \.title) { section in
                locationSection(
                    title: section.title,
                    locations: section.locations,
                    isHidden: section.isHidden
                )
                .accessibilityIdentifier(section.accessibilityIdentifier)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 620, minHeight: 420)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityIdentifiers.cloudSettings)
        .accessibilityLabel("Cloud Locations settings")
        .alert(
            "Cloud Locations",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK") {
                errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var settingsSections: [CloudLocationsSettingsSectionPresentation] {
        CloudLocationsSettingsPresentation.sections(
            visible: cloudLocations.visibleLocations,
            hidden: cloudLocations.hiddenLocations
        )
    }

    private func locationSection(
        title: String,
        locations: [StorageLocation],
        isHidden: Bool
    ) -> some View {
        Section(title) {
            if locations.isEmpty {
                Text(isHidden ? "No hidden locations." : "No visible locations.")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(
                        isHidden ? "No hidden cloud locations" : "No visible cloud locations"
                    )
            } else {
                ForEach(locations) { location in
                    locationRow(location, isHidden: isHidden)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    private func locationRow(
        _ location: StorageLocation,
        isHidden: Bool
    ) -> some View {
        let presentation = CloudLocationRowPresentation.values(for: location)
        let actions = CloudLocationsSettingsPresentation.actions(
            for: location,
            isHidden: isHidden
        )

        return HStack(spacing: 12) {
            Image(systemName: presentation.systemImage)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(presentation.locationName)
                Text(
                    "\(presentation.providerName) · \(presentation.availabilityDescription)"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            ForEach(actions, id: \.self) { action in
                Button(
                    action.title,
                    role: action == .removeManualLocation ? .destructive : nil
                ) {
                    perform(action, for: location)
                }
                .accessibilityIdentifier(
                    AccessibilityIdentifiers.cloudSettingsAction(
                        action,
                        locationID: location.id
                    )
                )
                .accessibilityLabel(action.accessibilityLabel)
                .help(action.help)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(presentation.accessibilityLabel)
    }

    private func perform(
        _ action: CloudLocationsSettingsAction,
        for location: StorageLocation
    ) {
        do {
            try CloudLocationsSettingsActions.perform(
                action,
                for: location,
                in: cloudLocations
            )
        } catch {
            errorMessage = "The cloud location setting could not be updated."
        }
    }

    private func rescan() {
        guard !isRescanning else { return }
        isRescanning = true
        Task {
            defer { isRescanning = false }
            do {
                try await cloudLocations.rescan()
            } catch is CancellationError {
                return
            } catch {
                errorMessage = "Cloud locations could not be rescanned."
            }
        }
    }
}
