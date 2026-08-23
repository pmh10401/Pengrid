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
              let anchorExtension = actualExtension(for: anchor.url)
        else { return nil }

        let foldedAnchorExtension = fold(anchorExtension)
        return Set(visibleItems.compactMap { item in
            guard isRegularFile(item),
                  let itemExtension = actualExtension(for: item.url),
                  fold(itemExtension) == foldedAnchorExtension
            else { return nil }
            return item.url
        })
    }

    private static func isRegularFile(_ item: FileItem) -> Bool {
        !item.isDirectory && !item.isPackage
    }

    private static func actualExtension(for url: URL) -> String? {
        let pathExtension = url.pathExtension
        guard !pathExtension.isEmpty else { return nil }

        let basename = url.lastPathComponent
        if basename.hasPrefix(".") && !basename.dropFirst().contains(".") {
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
