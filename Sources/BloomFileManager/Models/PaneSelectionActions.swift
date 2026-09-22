import Foundation

enum PaneSelectionActions {
    static func selectAll(visibleItems: [FileItem]) -> Set<URL> {
        Set(visibleItems.map(\.url))
    }

    static func invert(current: Set<URL>, visibleItems: [FileItem]) -> Set<URL> {
        Set(visibleItems.map(\.url)).subtracting(current)
    }

    static func matchingNamePattern(
        _ pattern: String,
        visibleItems: [FileItem]
    ) -> Set<URL>? {
        guard !pattern.isEmpty else { return nil }

        let patternTokens = normalizedNameTokens(pattern)
        return Set(visibleItems.compactMap { item in
            let nameTokens = normalizedNameTokens(item.name)
            return matchesNamePattern(patternTokens, name: nameTokens)
                ? item.url
                : nil
        })
    }

    static func matchingExtension(
        current: Set<URL>,
        visibleItems: [FileItem]
    ) -> Set<URL>? {
        guard current.count == 1,
              let anchorURL = current.first,
              let anchor = visibleItems.first(where: { $0.url == anchorURL }),
              isRegularFile(anchor),
              let anchorExtension = actualExtension(for: anchor.name)
        else { return nil }

        let foldedAnchorExtension = fold(anchorExtension)
        return Set(visibleItems.compactMap { item in
            guard isRegularFile(item),
                  let itemExtension = actualExtension(for: item.name),
                  fold(itemExtension) == foldedAnchorExtension
            else { return nil }
            return item.url
        })
    }

    private static func isRegularFile(_ item: FileItem) -> Bool {
        item.isRegularFile && !item.isDirectory && !item.isPackage && !item.isSymbolicLink
    }

    private static func normalizedNameTokens(_ value: String) -> [String] {
        let locale = Locale(identifier: "en_US_POSIX")
        return value.map { character in
            String(character)
                .precomposedStringWithCanonicalMapping
                .folding(options: [.caseInsensitive], locale: locale)
        }
    }

    // ponytail: O(pattern * name) per item keeps wildcard matching bounded; optimize only for larger projections.
    private static func matchesNamePattern(
        _ pattern: [String],
        name: [String]
    ) -> Bool {
        var previous = Array(repeating: false, count: name.count + 1)
        previous[0] = true

        for token in pattern {
            var current = Array(repeating: false, count: name.count + 1)

            if token == "*" {
                current[0] = previous[0]
                if !name.isEmpty {
                    for nameIndex in 1...name.count {
                        current[nameIndex] = previous[nameIndex] || current[nameIndex - 1]
                    }
                }
            } else if !name.isEmpty {
                for nameIndex in 1...name.count {
                    current[nameIndex] = previous[nameIndex - 1]
                        && (token == "?" || token == name[nameIndex - 1])
                }
            }

            previous = current
        }

        return previous[name.count]
    }

    private static func actualExtension(for name: String) -> String? {
        let pathExtension = (name as NSString).pathExtension
        guard !pathExtension.isEmpty else { return nil }

        if name.hasPrefix(".") && !name.dropFirst().contains(".") {
            return nil
        }
        return pathExtension
    }

    private static func fold(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: nil
        )
    }
}
