import SwiftUI

struct FileOperationCenterPresentation: Equatable, Sendable {
    let hasActiveJob: Bool
    let queuedCount: Int
    let recentCount: Int
    let isQueueBlockedByRecovery: Bool

    init(
        activeJob: FileOperationJobSnapshot?,
        queuedCount: Int,
        recentCount: Int,
        isQueueBlockedByRecovery: Bool
    ) {
        hasActiveJob = activeJob != nil
        self.queuedCount = max(queuedCount, 0)
        self.recentCount = max(recentCount, 0)
        self.isQueueBlockedByRecovery = isQueueBlockedByRecovery
    }

    var isVisible: Bool {
        isQueueBlockedByRecovery || hasActiveJob || queuedCount > 0 || recentCount > 0
    }

    var compactLabel: String {
        if isQueueBlockedByRecovery {
            return "Recovery attention"
        }
        if hasActiveJob {
            return queuedCount == 0 ? "1 active" : "1 active, \(queuedCount) queued"
        }
        if queuedCount > 0 {
            return "\(queuedCount) queued"
        }
        return "Recent: \(recentCount)"
    }

    var accessibilityLabel: String {
        "Operation center, "
            + (isQueueBlockedByRecovery ? "recovery attention required, " : "")
            + "\(hasActiveJob ? 1 : 0) active operation, "
            + "\(queuedCount) queued operations, \(recentCount) recent operations"
    }
}

struct FileOperationCenterView: View {
    let controller: FileOperationController

    @State private var isPresented = false
    @State private var expandedHistory: Set<UUID> = []
    @AccessibilityFocusState private var focusedQueuedJobID: UUID?

    private var presentation: FileOperationCenterPresentation {
        FileOperationCenterPresentation(
            activeJob: controller.activeJob,
            queuedCount: controller.queuedJobs.count,
            recentCount: controller.operationHistory.count,
            isQueueBlockedByRecovery: controller.isQueueBlockedByRecovery
        )
    }

    var body: some View {
        if presentation.isVisible {
            Button {
                isPresented.toggle()
            } label: {
                Label(presentation.compactLabel, systemImage: "list.bullet.rectangle")
                    .font(.caption)
                    .lineLimit(1)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
            .accessibilityLabel(presentation.accessibilityLabel)
            .accessibilityIdentifier(AccessibilityIdentifiers.operationCenter)
            .help("Show file operations")
            .popover(isPresented: $isPresented, arrowEdge: .top) {
                operationCenter
            }
        }
    }

    private var operationCenter: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("File Operations")
                .font(.headline)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if controller.isQueueBlockedByRecovery {
                        recoverySection
                    }

                    if let activeJob = controller.activeJob {
                        section("Active", identifier: AccessibilityIdentifiers.operationCenterActive) {
                            activeRow(activeJob)
                        }
                    }

                    if !controller.queuedJobs.isEmpty {
                        section(
                            "Queue (\(controller.queuedJobs.count))",
                            identifier: AccessibilityIdentifiers.operationCenterQueue
                        ) {
                            ForEach(Array(controller.queuedJobs.enumerated()), id: \.element.id) {
                                index, job in
                                queuedRow(job, index: index)
                            }
                        }
                    }

                    if !controller.operationHistory.isEmpty {
                        section(
                            "Recent",
                            identifier: AccessibilityIdentifiers.operationCenterHistory
                        ) {
                            ForEach(controller.operationHistory) { job in
                                historyRow(job)
                            }
                        }
                    }
                }
                .padding(14)
            }
        }
        .frame(width: 390, height: 430)
        .accessibilityLabel("File operation center")
    }

    private var recoverySection: some View {
        section(
            "Attention",
            identifier: AccessibilityIdentifiers.operationCenterRecovery
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Text("A file operation needs recovery review. Waiting jobs will not start automatically.")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Continue Queue", systemImage: "play.fill") {
                    controller.continueAfterRecovery()
                }
                .controlSize(.small)
                .accessibilityLabel("Continue file operation queue after recovery review")
                .accessibilityIdentifier(
                    AccessibilityIdentifiers.operationCenterContinueAfterRecovery
                )
                .help("Continue waiting operations after reviewing recovery guidance")
            }
            .padding(10)
            .background(.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func section<Content: View>(
        _ title: String,
        identifier: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier(identifier)
    }

    private func activeRow(_ job: FileOperationJobSnapshot) -> some View {
        jobCard(job) {
            HStack(spacing: 8) {
                if job.state == .paused || job.state == .pauseRequested {
                    Button("Resume", systemImage: "play.fill") {
                        Task { await controller.resumeActiveJob() }
                    }
                    .accessibilityLabel("Resume active file operation")
                    .accessibilityIdentifier(AccessibilityIdentifiers.operationCenterResume)
                    .help("Resume the active file operation")
                } else {
                    Button("Pause", systemImage: "pause.fill") {
                        Task { await controller.pauseActiveJob() }
                    }
                    .accessibilityLabel("Pause active file operation")
                    .accessibilityIdentifier(AccessibilityIdentifiers.operationCenterPause)
                    .help("Pause at the next safe file boundary")
                }

                Button("Cancel", systemImage: "xmark") {
                    controller.cancelActiveJob()
                }
                .accessibilityLabel("Cancel active file operation")
                .accessibilityIdentifier(AccessibilityIdentifiers.operationCenterCancelActive)
                .help("Cancel after safe cleanup")
            }
            .controlSize(.small)
        }
    }

    private func queuedRow(_ job: FileOperationJobSnapshot, index: Int) -> some View {
        jobCard(job) {
            HStack(spacing: 8) {
                Button("Up", systemImage: "arrow.up") {
                    controller.moveQueuedJob(job.id, by: -1)
                    focusedQueuedJobID = job.id
                }
                .disabled(index == 0)
                .accessibilityLabel("Move \(job.itemDisplayName) earlier in queue")
                .accessibilityIdentifier(AccessibilityIdentifiers.operationCenterMoveQueuedUp)
                .help("Move this operation earlier")

                Button("Down", systemImage: "arrow.down") {
                    controller.moveQueuedJob(job.id, by: 1)
                    focusedQueuedJobID = job.id
                }
                .disabled(index == controller.queuedJobs.count - 1)
                .accessibilityLabel("Move \(job.itemDisplayName) later in queue")
                .accessibilityIdentifier(
                    AccessibilityIdentifiers.operationCenterMoveQueuedDown
                )
                .help("Move this operation later")

                Button("Remove", systemImage: "xmark") {
                    let remaining = controller.queuedJobs.filter { $0.id != job.id }
                    let nextFocus = remaining.indices.contains(min(index, remaining.count - 1))
                        ? remaining[min(index, remaining.count - 1)].id
                        : nil
                    if controller.cancelQueuedJob(job.id) {
                        focusedQueuedJobID = nextFocus
                    }
                }
                .accessibilityLabel("Remove \(job.itemDisplayName) from queue")
                .accessibilityIdentifier(AccessibilityIdentifiers.operationCenterCancelQueued)
                .help("Remove this operation from the queue")
            }
            .controlSize(.small)
        }
        .accessibilityFocused($focusedQueuedJobID, equals: job.id)
    }

    private func historyRow(_ job: FileOperationJobSnapshot) -> some View {
        jobCard(job) {
            HStack(spacing: 8) {
                if job.canRetry {
                    Button("Retry", systemImage: "arrow.clockwise") {
                        controller.retryJob(job.id)
                    }
                    .accessibilityLabel("Retry \(job.title)")
                    .accessibilityIdentifier(AccessibilityIdentifiers.operationCenterRetry)
                    .help("Queue a new attempt")
                }
                if job.canUndo {
                    Button("Undo", systemImage: "arrow.uturn.backward") {
                        controller.undoJob(job.id)
                    }
                    .accessibilityLabel("Undo \(job.title)")
                    .accessibilityIdentifier(AccessibilityIdentifiers.operationCenterUndo)
                    .help("Undo only if the files are still unchanged")
                }
                Button("Details", systemImage: "info.circle") {
                    if expandedHistory.contains(job.id) {
                        expandedHistory.remove(job.id)
                    } else {
                        expandedHistory.insert(job.id)
                    }
                }
                .accessibilityLabel("Show details for \(job.title)")
                .accessibilityIdentifier(AccessibilityIdentifiers.operationCenterDetails)
                .help("Show privacy-safe operation details")
            }
            .controlSize(.small)

            if expandedHistory.contains(job.id) {
                Text(historyDetail(for: job))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(historyDetail(for: job))
            }
        }
    }

    private func historyDetail(for job: FileOperationJobSnapshot) -> String {
        let count = job.itemCount == 1 ? "1 item" : "\(job.itemCount) items"
        if job.state == .succeeded {
            return job.canUndo
                ? "\(count). Undo is available while every item remains unchanged."
                : "\(count). Undo is unavailable because this operation cannot be safely reversed."
        }
        if job.state == .failed || job.state == .cancelled {
            return job.canRetry
                ? "\(count). A new identity-checked attempt is available."
                : "\(count). Retry is unavailable because repeating the whole operation could duplicate or conflict with completed changes."
        }
        return count
    }

    private func jobCard<Actions: View>(
        _ job: FileOperationJobSnapshot,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(job.title)
                        .font(.subheadline.weight(.medium))
                    Text(job.itemDisplayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Text(job.state.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let progress = job.progress {
                HStack(spacing: 8) {
                    if progress.totalCount > 0 {
                        ProgressView(value: progress.fractionCompleted, total: 1)
                    } else if job.state == .running {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(progress.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(job.accessibilityLabel)
            }

            actions()
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(job.accessibilityLabel)
    }
}
