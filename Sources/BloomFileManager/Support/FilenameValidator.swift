import Foundation

enum FilenameError: Error, Equatable, Sendable {
    case empty
    case containsPathSeparator
    case containsNUL
    case dotEntry
}

enum FilenameValidator {
    static func validate(_ candidate: String) throws {
        guard !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FilenameError.empty
        }
        guard !candidate.contains("/") else {
            throw FilenameError.containsPathSeparator
        }
        guard !candidate.contains("\0") else {
            throw FilenameError.containsNUL
        }
        guard candidate != ".", candidate != ".." else {
            throw FilenameError.dotEntry
        }
    }
}

enum KeepBothNamer {
    static func availableName(for name: String, existing: Set<String>) -> String {
        guard existing.contains(name) else {
            return name
        }

        let url = URL(filePath: name)
        let ext = url.pathExtension
        let stem = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
        var index = 2

        while true {
            let candidate = ext.isEmpty ? "\(stem) \(index)" : "\(stem) \(index).\(ext)"
            if !existing.contains(candidate) {
                return candidate
            }
            index += 1
        }
    }
}
