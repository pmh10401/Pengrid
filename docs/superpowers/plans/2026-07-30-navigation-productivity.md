# Pengrid 1.2 Navigation Productivity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add pane-local filename filtering, bounded navigation history, per-directory selection and scroll restoration, and live-selection Quick Look updates to Pengrid 1.2.

**Architecture:** Keep `FilePaneState` as the pane source of truth, but move filename matching, bounded history, and bounded view-state caching into focused value types. Extend the existing AppKit table bridge with explicit scroll-anchor input and output, and extend `QuickLookController` with an idempotent update-only-when-presented path. No feature in this plan performs recursive search, file-content reads, or cloud materialization except the existing Quick Look gate.

**Tech Stack:** Swift 6.1, SwiftUI, AppKit `NSTableView`, QuickLookUI, Observation, Swift Testing, Swift Package Manager, macOS 15.0+

## Global Constraints

- Preserve the internal package, executable, source module, and bundle name `BloomFileManager`.
- Support Apple Silicon on macOS 15.0 or newer.
- Add no third-party dependency.
- Search only the already-loaded current-directory item names.
- Search must not recurse, read file contents, call the listing service, or materialize File Provider items.
- Keep filename matching case-insensitive and diacritic-insensitive using localized standard matching.
- Keep filter state, backward and forward history, and view restoration independent per pane.
- Clear the current filter when navigating to another directory.
- Keep navigation history and view-state caches session-only and capped at 100 entries per pane.
- Preserve existing workspace persistence payload compatibility.
- Route cloud-only Quick Look through the existing identity-preserving materialization gate.
- Treat the 10,000-item duration as a generous regression ceiling, not a four-second product promise.
- Do not begin Pengrid 1.3 batch rename, archive, queue, retry, or undo work in this plan.

---

## File Structure

### New production files

- `Sources/BloomFileManager/Models/PaneFilenameFilter.swift` — pure localized filename matching.
- `Sources/BloomFileManager/Models/PaneNavigationHistory.swift` — bounded backward/forward stack transitions.
- `Sources/BloomFileManager/Models/PaneViewStateCache.swift` — bounded least-recently-used directory view state and scroll request values.

### Modified production files

- `Sources/BloomFileManager/Stores/FilePaneState.swift` — composes the three new models with pane loading, selection, and focus state.
- `Sources/BloomFileManager/Stores/WorkspaceState.swift` — recognizes filter text editing as an ordinary text-editing session.
- `Sources/BloomFileManager/Views/FilePaneView.swift` — renders and focuses the filename filter, reports scroll anchors, and consumes restoration requests.
- `Sources/BloomFileManager/Views/AppKit/FileTableView.swift` — reports the first visible item and applies idempotent scroll requests.
- `Sources/BloomFileManager/Views/WorkspaceView.swift` — observes active-pane selection and requests live Quick Look updates.
- `Sources/BloomFileManager/Support/WorkspaceCommands.swift` — adds the `Command-F` active-pane filter command.
- `Sources/BloomFileManager/Support/QuickLookController.swift` — tracks presentation state and updates or closes an existing panel safely.
- `Sources/BloomFileManager/Support/AccessibilityIdentifiers.swift` — adds stable filter identifiers and result-count presentation.

### New or modified tests

- `Tests/BloomFileManagerTests/PaneFilenameFilterTests.swift`
- `Tests/BloomFileManagerTests/PaneNavigationHistoryTests.swift`
- `Tests/BloomFileManagerTests/PaneViewStateCacheTests.swift`
- `Tests/BloomFileManagerTests/FilePaneStateTests.swift`
- `Tests/BloomFileManagerTests/FileTableViewLifecycleTests.swift`
- `Tests/BloomFileManagerTests/WorkspaceCommandTests.swift`
- `Tests/BloomFileManagerTests/CloudOperationGateTests.swift`
- `Tests/BloomFileManagerTests/AccessibilityPresentationTests.swift`
- `Tests/BloomFileManagerTests/NavigationProductivityPerformanceTests.swift`

### Documentation

- `docs/verification/version-1.2-checklist.md`
- `README.md`

---

### Task 1: Pane-local filename filtering model and state

**Files:**

- Create: `Sources/BloomFileManager/Models/PaneFilenameFilter.swift`
- Modify: `Sources/BloomFileManager/Stores/FilePaneState.swift`
- Create: `Tests/BloomFileManagerTests/PaneFilenameFilterTests.swift`
- Modify: `Tests/BloomFileManagerTests/FilePaneStateTests.swift`

**Interfaces:**

- Produces: `PaneFilenameFilter.init(query:)`
- Produces: `PaneFilenameFilter.apply(to:) -> [FileItem]`
- Produces: `FilePaneState.isFilterPresented: Bool`
- Produces: `FilePaneState.filterQuery: String`
- Produces: `FilePaneState.filterResultCount: Int`
- Produces: `FilePaneState.beginFiltering()`
- Produces: `FilePaneState.updateFilterQuery(_:)`
- Produces: `FilePaneState.dismissFiltering()`
- Consumes: existing `FilePaneState.items`, `selection`, `sort`, and `requestTableFocus()`

- [ ] **Step 1: Write failing pure-matcher tests**

Create `PaneFilenameFilterTests.swift` with explicit English, case, accent, and
Korean examples:

```swift
import Foundation
import Testing
@testable import BloomFileManager

struct PaneFilenameFilterTests {
    @Test func emptyQueryKeepsEveryItemInInputOrder() {
        let items = filterItems("Zulu.txt", "alpha.txt", "한글.pdf")
        #expect(PaneFilenameFilter(query: "").apply(to: items) == items)
        #expect(PaneFilenameFilter(query: "   ").apply(to: items) == items)
    }

    @Test func matchingIsLocalizedCaseAndDiacriticInsensitive() {
        let items = filterItems("Résumé.PDF", "resume-notes.txt", "photo.jpg")
        let matches = PaneFilenameFilter(query: "RESUME").apply(to: items)
        #expect(matches.map(\.name) == ["Résumé.PDF", "resume-notes.txt"])
    }

    @Test func koreanSubstringMatchingKeepsOriginalOrder() {
        let items = filterItems("여행사진.heic", "업무보고서.pdf", "여행계획.md")
        let matches = PaneFilenameFilter(query: "여행").apply(to: items)
        #expect(matches.map(\.name) == ["여행사진.heic", "여행계획.md"])
    }
}

private func filterItems(_ names: String...) -> [FileItem] {
    names.map { name in
        FileItem(
            url: URL(filePath: "/filter/\(name)"),
            name: name,
            isDirectory: false,
            isPackage: false,
            modifiedAt: nil,
            byteSize: 1,
            typeDescription: "File"
        )
    }
}
```

- [ ] **Step 2: Run the matcher tests and verify the type is missing**

Run:

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --disable-sandbox --filter PaneFilenameFilterTests
```

Expected: compilation fails because `PaneFilenameFilter` is not defined.

- [ ] **Step 3: Implement the pure matcher**

Create `PaneFilenameFilter.swift`:

```swift
import Foundation

struct PaneFilenameFilter: Equatable, Sendable {
    let query: String

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func apply(to items: [FileItem]) -> [FileItem] {
        guard !trimmedQuery.isEmpty else { return items }
        return items.filter { $0.name.localizedStandardContains(trimmedQuery) }
    }
}
```

- [ ] **Step 4: Run the matcher tests and verify they pass**

Run the command from Step 2.

Expected: all `PaneFilenameFilterTests` pass.

- [ ] **Step 5: Write failing pane filter-session tests**

Append tests to `FilePaneStateTests.swift` using a listing containing
`alpha.txt`, `Résumé.pdf`, and `한글보고서.pdf`:

```swift
@Test func filterSessionUsesLoadedItemsAndRestoresCapturedSelection() async {
    let root = URL(filePath: "/filter-root", directoryHint: .isDirectory)
    let alpha = makeItem(named: "alpha.txt", in: root)
    let resume = makeItem(named: "Résumé.pdf", in: root)
    let korean = makeItem(named: "한글보고서.pdf", in: root)
    let listing = CountingDirectoryListingService(values: [root: [alpha, resume, korean]])
    let pane = FilePaneState(directory: root, listingService: listing)
    await pane.navigate(to: root, recordHistory: false)
    pane.selection = [resume.url]

    pane.beginFiltering()
    pane.updateFilterQuery("한글")

    #expect(pane.visibleItems.map(\.name) == ["한글보고서.pdf"])
    #expect(pane.selection.isEmpty)
    #expect(pane.filterResultCount == 1)
    #expect(listing.callCount(for: root) == 1)

    pane.dismissFiltering()

    #expect(pane.visibleItems.count == 3)
    #expect(pane.selection == [resume.url])
    #expect(pane.filterQuery.isEmpty)
    #expect(!pane.isFilterPresented)
}

@Test func navigationClearsPaneFilterWithoutRestoringOldDirectorySelection() async {
    let root = URL(filePath: "/filter-root", directoryHint: .isDirectory)
    let next = root.appending(path: "Next", directoryHint: .isDirectory)
    let selected = makeItem(named: "selected.txt", in: root)
    let pane = FilePaneState(
        directory: root,
        listingService: StubDirectoryListingService(values: [
            root: [selected],
            next: [makeItem(named: "next.txt", in: next)]
        ])
    )
    await pane.navigate(to: root, recordHistory: false)
    pane.selection = [selected.url]
    pane.beginFiltering()
    pane.updateFilterQuery("selected")

    await pane.navigate(to: next)

    #expect(!pane.isFilterPresented)
    #expect(pane.filterQuery.isEmpty)
    #expect(pane.selection.isEmpty)
}
```

Add a thread-safe `CountingDirectoryListingService` test double whose
`batches(in:)` increments a locked count and emits the configured items once.

```swift
private final class CountingDirectoryListingService:
    DirectoryListingService,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let values: [URL: [FileItem]]
    private var counts: [URL: Int] = [:]

    init(values: [URL: [FileItem]]) {
        self.values = values
    }

    func batches(in directory: URL) -> AsyncThrowingStream<[FileItem], Error> {
        lock.withLock { counts[directory, default: 0] += 1 }
        let items = values[directory] ?? []
        return AsyncThrowingStream { continuation in
            continuation.yield(items)
            continuation.finish()
        }
    }

    func callCount(for directory: URL) -> Int {
        lock.withLock { counts[directory, default: 0] }
    }
}
```

- [ ] **Step 6: Run the pane tests and verify the new API is missing**

Run:

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --disable-sandbox --filter FilePaneStateTests
```

Expected: compilation fails on the new filter-session members.

- [ ] **Step 7: Implement pane filter-session state**

Add these members to `FilePaneState`:

```swift
private var selectionBeforeFiltering: Set<URL> = []
private(set) var isFilterPresented = false
private(set) var filterQuery = ""

var filterResultCount: Int { visibleItems.count }

var visibleItems: [FileItem] {
    sort.apply(to: PaneFilenameFilter(query: filterQuery).apply(to: items))
}

func beginFiltering() {
    if !isFilterPresented {
        selectionBeforeFiltering = selection
        isFilterPresented = true
    }
}

func updateFilterQuery(_ query: String) {
    filterQuery = query
    let visibleURLs = Set(visibleItems.map(\.url))
    selection.formIntersection(visibleURLs)
}

func dismissFiltering() {
    let captured = selectionBeforeFiltering
    isFilterPresented = false
    filterQuery = ""
    selectionBeforeFiltering.removeAll()
    let loadedURLs = Set(items.map(\.url))
    selection = captured.intersection(loadedURLs)
    requestTableFocus()
}

private func resetFilterForNavigation() {
    isFilterPresented = false
    filterQuery = ""
    selectionBeforeFiltering.removeAll()
}
```

Call `resetFilterForNavigation()` from `prepareForNavigation()` before starting
the replacement load. Do not call `dismissFiltering()` there, because that
would restore the previous directory selection into the destination.

- [ ] **Step 8: Run focused filter and pane tests**

Run:

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --disable-sandbox \
  --filter 'PaneFilenameFilterTests|FilePaneStateTests'
```

Expected: all selected tests pass.

- [ ] **Step 9: Commit the filter model and state**

```bash
git add Sources/BloomFileManager/Models/PaneFilenameFilter.swift \
  Sources/BloomFileManager/Stores/FilePaneState.swift \
  Tests/BloomFileManagerTests/PaneFilenameFilterTests.swift \
  Tests/BloomFileManagerTests/FilePaneStateTests.swift
git commit -m "feat: add pane-local filename filtering"
```

---

### Task 2: Filter field, command routing, focus, and accessibility

**Files:**

- Modify: `Sources/BloomFileManager/Stores/FilePaneState.swift`
- Modify: `Sources/BloomFileManager/Stores/WorkspaceState.swift`
- Modify: `Sources/BloomFileManager/Views/FilePaneView.swift`
- Modify: `Sources/BloomFileManager/Support/WorkspaceCommands.swift`
- Modify: `Sources/BloomFileManager/Support/AccessibilityIdentifiers.swift`
- Modify: `Tests/BloomFileManagerTests/WorkspaceCommandTests.swift`
- Modify: `Tests/BloomFileManagerTests/AccessibilityPresentationTests.swift`

**Interfaces:**

- Consumes: Task 1 filter-session methods.
- Produces: `FilePaneState.filterFocusRequestID: UUID?`
- Produces: `FilePaneState.requestFilterFocus()`
- Produces: `WorkspaceTextEditingSession.Kind.filter`
- Produces: `AccessibilityIdentifiers.leftPaneFilter`
- Produces: `AccessibilityIdentifiers.rightPaneFilter`
- Produces: `PaneFilterAccessibilityPresentation.resultCount(_:)`

- [ ] **Step 1: Write failing command and accessibility tests**

Add to `WorkspaceCommandTests.swift`:

```swift
@Test func filterEditingIsATextSessionAndCommandFTargetsOnlyTheActivePane() {
    let workspace = WorkspaceState(
        leftURL: URL(filePath: "/left"),
        rightURL: URL(filePath: "/right"),
        listingService: StubDirectoryListingService(values: [:])
    )
    let session = WorkspaceTextEditingSession(paneID: .right, kind: .filter)
    workspace.beginTextEditing(session)
    #expect(workspace.activeTextEditingSession == session)
    workspace.endTextEditing(session)

    workspace.activate(.right)
    WorkspaceFilterCommandActions.showFilter(in: workspace)
    #expect(!workspace.left.isFilterPresented)
    #expect(workspace.right.isFilterPresented)
    #expect(workspace.right.filterFocusRequestID != nil)
}
```

Add to `AccessibilityPresentationTests.swift`:

```swift
@Test func paneFilterAccessibilityIsStableAndReportsResults() {
    #expect(AccessibilityIdentifiers.leftPaneFilter == "leftPane.filter")
    #expect(AccessibilityIdentifiers.rightPaneFilter == "rightPane.filter")
    #expect(PaneFilterAccessibilityPresentation.resultCount(0) == "No matching items")
    #expect(PaneFilterAccessibilityPresentation.resultCount(1) == "1 matching item")
    #expect(PaneFilterAccessibilityPresentation.resultCount(12) == "12 matching items")
}
```

Extend the static source test to require the filter identifiers,
`.accessibilityValue(PaneFilterAccessibilityPresentation.resultCount(`, and
`.onExitCommand { dismissFilter() }` in `FilePaneView.swift`.

- [ ] **Step 2: Run the focused tests and verify the APIs are missing**

Run:

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --disable-sandbox \
  --filter 'WorkspaceCommandTests|AccessibilityPresentationTests'
```

Expected: compilation fails on `.filter`, `WorkspaceFilterCommandActions`, and
the accessibility symbols.

- [ ] **Step 3: Add focus request and command action interfaces**

Add to `FilePaneState`:

```swift
private(set) var filterFocusRequestID: UUID?

func requestFilterFocus() {
    beginFiltering()
    filterFocusRequestID = UUID()
}
```

Add `.filter` to `WorkspaceTextEditingSession.Kind`.

Add to `WorkspaceCommands.swift`:

```swift
@MainActor
enum WorkspaceFilterCommandActions {
    static func showFilter(in workspace: WorkspaceState) {
        workspace.activePane.requestFilterFocus()
    }
}
```

In the commands body, add an Edit-menu command without replacing the existing
pasteboard group:

```swift
CommandGroup(after: .pasteboard) {
    Button("Filter Files") {
        guard let workspace else { return }
        WorkspaceFilterCommandActions.showFilter(in: workspace)
    }
    .keyboardShortcut("f", modifiers: .command)
    .disabled(workspace == nil)
}
```

The command remains available while the filter field is already focused so
`Command-F` can refocus it. Existing file mutation commands remain suppressed
because `.filter` participates in `activeTextEditingSession`.

- [ ] **Step 4: Add accessibility identifiers and result-count copy**

Add:

```swift
static let leftPaneFilter = "leftPane.filter"
static let rightPaneFilter = "rightPane.filter"
```

and:

```swift
enum PaneFilterAccessibilityPresentation {
    static func resultCount(_ count: Int) -> String {
        switch count {
        case 0: "No matching items"
        case 1: "1 matching item"
        default: "\(count) matching items"
        }
    }
}
```

- [ ] **Step 5: Render and focus the pane-local filter**

In `FilePaneView`, add:

```swift
@State private var filterEditingSession: WorkspaceTextEditingSession?
@FocusState private var filterFieldIsFocused: Bool
```

Render this row between the path bar and `FileTableView` only while
`state.isFilterPresented`:

```swift
if state.isFilterPresented {
    HStack(spacing: 6) {
        Image(systemName: "magnifyingglass")
            .accessibilityHidden(true)
        TextField(
            "Filter files",
            text: Binding(
                get: { state.filterQuery },
                set: state.updateFilterQuery
            )
        )
        .textFieldStyle(.roundedBorder)
        .focused($filterFieldIsFocused)
        .onExitCommand { dismissFilter() }
        .accessibilityIdentifier(
            paneID == .left
                ? AccessibilityIdentifiers.leftPaneFilter
                : AccessibilityIdentifiers.rightPaneFilter
        )
        .accessibilityLabel("Filter files in this folder")
        .accessibilityValue(
            PaneFilterAccessibilityPresentation.resultCount(state.filterResultCount)
        )

        Text("\(state.filterResultCount)")
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)

        Button("Close") { dismissFilter() }
            .accessibilityLabel("Close file filter")
    }
    .padding(.horizontal, 8)
    .frame(height: 38)
    .background(.bar)
    .overlay(alignment: .bottom) { Divider() }
}
```

Add `onChange(of: state.filterFocusRequestID)` to activate the pane and focus
the field on the next main-actor turn. Mirror the existing path editing session
pattern with `.filter`, and make `dismissFilter()` end that session, call
`state.dismissFiltering()`, and return focus to the table. Also observe
`state.isFilterPresented`; when navigation resets it to `false`, clear
`filterFieldIsFocused` and end `filterEditingSession`. Include the filter
session in the existing `onDisappear` cleanup so
`WorkspaceState.activeTextEditingSession` cannot retain a disappeared editor.

- [ ] **Step 6: Run focused tests and build**

Run:

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --disable-sandbox \
  --filter 'WorkspaceCommandTests|AccessibilityPresentationTests|FilePaneStateTests'
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift build --disable-sandbox
```

Expected: focused tests pass and the app builds.

- [ ] **Step 7: Commit filter UI and command routing**

```bash
git add Sources/BloomFileManager/Stores/FilePaneState.swift \
  Sources/BloomFileManager/Stores/WorkspaceState.swift \
  Sources/BloomFileManager/Views/FilePaneView.swift \
  Sources/BloomFileManager/Support/WorkspaceCommands.swift \
  Sources/BloomFileManager/Support/AccessibilityIdentifiers.swift \
  Tests/BloomFileManagerTests/WorkspaceCommandTests.swift \
  Tests/BloomFileManagerTests/AccessibilityPresentationTests.swift
git commit -m "feat: add accessible file filter controls"
```

---

### Task 3: Bounded navigation history hardening

**Files:**

- Create: `Sources/BloomFileManager/Models/PaneNavigationHistory.swift`
- Modify: `Sources/BloomFileManager/Stores/FilePaneState.swift`
- Create: `Tests/BloomFileManagerTests/PaneNavigationHistoryTests.swift`
- Modify: `Tests/BloomFileManagerTests/FilePaneStateTests.swift`

**Interfaces:**

- Produces: `PaneNavigationHistory.init(capacity:)`
- Produces: `recordUserNavigation(from:to:)`
- Produces: `popBackward(from:) -> URL?`
- Produces: `popForward(from:) -> URL?`
- Produces: `backward: [URL]`
- Produces: `forward: [URL]`
- Consumes: existing `FilePaneState` navigation generation and snapshot rollback.

- [ ] **Step 1: Write failing bounded-history tests**

Create `PaneNavigationHistoryTests.swift`:

```swift
import Foundation
import Testing
@testable import BloomFileManager

struct PaneNavigationHistoryTests {
    @Test func userNavigationDropsAdjacentDuplicatesAndClearsForward() {
        var history = PaneNavigationHistory(capacity: 3)
        let a = URL(filePath: "/a")
        let b = URL(filePath: "/b")
        history.recordUserNavigation(from: a, to: b)
        history.recordUserNavigation(from: URL(filePath: "/a/"), to: b)
        #expect(history.backward == [a])
        #expect(history.forward.isEmpty)
    }

    @Test func stacksKeepOnlyTheNewestCapacityEntries() {
        var history = PaneNavigationHistory(capacity: 3)
        let urls = (0...4).map { URL(filePath: "/\($0)") }
        for index in 1..<urls.count {
            history.recordUserNavigation(from: urls[index - 1], to: urls[index])
        }
        #expect(history.backward == Array(urls[1...3]))
    }

    @Test func backwardAndForwardTransitionsAreSymmetric() {
        var history = PaneNavigationHistory(capacity: 100)
        let a = URL(filePath: "/a")
        let b = URL(filePath: "/b")
        let c = URL(filePath: "/c")
        history.recordUserNavigation(from: a, to: b)
        history.recordUserNavigation(from: b, to: c)
        #expect(history.popBackward(from: c) == b)
        #expect(history.backward == [a])
        #expect(history.forward == [c])
        #expect(history.popForward(from: b) == c)
        #expect(history.backward == [a, b])
        #expect(history.forward.isEmpty)
    }
}
```

- [ ] **Step 2: Run and verify the model is missing**

Run:

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --disable-sandbox --filter PaneNavigationHistoryTests
```

Expected: compilation fails because `PaneNavigationHistory` is undefined.

- [ ] **Step 3: Implement the bounded history value**

Create:

```swift
import Foundation

struct PaneNavigationHistory: Equatable, Sendable {
    private(set) var backward: [URL] = []
    private(set) var forward: [URL] = []
    let capacity: Int

    init(capacity: Int = 100) {
        self.capacity = max(1, capacity)
    }

    mutating func recordUserNavigation(from current: URL, to destination: URL) {
        guard Self.path(current) != Self.path(destination) else { return }
        backward = Self.appending(current, to: backward, capacity: capacity)
        forward.removeAll(keepingCapacity: true)
    }

    mutating func popBackward(from current: URL) -> URL? {
        guard let target = backward.popLast() else { return nil }
        forward = Self.appending(current, to: forward, capacity: capacity)
        return target
    }

    mutating func popForward(from current: URL) -> URL? {
        guard let target = forward.popLast() else { return nil }
        backward = Self.appending(current, to: backward, capacity: capacity)
        return target
    }

    private static func appending(
        _ url: URL,
        to original: [URL],
        capacity: Int
    ) -> [URL] {
        var stack = original
        let normalized = Self.path(url)
        if stack.last.map(Self.path) != normalized {
            stack.append(url.standardizedFileURL)
        }
        if stack.count > capacity {
            stack.removeFirst(stack.count - capacity)
        }
        return stack
    }

    private static func path(_ url: URL) -> String {
        url.standardizedFileURL.path(percentEncoded: false)
    }
}
```

- [ ] **Step 4: Run the pure history tests**

Run the command from Step 2.

Expected: all `PaneNavigationHistoryTests` pass.

- [ ] **Step 5: Integrate the value into pane snapshots**

Replace the two stored arrays in `FilePaneState` with:

```swift
private var navigationHistory = PaneNavigationHistory(capacity: 100)
var backHistory: [URL] { navigationHistory.backward }
var forwardHistory: [URL] { navigationHistory.forward }
```

Use:

```swift
navigationHistory.recordUserNavigation(from: currentDirectory, to: directory)
```

for ordinary navigation, and:

```swift
guard let target = navigationHistory.popBackward(from: currentDirectory) else { return }
```

or `popForward(from:)` for history movement. Store the complete
`PaneNavigationHistory` value in `PaneSnapshot` so existing cancellation and
failure rollback semantics remain atomic.

Add a `FilePaneStateTests` case that performs 105 successful navigations and
asserts `backHistory.count == 100`. Retain the existing failed-back test; it
proves an invalid destination is removed while the current directory and
remaining history survive.

- [ ] **Step 6: Run all pane and history tests**

Run:

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --disable-sandbox \
  --filter 'PaneNavigationHistoryTests|FilePaneStateTests'
```

Expected: all selected tests pass, including existing cancellation tests.

- [ ] **Step 7: Commit bounded history**

```bash
git add Sources/BloomFileManager/Models/PaneNavigationHistory.swift \
  Sources/BloomFileManager/Stores/FilePaneState.swift \
  Tests/BloomFileManagerTests/PaneNavigationHistoryTests.swift \
  Tests/BloomFileManagerTests/FilePaneStateTests.swift
git commit -m "refactor: bound pane navigation history"
```

---

### Task 4: Per-directory selection and scroll restoration

**Files:**

- Create: `Sources/BloomFileManager/Models/PaneViewStateCache.swift`
- Modify: `Sources/BloomFileManager/Stores/FilePaneState.swift`
- Modify: `Sources/BloomFileManager/Views/AppKit/FileTableView.swift`
- Modify: `Sources/BloomFileManager/Views/FilePaneView.swift`
- Create: `Tests/BloomFileManagerTests/PaneViewStateCacheTests.swift`
- Modify: `Tests/BloomFileManagerTests/FilePaneStateTests.swift`
- Modify: `Tests/BloomFileManagerTests/FileTableViewLifecycleTests.swift`

**Interfaces:**

- Produces: `PaneDirectoryViewState(selection:scrollAnchor:)`
- Produces: `PaneViewStateCache.store(_:for:)`
- Produces: `PaneViewStateCache.value(for:)`
- Produces: `PaneScrollRequest(id:anchor:)`
- Produces: `FilePaneState.recordFirstVisibleItem(_:)`
- Produces: `FilePaneState.scrollRestoreRequest: PaneScrollRequest?`
- Produces: `FilePaneState.consumeScrollRestoreRequest(_:)`
- Extends: `FileTableView` with `scrollRequest` and `onFirstVisibleItemChange`.

- [ ] **Step 1: Write failing cache tests**

Create `PaneViewStateCacheTests.swift`:

```swift
import Foundation
import Testing
@testable import BloomFileManager

struct PaneViewStateCacheTests {
    @Test func cacheReturnsStoredSelectionAndAnchor() {
        var cache = PaneViewStateCache(capacity: 2)
        let directory = URL(filePath: "/folder")
        let state = PaneDirectoryViewState(
            selection: [URL(filePath: "/folder/a")],
            scrollAnchor: URL(filePath: "/folder/m")
        )
        cache.store(state, for: directory)
        #expect(cache.value(for: directory) == state)
    }

    @Test func cacheEvictsTheLeastRecentlyUsedDirectory() {
        var cache = PaneViewStateCache(capacity: 2)
        let a = URL(filePath: "/a")
        let b = URL(filePath: "/b")
        let c = URL(filePath: "/c")
        cache.store(.init(selection: [], scrollAnchor: nil), for: a)
        cache.store(.init(selection: [], scrollAnchor: nil), for: b)
        _ = cache.value(for: a)
        cache.store(.init(selection: [], scrollAnchor: nil), for: c)
        #expect(cache.value(for: a) != nil)
        #expect(cache.value(for: b) == nil)
        #expect(cache.value(for: c) != nil)
    }
}
```

- [ ] **Step 2: Run and verify the cache types are missing**

Run:

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --disable-sandbox --filter PaneViewStateCacheTests
```

Expected: compilation fails on the new cache types.

- [ ] **Step 3: Implement bounded LRU view state**

Create:

```swift
import Foundation

struct PaneDirectoryViewState: Equatable, Sendable {
    let selection: Set<URL>
    let scrollAnchor: URL?
}

struct PaneScrollRequest: Equatable, Sendable {
    let id: UUID
    let anchor: URL
}

struct PaneViewStateCache: Sendable {
    private var values: [String: PaneDirectoryViewState] = [:]
    private var recency: [String] = []
    let capacity: Int

    init(capacity: Int = 100) {
        self.capacity = max(1, capacity)
    }

    mutating func store(_ value: PaneDirectoryViewState, for directory: URL) {
        let key = Self.key(directory)
        values[key] = value
        touch(key)
        while recency.count > capacity {
            values.removeValue(forKey: recency.removeFirst())
        }
    }

    mutating func value(for directory: URL) -> PaneDirectoryViewState? {
        let key = Self.key(directory)
        guard let value = values[key] else { return nil }
        touch(key)
        return value
    }

    private mutating func touch(_ key: String) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }

    private static func key(_ url: URL) -> String {
        url.standardizedFileURL.path(percentEncoded: false)
    }
}
```

- [ ] **Step 4: Run the cache tests**

Run the command from Step 2.

Expected: all cache tests pass.

- [ ] **Step 5: Write failing pane restoration tests**

Add to `FilePaneStateTests.swift`:

```swift
@Test func returningToDirectoryRestoresExistingSelectionAndScrollAnchor() async {
    let a = URL(filePath: "/a", directoryHint: .isDirectory)
    let b = URL(filePath: "/b", directoryHint: .isDirectory)
    let first = makeItem(named: "first.txt", in: a)
    let middle = makeItem(named: "middle.txt", in: a)
    let pane = FilePaneState(
        directory: a,
        listingService: StubDirectoryListingService(values: [
            a: [first, middle],
            b: [makeItem(named: "other.txt", in: b)]
        ])
    )
    await pane.navigate(to: a, recordHistory: false)
    pane.selection = [middle.url]
    pane.recordFirstVisibleItem(first.url)
    await pane.navigate(to: b)
    await pane.goBack()

    #expect(pane.selection == [middle.url])
    #expect(pane.scrollRestoreRequest?.anchor == first.url)
}

@Test func missingRestorationTargetsAreSilentlyDiscarded() async {
    let a = URL(filePath: "/a", directoryHint: .isDirectory)
    let b = URL(filePath: "/b", directoryHint: .isDirectory)
    let disappearing = makeItem(named: "gone.txt", in: a)
    let listing = MutableDirectoryListingService(values: [
        a: [disappearing],
        b: []
    ])
    let pane = FilePaneState(directory: a, listingService: listing)
    await pane.navigate(to: a, recordHistory: false)
    pane.selection = [disappearing.url]
    pane.recordFirstVisibleItem(disappearing.url)
    await pane.navigate(to: b)
    listing.set([], for: a)
    await pane.goBack()

    #expect(pane.selection.isEmpty)
    #expect(pane.scrollRestoreRequest == nil)
    #expect(pane.errorMessage == nil)
}
```

Use a locked `MutableDirectoryListingService` test double so the second visit
can emit a changed listing.

```swift
private final class MutableDirectoryListingService:
    DirectoryListingService,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var values: [URL: [FileItem]]

    init(values: [URL: [FileItem]]) {
        self.values = values
    }

    func set(_ items: [FileItem], for directory: URL) {
        lock.withLock { values[directory] = items }
    }

    func batches(in directory: URL) -> AsyncThrowingStream<[FileItem], Error> {
        let items = lock.withLock { values[directory] ?? [] }
        return AsyncThrowingStream { continuation in
            continuation.yield(items)
            continuation.finish()
        }
    }
}
```

- [ ] **Step 6: Integrate the cache with committed navigation**

Add to `FilePaneState`:

```swift
private var viewStateCache = PaneViewStateCache(capacity: 100)
private var firstVisibleItem: URL?
private(set) var scrollRestoreRequest: PaneScrollRequest?

func recordFirstVisibleItem(_ url: URL?) {
    firstVisibleItem = url
}

func consumeScrollRestoreRequest(_ id: UUID) {
    guard scrollRestoreRequest?.id == id else { return }
    scrollRestoreRequest = nil
}

private func storeCurrentDirectoryViewState() {
    viewStateCache.store(
        PaneDirectoryViewState(
            selection: selection,
            scrollAnchor: firstVisibleItem
        ),
        for: currentDirectory
    )
}

private func restoreDirectoryViewState(for directory: URL) {
    guard let saved = viewStateCache.value(for: directory) else {
        scrollRestoreRequest = nil
        return
    }
    let loadedByPath = Dictionary(uniqueKeysWithValues: items.map {
        (Self.entryPath($0.url), $0.url)
    })
    selection = Set(saved.selection.compactMap {
        loadedByPath[Self.entryPath($0)]
    })
    scrollRestoreRequest = saved.scrollAnchor.flatMap {
        loadedByPath[Self.entryPath($0)]
    }.map { PaneScrollRequest(id: UUID(), anchor: $0) }
}
```

Call `storeCurrentDirectoryViewState()` before clearing items for a navigation.
Reset `firstVisibleItem` and stale scroll requests for the incoming directory.
In successful `completeNavigation`, call
`restoreDirectoryViewState(for: directory)` before assigning
`committedState = snapshot()`. This ensures later cancellation rollback includes
the restored selection. Do not include the cache in `WorkspacePersistence`; it
remains session-only.

- [ ] **Step 7: Add AppKit table scroll input and output**

Extend `FileTableView`:

```swift
let scrollRequest: PaneScrollRequest?
let onFirstVisibleItemChange: (URL?) -> Void
let onConsumeScrollRequest: (UUID) -> Void
```

Add these parameters without breaking existing call sites:

```swift
init(
    items: [FileItem],
    selection: Binding<Set<URL>>,
    sort: FileSort = FileSort(),
    directory: URL = URL(filePath: "/", directoryHint: .isDirectory),
    focusRequestID: UUID? = nil,
    renameRequestID: UUID? = nil,
    scrollRequest: PaneScrollRequest? = nil,
    isOperationRunning: Bool = false,
    dropModifierFlags: @escaping () -> NSEvent.ModifierFlags = {
        NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
    },
    onActivatePane: @escaping () -> Void,
    onOpen: @escaping (FileItem) -> Void,
    onSortChange: @escaping (FileSort) -> Void,
    onFirstVisibleItemChange: @escaping (URL?) -> Void = { _ in },
    onConsumeScrollRequest: @escaping (UUID) -> Void = { _ in },
    onConsumeRenameRequest: @escaping (UUID) -> Void = { _ in },
    onInlineEditingEvent: @escaping (InlineTextEditingEvent) -> Void = { _ in },
    onDiscardRename: @escaping () -> Void = {},
    onCommitRename: @escaping (URL, String) -> Void = { _, _ in },
    onDrop: @escaping ([URL], URL, DropIntent) -> Void = { _, _, _ in },
    canAddToFavorites: @escaping (FileItem) -> Bool = { _ in false },
    onAddToFavorites: @escaping (URL) -> Void = { _ in },
    onCreateFolder: @escaping () -> Void = {},
    onRequestRename: @escaping () -> Void = {},
    onCopy: @escaping () -> Void = {},
    onPaste: @escaping () -> Void = {},
    onRequestTrashConfirmation: @escaping () -> Void = {}
)
```

Assign all three new arguments to their matching stored properties.

In `makeScrollView`, observe
`NSView.boundsDidChangeNotification` from `scrollView.contentView`, set
`postsBoundsChangedNotifications = true`, and route the notification to the
coordinator. Remove the observer in a new `dismantleNSView`.

Add coordinator methods:

```swift
func reportFirstVisibleItem(in tableView: NSTableView) {
    let row = tableView.rows(in: tableView.visibleRect).location
    let url = items.indices.contains(row) ? items[row].url : nil
    parent.onFirstVisibleItemChange(url)
}

func applyScrollRequest(to tableView: NSTableView) {
    guard let request = parent.scrollRequest,
          request.id != lastHandledScrollRequestID,
          let row = items.firstIndex(where: { $0.url == request.anchor })
    else { return }
    tableView.scrollRowToVisible(row)
    lastHandledScrollRequestID = request.id
    parent.onConsumeScrollRequest(request.id)
}
```

Call `applyScrollRequest(to:)` after `apply(items:selection:to:)` in
`updateNSView`. Report the first visible item after user scrolling and after
items are applied. Suppress reporting while an explicit restoration request is
being applied so the restored anchor is not overwritten mid-update.

- [ ] **Step 8: Write and run AppKit lifecycle tests**

Add tests to `FileTableViewLifecycleTests.swift` that:

1. Build 30 items, size the scroll view to show fewer rows, scroll to row 20,
   and assert `onFirstVisibleItemChange` reports an item at or near row 20.
2. Pass a `PaneScrollRequest` anchored at row 20, call
   `coordinator.applyScrollRequest(to:)` twice, and assert the consume callback
   receives the request ID exactly once.
3. Replace the item list without the anchor and assert the request is not
   consumed and no out-of-range access occurs.

Use concrete coordinator tests:

```swift
@Test func tableReportsTheFirstVisibleItemAfterScrolling() throws {
    let directory = URL(filePath: "/scroll", directoryHint: .isDirectory)
    let items = (0..<30).map {
        makeTableItem(named: String(format: "item-%02d", $0), in: directory)
    }
    var reported: URL?
    let view = FileTableView(
        items: items,
        selection: .constant([]),
        onActivatePane: {},
        onOpen: { _ in },
        onSortChange: { _ in },
        onFirstVisibleItemChange: { reported = $0 }
    )
    let coordinator = view.makeCoordinator()
    let scroll = view.makeScrollView(coordinator: coordinator)
    scroll.frame = NSRect(x: 0, y: 0, width: 500, height: 140)
    let table = try #require(scroll.documentView as? NSTableView)
    table.frame = NSRect(x: 0, y: 0, width: 500, height: 30 * 28)
    scroll.contentView.scroll(to: NSPoint(x: 0, y: 20 * 28))
    scroll.reflectScrolledClipView(scroll.contentView)

    coordinator.reportFirstVisibleItem(in: table)

    let index = try #require(items.firstIndex { $0.url == reported })
    #expect((19...21).contains(index))
}

@Test func tableConsumesEachAvailableScrollRequestExactlyOnce() throws {
    let directory = URL(filePath: "/scroll", directoryHint: .isDirectory)
    let items = (0..<30).map {
        makeTableItem(named: "item-\($0)", in: directory)
    }
    let request = PaneScrollRequest(id: UUID(), anchor: items[20].url)
    var consumed: [UUID] = []
    var view = FileTableView(
        items: items,
        selection: .constant([]),
        scrollRequest: request,
        onActivatePane: {},
        onOpen: { _ in },
        onSortChange: { _ in },
        onConsumeScrollRequest: { consumed.append($0) }
    )
    let coordinator = view.makeCoordinator()
    let scroll = view.makeScrollView(coordinator: coordinator)
    let table = try #require(scroll.documentView as? NSTableView)
    coordinator.apply(items: items, selection: [], to: table)

    coordinator.applyScrollRequest(to: table)
    coordinator.applyScrollRequest(to: table)
    #expect(consumed == [request.id])

    view = FileTableView(
        items: Array(items.dropLast(10)),
        selection: .constant([]),
        scrollRequest: PaneScrollRequest(id: UUID(), anchor: items[29].url),
        onActivatePane: {},
        onOpen: { _ in },
        onSortChange: { _ in },
        onConsumeScrollRequest: { consumed.append($0) }
    )
    coordinator.parent = view
    coordinator.apply(items: view.items, selection: [], to: table)
    coordinator.applyScrollRequest(to: table)
    #expect(consumed == [request.id])
}
```

Run:

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --disable-sandbox \
  --filter 'PaneViewStateCacheTests|FilePaneStateTests|FileTableViewLifecycleTests'
```

Expected: all selected tests pass.

- [ ] **Step 9: Wire the table callbacks in `FilePaneView`**

Pass:

```swift
scrollRequest: state.scrollRestoreRequest,
onFirstVisibleItemChange: state.recordFirstVisibleItem,
onConsumeScrollRequest: state.consumeScrollRestoreRequest,
```

to `FileTableView`. Verify the existing initializer defaults keep all other
call sites source-compatible.

- [ ] **Step 10: Run pane, table, and persistence regression tests**

Run:

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --disable-sandbox \
  --filter 'PaneViewStateCacheTests|FilePaneStateTests|FileTableViewLifecycleTests|WorkspacePersistenceTests'
```

Expected: all selected tests pass and persistence tests show no schema change.

- [ ] **Step 11: Commit view restoration**

```bash
git add Sources/BloomFileManager/Models/PaneViewStateCache.swift \
  Sources/BloomFileManager/Stores/FilePaneState.swift \
  Sources/BloomFileManager/Views/AppKit/FileTableView.swift \
  Sources/BloomFileManager/Views/FilePaneView.swift \
  Tests/BloomFileManagerTests/PaneViewStateCacheTests.swift \
  Tests/BloomFileManagerTests/FilePaneStateTests.swift \
  Tests/BloomFileManagerTests/FileTableViewLifecycleTests.swift
git commit -m "feat: restore pane selection and scroll position"
```

---

### Task 5: Quick Look follows active-pane selection

**Files:**

- Modify: `Sources/BloomFileManager/Support/QuickLookController.swift`
- Modify: `Sources/BloomFileManager/Views/WorkspaceView.swift`
- Modify: `Tests/BloomFileManagerTests/CloudOperationGateTests.swift`

**Interfaces:**

- Produces: `QuickLookController.isPresenting: Bool`
- Produces: `QuickLookController.updateIfPresented(requests:materializer:)`
- Consumes: `WorkspaceOpenActions.identifiedRequests(for:fileSystem:accessCoordinator:)`
- Consumes: existing materialization generation and identity-preserving gate.

- [ ] **Step 1: Write failing live-update tests**

Add to `CloudOperationGateTests.swift`:

```swift
@Test func quickLookUpdatesOnlyAfterItHasBeenPresented() async {
    let first = IdentifiedFileRequest(
        url: URL(filePath: "/Cloud/first.txt"),
        identity: identity("first")
    )
    let second = IdentifiedFileRequest(
        url: URL(filePath: "/Cloud/second.txt"),
        identity: identity("second")
    )
    let recorder = QuickLookPresentationRecorder()
    let controller = QuickLookController { recorder.present($0) }
    let materializer = RecordingGateMaterializer(result: .init(
        preparedRequests: [second],
        failures: [],
        wasCancelled: false
    ))

    await controller.updateIfPresented(requests: [second], materializer: materializer)
    #expect(recorder.history.isEmpty)

    await controller.prepareAndPresent(
        requests: [first],
        materializer: RecordingGateMaterializer(result: .init(
            preparedRequests: [first],
            failures: [],
            wasCancelled: false
        ))
    )
    await controller.updateIfPresented(requests: [second], materializer: materializer)

    #expect(recorder.history == [[first.url], [second.url]])
}

@Test func liveQuickLookClosesForEmptyOrFailedReplacement() async {
    let first = IdentifiedFileRequest(
        url: URL(filePath: "/Cloud/first.txt"),
        identity: identity("first")
    )
    let recorder = QuickLookPresentationRecorder()
    let controller = QuickLookController { recorder.present($0) }
    await controller.prepareAndPresent(
        requests: [first],
        materializer: RecordingGateMaterializer(result: .init(
            preparedRequests: [first],
            failures: [],
            wasCancelled: false
        ))
    )

    await controller.updateIfPresented(
        requests: [],
        materializer: InMemoryCloudMaterializer()
    )

    #expect(recorder.history == [[first.url], []])
    #expect(!controller.isPresenting)

    await controller.prepareAndPresent(
        requests: [first],
        materializer: RecordingGateMaterializer(result: .init(
            preparedRequests: [first],
            failures: [],
            wasCancelled: false
        ))
    )
    await controller.updateIfPresented(
        requests: [first],
        materializer: RecordingGateMaterializer(result: .init(
            preparedRequests: [],
            failures: [.init(name: "first.txt", reason: .offline)],
            wasCancelled: false
        ))
    )
    #expect(recorder.history.suffix(2) == [[first.url], []])
    #expect(!controller.isPresenting)
}

@Test func supersededLiveUpdateCannotReplaceTheLatestPreview() async {
    let initial = IdentifiedFileRequest(
        url: URL(filePath: "/Cloud/initial.txt"),
        identity: identity("initial")
    )
    let old = IdentifiedFileRequest(
        url: URL(filePath: "/Cloud/old.txt"),
        identity: identity("old")
    )
    let new = IdentifiedFileRequest(
        url: URL(filePath: "/Cloud/new.txt"),
        identity: identity("new")
    )
    let recorder = QuickLookPresentationRecorder()
    let controller = QuickLookController { recorder.present($0) }
    await controller.prepareAndPresent(
        requests: [initial],
        materializer: RecordingGateMaterializer(result: .init(
            preparedRequests: [initial],
            failures: [],
            wasCancelled: false
        ))
    )
    let suspended = SuspendingGateMaterializer()
    let oldTask = Task { @MainActor in
        await controller.updateIfPresented(
            requests: [old],
            materializer: suspended
        )
    }
    while await !suspended.hasProgressed {
        await Task.yield()
    }
    await controller.updateIfPresented(
        requests: [new],
        materializer: RecordingGateMaterializer(result: .init(
            preparedRequests: [new],
            failures: [],
            wasCancelled: false
        ))
    )
    await suspended.release()
    await oldTask.value

    #expect(recorder.history == [[initial.url], [new.url]])
}

@Test func closingTheSystemPanelStopsFutureSelectionUpdates() async {
    let request = IdentifiedFileRequest(
        url: URL(filePath: "/Cloud/item.txt"),
        identity: identity("item")
    )
    let recorder = QuickLookPresentationRecorder()
    let controller = QuickLookController { recorder.present($0) }
    await controller.prepareAndPresent(
        requests: [request],
        materializer: RecordingGateMaterializer(result: .init(
            preparedRequests: [request],
            failures: [],
            wasCancelled: false
        ))
    )

    controller.previewPanelWillClose(nil)

    #expect(!controller.isPresenting)
    await controller.updateIfPresented(
        requests: [request],
        materializer: InMemoryCloudMaterializer()
    )
    #expect(recorder.history == [[request.url]])
}
```

- [ ] **Step 2: Run and verify the update API is missing**

Run:

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --disable-sandbox --filter CloudOperationGateTests
```

Expected: compilation fails on `isPresenting` and `updateIfPresented`.

- [ ] **Step 3: Implement explicit presentation state and update behavior**

Add:

```swift
private(set) var isPresenting = false

func updateIfPresented(
    requests: [IdentifiedFileRequest],
    materializer: any CloudMaterializing
) async {
    guard isPresenting else { return }
    requestGeneration &+= 1
    let generation = requestGeneration
    guard !requests.isEmpty else {
        presentPrepared(urls: [])
        return
    }
    let result = await materializer.materialize(
        requests,
        purpose: .quickLook,
        progress: { _ in }
    )
    guard generation == requestGeneration, !Task.isCancelled else { return }
    guard !result.wasCancelled,
          result.failures.isEmpty,
          let prepared = CloudOperationRequestGate.identityPreservingPreparedRequests(
              original: requests,
              prepared: result.preparedRequests
          )
    else {
        presentPrepared(urls: [])
        return
    }
    presentPrepared(urls: prepared.map(\.url))
}
```

Set `isPresenting = !urls.isEmpty` at the start of `presentPrepared(urls:)`.
Preserve the existing initial-presentation rule: a failed
`prepareAndPresent` must not call the presenter.

Implement the delegate close callback so a manually closed system panel does
not reopen on the next selection change:

```swift
func previewPanelWillClose(_ panel: QLPreviewPanel!) {
    requestGeneration &+= 1
    urls.removeAll()
    isPresenting = false
}
```

- [ ] **Step 4: Run Quick Look gate tests**

Run the command from Step 2.

Expected: existing and new generation, cancellation, failure, and identity
tests all pass.

- [ ] **Step 5: Observe active-pane selection in `WorkspaceView`**

Define a private hashable request key:

```swift
private struct QuickLookSelectionKey: Hashable {
    let paneID: String
    let urls: [URL]
}
```

Add:

```swift
private var quickLookSelectionKey: QuickLookSelectionKey {
    QuickLookSelectionKey(
        paneID: workspace.activePaneID.rawValue,
        urls: workspace.selectedURLsForCommands
    )
}

private func updateQuickLookForSelection() async {
    guard quickLookController.isPresenting else { return }
    let urls = workspace.selectedURLsForCommands
    guard !urls.isEmpty else {
        await quickLookController.updateIfPresented(
            requests: [],
            materializer: materializer
        )
        return
    }
    guard let requests = await WorkspaceOpenActions.identifiedRequests(
        for: urls,
        fileSystem: fileSystem,
        accessCoordinator: cloudAccessCoordinator
    ) else {
        await quickLookController.updateIfPresented(
            requests: [],
            materializer: materializer
        )
        return
    }
    await quickLookController.updateIfPresented(
        requests: requests,
        materializer: materializer
    )
}
```

Attach `.task(id: quickLookSelectionKey) { await updateQuickLookForSelection() }`
to `ordinaryWorkspace`. SwiftUI cancellation plus the controller generation
prevents stale selection updates from winning.

- [ ] **Step 6: Run focused Quick Look and workspace tests**

Run:

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --disable-sandbox \
  --filter 'CloudOperationGateTests|WorkspaceStateTests|WorkspaceCommandTests'
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift build --disable-sandbox
```

Expected: focused tests and build pass.

- [ ] **Step 7: Commit live Quick Look updates**

```bash
git add Sources/BloomFileManager/Support/QuickLookController.swift \
  Sources/BloomFileManager/Views/WorkspaceView.swift \
  Tests/BloomFileManagerTests/CloudOperationGateTests.swift
git commit -m "feat: keep Quick Look aligned with selection"
```

---

### Task 6: Performance, release checklist, and end-to-end verification

**Files:**

- Create: `Tests/BloomFileManagerTests/NavigationProductivityPerformanceTests.swift`
- Modify: `Tests/BloomFileManagerTests/AccessibilityPresentationTests.swift`
- Create: `docs/verification/version-1.2-checklist.md`
- Modify: `README.md`

**Interfaces:**

- Consumes: all Tasks 1–5 production interfaces.
- Produces: automated 10,000-item regression evidence and a physical-test
  checklist that separates completed from unrun gates.

- [ ] **Step 1: Write the 10,000-item performance test**

Create:

```swift
import Foundation
import Testing
@testable import BloomFileManager

struct NavigationProductivityPerformanceTests {
    @Test func filenameFilteringTenThousandLoadedItemsStaysBelowRegressionCeiling() {
        let items = (0..<10_000).map { index in
            FileItem(
                url: URL(filePath: "/scale/report-\(index).txt"),
                name: "report-\(index).txt",
                isDirectory: false,
                isPackage: false,
                modifiedAt: nil,
                byteSize: 1,
                typeDescription: "Text"
            )
        }
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for query in ["1", "19", "199", "1999", "report"] {
                _ = PaneFilenameFilter(query: query).apply(to: items)
            }
        }
        #expect(elapsed < .seconds(5))
    }
}
```

The five-second value is a CI regression ceiling across five queries, not a
promise that a user operation may take five seconds.

- [ ] **Step 2: Run the performance and accessibility tests**

Run:

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --disable-sandbox \
  --filter 'NavigationProductivityPerformanceTests|AccessibilityPresentationTests'
```

Expected: all selected tests pass.

- [ ] **Step 3: Write the version 1.2 physical verification checklist**

Create `docs/verification/version-1.2-checklist.md` with unchecked manual rows
for:

```markdown
# Pengrid version 1.2 verification checklist

## Automated evidence

- [ ] Full Swift test suite passes at the release-candidate commit.
- [ ] `./script/build_and_run.sh --verify` passes at the same commit.
- [ ] The 10,000-item filter regression test passes.

## Filter and keyboard

- [ ] Command-F opens the active pane's filter and does not affect the other pane.
- [ ] Escape restores the prior selection when that item still exists.
- [ ] Korean, English, case, and accent matching behave as documented.
- [ ] Filtering a File Provider listing causes no download request.

## Navigation and restoration

- [ ] Back and Forward remain independent in both panes.
- [ ] Returning near the top, middle, and end of a large folder restores position.
- [ ] Deleted selections, anchors, and history destinations recover without a crash.

## Quick Look

- [ ] An open panel follows local-file selection.
- [ ] An online-only item uses the existing materialization gate.
- [ ] Empty, deleted, offline, and superseded selections do not show stale content.

## Accessibility and appearance

- [ ] VoiceOver announces filter labels, result count, and restored selection.
- [ ] Keyboard focus returns to the table after Escape.
- [ ] Light, dark, increased contrast, and reduced motion remain usable.
```

Do not mark manual rows complete without performing them physically.

- [ ] **Step 4: Update README feature and release-status copy**

Add a concise “Navigation productivity” section describing current-folder
filtering, history, restoration, and live Quick Look. Explicitly say the filter
is not recursive or content search and does not download cloud-only files.
Link `docs/verification/version-1.2-checklist.md` from Release status. Do not
claim the manual checklist has passed.

Use this copy:

```markdown
## Navigation productivity

Each pane has an independent current-folder filename filter, Back and Forward
history, and session-only selection and scroll restoration. An open Quick Look
panel follows selection changes through the same identity and cloud
materialization safety gates used when it first opens.

The filename filter works only on the directory listing already loaded in
memory. It is not recursive or file-content search, and it does not download
cloud-only files.
```

Add `docs/verification/version-1.2-checklist.md` to the existing Release status
document list.

- [ ] **Step 5: Run the full automated verification**

Run:

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --disable-sandbox --no-parallel
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  ./script/build_and_run.sh --verify
git diff --check
git status --short
```

Expected:

- Swift exits 0 with every test passing.
- Build verification exits 0 and reports an arm64 app bundle.
- `git diff --check` prints no errors.
- `git status --short` lists only the intended Task 6 documentation and test
  changes before commit.

- [ ] **Step 6: Perform proportionate manual smoke checks**

Open `dist/Pengrid.app` and physically check:

1. `Command-F`, typing, selection, and `Escape` in both panes.
2. Back/Forward and restoration in three folders.
3. Quick Look selection changes for two local files.
4. A configured File Provider folder, if one is available, without claiming
   that unavailable provider scenarios passed.

Record exact pass, fail, or not-run status in the version 1.2 checklist. Do not
convert not-run rows to passes.

- [ ] **Step 7: Commit tests and documentation**

```bash
git add Tests/BloomFileManagerTests/NavigationProductivityPerformanceTests.swift \
  Tests/BloomFileManagerTests/AccessibilityPresentationTests.swift \
  docs/verification/version-1.2-checklist.md README.md
git commit -m "test: verify Pengrid navigation productivity"
```

- [ ] **Step 8: Review the complete implementation range**

Run:

```bash
git log --oneline 52eeaa9..HEAD
git diff --stat 52eeaa9..HEAD
git status --short
```

Expected: six focused implementation commits after the approved design commit,
plus the implementation-plan documentation commit. Only the files named in
this plan and this plan document itself changed, and the worktree is clean.

Do not push, retag, rebuild the public DMG, or replace the GitHub release until
the user separately authorizes the release update and the signing/notarization
status is represented accurately.
