import AppKit
import SwiftUI

struct WorkspaceSplitView<Left: View, Right: View>: NSViewRepresentable {
    @Binding var ratio: Double
    let left: Left
    let right: Right

    init(
        ratio: Binding<Double>,
        @ViewBuilder left: () -> Left,
        @ViewBuilder right: () -> Right
    ) {
        _ratio = ratio
        self.left = left()
        self.right = right()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(ratio: $ratio)
    }

    func makeNSView(context: Context) -> NSSplitView {
        let splitView = NSSplitView()
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = context.coordinator
        splitView.addArrangedSubview(NSHostingView(rootView: left))
        splitView.addArrangedSubview(NSHostingView(rootView: right))
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 1)
        return splitView
    }

    func updateNSView(_ splitView: NSSplitView, context: Context) {
        context.coordinator.ratio = $ratio
        let clampedRatio = WorkspaceSplitRatio.clamped(ratio)
        context.coordinator.normalizeBinding(from: ratio, to: clampedRatio)

        if let leftHost = splitView.arrangedSubviews.first as? NSHostingView<Left> {
            leftHost.rootView = left
        }
        if let rightHost = splitView.arrangedSubviews.last as? NSHostingView<Right> {
            rightHost.rootView = right
        }

        splitView.layoutSubtreeIfNeeded()
        let availableWidth = splitView.bounds.width - splitView.dividerThickness
        guard availableWidth > 0 else { return }
        let actualRatio = splitView.arrangedSubviews[0].frame.width / availableWidth
        guard abs(actualRatio - clampedRatio) > 0.001 else { return }

        context.coordinator.isApplyingRatio = true
        splitView.setPosition(availableWidth * clampedRatio, ofDividerAt: 0)
        context.coordinator.isApplyingRatio = false
    }

    @MainActor
    final class Coordinator: NSObject, NSSplitViewDelegate {
        var ratio: Binding<Double>
        var isApplyingRatio = false
        private var normalizationTask: Task<Void, Never>?

        init(ratio: Binding<Double>) {
            self.ratio = ratio
        }

        @discardableResult
        func normalizeBinding(from currentRatio: Double, to normalizedRatio: Double) -> Task<Void, Never>? {
            guard currentRatio != normalizedRatio else { return nil }
            normalizationTask?.cancel()
            let task = Task { @MainActor [weak self] in
                await Task.yield()
                guard !Task.isCancelled,
                      let self,
                      ratio.wrappedValue == currentRatio
                else { return }
                ratio.wrappedValue = normalizedRatio
            }
            normalizationTask = task
            return task
        }

        func splitView(
            _ splitView: NSSplitView,
            constrainSplitPosition proposedPosition: CGFloat,
            ofSubviewAt dividerIndex: Int
        ) -> CGFloat {
            guard dividerIndex == 0 else { return proposedPosition }
            let availableWidth = splitView.bounds.width - splitView.dividerThickness
            guard availableWidth > 0 else { return proposedPosition }
            return availableWidth * WorkspaceSplitRatio.clamped(proposedPosition / availableWidth)
        }

        func splitViewDidResizeSubviews(_ notification: Notification) {
            guard !isApplyingRatio,
                  let splitView = notification.object as? NSSplitView,
                  splitView.arrangedSubviews.count == 2
            else { return }

            let availableWidth = splitView.bounds.width - splitView.dividerThickness
            guard availableWidth > 0 else { return }
            let updatedRatio = WorkspaceSplitRatio.clamped(
                splitView.arrangedSubviews[0].frame.width / availableWidth
            )
            if abs(ratio.wrappedValue - updatedRatio) > 0.001 {
                ratio.wrappedValue = updatedRatio
            }
        }
    }
}
