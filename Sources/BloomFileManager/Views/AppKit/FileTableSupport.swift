import AppKit

enum FileTableSelection {
    static func urls(for indexes: IndexSet, items: [URL]) -> Set<URL> {
        Set(indexes.compactMap { items.indices.contains($0) ? items[$0] : nil })
    }
}

enum InlineRenameSelection {
    static func range(for name: String, isDirectory: Bool) -> NSRange {
        let fullRange = NSRange(name.startIndex..<name.endIndex, in: name)
        guard !isDirectory,
              let dot = name.lastIndex(of: "."),
              dot != name.startIndex
        else { return fullRange }
        return NSRange(name.startIndex..<dot, in: name)
    }
}

enum FileTableDropRouting {
    static func destination(for row: Int, items: [FileItem], paneDirectory: URL) -> URL? {
        if items.indices.contains(row) {
            let item = items[row]
            return item.isDirectory && !item.isPackage ? item.url : nil
        }
        return paneDirectory
    }
}

enum InlineTextEditingEvent: Equatable {
    case began(UUID)
    case ended(UUID)
}

final class PaneActivatingTableView: NSTableView {
    var onBecomeFirstResponder: (() -> Void)?
    var onCancel: (() -> Bool)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onBecomeFirstResponder?() }
        return accepted
    }

    override func keyDown(with event: NSEvent) {
        let commandModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
        if event.keyCode == 53,
           event.modifierFlags.intersection(commandModifiers).isEmpty,
           onCancel?() == true {
            return
        }
        if event.charactersIgnoringModifiers == " ",
           event.modifierFlags.intersection(commandModifiers).isEmpty,
           NSApp.mainMenu?.performKeyEquivalent(with: event) == true {
            return
        }
        super.keyDown(with: event)
    }

}
