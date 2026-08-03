import SwiftUI

struct FileOperationCenterPresentation: Equatable, Sendable {
    let hasActiveJob: Bool
    let queuedCount: Int
    let recentCount: Int

    init(
        activeJob: FileOperationJobSnapshot?,
        queuedCount: Int,
        recentCount: Int
    ) {
        hasActiveJob = activeJob != nil
        self.queuedCount = max(queuedCount, 0)
        self.recentCount = max(recentCount, 0)
    }

    var isVisible: Bool {
        hasActiveJob || queuedCount > 0 || recentCount > 0
    }

    var compactLabel: String {
        if hasActiveJob {
            return queuedCount == 0 ? "1 active" : "1 active, \(queuedCount) queued"
        }
        if queuedCount > 0 {
            return "\(queuedCount) queued"
        }
        return "Recent: \(recentCount)"
    }

    var accessibilityLabel: String {
        "Operation center, \(hasActiveJob ? 1 : 0) active operation, "
            + "\(queuedCount) queued operations, \(recentCount) recent operations"
    }
}

struct FileOperationCenterView: View {
    let controller: FileOperationController

    @State private var isPresented = false

    private var presentation: FileOperationCenterPresentation {
        FileOperationCenterPresentation(
            activeJob: controller.activeJob,
            queuedCount: controller.queuedJobs.count,
            recentCount: controller.operationHistory.count
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
                            ForEach(controller.queuedJobs) { job in
                                queuedRow(job)
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
                if job.state == .paused {
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

    private func queuedRow(_ job: FileOperationJobSnapshot) -> some View {
        jobCard(job) {
            Button("Remove", systemImage: "xmark") {
                controller.cancelQueuedJob(job.id)
            }
            .controlSize(.small)
            .accessibilityLabel("Remove \(job.itemDisplayName) from queue")
            .accessibilityIdentifier(AccessibilityIdentifiers.operationCenterCancelQueued)
            .help("Remove this operation from the queue")
        }
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
            }
            .controlSize(.small)
        }
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
