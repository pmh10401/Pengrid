import SwiftUI

struct StorageInspectorToolbarView: View {
    let storage: StorageAnalysisStore
    @Binding var options: StorageScanOptions
    let onExit: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button("Choose Location…") {
                StorageInspectorCommandActions.chooseLocation(
                    storage: storage,
                    options: options
                )
            }
            .disabled(!policy.canStart)
            .accessibilityIdentifier(AccessibilityIdentifiers.storageInspectorChooseLocation)

            Button("Start Scan") {
                StorageInspectorCommandActions.start(
                    storage: storage,
                    options: options
                )
            }
            .disabled(!policy.canStart)
            .accessibilityIdentifier(AccessibilityIdentifiers.storageInspectorStart)

            Button("Cancel Scan") {
                storage.cancel()
            }
            .disabled(!policy.canCancel)
            .accessibilityIdentifier(AccessibilityIdentifiers.storageInspectorCancel)

            Button("Scan Again") {
                Task { await storage.scanAgain() }
            }
            .disabled(!policy.canStart || storage.rootURL == nil)
            .accessibilityIdentifier(AccessibilityIdentifiers.storageInspectorScanAgain)

            Toggle("Include Hidden Items", isOn: $options.includeHiddenItems)
                .disabled(policy.canCancel)
                .accessibilityIdentifier(
                    AccessibilityIdentifiers.storageInspectorHiddenItems
                )

            Spacer()

            Label(
                StorageInspectorPresentation.phaseTitle(storage.phase),
                systemImage: phaseSymbol
            )
            .foregroundStyle(.secondary)
            .accessibilityLabel("Storage analysis status")
            .accessibilityValue(
                StorageInspectorPresentation.phaseAccessibilityValue(storage.phase)
            )

            Text("\(storage.entries.count) items")
                .foregroundStyle(.secondary)

            Text(StorageInspectorPresentation.analyzedBytesTitle(storage.totalBytes))
                .foregroundStyle(.secondary)

            Button("Exit Storage Inspector", action: onExit)
                .accessibilityIdentifier(AccessibilityIdentifiers.storageInspectorExit)
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .frame(height: 42)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityIdentifiers.storageInspectorToolbar)
    }

    private var policy: StorageInspectorCommandPolicy {
        StorageInspectorCommandPolicy(isActive: storage.isActive, phase: storage.phase)
    }

    private var phaseSymbol: String {
        switch storage.phase {
        case .inactive, .idle: "pause.circle"
        case .scanning, .verifying: "progress.indicator"
        case .complete: "checkmark.circle"
        case .paused: "exclamationmark.circle"
        case .cancelled: "xmark.circle"
        }
    }
}
