import AppKit
import Foundation
import Testing
@testable import BloomFileManager

@Test func panelDropDefaultsToCopyAndCommandForcesMove() {
    #expect(DropIntent.resolve(modifiers: []) == .copy)
    #expect(DropIntent.resolve(modifiers: [.command]) == .move)
    #expect(DropIntent.resolve(modifiers: [.option]) == .copy)
    #expect(DropIntent.resolve(modifiers: [.command, .option]) == .move)
}

@Test func commandPolicyDisablesMutationsDuringAnOperation() {
    let policy = WorkspaceCommandPolicy(
        selectionCount: 1,
        isOperationRunning: true,
        pasteboardHasFileURLs: true
    )

    #expect(policy.canCreateFolder == false)
    #expect(policy.canRename == false)
    #expect(policy.canPaste == false)
    #expect(policy.canTrash == false)
    #expect(policy.canCopy)
}

@Test func commandPolicyRequiresOneSelectionForRenameAndURLsForPaste() {
    let empty = WorkspaceCommandPolicy(
        selectionCount: 0,
        isOperationRunning: false,
        pasteboardHasFileURLs: false
    )
    let multiple = WorkspaceCommandPolicy(
        selectionCount: 2,
        isOperationRunning: false,
        pasteboardHasFileURLs: true
    )

    #expect(empty.canRename == false)
    #expect(empty.canCopy == false)
    #expect(empty.canPaste == false)
    #expect(multiple.canRename == false)
    #expect(multiple.canCopy)
    #expect(multiple.canPaste)
    #expect(multiple.canTrash)
}

@MainActor
@Test func fileURLPasteboardRoundTripsOnlyFileURLs() {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("BloomFileManagerTests-\(UUID())"))
    let urls = [URL(filePath: "/tmp/a"), URL(filePath: "/tmp/b")]

    FileURLPasteboard.write(urls, to: pasteboard)

    #expect(FileURLPasteboard.read(from: pasteboard) == urls)
    #expect(FileURLPasteboard.containsFileURLs(in: pasteboard))
}

@Test func inlineRenameSelectsOnlyARegularFilesStem() {
    #expect(InlineRenameSelection.range(for: "Report.final.pdf", isDirectory: false) == NSRange(location: 0, length: 12))
    #expect(InlineRenameSelection.range(for: "Archive", isDirectory: false) == NSRange(location: 0, length: 7))
    #expect(InlineRenameSelection.range(for: "Folder.name", isDirectory: true) == NSRange(location: 0, length: 11))
}

@Test func textEditingYieldsConflictingFileCommandsToTheTextResponder() {
    let policy = WorkspaceCommandPolicy(
        selectionCount: 1,
        isOperationRunning: false,
        pasteboardHasFileURLs: true,
        isTextEditing: true
    )

    #expect(policy.canCreateFolder == false)
    #expect(policy.canRename == false) // Return and F2
    #expect(policy.canTrash == false) // Delete and Command-Delete
    #expect(policy.copyRoute == .textResponder) // Command-C
    #expect(policy.pasteRoute == .textResponder) // Command-V
}

@MainActor
@Test func invalidPasteboardDoesNotProduceFileURLs() {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("BloomInvalidPasteboard-\(UUID())"))
    pasteboard.clearContents()
    pasteboard.setString("not a file URL", forType: .string)

    #expect(FileURLPasteboard.read(from: pasteboard).isEmpty)
    #expect(FileURLPasteboard.containsFileURLs(in: pasteboard) == false)
}

@Test func dropDestinationAcceptsDirectoriesAndBlankPaneButRejectsFilesAndPackages() {
    let directory = URL(filePath: "/destination", directoryHint: .isDirectory)
    let folder = makeDropItem(path: "/destination/folder", isDirectory: true, isPackage: false)
    let file = makeDropItem(path: "/destination/file", isDirectory: false, isPackage: false)
    let package = makeDropItem(path: "/destination/App.app", isDirectory: true, isPackage: true)
    let items = [folder, file, package]

    #expect(FileTableDropRouting.destination(for: 0, items: items, paneDirectory: directory) == folder.url)
    #expect(FileTableDropRouting.destination(for: 1, items: items, paneDirectory: directory) == nil)
    #expect(FileTableDropRouting.destination(for: 2, items: items, paneDirectory: directory) == nil)
    #expect(FileTableDropRouting.destination(for: items.count, items: items, paneDirectory: directory) == directory)
    #expect(FileTableDropRouting.destination(for: -1, items: items, paneDirectory: directory) == directory)
}

@MainActor
@Test func copyAndPasteDispatchToAnActualNSTextResponder() {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    let textView = NSTextView(frame: window.contentView?.bounds ?? .zero)
    window.contentView = textView
    NSApplication.shared.activate()
    window.makeKeyAndOrderFront(nil)
    window.makeKey()
    #expect(window.makeFirstResponder(textView))
    textView.string = "Copy this"
    textView.setSelectedRange(NSRange(location: 0, length: 4))

    #expect(TextResponderCommand.copy(to: textView))
    #expect(NSPasteboard.general.string(forType: .string) == "Copy")

    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString("Paste", forType: .string)
    textView.setSelectedRange(NSRange(location: 0, length: textView.string.utf16.count))
    #expect(TextResponderCommand.paste(to: textView))
    #expect(textView.string == "Paste")

    textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))
    textView.insertNewline(nil)
    #expect(textView.string == "Paste\n")
    textView.deleteBackward(nil)
    #expect(textView.string == "Paste")
    textView.deleteToBeginningOfLine(nil)
    #expect(textView.string.isEmpty)
    textView.insertText(" ", replacementRange: NSRange(location: 0, length: 0))
    #expect(textView.string == " ")
}

private func makeDropItem(path: String, isDirectory: Bool, isPackage: Bool) -> FileItem {
    let url = URL(filePath: path, directoryHint: isDirectory ? .isDirectory : .notDirectory)
    return FileItem(
        url: url,
        name: url.lastPathComponent,
        isDirectory: isDirectory,
        isPackage: isPackage,
        modifiedAt: nil,
        byteSize: nil,
        typeDescription: isDirectory ? "Folder" : "File"
    )
}
