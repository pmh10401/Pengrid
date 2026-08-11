import Foundation
import Observation

enum BatchRenameLocationCapability: Sendable, Equatable {
    case writable
    case readOnly
    case unknown
}

enum BatchRenameModelPhase: Sendable, Equatable {
    case idle
    case capturing
    case planning
    case ready
    case executing
    case failed(String)
}

enum BatchRenameValidationSummary: Sendable, Equatable {
    case preparing
    case ready(changedCount: Int, totalCount: Int)
    case noChanges
    case invalid(count: Int, message: String)
    case unavailable(String)

    var invalidCount: Int {
        guard case let .invalid(count, _) = self else { return 0 }
        return count
    }

    var message: String {
        switch self {
        case .preparing:
            "Preparing preview…"
        case let .ready(changedCount, totalCount):
            "\(changedCount) of \(totalCount) items will be renamed."
        case .noChanges:
            "The current rule does not change any selected name."
        case let .invalid(_, message), let .unavailable(message):
            message
        }
    }
}

typealias BatchRenamePreviewGenerator = @Sendable (
    BatchRenamePlanningRequest,
    BatchRenameRule,
    Set<String>,
    FilenameComparisonPolicy
) async throws -> BatchRenamePreview

@MainActor @Observable
final class BatchRenameModel {
    private struct Capture: Sendable {
        let request: BatchRenamePlanningRequest
        let occupiedNames: Set<String>
        let comparisonPolicy: FilenameComparisonPolicy
    }

    private(set) var isPresented = false
    private(set) var phase: BatchRenameModelPhase = .idle
    private(set) var preview = BatchRenamePreview(entries: [], plan: nil)
    private(set) var validationSummary: BatchRenameValidationSummary = .preparing
    private(set) var rule: BatchRenameRule = .prefix("")

    var canSubmit: Bool {
        isPresented && phase == .ready && preview.plan != nil
    }

    @ObservationIgnored private let fileSystem: any FileSystemAccess
    @ObservationIgnored private let accessCoordinator: CloudLocationScopedAccessCoordinator
    @ObservationIgnored private let previewGenerator: BatchRenamePreviewGenerator
    @ObservationIgnored private var capture: Capture?
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var generation: UInt64 = 0

    init(
        fileSystem: any FileSystemAccess = LiveFileSystemAccess(),
        accessCoordinator: CloudLocationScopedAccessCoordinator = .init(),
        previewGenerator: @escaping BatchRenamePreviewGenerator = BatchRenameModel.livePreview
    ) {
        self.fileSystem = fileSystem
        self.accessCoordinator = accessCoordinator
        self.previewGenerator = previewGenerator
    }

    nonisolated static func livePreview(
        _ request: BatchRenamePlanningRequest,
        _ rule: BatchRenameRule,
        _ occupiedNames: Set<String>,
        _ comparisonPolicy: FilenameComparisonPolicy
    ) async throws -> BatchRenamePreview {
        try Task.checkCancellation()
        let value = try BatchRenamePlanner.preview(
            request: request,
            rule: rule,
            occupiedNames: occupiedNames,
            comparisonPolicy: comparisonPolicy
        )
        try Task.checkCancellation()
        return value
    }

    func present(
        items: [FileItem],
        in parentURL: URL,
        capability: BatchRenameLocationCapability = .writable
    ) async {
        resetTransientStateForPresentation()
        isPresented = true
        phase = .capturing
        validationSummary = .preparing
        let presentationGeneration = generation

        switch capability {
        case .writable:
            break
        case .readOnly:
            failPresentation("This location does not allow local file operations.")
            return
        case .unknown:
            failPresentation("Pengrid could not verify that this location supports renaming.")
            return
        }

        guard items.count >= 2 else {
            failPresentation("Select at least two items to rename.")
            return
        }
        let parent = parentURL.standardizedFileURL
        guard items.allSatisfy({
            $0.url.deletingLastPathComponent().standardizedFileURL == parent
        }) else {
            failPresentation("Every selected item must be in the same folder.")
            return
        }

        let leases: [CloudLocationScopedAccessLease]
        do {
            leases = try accessCoordinator.acquireAccess(
                for: [parentURL] + items.map(\.url)
            )
        } catch {
            failPresentation(error.localizedDescription)
            return
        }
        defer { leases.forEach { $0.finish() } }

        do {
            let parentIdentity = try await fileSystem.identity(of: parentURL)
            guard presentationGeneration == generation, isPresented else { return }
            guard let parentIdentity else {
                failPresentation("The containing folder is no longer available.")
                return
            }
            let comparisonPolicy = try await fileSystem.filenameComparisonPolicy(in: parentURL)
            guard presentationGeneration == generation, isPresented else { return }
            let occupiedNames = try await fileSystem.names(in: parentURL)
            guard presentationGeneration == generation, isPresented else { return }

            var sources: [BatchRenameSource] = []
            sources.reserveCapacity(items.count)
            for item in items {
                try Task.checkCancellation()
                guard let identity = try await fileSystem.identity(of: item.url) else {
                    failPresentation("\(item.name) is no longer available.")
                    return
                }
                guard presentationGeneration == generation, isPresented else { return }
                sources.append(BatchRenameSource(
                    url: item.url,
                    identity: identity,
                    name: item.name,
                    isDirectory: item.isDirectory,
                    isPackage: item.isPackage
                ))
            }

            capture = Capture(
                request: BatchRenamePlanningRequest(
                    parentURL: parentURL,
                    parentIdentity: parentIdentity,
                    sources: sources
                ),
                occupiedNames: occupiedNames,
                comparisonPolicy: comparisonPolicy
            )
            schedulePreview()
        } catch is CancellationError {
            guard presentationGeneration == generation else { return }
            dismiss()
        } catch {
            guard presentationGeneration == generation, isPresented else { return }
            failPresentation(error.localizedDescription)
        }
    }

    func updateRule(_ newRule: BatchRenameRule) {
        guard isPresented, phase != .executing else { return }
        rule = newRule
        schedulePreview()
    }

    func beginSubmission() -> BatchRenamePlan? {
        guard canSubmit, let plan = preview.plan else { return nil }
        generation &+= 1
        previewTask?.cancel()
        previewTask = nil
        phase = .executing
        return plan
    }

    func finishSubmission(didStart: Bool) {
        guard phase == .executing else { return }
        if didStart {
            dismiss()
        } else {
            let message = "The rename operation could not be started."
            phase = .failed(message)
            validationSummary = .unavailable(message)
        }
    }

    func cancel() {
        dismiss()
    }

    func dismiss() {
        generation &+= 1
        previewTask?.cancel()
        previewTask = nil
        capture = nil
        preview = BatchRenamePreview(entries: [], plan: nil)
        validationSummary = .preparing
        isPresented = false
        phase = .idle
    }

    private func resetTransientStateForPresentation() {
        generation &+= 1
        previewTask?.cancel()
        previewTask = nil
        capture = nil
        preview = BatchRenamePreview(entries: [], plan: nil)
        validationSummary = .preparing
        rule = .prefix("")
        phase = .idle
    }

    private func schedulePreview() {
        guard let capture, isPresented, phase != .executing else { return }
        generation &+= 1
        let previewGeneration = generation
        previewTask?.cancel()
        phase = .planning
        validationSummary = .preparing
        let rule = self.rule
        let generator = previewGenerator
        let worker = Task.detached(priority: .userInitiated) {
            try await generator(
                capture.request,
                rule,
                capture.occupiedNames,
                capture.comparisonPolicy
            )
        }
        previewTask = Task { [weak self] in
            let result = await withTaskCancellationHandler {
                await worker.result
            } onCancel: {
                worker.cancel()
            }
            guard let self,
                  !Task.isCancelled,
                  previewGeneration == generation,
                  isPresented,
                  phase != .executing
            else { return }

            switch result {
            case let .success(preview):
                self.preview = preview
                validationSummary = Self.summary(for: preview)
                phase = .ready
            case let .failure(error as BatchRenamePlanningError):
                self.preview = BatchRenamePreview(entries: [], plan: nil)
                validationSummary = Self.summary(for: error, itemCount: capture.request.sources.count)
                phase = .ready
            case let .failure(error as CancellationError):
                _ = error
            case let .failure(error):
                let message = error.localizedDescription
                self.preview = BatchRenamePreview(entries: [], plan: nil)
                validationSummary = .unavailable(message)
                phase = .failed(message)
            }
        }
    }

    private func failPresentation(_ message: String) {
        previewTask?.cancel()
        previewTask = nil
        capture = nil
        preview = BatchRenamePreview(entries: [], plan: nil)
        validationSummary = .unavailable(message)
        phase = .failed(message)
    }

    private static func summary(
        for preview: BatchRenamePreview
    ) -> BatchRenameValidationSummary {
        if let plan = preview.plan {
            return .ready(
                changedCount: plan.entries.count,
                totalCount: preview.entries.count
            )
        }
        let invalidNames = preview.entries.count { entry in
            if case .invalidName = entry.status { return true }
            return false
        }
        let duplicates = preview.entries.count { $0.status == .duplicate }
        let occupied = preview.entries.count { $0.status == .occupied }
        let invalidCount = invalidNames + duplicates + occupied
        guard invalidCount > 0 else { return .noChanges }
        if invalidNames == invalidCount {
            return .invalid(
                count: invalidCount,
                message: invalidCount == 1 ? "1 name is invalid." : "\(invalidCount) names are invalid."
            )
        }
        if duplicates == invalidCount {
            return .invalid(
                count: invalidCount,
                message: invalidCount == 1
                    ? "1 name duplicates another result."
                    : "\(invalidCount) names duplicate another result."
            )
        }
        if occupied == invalidCount {
            return .invalid(
                count: invalidCount,
                message: invalidCount == 1
                    ? "1 name is already in use."
                    : "\(invalidCount) names are already in use."
            )
        }
        return .invalid(count: invalidCount, message: "\(invalidCount) names need attention.")
    }

    private static func summary(
        for error: BatchRenamePlanningError,
        itemCount: Int
    ) -> BatchRenameValidationSummary {
        switch error {
        case .emptyFindText:
            .invalid(count: itemCount, message: "Enter text to find.")
        case .invalidSequence:
            .invalid(count: itemCount, message: "Enter a valid sequence name and number.")
        case .selectionTooSmall:
            .unavailable("Select at least two items to rename.")
        case .mixedParents:
            .unavailable("Every selected item must be in the same folder.")
        case .proposedNameCountMismatch:
            .unavailable("The preview could not be generated safely.")
        }
    }
}
