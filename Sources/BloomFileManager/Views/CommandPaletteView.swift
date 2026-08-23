import SwiftUI

struct CommandPaletteView: View {
    let store: CommandPaletteStore

    @FocusState private var queryFieldIsFocused: Bool
    @State private var selection: String?

    init(store: CommandPaletteStore) {
        self.store = store
        _selection = State(initialValue: store.selectedItemID)
    }

    var body: some View {
        @Bindable var store = store

        VStack(spacing: 12) {
            TextField("Search commands and locations", text: $store.query)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier(AccessibilityIdentifiers.commandPaletteQuery)
                .accessibilityLabel("Search commands and locations")
                .defaultFocus($queryFieldIsFocused, true)
                .onSubmit(executeSelection)

            if store.results.isEmpty {
                ContentUnavailableView.search
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(store.results) { item in
                        Button {
                            selection = item.id
                            store.requestExecution(itemID: item.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                if let subtitle = item.subtitle {
                                    Text(subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .tag(item.id)
                        .accessibilityIdentifier(AccessibilityIdentifiers.commandPaletteRow(item.id))
                        .accessibilityLabel(item.title)
                    }
                }
                .accessibilityIdentifier(AccessibilityIdentifiers.commandPaletteResults)
                .onChange(of: store.selectedItemID) { _, selectedItemID in
                    selection = selectedItemID
                }
            }
        }
        .padding()
        .frame(minWidth: 460, minHeight: 330)
        .accessibilityIdentifier(AccessibilityIdentifiers.commandPaletteSheet)
        .onExitCommand { store.dismiss() }
    }

    private func executeSelection() {
        guard let selection else { return }
        store.requestExecution(itemID: selection)
    }
}
