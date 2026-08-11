import Foundation

enum FileOperationJobKind: Sendable, Equatable {
    case copy
    case move
    case trash
    case createFolder
    case rename
    case compress(ArchiveFormat)
    case compressProtectedZIP
    case extract(ArchiveFormat)
    case undo

    var title: String {
        switch self {
        case .copy: "Copy"
        case .move: "Move"
        case .trash: "Move to Trash"
        case .createFolder: "Create Folder"
        case .rename: "Rename"
        case let .compress(format): "Compress \(format.displayName)"
        case .compressProtectedZIP: "Compress Encrypted ZIP"
        case let .extract(format): "Extract \(format.displayName)"
        case .undo: "Undo"
        }
    }
}

enum FileOperationJobState: Sendable, Equatable {
    case queued
    case running
    case waitingForPassword
    case pauseRequested
    case paused
    case succeeded
    case failed
    case cancelled

    var label: String {
        switch self {
        case .queued: "Queued"
        case .running: "Running"
        case .waitingForPassword: "Waiting for password"
        case .pauseRequested: "Pause requested"
        case .paused: "Paused"
        case .succeeded: "Completed"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }
}

struct FileOperationJobProgress: Sendable, Equatable {
    let completedCount: Int
    let totalCount: Int
    let detail: String

    var fractionCompleted: Double {
        let safeTotal = max(totalCount, 0)
        guard safeTotal > 0 else { return 0 }
        let safeCompleted = min(max(completedCount, 0), safeTotal)
        return Double(safeCompleted) / Double(safeTotal)
    }
}

struct FileOperationJobSnapshot: Identifiable, Sendable, Equatable {
    let id: UUID
    let kind: FileOperationJobKind
    let itemDisplayName: String
    let itemCount: Int
    let state: FileOperationJobState
    let progress: FileOperationJobProgress?
    private let retryEligible: Bool
    private let undoEligible: Bool

    init(
        id: UUID,
        kind: FileOperationJobKind,
        itemDisplayName: String,
        itemCount: Int,
        state: FileOperationJobState,
        progress: FileOperationJobProgress?,
        canUndo: Bool,
        canRetry: Bool = true
    ) {
        self.id = id
        self.kind = kind
        self.itemDisplayName = Self.safeBasename(itemDisplayName)
        self.itemCount = max(itemCount, 0)
        self.state = state
        self.progress = progress
        retryEligible = canRetry
        undoEligible = canUndo
    }

    var title: String {
        if kind == .rename, itemCount > 1 {
            return "Rename \(itemCount) Items"
        }
        return kind.title
    }

    var canRetry: Bool {
        retryEligible && kind != .undo && (state == .failed || state == .cancelled)
    }

    var isRetryEligible: Bool { retryEligible }

    var canUndo: Bool {
        state == .succeeded && undoEligible
    }

    var accessibilityLabel: String {
        let countLabel = itemCount == 1 ? "1 item" : "\(itemCount) items"
        let progressLabel = progress.map {
            ", \(min(max($0.completedCount, 0), max($0.totalCount, 0))) of \(max($0.totalCount, 0)), \($0.detail)"
        } ?? ""
        return "\(title), \(state.label), \(itemDisplayName), \(countLabel)\(progressLabel)"
    }

    private static func safeBasename(_ value: String) -> String {
        let withoutNewlines = value
            .components(separatedBy: .newlines)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !withoutNewlines.isEmpty else { return "Item" }
        let basename = URL(filePath: withoutNewlines).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return basename.isEmpty ? "Item" : basename
    }
}
