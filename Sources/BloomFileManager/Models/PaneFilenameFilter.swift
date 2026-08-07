import Foundation

struct PaneFilenameFilter: Equatable, Sendable {
    let query: String

    static let cancellationCheckStride = 128

    static func normalize(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isPrintableASCII(_ value: String) -> Bool {
        !value.isEmpty
            && value.unicodeScalars.allSatisfy { (0x20...0x7E).contains($0.value) }
    }

    static func isASCIIAlphanumeric(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy {
            (0x30...0x39).contains($0.value)
                || (0x41...0x5A).contains($0.value)
                || (0x61...0x7A).contains($0.value)
        }
    }

    static func isEligibleASCIIExtension(from oldQuery: String, to newQuery: String) -> Bool {
        let old = normalize(oldQuery)
        let new = normalize(newQuery)
        guard isASCIIAlphanumeric(old), isASCIIAlphanumeric(new),
              new.unicodeScalars.count == old.unicodeScalars.count + 1
        else { return false }
        return new.unicodeScalars.starts(with: old.unicodeScalars)
    }

    func apply(to items: [FileItem]) -> [FileItem] {
        let normalizedQuery = Self.normalize(query)
        guard !normalizedQuery.isEmpty else { return items }
        return items.filter { $0.name.localizedStandardContains(normalizedQuery) }
    }
}
