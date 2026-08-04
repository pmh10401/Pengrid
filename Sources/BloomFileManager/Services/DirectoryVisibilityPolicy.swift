import Foundation

struct DirectoryVisibilityPolicy: Equatable, Sendable {
    let includesHiddenItems: Bool

    static let baseline = DirectoryVisibilityPolicy(includesHiddenItems: true)

    var fileManagerOptions: FileManager.DirectoryEnumerationOptions {
        includesHiddenItems ? [] : [.skipsHiddenFiles]
    }

    func includes(name: String) -> Bool {
        includesHiddenItems || !name.hasPrefix(".")
    }
}
