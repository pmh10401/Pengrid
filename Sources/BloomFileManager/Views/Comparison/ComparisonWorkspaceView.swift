import SwiftUI

@MainActor
final class ComparisonNavigationState {
    private struct PendingNavigation {
        let id: UUID
        let task: Task<Void, Never>
    }

    private var pending: [PaneID: PendingNavigation] = [:]

    var isNavigating: Bool { !pending.isEmpty }

    func navigate(
        side: PaneID,
        comparison: ComparisonCoordinator,
        currentRoot: @escaping @MainActor () -> URL,
        operation: @escaping @MainActor () async -> Void,
        restart: @escaping @MainActor () -> Void
    ) {
        guard comparison.isActive, let capturedSession = comparison.session else { return }
        let capturedRoot = currentRoot()
        let requestID = UUID()

        cancel(side: side)
        let task = Task { @MainActor [weak self, weak comparison] in
            await operation()
            guard let self else { return }
            defer { finish(side: side, requestID: requestID) }
            guard !Task.isCancelled,
                  pending[side]?.id == requestID,
                  let comparison,
                  comparison.isActive,
                  comparison.session == capturedSession,
                  comparison.session?.generation == capturedSession.generation,
                  currentRoot() != capturedRoot
            else { return }
            restart()
        }
        pending[side] = PendingNavigation(id: requestID, task: task)
    }

    func cancelAll() {
        let tasks = pending.values.map(\.task)
        pending.removeAll()
        tasks.forEach { $0.cancel() }
    }

    private func cancel(side: PaneID) {
        let task = pending.removeValue(forKey: side)?.task
        task?.cancel()
    }

    private func finish(side: PaneID, requestID: UUID) {
        guard pending[side]?.id == requestID else { return }
        pending.removeValue(forKey: side)
    }
}

struct ComparisonWorkspaceView: View {
    let workspace: WorkspaceState
    let comparison: ComparisonCoordinator
    let operationController: FileOperationController
    let searchPresented: Bool
    let batchRenamePresented: Bool
    let trashPresented: Bool
    let profilesPresented: Bool
    @Binding var modalPresentationState: WorkspaceModalPresentationState
    @State private var navigation = ComparisonNavigationState()
    @State private var tableFocusRequestID: UUID?

    var body: some View {
        @Bindable var comparison = comparison

        VStack(spacing: 0) {
            ComparisonToolbarView(
                workspace: workspace,
                comparison: comparison,
                onExit: {
                    navigation.cancelAll()
                    ComparisonCommandActions.exit(
                        workspace: workspace,
                        comparison: comparison
                    )
                }
            )

            HStack(spacing: 0) {
                ComparisonNavigationHeader(
                    side: .left,
                    pane: workspace.left,
                    workspace: workspace,
                    comparison: comparison,
                    navigation: navigation
                )
                .frame(maxWidth: .infinity)

                Text("Aligned Status")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 210)
                    .accessibilityLabel("Comparison status column")
                    .accessibilityIdentifier(AccessibilityIdentifiers.comparisonStatusRail)

                ComparisonNavigationHeader(
                    side: .right,
                    pane: workspace.right,
                    workspace: workspace,
                    comparison: comparison,
                    navigation: navigation
                )
                .frame(maxWidth: .infinity)
            }
            .frame(height: 38)
            .background(.regularMaterial)
            .overlay(alignment: .bottom) { Divider() }

            ComparisonTableView(
                rows: comparison.visibleRows,
                selection: $comparison.selection,
                focusRequestID: tableFocusRequestID
            )

            ComparisonActionBar(
                workspace: workspace,
                comparison: comparison,
                operationController: operationController
            )
        }
        .background(.regularMaterial)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Folder comparison")
        .accessibilityIdentifier(AccessibilityIdentifiers.comparisonWorkspace)
        .onAppear {
            if tableFocusRequestID == nil {
                tableFocusRequestID = UUID()
            }
        }
        .onDisappear {
            navigation.cancelAll()
        }
        .sheet(item: moveConfirmationBinding) { confirmation in
            ComparisonMoveConfirmationSheet(
                comparison: comparison,
                initialConfirmation: confirmation,
                onCancel: { comparison.cancelMove() },
                onConfirm: {
                    comparison.confirmMove(
                        operationController: operationController,
                        workspace: workspace
                    )
                }
            )
        }
        .sheet(isPresented: synchronizationReviewBinding) {
            FolderSynchronizationReviewSheet(
                comparison: comparison,
                operationController: operationController,
                workspace: workspace,
                onCancel: { comparison.cancelFolderSynchronizationReview() },
                onConfirm: {
                    comparison.confirmFolderSynchronizationReview(
                        operationController: operationController,
                        workspace: workspace
                    )
                }
            )
            .onAppear { modalPresentationState.synchronizationReviewSheetDidAppear() }
            .onDisappear { modalPresentationState.synchronizationReviewSheetDidDisappear() }
        }
    }

    private var synchronizationReviewBinding: Binding<Bool> {
        Binding(
            get: {
                guard comparison.folderSynchronizationReview != .idle else { return false }
                return modalPresentationState.allowsSynchronizationReviewPresentation(
                    conflictPresented: operationController.pendingConflict != nil,
                    searchPresented: searchPresented,
                    batchRenamePresented: batchRenamePresented,
                    passwordPresented: modalPresentationState.presentedPasswordRequestID != nil,
                    selectionFolderPresented: modalPresentationState.isSelectionFolderPresented
                ) && !trashPresented && !profilesPresented
                    || modalPresentationState.isSynchronizationReviewPresented
            },
            set: { isPresented in
                if !isPresented, comparison.folderSynchronizationReview != .idle {
                    comparison.cancelFolderSynchronizationReview()
                }
            }
        )
    }

    private var moveConfirmationBinding: Binding<ComparisonMoveConfirmation?> {
        Binding(
            get: { comparison.pendingMoveConfirmation },
            set: { value in
                if value == nil, comparison.pendingMoveConfirmation != nil {
                    comparison.cancelMove()
                }
            }
        )
    }
}

private struct ComparisonMoveConfirmationSheet: View {
    let comparison: ComparisonCoordinator
    let initialConfirmation: ComparisonMoveConfirmation
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.title2.weight(.semibold))

            Text(summary)

            if !confirmation.representativeNames.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Items")
                        .font(.headline)
                    ForEach(
                        Array(confirmation.representativeNames.enumerated()),
                        id: \.offset
                    ) { _, name in
                        Text(name)
                            .lineLimit(1)
                    }
                    if confirmation.requests.count > confirmation.representativeNames.count {
                        Text("and \(confirmation.requests.count - confirmation.representativeNames.count) more")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            rootRow(label: "Source", url: confirmation.sourceRoot)
            rootRow(label: "Destination", url: confirmation.destinationRoot)

            volumeMessage
                .font(.callout)
                .foregroundStyle(confirmation.crossesVolumes == true ? .orange : .secondary)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Move", role: .destructive, action: onConfirm)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(minWidth: 520)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Move confirmation")
        .accessibilityIdentifier(AccessibilityIdentifiers.comparisonMoveConfirmation)
    }

    private var title: String {
        switch confirmation.direction {
        case .leftToRight: "Move Left to Right?"
        case .rightToLeft: "Move Right to Left?"
        }
    }

    private var confirmation: ComparisonMoveConfirmation {
        guard comparison.pendingMoveConfirmation?.id == initialConfirmation.id else {
            return initialConfirmation
        }
        return comparison.pendingMoveConfirmation ?? initialConfirmation
    }

    private var summary: String {
        let count = confirmation.requests.count
        return count == 1
            ? "Review this item before moving it."
            : "Review these \(count) items before moving them."
    }

    @ViewBuilder
    private func rootRow(label: String, url: URL) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.headline)
            Text(url.path)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var volumeMessage: some View {
        switch confirmation.crossesVolumes {
        case .some(true):
            Label(
                "This move crosses volumes. \(AppIdentity.displayName) verifies the copy before removing each source item.",
                systemImage: "exclamationmark.triangle.fill"
            )
        case .some(false):
            Label("Source and destination are on the same volume.", systemImage: "internaldrive")
        case nil:
            Label(
                "Volume relationship is being checked. \(AppIdentity.displayName) will use the safest supported move path.",
                systemImage: "hourglass"
            )
        }
    }
}

private struct ComparisonNavigationHeader: View {
    let side: PaneID
    let pane: FilePaneState
    let workspace: WorkspaceState
    let comparison: ComparisonCoordinator
    let navigation: ComparisonNavigationState

    var body: some View {
        HStack(spacing: 6) {
            Button {
                workspace.activate(side)
                navigate { await pane.goBack() }
            } label: {
                Image(systemName: "chevron.left")
                    .accessibilityHidden(true)
            }
            .buttonStyle(.borderless)
            .disabled(!pane.canGoBack)
            .help("Back")
            .accessibilityLabel("Back")

            Button {
                workspace.activate(side)
                navigate { await pane.goForward() }
            } label: {
                Image(systemName: "chevron.right")
                    .accessibilityHidden(true)
            }
            .buttonStyle(.borderless)
            .disabled(!pane.canGoForward)
            .help("Forward")
            .accessibilityLabel("Forward")

            Button {
                workspace.activate(side)
                navigate { await pane.goToParent() }
            } label: {
                Image(systemName: "arrow.up")
                    .accessibilityHidden(true)
            }
            .buttonStyle(.borderless)
            .disabled(pane.currentDirectory.deletingLastPathComponent() == pane.currentDirectory)
            .help("Parent Folder")
            .accessibilityLabel("Parent Folder")

            Text(pane.currentDirectory.path)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(side == .left ? "Left folder" : "Right folder")
                .accessibilityValue(pane.currentDirectory.path)
        }
        .padding(.horizontal, 8)
    }

    private func navigate(_ operation: @escaping @MainActor () async -> Void) {
        navigation.navigate(
            side: side,
            comparison: comparison,
            currentRoot: { pane.currentDirectory },
            operation: operation,
            restart: { comparison.rootsDidChange(workspace: workspace) }
        )
    }
}
