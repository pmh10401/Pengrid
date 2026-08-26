import SwiftUI

enum PengridHelpScene {
    static let id = "pengrid-help"
}

struct PengridHelpCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Pengrid Help") {
                openWindow(id: PengridHelpScene.id)
            }
            .keyboardShortcut("?", modifiers: .command)
        }
    }
}
