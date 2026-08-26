# Pengrid Native Help Center Design

Date: 2026-08-26
Status: Approved for implementation planning

## Summary

Pengrid will add a native, offline Help window that explains the eight most
important user workflows in Korean and English. Users open one singleton Help
window from the standard Help menu or with Command-?. The window provides
topic navigation, bilingual full-text search including Korean initial-consonant
queries, a language picker, accessible native controls, and allowlisted links
to the complete GitHub user guide and release page.

This feature is a documentation surface. It does not read user files, inspect
workspace state, start File Provider materialization, or make network requests
inside Pengrid.

## Goals

- Make the core Pengrid workflows discoverable without leaving the app.
- Work offline for the eight core topics.
- Provide equivalent Korean and English topic coverage.
- Reuse Pengrid's established case-, diacritic-, and Hangul-initial search
  behavior.
- Follow native macOS window, menu, keyboard, sidebar, and accessibility
  conventions.
- Keep external navigation explicit, allowlisted, and separate from offline
  content.
- Make catalog integrity, search, language resolution, scene wiring, and
  accessibility contracts testable without opening user files.

## Non-goals

- Apple Help Book registration or Help Viewer indexing.
- Rendering the repository Markdown files inside the app.
- Embedding a WebView or loading remote content inside Pengrid.
- A context-sensitive help system that follows the selected file or active
  workspace control.
- Search-result ranking, snippets, or matched-text highlighting.
- Editing, downloading, or updating help content independently of an app
  release.
- Translating the rest of Pengrid's English application UI in this change.

## User entry points and window behavior

`BloomFileManagerApp` will register a singleton auxiliary scene:

```swift
Window("Pengrid Help", id: PengridHelpScene.id) {
    HelpView()
}
```

The default size is approximately 860 by 620 points, with a practical minimum
size that keeps the topic list and detail readable. The scene owns no workspace
or file-operation dependencies.

`PengridHelpCommands` replaces the standard Help command group with a visible
**Pengrid Help** action. It opens `PengridHelpScene.id` through
`openWindow(id:)` and uses Command-? as its shortcut. Repeated invocation
brings the singleton Help window forward instead of creating duplicates.

Opening, closing, searching, or changing language in Help must not change the
main workspace selection, navigation, modal ownership, preview state, or file
operation queue.

## Information architecture

The catalog has exactly eight stable topic identifiers in this order:

1. `gettingStarted` — installation trust notice, first launch, two-pane model
2. `dualPaneNavigation` — active pane, history, tabs, profiles, preview
3. `search` — pane filter, Smart Search, indexed contents, Korean initials
4. `fileOperations` — copy, move, Duplicate, Operation Center, safe cancel,
   Retry, Undo, transferred-content verification
5. `archives` — supported formats, progress, AES-256 protected ZIP boundaries
6. `cloudLocations` — macOS File Provider, Google Drive, OneDrive,
   online-only materialization, no direct OAuth client
7. `shortcuts` — the primary keyboard commands grouped by purpose
8. `troubleshooting` — Gatekeeper, permissions, cloud availability, recovery,
   privacy, and where to report reproducible issues

Each topic contains a title, concise summary, ordered sections, searchable
keywords, optional shortcut rows, and optional external destinations. Korean
and English catalogs must contain the same identifiers, order, section intent,
and external destinations. The prose is language-specific rather than a
machine translation performed at runtime.

## Model boundaries

### `HelpLanguage`

`HelpLanguage` has `.korean` and `.english` values plus stable stored codes. A
pure resolver selects the effective language using these rules:

1. A valid stored user choice wins.
2. Without a stored choice, a first preferred-language identifier beginning
   with `ko` selects Korean.
3. Every other or malformed value selects English.

The view stores an explicit choice in `@AppStorage`. An empty stored value
means “follow the initial system preference.” Search text and topic selection
remain window-local and are not persisted.

### Topic values

`HelpTopicID` is a stable enum for the eight topics. `HelpTopic`,
`HelpSection`, and `HelpShortcut` are immutable, `Sendable`, equatable value
types. Views receive values and do not mutate the catalog.

### External destinations

Catalog content never stores arbitrary URL strings. It refers to a closed
`HelpExternalDestination` enum such as `.userGuide` and `.releases`.
Destination resolution produces only HTTPS URLs on `github.com` under the
`pmh10401/Pengrid` repository. The user-guide destination resolves to the
selected language's guide; the releases destination is language-independent.

This closed model makes unsupported schemes, hosts, repository paths, and
user-supplied URLs unrepresentable in production catalog data. Tests still
assert every resolved destination remains inside the allowlist.

### `HelpCatalog`

`HelpCatalog` exposes localized topics by language and a search operation. It
validates static catalog invariants in tests rather than failing at runtime for
developer-authored constants. Production lookup is deterministic and has no
I/O.

## Search behavior

The search field matches topic titles, summaries, section headings, section
bodies, shortcut labels and keys, and hidden keywords. A topic's Korean and
English searchable text are both indexed regardless of the currently displayed
language. This keeps the result set and selected topic stable when the user
changes language and lets a user find a Korean topic with an English term, or
the reverse. Results are rendered in the chosen display language.

Search reuses `SmartSearchTextAnalyzer`:

- literal matching is case- and diacritic-insensitive;
- compatibility and canonical Korean initial consonants are supported;
- mixed literal and initial-consonant clauses must all match;
- a blank or whitespace-only query returns all eight topics;
- a nonblank query with no matches returns an empty result;
- matching topics preserve catalog order; there is no scoring in this version.

The implementation builds one bounded search text per topic from the two
localized presentations. The catalog is fixed at eight small topics, so search
is synchronous and requires no task, cancellation, cache, or background index.

## View design

`HelpView` uses a native `NavigationSplitView`:

- The sidebar contains the search field, a result count, and the filtered topic
  list using native sidebar rows.
- The detail pane contains the selected topic's title, summary, sections,
  shortcuts, and external actions in a vertically scrolling view.
- A compact Korean/English picker is visible in the Help window toolbar.
- The first topic is selected initially.
- When search removes the current selection, the first matching topic becomes
  selected. No result clears the selection and shows a dedicated empty state.
- Clearing search restores all topics and selects the first topic if no valid
  selection remains.
- Changing language preserves the search result membership and selected topic
  because search indexes both translations by stable topic ID.

The no-result state says that no help topic matches and provides a clear-search
button. The detail view does not implement result highlighting in this version.

External buttons state that the destination requires internet access. They use
the environment `openURL` action. A rejected open request presents a bounded,
nontechnical error in the Help window and does not retry automatically. Once a
request is accepted by macOS, browser connectivity and rendering are outside
Pengrid's responsibility.

## Accessibility and keyboard behavior

The Help menu and Command-? provide keyboard entry. Standard Tab and native
sidebar navigation reach the search field, language picker, topic list, detail
content, clear-search action, and external links.

Stable accessibility identifiers will cover:

- Help window root
- search field and result count
- language picker
- topic list and topic rows derived only from `HelpTopicID`
- detail title and detail content
- no-result state and clear-search button
- user-guide and releases actions
- external-link error state

Identifiers never contain translated text, search queries, file paths, or URLs.
VoiceOver labels and hints are localized with the displayed Help language.
Semantic headings identify the topic title and section headings. The UI uses
system colors, materials, Dynamic Type-compatible text styles, and Reduce
Motion-safe native transitions; it adds no custom animation.

## File and component plan

- `Sources/BloomFileManager/Models/HelpModels.swift`
  - languages, stable topic identifiers, immutable topic values, external
    destination values, language resolution
- `Sources/BloomFileManager/Support/HelpCatalog.swift`
  - Korean and English catalog constants, bilingual search projection,
    deterministic filtering
- `Sources/BloomFileManager/Views/HelpView.swift`
  - window-local state and native sidebar-detail presentation
- `Sources/BloomFileManager/Support/PengridHelpCommands.swift`
  - Help command group, shortcut, scene ID
- `Sources/BloomFileManager/App/BloomFileManagerApp.swift`
  - singleton Help scene and command registration
- `Sources/BloomFileManager/Support/AccessibilityIdentifiers.swift`
  - stable Help identifiers
- `Tests/BloomFileManagerTests/HelpCatalogTests.swift`
  - catalog, language, destination, and search behavior
- `Tests/BloomFileManagerTests/HelpPresentationTests.swift`
  - scene, commands, shortcut, view structure, and accessibility contracts
- `README.md`, `README.ko.md`, `docs/user-guide.md`, and
  `docs/user-guide.ko.md`
  - Help entry point, language/search behavior, offline and online boundary

If implementation shows that `HelpView.swift` cannot remain focused, topic
detail and empty-state views may move into separate files without changing the
public design. No unrelated view refactor is in scope.

## TDD and verification

Implementation follows red-green-refactor. Before each production behavior,
the corresponding test must be observed failing for the missing feature.

### Model and catalog tests

- exactly eight unique stable topic IDs in the approved order;
- identical Korean and English topic IDs and corresponding section intent;
- nonempty titles, summaries, section headings and bodies, and search text;
- valid stored language wins, `ko` system preference falls back to Korean, and
  malformed or other preferences fall back to English;
- every external destination resolves to HTTPS on the allowed GitHub
  repository and the user guide follows the selected language;
- blank search returns all topics in order;
- English literals, Korean literals, case/diacritic folding, compatibility and
  canonical Korean initials, and mixed queries return the expected topics;
- both-language indexing keeps search membership stable across display-language
  changes;
- unmatched nonblank search returns no topics;
- selection reconciliation keeps a visible ID, selects the first replacement,
  and clears for no results.

### Presentation contract tests

- the app registers one `Window` with the stable Help scene ID;
- the Help command group exposes **Pengrid Help**, opens that scene ID, and
  declares Command-? exactly once;
- the view uses native searchable sidebar-detail presentation and a language
  picker;
- Help accessibility identifiers exist, are unique, and do not contain paths,
  URLs, queries, or translated copy;
- external-open rejection has a visible and accessible error state;
- no Help component depends on workspace, File Provider, or file-operation
  services.

### Verification sequence

1. Run focused Help tests during each TDD cycle.
2. Run all Help catalog and presentation tests together.
3. Run the complete nonparallel Swift test suite.
4. Build the arm64 Release product.
5. Build and launch the development app.
6. Manually verify one Help window, Help menu, Command-?, all eight topics,
   search, Korean initials, language switching, no-result recovery, external
   actions, Light/Dark Mode, keyboard traversal, and a basic VoiceOver pass.
7. Run existing package contract checks before considering a release candidate.

Manual checks remain labelled as manual evidence; automated source and model
tests do not claim that VoiceOver or external browser behavior was physically
observed.

## Documentation and release boundary

README and user-guide updates will describe the feature only after the code is
implemented and verified. The Help window will identify its offline scope and
link to the current `main` user guide for detail. A release note must not claim
that the feature is in a published DMG until an exact merged commit is packaged,
validated, uploaded, and publicly redownloaded.

## Acceptance criteria

The feature is ready for integration when:

- Help opens from the standard menu and Command-? into one singleton window;
- the Help window presents all eight approved topics offline in Korean and
  English;
- search supports literals, folding, Korean initials, and mixed queries while
  preserving stable catalog order;
- language choice is remembered and language switching preserves the selected
  topic and search membership;
- the Help surface is fully usable without file-system, File Provider, or
  network access;
- external destinations are closed, allowlisted GitHub HTTPS links with a
  bounded rejection state;
- accessibility identifiers and semantic labels meet the stated privacy and
  stability rules;
- focused tests, the complete test suite, arm64 Release build, app launch, and
  the recorded manual checks pass;
- English and Korean public documentation accurately distinguishes current
  source behavior from the latest published DMG.
