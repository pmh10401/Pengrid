import Foundation

enum PaneSelectionActions {
    static func selectAll(visibleItems: [FileItem]) -> Set<URL> {
        Set(visibleItems.map(\.url))
    }

    static func invert(current: Set<URL>, visibleItems: [FileItem]) -> Set<URL> {
        Set(visibleItems.map(\.url)).subtracting(current)
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
