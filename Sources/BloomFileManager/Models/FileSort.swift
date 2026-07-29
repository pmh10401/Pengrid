import Foundation

enum FileSortKey: String, Codable, Sendable, CaseIterable {
    case name, modifiedAt, kind, size
}

enum SortDirection: String, Codable, Sendable {
    case ascending, descending
}

struct FileSort: Codable, Equatable, Sendable {
    let key: FileSortKey
    let direction: SortDirection

    init(key: FileSortKey = .name, direction: SortDirection = .ascending) {
        self.key = key
        self.direction = direction
    }

    func apply(to items: [FileItem]) -> [FileItem] {
        items.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            let comparison: ComparisonResult
            switch key {
            case .name:
                comparison = lhs.name.localizedStandardCompare(rhs.name)
            case .modifiedAt:
                comparison = (lhs.modifiedAt ?? .distantPast).compare(rhs.modifiedAt ?? .distantPast)
            case .kind:
                comparison = lhs.typeDescription.localizedStandardCompare(rhs.typeDescription)
            case .size:
                let left = lhs.byteSize ?? -1
                let right = rhs.byteSize ?? -1
                comparison = left == right ? .orderedSame : (left < right ? .orderedAscending : .orderedDescending)
            }
            if comparison == .orderedSame { return lhs.url.path < rhs.url.path }
            return direction == .ascending ? comparison == .orderedAscending : comparison == .orderedDescending
        }
    }
}
