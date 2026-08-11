import Foundation

enum BatchRenamePlanner {
    static func preview(
        request: BatchRenamePlanningRequest,
        rule: BatchRenameRule,
        occupiedNames: Set<String>,
        comparisonPolicy: FilenameComparisonPolicy,
        locale: Locale = .current
    ) throws -> BatchRenamePreview {
        try validate(request)
        let proposedNames = try request.sources.enumerated().map { index, source in
            try proposedName(
                for: source,
                rule: rule,
                sequenceIndex: index,
                locale: locale
            )
        }
        return try preview(
            request: request,
            proposedNames: proposedNames,
            occupiedNames: occupiedNames,
            comparisonPolicy: comparisonPolicy
        )
    }

    static func preview(
        request: BatchRenamePlanningRequest,
        proposedNames: [String],
        occupiedNames: Set<String>,
        comparisonPolicy: FilenameComparisonPolicy
    ) throws -> BatchRenamePreview {
        try validate(request)
        guard proposedNames.count == request.sources.count else {
            throw BatchRenamePlanningError.proposedNameCountMismatch
        }

        var statuses = zip(request.sources, proposedNames).map { source, proposedName in
            initialStatus(source: source, proposedName: proposedName)
        }
        let proposedKeys = proposedNames.map(comparisonPolicy.key(for:))
        let duplicateKeys = Set(
            Dictionary(grouping: proposedKeys, by: { $0 })
                .compactMap { key, values in values.count > 1 ? key : nil }
        )
        for index in statuses.indices where duplicateKeys.contains(proposedKeys[index]) {
            if case .invalidName = statuses[index] {
                continue
            }
            statuses[index] = .duplicate
        }

        let selectedKeys = Set(request.sources.map { comparisonPolicy.key(for: $0.name) })
        let externallyOccupiedKeys = Set(occupiedNames.map(comparisonPolicy.key(for:)))
            .subtracting(selectedKeys)
        for index in statuses.indices where externallyOccupiedKeys.contains(proposedKeys[index]) {
            guard statuses[index] == .ready else { continue }
            statuses[index] = .occupied
        }

        let previewEntries = request.sources.indices.map { index in
            BatchRenamePreviewEntry(
                source: request.sources[index],
                proposedName: proposedNames[index],
                status: statuses[index]
            )
        }
        let invalid = statuses.contains { status in
            switch status {
            case .invalidName, .duplicate, .occupied:
                true
            case .ready, .unchanged:
                false
            }
        }
        let changedIndices = statuses.indices.filter { statuses[$0] == .ready }
        let plan: BatchRenamePlan?
        if invalid || changedIndices.isEmpty {
            plan = nil
        } else {
            plan = BatchRenamePlan(
                parentURL: request.parentURL,
                parentIdentity: request.parentIdentity,
                entries: changedIndices.map { index in
                    let source = request.sources[index]
                    return BatchRenamePlanEntry(
                        source: source,
                        proposedName: proposedNames[index],
                        destinationURL: request.parentURL.appending(
                            path: proposedNames[index],
                            directoryHint: source.isDirectory ? .isDirectory : .notDirectory
                        )
                    )
                },
                comparisonPolicy: comparisonPolicy
            )
        }
        return BatchRenamePreview(entries: previewEntries, plan: plan)
    }

    private static func validate(_ request: BatchRenamePlanningRequest) throws {
        guard request.sources.count >= 2 else {
            throw BatchRenamePlanningError.selectionTooSmall
        }
        let parent = request.parentURL.standardizedFileURL
        guard request.sources.allSatisfy({
            $0.url.deletingLastPathComponent().standardizedFileURL == parent
        }) else {
            throw BatchRenamePlanningError.mixedParents
        }
    }

    private static func initialStatus(
        source: BatchRenameSource,
        proposedName: String
    ) -> BatchRenamePreviewStatus {
        do {
            try FilenameValidator.validate(proposedName)
        } catch let error as FilenameError {
            return .invalidName(error)
        } catch {
            return .invalidName(.empty)
        }
        return source.name == proposedName ? .unchanged : .ready
    }

    private static func proposedName(
        for source: BatchRenameSource,
        rule: BatchRenameRule,
        sequenceIndex: Int,
        locale: Locale
    ) throws -> String {
        let parts = BatchRenameFilenameParts(source: source)
        let renamedStem: String
        switch rule {
        case let .findReplace(find, replacement, caseSensitive):
            guard !find.isEmpty else {
                throw BatchRenamePlanningError.emptyFindText
            }
            renamedStem = replaceAll(
                in: parts.stem,
                find: find,
                replacement: replacement,
                caseSensitive: caseSensitive,
                locale: locale
            )
        case let .prefix(prefix):
            renamedStem = prefix + parts.stem
        case let .suffix(suffix):
            renamedStem = parts.stem + suffix
        case let .sequence(baseName, start, digits):
            guard start >= 0, (1...12).contains(digits) else {
                throw BatchRenamePlanningError.invalidSequence
            }
            let (number, overflow) = start.addingReportingOverflow(sequenceIndex)
            guard !overflow else {
                throw BatchRenamePlanningError.invalidSequence
            }
            renamedStem = "\(baseName) \(String(format: "%0*d", digits, number))"
        }
        return renamedStem + parts.preservedSuffix
    }

    private static func replaceAll(
        in value: String,
        find: String,
        replacement: String,
        caseSensitive: Bool,
        locale: Locale
    ) -> String {
        let options: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        var result = ""
        var cursor = value.startIndex
        while let range = value.range(
            of: find,
            options: options,
            range: cursor..<value.endIndex,
            locale: locale
        ) {
            result += value[cursor..<range.lowerBound]
            result += replacement
            cursor = range.upperBound
        }
        result += value[cursor..<value.endIndex]
        return result
    }
}

private struct BatchRenameFilenameParts {
    let stem: String
    let preservedSuffix: String

    init(source: BatchRenameSource) {
        let name = source.name
        if source.isDirectory && !source.isPackage {
            stem = name
            preservedSuffix = ""
            return
        }
        if let archiveSuffix = ArchiveFormat.recognizedSuffix(in: name) {
            stem = String(name.dropLast(archiveSuffix.count))
            preservedSuffix = archiveSuffix
            return
        }
        if name.first == ".", !name.dropFirst().contains(".") {
            stem = name
            preservedSuffix = ""
            return
        }
        let pathExtension = URL(filePath: name).pathExtension
        guard !pathExtension.isEmpty else {
            stem = name
            preservedSuffix = ""
            return
        }
        preservedSuffix = String(name.suffix(pathExtension.count + 1))
        stem = String(name.dropLast(preservedSuffix.count))
    }
}
