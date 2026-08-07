import Foundation

struct FileTableRowMove: Equatable {
    let from: Int
    let to: Int
}

enum FileTableUpdatePlan: Equatable {
    case none
    case insert(IndexSet)
    case remove(IndexSet)
    case reload(IndexSet)
    case move([FileTableRowMove])
    case reloadAll
}

struct FileTableUpdatePlanner {
    let maximumIncrementalChanges: Int

    init(maximumIncrementalChanges: Int = 0) {
        self.maximumIncrementalChanges = max(0, maximumIncrementalChanges)
    }

    func plan(from old: [FileItem], to new: [FileItem]) -> FileTableUpdatePlan {
        let minimumStructuralChanges = old.count > new.count
            ? old.count - new.count
            : new.count - old.count
        if minimumStructuralChanges > maximumIncrementalChanges {
            return .reloadAll
        }

        let oldIDs = old.map { $0.url.standardizedFileURL }
        let newIDs = new.map { $0.url.standardizedFileURL }
        let oldIDSet = Set(oldIDs)
        let newIDSet = Set(newIDs)

        guard oldIDSet.count == oldIDs.count,
              newIDSet.count == newIDs.count
        else { return .reloadAll }

        if old == new {
            return .none
        }

        if oldIDs == newIDs {
            return .reload(IndexSet(new.indices.filter { old[$0] != new[$0] }))
        }

        let oldItemsByID = Dictionary(uniqueKeysWithValues: zip(oldIDs, old))

        if newIDs.filter(oldIDSet.contains) == oldIDs {
            guard zip(newIDs, new).allSatisfy({ identity, item in
                !oldIDSet.contains(identity) || oldItemsByID[identity] == item
            }) else { return .reloadAll }
            let inserted = IndexSet(newIDs.indices.filter { !oldIDSet.contains(newIDs[$0]) })
            return bounded(inserted.count, plan: .insert(inserted))
        }

        if oldIDs.filter(newIDSet.contains) == newIDs {
            guard zip(newIDs, new).allSatisfy({ oldItemsByID[$0.0] == $0.1 }) else {
                return .reloadAll
            }
            let removed = IndexSet(oldIDs.indices.filter { !newIDSet.contains(oldIDs[$0]) })
            return bounded(removed.count, plan: .remove(removed))
        }

        guard oldIDSet == newIDSet else {
            return .reloadAll
        }

        guard zip(newIDs, new).allSatisfy({ oldItemsByID[$0.0] == $0.1 }) else {
            return .reloadAll
        }

        var workingIDs = oldIDs
        var moves: [FileTableRowMove] = []
        moves.reserveCapacity(min(newIDs.count, maximumIncrementalChanges))

        for targetIndex in newIDs.indices where workingIDs[targetIndex] != newIDs[targetIndex] {
            guard let sourceIndex = workingIDs[targetIndex...].firstIndex(of: newIDs[targetIndex]) else {
                return .reloadAll
            }
            let movedID = workingIDs.remove(at: sourceIndex)
            workingIDs.insert(movedID, at: targetIndex)
            moves.append(FileTableRowMove(from: sourceIndex, to: targetIndex))
            if moves.count > maximumIncrementalChanges {
                return .reloadAll
            }
        }

        return .move(moves)
    }

    private func bounded(_ changeCount: Int, plan: FileTableUpdatePlan) -> FileTableUpdatePlan {
        changeCount <= maximumIncrementalChanges ? plan : .reloadAll
    }
}
