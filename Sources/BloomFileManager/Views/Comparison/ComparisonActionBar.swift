import SwiftUI

struct ComparisonActionBar: View {
    let workspace: WorkspaceState
    let comparison: ComparisonCoordinator
    let operationController: FileOperationController

    var body: some View {
        HStack(spacing: 10) {
            Text(selectionSummary)
                .foregroundStyle(.secondary)

            Spacer()

            Button("Copy Left to Right") {
                comparison.copy(
                    direction: .leftToRight,
                    operationController: operationController,
                    workspace: workspace
                )
            }
            .disabled(!comparison.canCopy(.leftToRight))
            .help("Copy the selected left-side items to the right folder")

            Button("Move Left to Right…") {
                comparison.requestMove(direction: .leftToRight)
            }
            .disabled(!comparison.canMove(.leftToRight))
            .help(moveHelp(.leftToRight))
            .accessibilityHint(moveHelp(.leftToRight))

            Button("Copy Right to Left") {
                comparison.copy(
                    direction: .rightToLeft,
                    operationController: operationController,
                    workspace: workspace
                )
            }
            .disabled(!comparison.canCopy(.rightToLeft))
            .help("Copy the selected right-side items to the left folder")

            Button("Move Right to Left…") {
                comparison.requestMove(direction: .rightToLeft)
            }
            .disabled(!comparison.canMove(.rightToLeft))
            .help(moveHelp(.rightToLeft))
            .accessibilityHint(moveHelp(.rightToLeft))

            Divider()
                .frame(height: 20)

            Button("Verify Selected Contents") {
                comparison.verifySelected()
            }
            .disabled(!comparison.canVerifySelected)

            Button("Verify All Contents") {
                comparison.verifyAll()
            }
            .disabled(!comparison.isActive)
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .frame(height: 42)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityIdentifiers.comparisonActionBar)
    }

    private var selectionSummary: String {
        let count = comparison.selection.count
        return count == 1 ? "1 item selected" : "\(count) items selected"
    }

    private func moveHelp(_ direction: ComparisonDirection) -> String {
        comparison.moveBlockReason(direction) ?? {
            switch direction {
            case .leftToRight:
                "Review and move the selected left-only items to the right folder"
            case .rightToLeft:
                "Review and move the selected right-only items to the left folder"
            }
        }()
    }
}
