import SwiftUI

enum BatchRenameRuleFamily: String, CaseIterable, Identifiable, Sendable {
    case findReplace
    case prefix
    case suffix
    case sequence

    var id: Self { self }

    var title: String {
        switch self {
        case .findReplace: "Find and Replace"
        case .prefix: "Add Prefix"
        case .suffix: "Add Suffix"
        case .sequence: "Name and Sequence"
        }
    }
}

enum BatchRenameFocusTarget: Hashable, Sendable {
    case findText
    case replacement
    case prefix
    case suffix
    case sequenceBase
    case sequenceStart
    case sequenceDigits
}

enum BatchRenameFocusRouting {
    static func target(
        for rule: BatchRenameRule,
        summary: BatchRenameValidationSummary
    ) -> BatchRenameFocusTarget? {
        guard case .invalid = summary else { return nil }
        return switch rule {
        case .findReplace: .findText
        case .prefix: .prefix
        case .suffix: .suffix
        case .sequence: .sequenceBase
        }
    }
}

struct BatchRenameSheetPresentation: Equatable, Sendable {
    let submitTitle: String
    let summaryLabel: String
    let isExecuting: Bool

    init(
        itemCount: Int,
        summary: BatchRenameValidationSummary,
        phase: BatchRenameModelPhase
    ) {
        let count = max(itemCount, 0)
        submitTitle = count == 1 ? "Rename 1 Item" : "Rename \(count) Items"
        summaryLabel = summary.message
        isExecuting = phase == .executing
    }
}

struct BatchRenameSheet: View {
    let model: BatchRenameModel
    let onSubmit: @MainActor (BatchRenamePlan) -> Bool

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var family: BatchRenameRuleFamily = .prefix
    @State private var findText = ""
    @State private var replacement = ""
    @State private var caseSensitive = true
    @State private var prefix = ""
    @State private var suffix = ""
    @State private var sequenceBase = "Item"
    @State private var sequenceStart = 1
    @State private var sequenceDigits = 2
    @FocusState private var focusedField: BatchRenameFocusTarget?

    private var presentation: BatchRenameSheetPresentation {
        BatchRenameSheetPresentation(
            itemCount: model.itemCount,
            summary: model.validationSummary,
            phase: model.phase
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Batch Rename")
                .font(.title2.weight(.semibold))

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Rule")
                    .frame(width: 96, alignment: .trailing)
                Picker("Rule", selection: $family) {
                    ForEach(BatchRenameRuleFamily.allCases) { family in
                        Text(family.title).tag(family)
                    }
                }
                .labelsHidden()
                .accessibilityIdentifier(AccessibilityIdentifiers.batchRenameRule)
            }

            ruleControls
                .disabled(presentation.isExecuting)

            Label(
                "File and package extensions are preserved.",
                systemImage: "lock.shield"
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            BatchRenamePreviewTable(entries: model.preview.entries)
                .frame(minHeight: 260)

            HStack(spacing: 12) {
                if model.phase == .capturing || model.phase == .planning {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Preparing rename preview")
                }
                Text(presentation.summaryLabel)
                    .font(.callout)
                    .foregroundStyle(model.validationSummary.invalidCount > 0 ? .red : .secondary)
                    .accessibilityIdentifier(AccessibilityIdentifiers.batchRenameValidation)
                    .accessibilityLabel(presentation.summaryLabel)

                Spacer()

                Button("Cancel") {
                    model.cancel()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(presentation.isExecuting)
                .accessibilityIdentifier(AccessibilityIdentifiers.batchRenameCancel)

                Button(presentation.submitTitle) {
                    submit()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canSubmit)
                .accessibilityIdentifier(AccessibilityIdentifiers.batchRenameSubmit)
            }
        }
        .padding(20)
        .frame(minWidth: 720, idealWidth: 820, minHeight: 500, idealHeight: 580)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityIdentifiers.batchRenameSheet)
        .interactiveDismissDisabled(presentation.isExecuting)
        .transaction { transaction in
            if accessibilityReduceMotion {
                transaction.animation = nil
            }
        }
        .onAppear {
            Task { @MainActor in
                await Task.yield()
                focusedField = .prefix
            }
        }
        .onChange(of: family) { _, _ in
            applyRule()
            focusedField = defaultFocus
        }
        .onChange(of: findText) { _, _ in applyRule() }
        .onChange(of: replacement) { _, _ in applyRule() }
        .onChange(of: caseSensitive) { _, _ in applyRule() }
        .onChange(of: prefix) { _, _ in applyRule() }
        .onChange(of: suffix) { _, _ in applyRule() }
        .onChange(of: sequenceBase) { _, _ in applyRule() }
        .onChange(of: sequenceStart) { _, _ in applyRule() }
        .onChange(of: sequenceDigits) { _, _ in applyRule() }
        .onChange(of: model.validationSummary) { _, summary in
            if let target = BatchRenameFocusRouting.target(for: model.rule, summary: summary) {
                focusedField = target
            }
        }
    }

    @ViewBuilder
    private var ruleControls: some View {
        switch family {
        case .findReplace:
            LabeledContent("Find") {
                TextField("Text to find", text: $findText)
                    .focused($focusedField, equals: .findText)
                    .accessibilityIdentifier(AccessibilityIdentifiers.batchRenameFind)
                    .accessibilityHint("Literal text in each filename; regular expressions are not used")
            }
            LabeledContent("Replace with") {
                TextField("Replacement text", text: $replacement)
                    .focused($focusedField, equals: .replacement)
                    .accessibilityIdentifier(AccessibilityIdentifiers.batchRenameReplacement)
            }
            Toggle("Match case", isOn: $caseSensitive)
                .padding(.leading, 108)

        case .prefix:
            LabeledContent("Prefix") {
                TextField("Text before each name", text: $prefix)
                    .focused($focusedField, equals: .prefix)
                    .accessibilityIdentifier(AccessibilityIdentifiers.batchRenamePrefix)
            }

        case .suffix:
            LabeledContent("Suffix") {
                TextField("Text after each name", text: $suffix)
                    .focused($focusedField, equals: .suffix)
                    .accessibilityIdentifier(AccessibilityIdentifiers.batchRenameSuffix)
            }

        case .sequence:
            LabeledContent("Base name") {
                TextField("Name before the number", text: $sequenceBase)
                    .focused($focusedField, equals: .sequenceBase)
                    .accessibilityIdentifier(AccessibilityIdentifiers.batchRenameSequenceBase)
            }
            LabeledContent("Start at") {
                Stepper(value: $sequenceStart, in: 0...999_999) {
                    Text("\(sequenceStart)")
                        .monospacedDigit()
                }
                .focused($focusedField, equals: .sequenceStart)
                .accessibilityIdentifier(AccessibilityIdentifiers.batchRenameSequenceStart)
            }
            LabeledContent("Number width") {
                Stepper(value: $sequenceDigits, in: 1...9) {
                    Text("\(sequenceDigits) digits")
                        .monospacedDigit()
                }
                .focused($focusedField, equals: .sequenceDigits)
                .accessibilityIdentifier(AccessibilityIdentifiers.batchRenameSequenceDigits)
            }
        }
    }

    private var defaultFocus: BatchRenameFocusTarget {
        switch family {
        case .findReplace: .findText
        case .prefix: .prefix
        case .suffix: .suffix
        case .sequence: .sequenceBase
        }
    }

    private func applyRule() {
        let rule = switch family {
        case .findReplace:
            BatchRenameRule.findReplace(
                find: findText,
                replacement: replacement,
                caseSensitive: caseSensitive
            )
        case .prefix:
            BatchRenameRule.prefix(prefix)
        case .suffix:
            BatchRenameRule.suffix(suffix)
        case .sequence:
            BatchRenameRule.sequence(
                baseName: sequenceBase,
                start: sequenceStart,
                digits: sequenceDigits
            )
        }
        model.updateRule(rule)
    }

    private func submit() {
        guard let plan = model.beginSubmission() else {
            focusedField = BatchRenameFocusRouting.target(
                for: model.rule,
                summary: model.validationSummary
            )
            return
        }
        let didStart = onSubmit(plan)
        model.finishSubmission(didStart: didStart)
    }
}
