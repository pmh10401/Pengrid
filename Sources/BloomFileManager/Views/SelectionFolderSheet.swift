import SwiftUI

enum SelectionFolderFocusTarget: Hashable, Sendable {
    case folderName
}

enum SelectionFolderFocusRouting {
    static let initialTarget = SelectionFolderFocusTarget.folderName
}

struct SelectionFolderSheetPresentation: Equatable, Sendable {
    let title: String
    let submitTitle = "Create Folder"
    let validationMessage: String?
    let isSubmitEnabled: Bool

    init(itemCount: Int, validationMessage: String?) {
        let count = max(itemCount, 0)
        title = count == 1 ? "New Folder with 1 Item" : "New Folder with \(count) Items"
        self.validationMessage = validationMessage
        isSubmitEnabled = validationMessage == nil
    }
}

struct SelectionFolderSheet: View {
    let model: SelectionFolderModel
    let onSubmit: @MainActor (SelectionFolderPlan) -> Bool

    @FocusState private var focusedField: SelectionFolderFocusTarget?

    private var presentation: SelectionFolderSheetPresentation {
        SelectionFolderSheetPresentation(
            itemCount: model.snapshot?.sources.count ?? 0,
            validationMessage: model.validationMessage
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(presentation.title)
                .font(.title2.weight(.semibold))

            Text("Selected items will be moved into the new folder.")
                .foregroundStyle(.secondary)

            TextField("Folder name", text: Binding(
                get: { model.folderName },
                set: { value in model.updateName(value) }
            ))
            .focused($focusedField, equals: .folderName)
            .accessibilityIdentifier(AccessibilityIdentifiers.selectionFolderName)

            if let validationMessage = model.validationMessage {
                Text(validationMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier(AccessibilityIdentifiers.selectionFolderValidation)
                    .accessibilityLabel(validationMessage)
            }

            HStack {
                Spacer()
                Button("Cancel") { model.dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier(AccessibilityIdentifiers.selectionFolderCancel)
                Button(presentation.submitTitle) { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canSubmit)
                    .accessibilityIdentifier(AccessibilityIdentifiers.selectionFolderSubmit)
            }
        }
        .padding(20)
        .frame(minWidth: 430)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityIdentifiers.selectionFolderSheet)
        .onAppear {
            Task { @MainActor in
                await Task.yield()
                focusedField = SelectionFolderFocusRouting.initialTarget
            }
        }
    }

    private func submit() {
        guard let plan = model.beginSubmission() else {
            focusedField = .folderName
            return
        }
        if onSubmit(plan) {
            model.dismiss()
        }
    }
}
