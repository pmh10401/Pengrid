import Foundation

struct StorageResultRow: Identifiable, Equatable {
    let id: StorageRelativePath
    let name: String
    let relativeParent: String
    let sizeText: String
    let modifiedText: String
    let categoryText: String
    let verificationText: String
    let accessibilityLabel: String
}

struct StorageDuplicateGroupSummary: Identifiable, Equatable {
    let id: StorageDuplicateGroupID
    let title: String
    let memberCount: Int
    let memberIDs: [StorageRelativePath]
    let reclaimableBytes: Int64
}

enum StorageInspectorResultsPolicy {
    static func showsTable(
        phase _: StorageAnalysisPhase,
        entryCount: Int
    ) -> Bool {
        entryCount > 0
    }
}

enum StorageInspectorPresentation {
    private static let modifiedDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    static func phaseTitle(_ phase: StorageAnalysisPhase) -> String {
        switch phase {
        case .inactive: "Storage Inspector inactive"
        case .idle: "Ready to scan"
        case .scanning: "Scanning files"
        case .verifying: "Verifying duplicates"
        case .complete: "Scan complete"
        case .paused: "Scan paused"
        case .cancelled: "Scan cancelled"
        }
    }

    static func phaseAccessibilityValue(_ phase: StorageAnalysisPhase) -> String {
        phaseTitle(phase)
    }

    static func sectionTitle(_ section: StorageAnalysisSection) -> String {
        switch section {
        case .overview: "Overview"
        case .duplicates: "Duplicate Files"
        case .largeFiles: "Large Files"
        case .longUnmodified: "Long-Unmodified Files"
        case .fileTypes: "File Types"
        }
    }

    static func sectionSymbol(_ section: StorageAnalysisSection) -> String {
        switch section {
        case .overview: "chart.pie"
        case .duplicates: "doc.on.doc"
        case .largeFiles: "internaldrive"
        case .longUnmodified: "clock"
        case .fileTypes: "square.grid.2x2"
        }
    }

    static func analyzedBytesTitle(_ byteCount: Int64) -> String {
        ByteCountFormatter.string(
            fromByteCount: max(0, byteCount),
            countStyle: .file
        )
    }

    @MainActor
    static func rows(
        section: StorageAnalysisSection,
        store: StorageAnalysisStore
    ) -> [StorageResultRow] {
        let duplicateIDs = Set(
            store.duplicateGroups.flatMap { $0.members.map(\.id) }
        )
        let entries: [StorageEntry]
        switch section {
        case .overview:
            entries = store.entries
        case .duplicates:
            let selectedGroup = store.duplicateGroups.first {
                $0.id == store.selectedDuplicateGroupID
            } ?? store.duplicateGroups.first
            entries = selectedGroup?.members ?? []
        case .largeFiles:
            entries = store.largeFiles
        case .longUnmodified:
            entries = store.longUnmodifiedFiles
        case .fileTypes:
            entries = store.entries
        }

        var seen: Set<StorageRelativePath> = []
        let uniqueEntries = entries.filter { seen.insert($0.id).inserted }
        let orderedEntries = switch section {
        case .largeFiles, .longUnmodified:
            uniqueEntries
        case .overview, .duplicates, .fileTypes:
            uniqueEntries.sorted { $0.relativePath < $1.relativePath }
        }
        return orderedEntries.map { entry in
            resultRow(
                entry,
                verification: store.verificationStates[entry.id] ?? .unverified,
                isDuplicate: duplicateIDs.contains(entry.id)
            )
        }
    }

    @MainActor
    static func duplicateGroupSummaries(
        store: StorageAnalysisStore
    ) -> [StorageDuplicateGroupSummary] {
        store.duplicateGroups
            .sorted { lhs, rhs in
                switch (
                    lhs.members.map(\.relativePath).min(),
                    rhs.members.map(\.relativePath).min()
                ) {
                case let (left?, right?):
                    left < right
                case (.some, .none):
                    true
                case (.none, .some):
                    false
                case (.none, .none):
                    lhs.id.byteSize < rhs.id.byteSize
                }
            }
            .enumerated()
            .map { index, group in
                let memberIDs = group.members.map(\.id).sorted()
                return StorageDuplicateGroupSummary(
                    id: group.id,
                    title: "Group \(index + 1), \(group.members.count) copies, "
                        + analyzedBytesTitle(group.id.byteSize),
                    memberCount: group.members.count,
                    memberIDs: memberIDs,
                    reclaimableBytes: group.reclaimableBytes
                )
            }
    }

    static func categoryTitle(_ category: StorageFileCategory) -> String {
        switch category {
        case .document: "Document"
        case .image: "Image"
        case .video: "Video"
        case .audio: "Audio"
        case .archive: "Archive"
        case .application: "Application"
        case .other: "Other"
        }
    }

    static func largeFileThresholdTitle(
        _ preset: StorageLargeFileThresholdPreset
    ) -> String {
        analyzedBytesTitle(preset.bytes)
    }

    static func ageThresholdTitle(_ preset: StorageAgeThresholdPreset) -> String {
        switch preset.days {
        case 365: "1 year"
        case 730: "2 years"
        default: "\(preset.days) days"
        }
    }

    static func cleanupSummary(_ review: StorageCleanupReview) -> String {
        let trashCount = review.groups.reduce(into: 0) {
            $0 += $1.trash.count
        }
        let keepCount = review.groups.count
        let fileWord = trashCount == 1 ? "file" : "files"
        let copyWord = keepCount == 1 ? "copy" : "copies"
        return "\(trashCount) \(fileWord) marked for Trash, "
            + "\(analyzedBytesTitle(review.reclaimableBytes)) reclaimable; "
            + "\(keepCount) \(copyWord) kept."
    }

    static func cleanupResultSummary(_ result: FileOperationResult) -> String {
        var succeeded = 0
        var recoveryNeeded = 0
        var failed = 0
        var skipped = 0
        var cancelled = 0
        for outcome in result.outcomes {
            switch outcome {
            case .succeeded:
                succeeded += 1
            case .recoveryNeeded:
                recoveryNeeded += 1
            case .failed:
                failed += 1
            case .skipped:
                skipped += 1
            case .cancelled:
                cancelled += 1
            }
        }
        let recoverySummary = recoveryNeeded == 0
            ? ""
            : "\(recoveryNeeded) recovery needed, "
        return "\(succeeded) succeeded, \(recoverySummary)\(failed) failed, "
            + "\(skipped) skipped, \(cancelled) cancelled."
    }

    static func cleanupOutcomeTitle(_ outcome: FileOperationItemOutcome) -> String {
        switch outcome {
        case .succeeded: "Moved to Trash"
        case .recoveryNeeded: "Recovery needed"
        case .failed: "Failed"
        case .skipped: "Skipped after revalidation"
        case .cancelled: "Cancelled"
        }
    }

    static func cleanupOutcomeGuidance(
        _ outcome: FileOperationItemOutcome
    ) -> String? {
        if case .recoveryNeeded = outcome {
            "A staged item was retained for safe manual recovery."
        } else {
            nil
        }
    }

    private static func resultRow(
        _ entry: StorageEntry,
        verification: StorageVerificationState,
        isDuplicate: Bool
    ) -> StorageResultRow {
        let name = entry.relativePath.components.last ?? "Item"
        let parentComponents = entry.relativePath.components.dropLast()
        let relativeParent = parentComponents.isEmpty
            ? "Top level"
            : parentComponents.joined(separator: "/")
        let sizeText = entry.fingerprint.byteSize.map {
            analyzedBytesTitle($0)
        } ?? "Unknown size"
        let modifiedText = entry.fingerprint.modifiedAt.map {
            modifiedDateFormatter.string(from: $0)
        } ?? "Unknown date"
        let categoryText = categoryTitle(entry.category)
        let verificationText = verificationTitle(
            verification,
            isDuplicate: isDuplicate
        )
        return StorageResultRow(
            id: entry.id,
            name: name,
            relativeParent: relativeParent,
            sizeText: sizeText,
            modifiedText: modifiedText,
            categoryText: categoryText,
            verificationText: verificationText,
            accessibilityLabel: [
                name,
                relativeParent,
                sizeText,
                modifiedText,
                categoryText,
                verificationText
            ].joined(separator: ", ")
        )
    }

    private static func verificationTitle(
        _ state: StorageVerificationState,
        isDuplicate: Bool
    ) -> String {
        switch state {
        case .unverified:
            "Not verified"
        case let .partial(progress):
            if let progress {
                "\(Int((min(max(progress, 0), 1) * 100).rounded()))% verified"
            } else {
                "Verification in progress"
            }
        case .complete:
            isDuplicate ? "Verified duplicate" : "Verified"
        case .unstable:
            "Changed during verification"
        case .unreadable:
            "Unreadable"
        }
    }
}
