import Foundation
import SwiftUI

struct HelpView: View {
    @AppStorage("pengrid.help.language") private var storedLanguageCode = ""
    @State private var query = ""
    @State private var selectedTopicID: HelpTopicID?
    @State private var externalErrorMessage: String?
    @Environment(\.openURL) private var openURL

    private var language: HelpLanguage {
        HelpLanguage.resolve(
            storedCode: storedLanguageCode,
            preferredLanguages: Locale.preferredLanguages
        )
    }

    var body: some View {
        let copy = HelpPresentationCopy.value(for: language)
        let results = HelpCatalog.search(query, displaying: language)
        let selectedTopic = selectedTopicID.flatMap { selectedID in
            results.first { topic in topic.id == selectedID }
        }

        NavigationSplitView {
            HelpSidebarView(
                query: $query,
                results: results,
                selectedTopicID: $selectedTopicID,
                language: language,
                copy: copy
            )
            .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 360)
        } detail: {
            HelpDetailColumn(
                topic: selectedTopic,
                resultCount: results.count,
                query: $query,
                language: language,
                copy: copy,
                externalErrorMessage: externalErrorMessage,
                openExternal: openExternal
            )
        }
        .navigationTitle(copy.windowTitle)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                HelpLanguagePicker(
                    selection: languageSelection,
                    language: language,
                    copy: copy
                )
            }
        }
        .accessibilityIdentifier(AccessibilityIdentifiers.helpWindow)
        .accessibilityLabel(copy.windowTitle)
        .frame(minWidth: 720, minHeight: 520)
        .onAppear {
            reconcileSelection()
        }
        .onChange(of: query) {
            reconcileSelection()
        }
        .onChange(of: language) {
            reconcileSelection()
        }
        .onChange(of: selectedTopicID) {
            externalErrorMessage = nil
        }
    }

    private var languageSelection: Binding<HelpLanguage> {
        Binding(
            get: { language },
            set: { storedLanguageCode = $0.rawValue }
        )
    }

    private func reconcileSelection() {
        let results = HelpCatalog.search(query, displaying: language)
        selectedTopicID = HelpCatalog.reconciledSelection(
            current: selectedTopicID,
            results: results
        )
        externalErrorMessage = nil
    }

    private func openExternal(
        _ destination: HelpExternalDestination,
        language: HelpLanguage
    ) {
        openURL(destination.url(for: language)) { accepted in
            if accepted {
                externalErrorMessage = nil
            } else {
                externalErrorMessage = HelpPresentationCopy.value(for: language)
                    .externalOpenFailedMessage
            }
        }
    }
}

private struct HelpSidebarView: View {
    @Binding var query: String
    let results: [HelpTopic]
    @Binding var selectedTopicID: HelpTopicID?
    let language: HelpLanguage
    let copy: HelpPresentationCopy

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField(copy.searchPrompt, text: $query)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier(AccessibilityIdentifiers.helpSearch)
                .accessibilityLabel(copy.searchPrompt)
                .accessibilityHint(searchHint)

            Text(copy.resultCount(results.count))
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(AccessibilityIdentifiers.helpResultCount)
                .accessibilityLabel(copy.resultCount(results.count))

            List(results, selection: $selectedTopicID) { topic in
                HelpTopicRow(topic: topic)
                    .tag(topic.id)
                    .accessibilityIdentifier(AccessibilityIdentifiers.helpTopic(topic.id))
            }
            .listStyle(.sidebar)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(AccessibilityIdentifiers.helpTopicList)
            .accessibilityLabel(topicListLabel)
            .accessibilityHint(topicListHint)
        }
        .padding(.vertical, 8)
    }

    private var topicListLabel: String {
        language == .korean ? "도움말 항목 목록" : "Help topics"
    }

    private var topicListHint: String {
        language == .korean
            ? "도움말 항목을 선택하면 오른쪽에 자세한 내용이 표시됩니다."
            : "Select a help topic to show its details on the right."
    }

    private var searchHint: String {
        language == .korean
            ? "제목과 도움말 내용을 검색합니다."
            : "Search help titles and content."
    }
}

private struct HelpLanguagePicker: View {
    let selection: Binding<HelpLanguage>
    let language: HelpLanguage
    let copy: HelpPresentationCopy

    var body: some View {
        Picker(copy.languageLabel, selection: selection) {
            Text(languageName(for: .korean)).tag(HelpLanguage.korean)
            Text(languageName(for: .english)).tag(HelpLanguage.english)
        }
        .pickerStyle(.segmented)
        .accessibilityIdentifier(AccessibilityIdentifiers.helpLanguage)
        .accessibilityLabel(copy.languageLabel)
        .accessibilityHint(languageHint)
    }

    private func languageName(for option: HelpLanguage) -> String {
        switch (language, option) {
        case (.korean, .korean): "한국어"
        case (.korean, .english): "영어"
        case (.english, .korean): "Korean"
        case (.english, .english): "English"
        }
    }

    private var languageHint: String {
        language == .korean
            ? "도움말에 표시할 언어를 선택합니다."
            : "Choose the language shown in Help."
    }
}

private struct HelpTopicRow: View {
    let topic: HelpTopic

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(topic.title)
                .font(.headline)
                .foregroundStyle(.primary)
            Text(topic.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(topic.title)
        .accessibilityHint(topic.summary)
    }
}

private struct HelpDetailColumn: View {
    let topic: HelpTopic?
    let resultCount: Int
    @Binding var query: String
    let language: HelpLanguage
    let copy: HelpPresentationCopy
    let externalErrorMessage: String?
    let openExternal: (HelpExternalDestination, HelpLanguage) -> Void

    var body: some View {
        Group {
            if let topic {
                HelpTopicDetailView(
                    topic: topic,
                    language: language,
                    copy: copy,
                    externalErrorMessage: externalErrorMessage,
                    openExternal: openExternal
                )
            } else if resultCount == 0 {
                HelpNoResultsView(query: $query, copy: copy, language: language)
            } else {
                HelpSelectTopicView(language: language)
            }
        }
        .accessibilityIdentifier(AccessibilityIdentifiers.helpDetail)
        .accessibilityLabel(detailLabel)
    }

    private var detailLabel: String {
        language == .korean ? "도움말 상세 내용" : "Help details"
    }
}

private struct HelpNoResultsView: View {
    @Binding var query: String
    let copy: HelpPresentationCopy
    let language: HelpLanguage

    var body: some View {
        ContentUnavailableView {
            Label(copy.noResultsTitle, systemImage: "magnifyingglass")
        } description: {
            Text(copy.noResultsMessage)
        } actions: {
            Button(copy.clearSearch) {
                query = ""
            }
            .accessibilityIdentifier(AccessibilityIdentifiers.helpClearSearch)
            .accessibilityHint(clearSearchHint)
        }
        .accessibilityIdentifier(AccessibilityIdentifiers.helpNoResults)
        .accessibilityLabel(copy.noResultsTitle)
        .accessibilityHint(noResultsHint)
    }

    private var noResultsHint: String {
        language == .korean
            ? "검색 필드에서 검색어를 지우면 모든 항목을 다시 표시합니다."
            : "Clear the search field to show all topics again."
    }

    private var clearSearchHint: String {
        language == .korean
            ? "검색어를 지우고 모든 도움말 항목을 표시합니다."
            : "Clear the query and show all help topics."
    }
}

private struct HelpSelectTopicView: View {
    let language: HelpLanguage

    var body: some View {
        ContentUnavailableView(
            language == .korean ? "도움말 항목을 선택하세요" : "Select a Help Topic",
            systemImage: "sidebar.left"
        )
    }
}

private struct HelpTopicDetailView: View {
    let topic: HelpTopic
    let language: HelpLanguage
    let copy: HelpPresentationCopy
    let externalErrorMessage: String?
    let openExternal: (HelpExternalDestination, HelpLanguage) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(topic.title)
                        .font(.title)
                        .foregroundStyle(.primary)
                        .accessibilityIdentifier(AccessibilityIdentifiers.helpDetailTitle)
                        .accessibilityAddTraits(.isHeader)
                    Text(topic.summary)
                        .font(.body)
                        .foregroundStyle(.secondary)
                }

                ForEach(topic.sections, id: \.heading) { section in
                    HelpSectionView(section: section)
                }

                if !topic.shortcuts.isEmpty {
                    HelpShortcutsView(shortcuts: topic.shortcuts, language: language)
                }

                if let destination = topic.externalDestination {
                    HelpExternalLinkView(
                        destination: destination,
                        language: language,
                        copy: copy,
                        externalErrorMessage: externalErrorMessage,
                        openExternal: openExternal
                    )
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(28)
        }
        .background(.background)
    }
}

private struct HelpSectionView: View {
    let section: HelpSection

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(section.heading)
                .font(.headline)
                .foregroundStyle(.primary)
                .accessibilityAddTraits(.isHeader)

            ForEach(section.paragraphs, id: \.self) { paragraph in
                Text(paragraph)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(section.bulletItems, id: \.self) { bullet in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("•")
                        .font(.body)
                        .foregroundStyle(.secondary)
                    Text(bullet)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

private struct HelpShortcutsView: View {
    let shortcuts: [HelpShortcut]
    let language: HelpLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(language == .korean ? "단축키" : "Shortcuts")
                .font(.headline)
                .foregroundStyle(.primary)
                .accessibilityAddTraits(.isHeader)

            ForEach(shortcuts, id: \.keys) { shortcut in
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Text(shortcut.keys)
                        .font(.body.monospaced())
                        .foregroundStyle(.primary)
                        .frame(minWidth: 150, alignment: .leading)
                    Text(shortcut.action)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(shortcut.keys), \(shortcut.action)")
            }
        }
    }
}

private struct HelpExternalLinkView: View {
    let destination: HelpExternalDestination
    let language: HelpLanguage
    let copy: HelpPresentationCopy
    let externalErrorMessage: String?
    let openExternal: (HelpExternalDestination, HelpLanguage) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(destination.buttonTitle(for: language)) {
                openExternal(destination, language)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier(externalActionIdentifier)
            .accessibilityHint(copy.internetRequired)

            Text(copy.internetRequired)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let externalErrorMessage {
                Text(externalErrorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(AccessibilityIdentifiers.helpExternalError)
                    .accessibilityLabel(copy.externalOpenFailedTitle)
                    .accessibilityValue(externalErrorMessage)
            }
        }
    }

    private var externalActionIdentifier: String {
        switch destination {
        case .userGuide:
            AccessibilityIdentifiers.helpUserGuideAction
        case .releases:
            AccessibilityIdentifiers.helpReleasesAction
        }
    }
}
