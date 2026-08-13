import Foundation

struct FolderSynchronizationPlanningService: Sendable {
    func plan(
        phase: ComparisonPhase,
        session: ComparisonSession?,
        rows: [ComparisonRow],
        direction: ComparisonDirection
    ) -> FolderSynchronizationPlanningResult {
        guard phase == .upToDate else {
            return .blocked([.init(reason: .comparisonNotCurrent)])
        }
        guard let session else {
            return .blocked([.init(reason: .missingComparisonSession)])
        }

        let roots = roots(for: direction, session: session)
        if roots.sourceIdentity.refersToSameItem(as: roots.destinationIdentity)
            || normalizedPathComponents(roots.source) == normalizedPathComponents(roots.destination) {
            return .blocked([.init(reason: .equalRoots)])
        }
        if isNested(roots.source, roots.destination) {
            return .blocked([.init(reason: .nestedRoots)])
        }

        var blockers = rowValidationBlockers(in: rows, session: session)
        blockers.append(contentsOf: statusAndKindBlockers(in: rows))
        if !blockers.isEmpty {
            return .blocked(sortedAndDeduplicated(blockers))
        }

        var plannedRows: [PlannedRow] = []
        var skipCount = 0

        for row in rows {
            let decision = action(for: row, direction: direction)
            plannedRows.append(.init(row: row, decision: decision))
            switch decision {
            case .action:
                break
            case .skip:
                skipCount += 1
            case let .block(blocker):
                blockers.append(blocker)
            }
        }

        blockers.append(contentsOf: ancestorCoverageBlockers(in: plannedRows))
        guard blockers.isEmpty else { return .blocked(sortedAndDeduplicated(blockers)) }

        let orderedActions = plannedRows.compactMap(\.decision.action).sorted(by: FolderSynchronizationAction.deterministicOrder)
        let coalescedActions = coalescingCoveredDescendants(in: orderedActions)
        let estimatedRegularFileCopyBytes = directRegularFileCopyBytes(in: coalescedActions)

        if coalescedActions.isEmpty {
            return .alreadySynchronized(try! FolderSynchronizationPlanSummary(
                direction: direction,
                comparisonGeneration: session.generation,
                sourceRoot: roots.source,
                destinationRoot: roots.destination,
                sourceRootIdentity: roots.sourceIdentity,
                destinationRootIdentity: roots.destinationIdentity,
                skipCount: skipCount
            ))
        }

        return .ready(try! FolderSynchronizationPlanDraft(
            direction: direction,
            comparisonGeneration: session.generation,
            sourceRoot: roots.source,
            destinationRoot: roots.destination,
            sourceRootIdentity: roots.sourceIdentity,
            destinationRootIdentity: roots.destinationIdentity,
            actions: coalescedActions,
            skipCount: skipCount,
            estimatedRegularFileCopyBytes: estimatedRegularFileCopyBytes
        ))
    }

    private func roots(
        for direction: ComparisonDirection,
        session: ComparisonSession
    ) -> (source: URL, destination: URL, sourceIdentity: FileIdentity, destinationIdentity: FileIdentity) {
        if direction == .leftToRight {
            (session.leftRoot, session.rightRoot, session.leftRootIdentity, session.rightRootIdentity)
        } else {
            (session.rightRoot, session.leftRoot, session.rightRootIdentity, session.leftRootIdentity)
        }
    }

    private func rowValidationBlockers(
        in rows: [ComparisonRow],
        session: ComparisonSession
    ) -> [FolderSynchronizationBlocker] {
        var blockers: [FolderSynchronizationBlocker] = []
        var paths = Set<ComparisonRelativePath>()

        for row in rows {
            if !paths.insert(row.relativePath).inserted {
                blockers.append(.init(relativePath: row.relativePath, reason: .duplicateComparisonPath))
            }
            if !hasValidStatusSideMatrix(row) || !entriesMatch(row, session: session) {
                blockers.append(.init(relativePath: row.relativePath, reason: .invalidComparisonRow))
            }
        }

        for row in rows {
            let ancestorRows = rows.filter { isDescendant(row.relativePath, of: $0.relativePath) }
            guard !ancestorRows.isEmpty else { continue }
            if ancestorRows.contains(where: { ancestor in
                [ancestor.left, ancestor.right].compactMap { $0 }.contains { $0.kind != .directory }
            }) {
                blockers.append(.init(relativePath: row.relativePath, reason: .unsafeAncestorRelationship))
            }
        }
        return blockers
    }

    private func statusAndKindBlockers(in rows: [ComparisonRow]) -> [FolderSynchronizationBlocker] {
        rows.flatMap(statusAndKindBlockers(for:))
    }

    private func statusAndKindBlockers(for row: ComparisonRow) -> [FolderSynchronizationBlocker] {
        switch row.status {
        case .typeConflict:
            return [.init(relativePath: row.relativePath, reason: .typeConflict)]
        case .nameConflict:
            return [.init(relativePath: row.relativePath, reason: .nameConflict)]
        case .checking:
            return [.init(relativePath: row.relativePath, reason: .checking)]
        case .unstable:
            return [.init(relativePath: row.relativePath, reason: .unstable)]
        case .error:
            return [.init(relativePath: row.relativePath, reason: .comparisonError)]
        case .identical, .metadataChanged, .contentChanged, .leftOnly, .rightOnly:
            let unsupported = [row.left, row.right].compactMap { $0 }.contains { entry in
                entry.kind != .regularFile && entry.kind != .directory
            }
            return unsupported ? [.init(relativePath: row.relativePath, reason: .unsupportedEntryKind)] : []
        }
    }

    private func action(for row: ComparisonRow, direction: ComparisonDirection) -> ActionDecision {
        let source = row.source(for: direction)
        let destination = row.destination(for: direction)

        switch row.status {
        case .identical:
            return .skip
        case .leftOnly, .rightOnly:
            if source != nil, destination == nil {
                return action(
                    relativePath: row.relativePath,
                    kind: .copy,
                    source: source,
                    destination: nil
                )
            }
            if source == nil, destination != nil {
                return action(
                    relativePath: row.relativePath,
                    kind: .moveDestinationToTrash,
                    source: nil,
                    destination: destination
                )
            }
            return .block(.init(relativePath: row.relativePath, reason: .invalidComparisonRow))
        case .metadataChanged, .contentChanged:
            guard let source, let destination, source.kind == destination.kind else {
                return .block(.init(relativePath: row.relativePath, reason: .invalidComparisonRow))
            }
            if source.kind == .directory {
                return .skip
            }
            return action(
                relativePath: row.relativePath,
                kind: .replace,
                source: source,
                destination: destination
            )
        case .typeConflict, .nameConflict, .checking, .unstable, .error:
            return .block(.init(relativePath: row.relativePath, reason: .invalidComparisonRow))
        }
    }

    private func action(
        relativePath: ComparisonRelativePath,
        kind: FolderSynchronizationActionKind,
        source: ComparisonEntry?,
        destination: ComparisonEntry?
    ) -> ActionDecision {
        guard let action = try? FolderSynchronizationAction(
            relativePath: relativePath,
            kind: kind,
            source: source,
            destination: destination
        ) else {
            return .block(.init(relativePath: relativePath, reason: .invalidComparisonRow))
        }
        return .action(action)
    }

    private func coalescingCoveredDescendants(
        in actions: [FolderSynchronizationAction]
    ) -> [FolderSynchronizationAction] {
        actions.filter { action in
            return !actions.contains { candidate in
                candidate.relativePath != action.relativePath
                    && isDescendant(action.relativePath, of: candidate.relativePath)
                    && candidate.kind == action.kind
                    && (candidate.kind == .copy || candidate.kind == .moveDestinationToTrash)
                    && (candidate.kind == .copy ? candidate.source?.kind : candidate.destination?.kind) == .directory
            }
        }
    }

    private func ancestorCoverageBlockers(in plannedRows: [PlannedRow]) -> [FolderSynchronizationBlocker] {
        plannedRows.flatMap { parent in
            guard case let .action(parentAction) = parent.decision,
                  parentAction.kind == .copy || parentAction.kind == .moveDestinationToTrash,
                  (parentAction.kind == .copy ? parentAction.source?.kind : parentAction.destination?.kind) == .directory else {
                return [FolderSynchronizationBlocker]()
            }
            return plannedRows.compactMap { descendant in
                guard isDescendant(descendant.row.relativePath, of: parent.row.relativePath) else { return nil }
                guard case let .action(descendantAction) = descendant.decision,
                      descendantAction.kind == parentAction.kind else {
                    return .init(relativePath: descendant.row.relativePath, reason: .unsafeAncestorRelationship)
                }
                return nil
            }
        }
    }

    private func sortedAndDeduplicated(_ blockers: [FolderSynchronizationBlocker]) -> [FolderSynchronizationBlocker] {
        var IDs = Set<String>()
        return blockers.sorted { left, right in
            switch (left.relativePath, right.relativePath) {
            case let (left?, right?):
                if left.components.count != right.components.count {
                    return left.components.count < right.components.count
                }
                if left != right { return left < right }
            case (nil, .some):
                return true
            case (.some, nil):
                return false
            case (nil, nil):
                break
            }
            return left.reason.rawValue < right.reason.rawValue
        }.filter { IDs.insert($0.id).inserted }
    }

    private func hasValidStatusSideMatrix(_ row: ComparisonRow) -> Bool {
        switch row.status {
        case .identical, .metadataChanged, .contentChanged:
            guard let left = row.left, let right = row.right else { return false }
            return left.kind == right.kind
        case .leftOnly:
            return row.left != nil && row.right == nil
        case .rightOnly:
            return row.left == nil && row.right != nil
        case .typeConflict:
            return row.left != nil && row.right != nil
        case .checking:
            return row.left != nil && row.right != nil
        case .unstable, .error, .nameConflict:
            return true
        }
    }

    private func entriesMatch(_ row: ComparisonRow, session: ComparisonSession) -> Bool {
        matches(row.left, row: row, root: session.leftRoot)
            && matches(row.right, row: row, root: session.rightRoot)
    }

    private func matches(_ entry: ComparisonEntry?, row: ComparisonRow, root: URL) -> Bool {
        guard let entry else { return true }
        return entry.relativePath == row.relativePath
            && entry.url.standardizedFileURL == root.appending(path: row.relativePath.string).standardizedFileURL
    }

    private func directRegularFileCopyBytes(in actions: [FolderSynchronizationAction]) -> Int64 {
        actions.reduce(into: Int64(0)) { total, action in
            guard let source = action.source, source.kind == .regularFile else { return }
            let bytes = max(0, source.fingerprint.byteSize ?? 0)
            total = saturatedAdd(total, bytes)
        }
    }

    private func normalizedPathComponents(_ url: URL) -> [String] {
        url.standardizedFileURL.pathComponents
    }

    private func isNested(_ first: URL, _ second: URL) -> Bool {
        let firstComponents = normalizedPathComponents(first)
        let secondComponents = normalizedPathComponents(second)
        return isStrictPrefix(firstComponents, of: secondComponents)
            || isStrictPrefix(secondComponents, of: firstComponents)
    }

    private func isDescendant(_ path: ComparisonRelativePath, of ancestor: ComparisonRelativePath) -> Bool {
        isStrictPrefix(ancestor.components, of: path.components)
    }

    private func isStrictPrefix(_ prefix: [String], of value: [String]) -> Bool {
        prefix.count < value.count && zip(prefix, value).allSatisfy(==)
    }

    private func saturatedAdd(_ left: Int64, _ right: Int64) -> Int64 {
        if left > Int64.max - right { return Int64.max }
        return left + right
    }
}

private enum ActionDecision {
    case action(FolderSynchronizationAction)
    case skip
    case block(FolderSynchronizationBlocker)
}

private extension ActionDecision {
    var action: FolderSynchronizationAction? {
        guard case let .action(action) = self else { return nil }
        return action
    }
}

private struct PlannedRow {
    let row: ComparisonRow
    let decision: ActionDecision
}
