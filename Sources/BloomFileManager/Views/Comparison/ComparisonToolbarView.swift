import SwiftUI

@MainActor
enum ComparisonOptionChange {
    static func setIncludeSubfolders(
        _ value: Bool,
        comparison: ComparisonCoordinator,
        workspace: WorkspaceState
    ) {
        guard comparison.options.includeSubfolders != value else { return }
        comparison.options.includeSubfolders = value
        comparison.rootsDidChange(workspace: workspace)
    }

    static func setIncludeHiddenItems(
        _ value: Bool,
        comparison: ComparisonCoordinator,
        workspace: WorkspaceState
    ) {
        guard comparison.options.includeHiddenItems != value else { return }
        comparison.options.includeHiddenItems = value
        comparison.rootsDidChange(workspace: workspace)
    }
}

struct ComparisonToolbarView: View {
    let workspace: WorkspaceState
    let comparison: ComparisonCoordinator
    let onExit: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Label(phaseTitle, systemImage: phaseSymbol)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Comparison status")
                .accessibilityValue(phaseTitle)

            Divider()
                .frame(height: 18)

            Picker("Filter", selection: filterIndex) {
                ForEach(Array(ComparisonFilter.allCases.enumerated()), id: \.offset) { index, filter in
                    Text(filter.title)
                        .accessibilityIdentifier(AccessibilityIdentifiers.comparisonFilter(filter))
                        .tag(index)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 190)

            Toggle("Include Subfolders", isOn: Binding(
                get: { comparison.options.includeSubfolders },
                set: {
                    ComparisonOptionChange.setIncludeSubfolders(
                        $0,
                        comparison: comparison,
                        workspace: workspace
                    )
                }
            ))

            Toggle("Show Hidden Items", isOn: Binding(
                get: { comparison.options.includeHiddenItems },
                set: {
                    ComparisonOptionChange.setIncludeHiddenItems(
                        $0,
                        comparison: comparison,
                        workspace: workspace
                    )
                }
            ))

            Spacer()

            Button("Exit Comparison") {
                onExit()
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .frame(height: 42)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityIdentifiers.comparisonToolbar)
    }

    private var filterIndex: Binding<Int> {
        Binding(
            get: { ComparisonFilter.allCases.firstIndex(of: comparison.filter) ?? 0 },
            set: { comparison.filter = ComparisonFilter.allCases[$0] }
        )
    }

    private var phaseTitle: String {
        switch comparison.phase {
        case .idle: "Idle"
        case .comparing: "Comparing folders"
        case .verifying: "Verifying contents"
        case .upToDate: "Comparison up to date"
        case .paused: "Comparison paused"
        case .disconnected: "Folder disconnected"
        }
    }

    private var phaseSymbol: String {
        switch comparison.phase {
        case .idle: "pause.circle"
        case .comparing, .verifying: "progress.indicator"
        case .upToDate: "checkmark.circle"
        case .paused: "exclamationmark.circle"
        case .disconnected: "externaldrive.badge.exclamationmark"
        }
    }
}

private extension ComparisonFilter {
    var title: String {
        switch self {
        case .differences: "Differences"
        case .all: "All Items"
        case .leftOnly: "Left Only"
        case .rightOnly: "Right Only"
        case .contentChanged: "Changed Contents"
        case .errors: "Errors and Conflicts"
        }
    }
}
