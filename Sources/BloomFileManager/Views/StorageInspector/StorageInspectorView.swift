import SwiftUI

@MainActor
struct StorageInspectorView: View {
    let workspace: WorkspaceState
    let storage: StorageAnalysisStore
    let cleanupController: StorageCleanupController
    let quickLookController: QuickLookController
    let materializer: any CloudMaterializing
    let fileSystem: any FileSystemAccess
    let workspaceActions: any CloudLocationWorkspaceActions
    let operationController: FileOperationController
    let accessCoordinator: CloudLocationScopedAccessCoordinator

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var options = StorageScanOptions()
    @State private var resultsFocusRequestID: UUID?
    @State private var reviewError: String?
    @State private var cleanupAcknowledgementPresented = false

    init(
        workspace: WorkspaceState,
        storage: StorageAnalysisStore,
        cleanupController: StorageCleanupController,
        quickLookController: QuickLookController,
        materializer: any CloudMaterializing,
        fileSystem: any FileSystemAccess,
        workspaceActions: any CloudLocationWorkspaceActions,
        operationController: FileOperationController,
        accessCoordinator: CloudLocationScopedAccessCoordinator
    ) {
        self.workspace = workspace
        self.storage = storage
        self.cleanupController = cleanupController
        self.quickLookController = quickLookController
        self.materializer = materializer
        self.fileSystem = fileSystem
        self.workspaceActions = workspaceActions
        self.operationController = operationController
        self.accessCoordinator = accessCoordinator
        _resultsFocusRequestID = State(initialValue: UUID())
    }

    var body: some View {
        VStack(spacing: 0) {
            StorageInspectorToolbarView(
                storage: storage,
                options: $options,
                onExit: {
                    StorageInspectorCommandActions.exit(
                        workspace: workspace,
                        storage: storage
                    )
                }
            )

            HStack(spacing: 0) {
                StorageInspectorSidebarView(storage: storage)
                    .frame(width: 220)

                Divider()

                results
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .transaction { transaction in
            if reduceMotion {
                transaction.animation = nil
            }
        }
        .onChange(of: storage.section) {
            resultsFocusRequestID = UUID()
        }
        .sheet(item: pendingReview) { review in
            StorageCleanupReviewSheet(
                review: review,
                cleanupController: cleanupController,
                storage: storage,
                operationController: operationController,
                workspace: workspace,
                onDismiss: {
                    cleanupController.cancelReview()
                }
            )
        }
        .alert("Scan Protected Location?", isPresented: protectedRootIsPresented) {
            Button("Cancel", role: .cancel) {
                storage.cancelProtectedScanRequest()
            }
            Button("Scan Anyway") {
                Task { await storage.confirmProtectedScan(options: options) }
            }
        } message: {
            Text(
                "This location can contain protected system files. "
                    + "Review the results carefully before taking any cleanup action."
            )
        }
        .alert(
            "Enable Cleanup for Protected Location?",
            isPresented: $cleanupAcknowledgementPresented
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Enable Cleanup", role: .destructive) {
                storage.confirmProtectedCleanupAcknowledgement()
            }
        } message: {
            Text(
                "The scan warning did not authorize cleanup. "
                    + "Confirm again before changing Keep or Trash decisions."
            )
        }
        .accessibilityIdentifier(AccessibilityIdentifiers.storageInspectorWorkspace)
    }

    @ViewBuilder
    private var results: some View {
        if !StorageInspectorResultsPolicy.showsTable(
            phase: storage.phase,
            entryCount: storage.entries.count
        ) {
            ContentUnavailableView {
                Label(
                    storage.phase == .scanning || storage.phase == .verifying
                        ? StorageInspectorPresentation.phaseTitle(storage.phase)
                        : "No Storage Results",
                    systemImage: "internaldrive"
                )
            } description: {
                Text("Choose a local folder or external volume to begin an on-demand scan.")
            } actions: {
                if storage.phase == .scanning || storage.phase == .verifying {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Storage analysis in progress")
                        .accessibilityIdentifier(
                            AccessibilityIdentifiers.storageInspectorProgress
                        )
                }
            }
            .accessibilityIdentifier(AccessibilityIdentifiers.storageInspectorResults)
        } else if resultRows.isEmpty {
            ContentUnavailableView {
                Label(
                    "No \(StorageInspectorPresentation.sectionTitle(storage.section))",
                    systemImage: StorageInspectorPresentation.sectionSymbol(storage.section)
                )
            } description: {
                Text("This completed analysis has no results in the selected section.")
            }
            .accessibilityIdentifier(AccessibilityIdentifiers.storageInspectorResults)
        } else {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Label(
                        StorageInspectorPresentation.sectionTitle(storage.section),
                        systemImage: StorageInspectorPresentation.sectionSymbol(storage.section)
                    )

                    Text("\(resultRows.count) results")
                        .foregroundStyle(.secondary)

                    if storage.phase == .scanning || storage.phase == .verifying {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Storage analysis in progress")
                            .accessibilityIdentifier(
                                AccessibilityIdentifiers.storageInspectorProgress
                            )
                    }

                    Spacer()

                    if storage.cleanupAcknowledgementRequired
                        && !storage.canPerformCleanupActions {
                        Button("Enable Cleanup…") {
                            cleanupAcknowledgementPresented = true
                        }
                        .accessibilityLabel(
                            "Confirm cleanup for the protected storage location"
                        )
                        .accessibilityIdentifier(
                            "\(AccessibilityIdentifiers.storageInspectorReview).authorize"
                        )
                    }

                    if let reviewError {
                        Label(reviewError, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier(
                                "\(AccessibilityIdentifiers.storageInspectorResults).reviewWarning"
                            )
                    }

                    Button("Review Cleanup…") {
                        prepareReview()
                    }
                    .disabled(
                        storage.phase != .complete
                            || !hasTrashMarks
                            || !storage.canPerformCleanupActions
                            || operationController.isRunning
                    )
                    .accessibilityLabel(
                        hasTrashMarks
                            ? "Review explicitly marked Trash files"
                            : "No files are marked for Trash"
                    )
                    .accessibilityIdentifier(
                        "\(AccessibilityIdentifiers.storageInspectorReview).open"
                    )
                }
                .padding(.horizontal, 12)
                .frame(height: 40)
                .background(.bar)

                Divider()

                sectionSummaryBar

                Divider()

                HStack(spacing: 0) {
                    StorageResultsTableView(
                        rows: resultRows,
                        section: storage.section,
                        selection: selectedEntryIDs,
                        focusRequestID: resultsFocusRequestID,
                        reduceMotion: reduceMotion,
                        onQuickLook: quickLook
                    )
                    .frame(minWidth: 420)

                    Divider()

                    if let selectedDetail {
                        StorageInspectorDetailView(
                            entry: selectedDetail.entry,
                            row: selectedDetail.row,
                            storage: storage,
                            quickLookController: quickLookController,
                            materializer: materializer,
                            fileSystem: fileSystem,
                            workspaceActions: workspaceActions,
                            cleanupController: cleanupController,
                            operationController: operationController,
                            accessCoordinator: accessCoordinator
                        )
                    } else {
                        ContentUnavailableView(
                            "Select a Result",
                            systemImage: "doc.text.magnifyingglass",
                            description: Text(
                                "Choose one result to review its relative metadata and safe actions."
                            )
                        )
                        .frame(minWidth: 260, idealWidth: 310, maxWidth: 360)
                        .accessibilityLabel("No storage result selected")
                        .accessibilityIdentifier(AccessibilityIdentifiers.storageInspectorDetail)
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(AccessibilityIdentifiers.storageInspectorResults)
        }
    }

    @ViewBuilder
    private var sectionSummaryBar: some View {
        HStack(spacing: 16) {
            switch storage.section {
            case .overview:
                metric("Files", storage.overviewMetrics.fileCount)
                metric("Directories", storage.overviewMetrics.directoryCount)
                metric("Inaccessible", storage.overviewMetrics.inaccessibleCount)
                Text(
                    "Reclaimable "
                        + StorageInspectorPresentation.analyzedBytesTitle(
                            storage.overviewMetrics.reclaimableBytes
                        )
                )
            case .duplicates:
                Picker("Duplicate group", selection: selectedDuplicateGroupID) {
                    ForEach(
                        StorageInspectorPresentation.duplicateGroupSummaries(store: storage)
                    ) { summary in
                        Text(summary.title).tag(Optional(summary.id))
                    }
                }
                .pickerStyle(.menu)
                .accessibilityLabel("Choose a verified duplicate group")
                .accessibilityIdentifier(
                    AccessibilityIdentifiers.storageInspectorGroupNavigation
                )
            case .largeFiles:
                Menu(
                    "Minimum "
                        + StorageInspectorPresentation.analyzedBytesTitle(
                            storage.thresholds.largeFileBytes
                        )
                ) {
                    ForEach(StorageLargeFileThresholdPreset.allCases, id: \.self) { preset in
                        Button(
                            StorageInspectorPresentation.largeFileThresholdTitle(preset)
                        ) {
                            storage.thresholds.largeFileBytes = preset.bytes
                        }
                    }
                }
                Text("Sorted largest first")
                    .foregroundStyle(.secondary)
            case .longUnmodified:
                Menu("Older than \(storage.thresholds.longUnmodifiedDays) days") {
                    ForEach(StorageAgeThresholdPreset.allCases, id: \.self) { preset in
                        Button(StorageInspectorPresentation.ageThresholdTitle(preset)) {
                            storage.thresholds.longUnmodifiedDays = preset.days
                        }
                    }
                }
                Text("Regular files only")
                    .foregroundStyle(.secondary)
            case .fileTypes:
                ForEach(storage.fileTypeGroups) { group in
                    Text(
                        "\(StorageInspectorPresentation.categoryTitle(group.category)) "
                            + "\(group.entryCount), "
                            + StorageInspectorPresentation.analyzedBytesTitle(group.byteCount)
                    )
                    .accessibilityLabel(
                        "\(StorageInspectorPresentation.categoryTitle(group.category)), "
                            + "\(group.entryCount) entries, "
                            + StorageInspectorPresentation.analyzedBytesTitle(group.byteCount)
                    )
                    .accessibilityIdentifier(
                        AccessibilityIdentifiers.storageInspectorCategory(group.category)
                    )
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 38)
        .background(.background)
    }

    private func metric(_ title: String, _ value: Int) -> some View {
        Text("\(title) \(value)")
            .accessibilityLabel("\(title), \(value)")
    }

    private var protectedRootIsPresented: Binding<Bool> {
        Binding {
            storage.pendingProtectedRoot != nil
        } set: { isPresented in
            if !isPresented, storage.pendingProtectedRoot != nil {
                storage.cancelProtectedScanRequest()
            }
        }
    }

    private var pendingReview: Binding<StorageCleanupReview?> {
        Binding {
            cleanupController.pendingReview
        } set: { review in
            if review == nil {
                cleanupController.cancelReview()
            }
        }
    }

    private var resultRows: [StorageResultRow] {
        StorageInspectorPresentation.rows(
            section: storage.section,
            store: storage
        )
    }

    private var selectedEntryIDs: Binding<Set<StorageRelativePath>> {
        Binding {
            storage.selectedEntryIDs
        } set: {
            storage.selectedEntryIDs = $0
        }
    }

    private var selectedDuplicateGroupID: Binding<StorageDuplicateGroupID?> {
        Binding {
            storage.selectedDuplicateGroupID
        } set: {
            storage.selectedDuplicateGroupID = $0
            storage.selectedEntryIDs = []
            resultsFocusRequestID = UUID()
        }
    }

    private var selectedDetail: (entry: StorageEntry, row: StorageResultRow)? {
        guard storage.selectedEntryIDs.count == 1,
              let id = storage.selectedEntryIDs.first,
              let row = resultRows.first(where: { $0.id == id }),
              let entry = storage.entries.first(where: { $0.id == id })
        else {
            return nil
        }
        return (entry, row)
    }

    private var hasTrashMarks: Bool {
        storage.duplicateGroups.contains { !$0.trashIDs.isEmpty }
    }

    private func quickLook(_ id: StorageRelativePath) {
        guard let entry = storage.entries.first(where: { $0.id == id }) else { return }
        Task {
            await StorageInspectorItemActions.quickLook(
                entry: entry,
                controller: quickLookController,
                materializer: materializer,
                fileSystem: fileSystem,
                accessCoordinator: accessCoordinator
            )
        }
    }

    private func prepareReview() {
        reviewError = nil
        do {
            guard let admission = storage.currentAdmission else {
                throw StorageCleanupValidationError.staleReview
            }
            try cleanupController.prepareReview(
                generation: storage.currentGeneration,
                admission: admission,
                groups: storage.duplicateGroups,
                cleanupAuthorized: storage.canPerformCleanupActions
            )
        } catch {
            reviewError = "Cleanup review is unavailable. Recheck the marked copies."
        }
    }
}
