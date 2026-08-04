# Folder Contents Preview Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Space show a fast, read-only, one-level contents preview for one ordinary folder while preserving system Quick Look for files, packages, symlinks, and multi-selection.

**Architecture:** Introduce one `WorkspacePreviewCoordinator` as the sole owner of closed/system/folder preview transitions. Folder snapshots are captured and enumerated with no-follow directory descriptors, staged privately, validated against exact `FileIdentity` and generation state, then published atomically without cloud materialization or coordinated content reads.

**Tech Stack:** Swift 6.1, AppKit `NSPanel`/`NSHostingView`, SwiftUI, Darwin descriptor APIs (`open`, `fdopendir`, `readdir`, `fstat`, `fstatat`), Swift Testing, existing Quick Look and File Provider integrations on macOS 15.

## Global Constraints

- On this workstation, prefix every `xcrun swift` command with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`; the selected CommandLineTools path cannot import Swift Testing.
- A single ordinary folder uses the folder panel; files, packages, symbolic links, and multi-selection retain existing system Quick Look behavior.
- Space and selection-change updates go only through `WorkspacePreviewCoordinator`; `WorkspaceView` must not call concrete preview controllers directly.
- Folder requests capture pane ID, standardized URL, exact `FileIdentity`, and no-follow directory kind.
- Open the folder with `O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK`; enumerate relative names from that stable descriptor.
- Stage all rows privately and publish them atomically only after descriptor identity, current path identity, generation, and cancellation validation.
- Folder preview makes zero `CloudMaterializing` calls and zero `NSFileCoordinator` coordinated content reads.
- `DirectoryVisibilityPolicy.baseline` includes hidden entries, matching the current pane listing's `options: []` behavior.
- Preview rows are read-only: no open, navigation, transfer, rename, archive, or Trash action.
- Text editing wins over Space and Escape; closing preview restores focus to the active file table.
- Follow RED → verify failure → GREEN → verify pass → refactor → commit for every production behavior.

---

## File Structure

- `Sources/BloomFileManager/Models/FolderPreviewModels.swift`: request, row, snapshot, mode, and error values.
- `Sources/BloomFileManager/Services/DirectoryVisibilityPolicy.swift`: one hidden-entry policy shared by pane and preview.
- `Sources/BloomFileManager/Services/FileSystemAccess.swift`: no-follow directory capture and identity-bound snapshot primitive.
- `Sources/BloomFileManager/Services/FolderPreviewListing.swift`: cancellable snapshot service facade.
- `Sources/BloomFileManager/Stores/FolderPreviewModel.swift`: observable loading/error/atomic-row state.
- `Sources/BloomFileManager/Support/FolderPreviewController.swift`: AppKit folder panel ownership only.
- `Sources/BloomFileManager/Support/WorkspacePreviewCoordinator.swift`: sole preview routing and generation authority.
- `Sources/BloomFileManager/Support/QuickLookController.swift`: system Quick Look remains concrete and coordinator-owned.
- `Sources/BloomFileManager/Views/FolderPreviewView.swift`: read-only header/status/table UI.
- `Sources/BloomFileManager/Views/WorkspaceView.swift`: selection-change forwarding to the coordinator.
- `Sources/BloomFileManager/Support/WorkspaceCommands.swift`: Space command forwarding to the coordinator.
- `Sources/BloomFileManager/App/BloomFileManagerApp.swift`: dependency creation and injection.
- `Sources/BloomFileManager/Services/LiveDirectoryListingService.swift`: consume the shared visibility policy.
- `Tests/BloomFileManagerTests/FolderPreview*.swift`: snapshot, model, coordinator, panel, and presentation coverage.

### Task 1: Shared visibility policy and stable directory snapshot primitive

**Files:**
- Create: `Sources/BloomFileManager/Services/DirectoryVisibilityPolicy.swift`
- Create: `Sources/BloomFileManager/Models/FolderPreviewModels.swift`
- Modify: `Sources/BloomFileManager/Services/LiveDirectoryListingService.swift`
- Modify: `Sources/BloomFileManager/Services/FileSystemAccess.swift`
- Modify: `Tests/BloomFileManagerTests/DirectoryListingServiceTests.swift`
- Modify: `Tests/BloomFileManagerTests/FileSystemAccessTests.swift`
- Modify: `Tests/BloomFileManagerTests/Support/RecordingFileSystem.swift`

**Interfaces:**
- Consumes: `FileIdentity`, Darwin descriptor helpers already private to `LiveFileSystemAccess`.
- Produces: `DirectoryVisibilityPolicy`, `FolderPreviewRequest`, `FolderPreviewEntry`, `FolderPreviewSnapshot`, `captureFolderPreviewRequest`, and `snapshotFolder` protocol methods.

- [ ] **Step 1: Write failing visibility and stable-snapshot tests**

```swift
@Test func baselineVisibilityIncludesHiddenEntries() async throws {
    let root = try TemporaryDirectory()
    defer { root.remove() }
    try Data([1]).write(to: root.url.appending(path: ".hidden"))
    try Data([1]).write(to: root.url.appending(path: "visible"))
    let service = LiveDirectoryListingService(visibility: .baseline)
    let names = try await service.batches(in: root.url).reduce(into: [String]()) {
        $0 += $1.map(\.name)
    }
    #expect(Set(names) == [".hidden", "visible"])
}

@Test func folderSnapshotRejectsSymlinkAndReplacement() async throws {
    let root = try TemporaryDirectory()
    defer { root.remove() }
    let original = root.url.appending(path: "folder", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false)
    let fileSystem = LiveFileSystemAccess(onAfterFolderPreviewOpen: { request in
        try FileManager.default.moveItem(at: request.url, to: root.url.appending(path: "old"))
        try FileManager.default.createDirectory(at: request.url, withIntermediateDirectories: false)
    })
    let request = try #require(await fileSystem.captureFolderPreviewRequest(
        paneID: .left,
        url: original
    ))
    await #expect(throws: FileSystemAccessError.self) {
        try await fileSystem.snapshotFolder(request, visibility: .baseline, progress: { _ in })
    }
}
```

Add this separate symlink assertion to the same test file:

```swift
let target = root.url.appending(path: "target", directoryHint: .isDirectory)
let link = root.url.appending(path: "link")
try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
#expect(try await LiveFileSystemAccess().captureFolderPreviewRequest(paneID: .left, url: link) == nil)
```

- [ ] **Step 2: Run listing/filesystem tests and verify RED**

Run: `xcrun swift test --filter DirectoryListingServiceTests && xcrun swift test --filter FileSystemAccessTests`

Expected: compilation fails because visibility and folder-snapshot types/APIs do not exist.

- [ ] **Step 3: Add the shared policy and value types**

```swift
struct DirectoryVisibilityPolicy: Equatable, Sendable {
    let includesHiddenItems: Bool
    static let baseline = DirectoryVisibilityPolicy(includesHiddenItems: true)

    var fileManagerOptions: FileManager.DirectoryEnumerationOptions {
        includesHiddenItems ? [] : [.skipsHiddenFiles]
    }
}

enum FolderPreviewSourceKind: Hashable, Sendable { case ordinaryDirectory }

struct FolderPreviewRequest: Hashable, Sendable {
    let paneID: PaneID
    let url: URL
    let identity: FileIdentity
    let kind: FolderPreviewSourceKind
}

struct FolderPreviewEntry: Identifiable, Equatable, Sendable {
    let name: String
    let isDirectory: Bool
    let isPackage: Bool
    let byteSize: Int64?
    let modifiedAt: Date?
    var id: String { name }
}

struct FolderPreviewSnapshot: Equatable, Sendable {
    let request: FolderPreviewRequest
    let entries: [FolderPreviewEntry]
}

enum FolderPreviewFailure: Equatable, Sendable { case folderChanged, unavailable }
enum FolderPreviewPhase: Equatable, Sendable {
    case idle, loading, loaded, failed(FolderPreviewFailure)
}
```

Inject `DirectoryVisibilityPolicy` into `LiveDirectoryListingService` with `.baseline` default and pass its `fileManagerOptions` to `contentsOfDirectory`.

- [ ] **Step 4: Implement descriptor-bound capture and snapshot APIs**

Add these requirements to `FileSystemAccess` and implement recording defaults in the test double:

```swift
func captureFolderPreviewRequest(paneID: PaneID, url: URL) async throws -> FolderPreviewRequest?
func snapshotFolder(
    _ request: FolderPreviewRequest,
    visibility: DirectoryVisibilityPolicy,
    progress: @escaping @Sendable (Int) -> Void
) async throws -> FolderPreviewSnapshot
```

Extend `RecordingFileSystem` with initializer inputs
`folderPreviewRequests: [URL: FolderPreviewRequest] = [:]` and
`folderPreviewSnapshots: [FolderPreviewRequest: FolderPreviewSnapshot] = [:]`.
Its capture method returns the mapped request or nil; its snapshot method returns
the mapped snapshot after invoking progress with the entry count. Make
`FolderPreviewRequest` conform to `Hashable` so it is a stable test-map key.

In `LiveFileSystemAccess`, `captureFolderPreviewRequest` opens with no-follow directory flags; `ENOTDIR` and `ELOOP` return nil, other failures throw. Capture `identity(ofDescriptor:)`, require current path identity equality, and set `kind: .ordinaryDirectory` before returning. `snapshotFolder` first requires that kind, reopens the same way, requires exact descriptor identity, duplicates the FD for `fdopendir`, rejects `.`/`..`, uses `fstatat(..., AT_SYMLINK_NOFOLLOW)` for child kind/size/timestamps, skips hidden names only when policy says so, and never follows child symlinks. Keep entries in a local array. After enumeration, require descriptor identity and `identity(of: request.url)` both equal `request.identity`; only then return a folders-first localized-name-sorted snapshot. Close every descriptor on all exits.

Add the deterministic race hook used by the failing test to the existing initializer beside its other test hooks:

```swift
onAfterFolderPreviewOpen: @escaping @Sendable (FolderPreviewRequest) throws -> Void = { _ in }
```

Invoke it after descriptor/request identity validation and before `fdopendir`; production uses the no-op default.

- [ ] **Step 5: Run listing/filesystem tests and verify GREEN**

Run: `xcrun swift test --filter DirectoryListingServiceTests && xcrun swift test --filter FileSystemAccessTests`

Expected: hidden policy, ordinary capture, symlink refusal, descriptor identity, replacement/ABA refusal, child no-follow metadata, sorting, cancellation, and descriptor cleanup pass.

- [ ] **Step 6: Commit the filesystem slice**

```bash
git add Sources/BloomFileManager/Models/FolderPreviewModels.swift Sources/BloomFileManager/Services/DirectoryVisibilityPolicy.swift Sources/BloomFileManager/Services/FileSystemAccess.swift Sources/BloomFileManager/Services/LiveDirectoryListingService.swift Tests/BloomFileManagerTests/DirectoryListingServiceTests.swift Tests/BloomFileManagerTests/FileSystemAccessTests.swift Tests/BloomFileManagerTests/Support/RecordingFileSystem.swift
git commit -m "feat: add identity-bound folder snapshot primitive"
```

### Task 2: Cancellable folder preview listing and atomic observable state

**Files:**
- Create: `Sources/BloomFileManager/Services/FolderPreviewListing.swift`
- Create: `Sources/BloomFileManager/Stores/FolderPreviewModel.swift`
- Create: `Tests/BloomFileManagerTests/FolderPreviewListingTests.swift`
- Create: `Tests/BloomFileManagerTests/FolderPreviewModelTests.swift`

**Interfaces:**
- Consumes: Task 1 request/snapshot and `FileSystemAccess.snapshotFolder`.
- Produces: `FolderPreviewListing`, `LiveFolderPreviewListing`, `@MainActor @Observable FolderPreviewModel`.

- [ ] **Step 1: Write failing cancellation and atomic-publication tests**

```swift
@Test @MainActor func rowsPublishOnlyAfterValidatedSnapshotCompletes() async {
    let listing = SuspendedFolderPreviewListing()
    let model = FolderPreviewModel(listing: listing)
    let request = previewRequest("one")
    let snapshot = previewSnapshot(request, name: "child.txt")
    model.load(request)
    await listing.waitUntilStarted(count: 1)
    await listing.reportProgress(200)
    #expect(model.entries.isEmpty)
    #expect(model.examinedCount == 200)
    await listing.finish(with: snapshot)
    #expect(model.entries == snapshot.entries)
}

@Test @MainActor func staleGenerationCannotPublishRowsOrError() async {
    let listing = SuspendedFolderPreviewListing()
    let model = FolderPreviewModel(listing: listing)
    let firstRequest = previewRequest("first")
    let secondRequest = previewRequest("second")
    let firstSnapshot = previewSnapshot(firstRequest, name: "old.txt")
    let secondSnapshot = previewSnapshot(secondRequest, name: "new.txt")
    model.load(firstRequest)
    await listing.waitUntilStarted(count: 1)
    model.load(secondRequest)
    await listing.waitUntilStarted(count: 2)
    await listing.finish(request: firstRequest, with: firstSnapshot)
    #expect(model.entries.isEmpty)
    await listing.finish(request: secondRequest, with: secondSnapshot)
    #expect(model.entries == secondSnapshot.entries)
}

private actor SuspendedFolderPreviewListing: FolderPreviewListing {
    private var waits: [(FolderPreviewRequest, @Sendable (Int) -> Void, CheckedContinuation<FolderPreviewSnapshot, any Error>)] = []
    func snapshot(_ request: FolderPreviewRequest, progress: @escaping @Sendable (Int) -> Void) async throws -> FolderPreviewSnapshot {
        try await withCheckedThrowingContinuation { waits.append((request, progress, $0)) }
    }
    func waitUntilStarted(count: Int) async {
        while waits.count < count { await Task.yield() }
    }
    func reportProgress(_ value: Int) { waits.last?.1(value) }
    func finish(with snapshot: FolderPreviewSnapshot) { waits.last?.2.resume(returning: snapshot) }
    func finish(request: FolderPreviewRequest, with snapshot: FolderPreviewSnapshot) {
        waits.first(where: { $0.0 == request })?.2.resume(returning: snapshot)
    }
}

private func previewRequest(_ name: String) -> FolderPreviewRequest {
    FolderPreviewRequest(
        paneID: .left,
        url: URL(filePath: "/preview/\(name)", directoryHint: .isDirectory),
        identity: FileIdentity(entryIdentifier: name, resolvedIdentifier: name),
        kind: .ordinaryDirectory
    )
}

private func previewSnapshot(_ request: FolderPreviewRequest, name: String) -> FolderPreviewSnapshot {
    FolderPreviewSnapshot(request: request, entries: [
        FolderPreviewEntry(name: name, isDirectory: false, isPackage: false, byteSize: 1, modifiedAt: nil)
    ])
}
```

- [ ] **Step 2: Run folder listing/model tests and verify RED**

Run: `xcrun swift test --filter FolderPreviewListingTests && xcrun swift test --filter FolderPreviewModelTests`

Expected: compilation fails because listing and model types do not exist.

- [ ] **Step 3: Implement the service facade and observable model**

```swift
protocol FolderPreviewListing: Sendable {
    func snapshot(
        _ request: FolderPreviewRequest,
        progress: @escaping @Sendable (Int) -> Void
    ) async throws -> FolderPreviewSnapshot
}

struct LiveFolderPreviewListing: FolderPreviewListing {
    let fileSystem: any FileSystemAccess
    let visibility: DirectoryVisibilityPolicy
}

@MainActor @Observable
final class FolderPreviewModel {
    private(set) var request: FolderPreviewRequest?
    private(set) var entries: [FolderPreviewEntry] = []
    private(set) var examinedCount = 0
    private(set) var phase: FolderPreviewPhase = .idle
    var statusText: String {
        switch phase {
        case .idle: ""
        case .loading: "Loading \(examinedCount) items…"
        case .loaded: "\(entries.count) items"
        case .failed(.folderChanged): "Folder changed. Close the preview and try again."
        case .failed(.unavailable): "Folder contents are unavailable without downloading."
        }
    }
    func load(_ request: FolderPreviewRequest)
    func cancel()
}
```

`load` increments a generation, cancels the previous task, clears published rows, and updates progress only for the current generation. Assign `entries` once from a complete snapshot after confirming request and generation. Map identity mismatch to `.failed(.folderChanged)`, provider/access failures to `.failed(.unavailable)`, and cancellation to no publication.

- [ ] **Step 4: Run folder listing/model tests and verify GREEN**

Run: `xcrun swift test --filter FolderPreviewListingTests && xcrun swift test --filter FolderPreviewModelTests`

Expected: no partial rows, current-generation progress, cancellation, stale success/error refusal, exact error mapping, and atomic publication pass.

- [ ] **Step 5: Commit listing and state**

```bash
git add Sources/BloomFileManager/Services/FolderPreviewListing.swift Sources/BloomFileManager/Stores/FolderPreviewModel.swift Tests/BloomFileManagerTests/FolderPreviewListingTests.swift Tests/BloomFileManagerTests/FolderPreviewModelTests.swift
git commit -m "feat: add atomic folder preview state"
```

### Task 3: One authoritative workspace preview coordinator

**Files:**
- Create: `Sources/BloomFileManager/Support/WorkspacePreviewCoordinator.swift`
- Create: `Tests/BloomFileManagerTests/WorkspacePreviewCoordinatorTests.swift`
- Modify: `Sources/BloomFileManager/Support/QuickLookController.swift`
- Modify: `Tests/BloomFileManagerTests/WorkspaceCommandTests.swift`

**Interfaces:**
- Consumes: `QuickLookController`, Task 1 capture API, Task 2 model, current workspace selection and materializer.
- Produces: `WorkspacePreviewMode`, `WorkspacePreviewSelection`, `WorkspacePreviewCoordinator.toggle` and `selectionDidChange`.

- [ ] **Step 1: Write failing routing and zero-folder-materialization tests**

```swift
@Test @MainActor func ordinaryFolderUsesFolderModeWithoutMaterialization() async {
    let folder = previewItem("folder", isDirectory: true)
    let request = folderRequest(for: folder, token: "folder")
    let materializer = InMemoryCloudMaterializer()
    let fileSystem = RecordingFileSystem(
        identities: [folder.url: request.identity],
        folderPreviewRequests: [folder.url: request]
    )
    let coordinator = WorkspacePreviewCoordinator(
        fileSystem: fileSystem,
        quickLookController: QuickLookController(onPresent: { _ in }),
        folderPresenter: RecordingFolderPreviewPresenter(),
        materializer: materializer,
        restoreFocus: {}
    )
    await coordinator.toggle(selection: .init(paneID: .left, items: [folder]))
    #expect(coordinator.mode == .folder(request))
    #expect(await materializer.recordedCalls().isEmpty)
}

@Test @MainActor func filePackageSymlinkAndMultiSelectionUseSystemQuickLook() async {
    let file = previewItem("file.txt", isDirectory: false)
    let package = previewItem("App.app", isDirectory: true, isPackage: true)
    let symlink = previewItem("linked-folder", isDirectory: true)
    let selections = [[file], [package], [symlink], [file, package]]
    for items in selections {
        let identities = Dictionary(uniqueKeysWithValues: items.map {
            ($0.url, FileIdentity(entryIdentifier: $0.name, resolvedIdentifier: $0.name))
        })
        let coordinator = WorkspacePreviewCoordinator(
            fileSystem: RecordingFileSystem(identities: identities),
            quickLookController: QuickLookController(onPresent: { _ in }),
            folderPresenter: RecordingFolderPreviewPresenter(),
            materializer: InMemoryCloudMaterializer(),
            restoreFocus: {}
        )
        let selection = WorkspacePreviewSelection(paneID: .left, items: items)
        await coordinator.toggle(selection: selection)
        #expect(coordinator.mode == .systemQuickLook)
    }
}

@Test @MainActor func selectionObserverCannotBypassCoordinator() async {
    let first = previewItem("first", isDirectory: true)
    let second = previewItem("second", isDirectory: true)
    let firstRequest = folderRequest(for: first, token: "first")
    let secondRequest = folderRequest(for: second, token: "second")
    let materializer = InMemoryCloudMaterializer()
    let coordinator = WorkspacePreviewCoordinator(
        fileSystem: RecordingFileSystem(
            identities: [first.url: firstRequest.identity, second.url: secondRequest.identity],
            folderPreviewRequests: [first.url: firstRequest, second.url: secondRequest]
        ),
        quickLookController: QuickLookController(onPresent: { _ in }),
        folderPresenter: RecordingFolderPreviewPresenter(),
        materializer: materializer,
        restoreFocus: {}
    )
    await coordinator.toggle(selection: .init(paneID: .left, items: [first]))
    await coordinator.selectionDidChange(to: .init(paneID: .left, items: [second]))
    #expect(coordinator.mode == .folder(secondRequest))
    #expect(await materializer.recordedCalls().isEmpty)
}

@MainActor private final class RecordingFolderPreviewPresenter: FolderPreviewPresenting {
    func present(request: FolderPreviewRequest) {}
    func close() {}
}

private func previewItem(_ name: String, isDirectory: Bool, isPackage: Bool = false) -> FileItem {
    FileItem(
        url: URL(filePath: "/preview/\(name)", directoryHint: isDirectory ? .isDirectory : .notDirectory),
        name: name,
        isDirectory: isDirectory,
        isPackage: isPackage,
        modifiedAt: nil,
        byteSize: isDirectory ? nil : 1,
        typeDescription: isDirectory ? "Folder" : "File"
    )
}

private func folderRequest(for item: FileItem, token: String) -> FolderPreviewRequest {
    FolderPreviewRequest(
        paneID: .left,
        url: item.url,
        identity: FileIdentity(entryIdentifier: token, resolvedIdentifier: token),
        kind: .ordinaryDirectory
    )
}
```

- [ ] **Step 2: Run coordinator tests and verify RED**

Run: `xcrun swift test --filter WorkspacePreviewCoordinatorTests`

Expected: compilation fails because coordinator types do not exist.

- [ ] **Step 3: Implement mutually exclusive modes and transitions**

```swift
enum WorkspacePreviewMode: Equatable, Sendable {
    case closed
    case systemQuickLook
    case folder(FolderPreviewRequest)
}

struct WorkspacePreviewSelection: Equatable, Sendable {
    let paneID: PaneID
    let items: [FileItem]
}

@MainActor
protocol FolderPreviewPresenting: AnyObject {
    func present(request: FolderPreviewRequest)
    func close()
}

@MainActor
final class WorkspacePreviewCoordinator {
    private(set) var mode: WorkspacePreviewMode = .closed
    init(
        fileSystem: any FileSystemAccess,
        quickLookController: QuickLookController,
        folderPresenter: any FolderPreviewPresenting,
        materializer: any CloudMaterializing,
        restoreFocus: @escaping @MainActor () -> Void
    )
    func toggle(selection: WorkspacePreviewSelection) async
    func selectionDidChange(to selection: WorkspacePreviewSelection) async
    func closeAndRestoreFocus()
}
```

For exactly one `FileItem` with `isDirectory && !isPackage`, call `captureFolderPreviewRequest`; a nonnil capture selects folder mode, while nil routes to system Quick Look. All other nonempty selections route to existing identity-captured Quick Look. Repeated Space closes the current mode. Selection change does nothing when closed; otherwise it increments generation, cancels both concrete controllers, and reroutes. Before and after every async capture, compare pane/items/generation. `closeAndRestoreFocus` cancels both controllers and invokes the injected active-table focus closure.

- [ ] **Step 4: Run coordinator and Quick Look regression tests and verify GREEN**

Run: `xcrun swift test --filter WorkspacePreviewCoordinatorTests && xcrun swift test --filter WorkspaceCommandTests && xcrun swift test --filter CloudOperationGateTests`

Expected: folder no-materialization, system routes, selection races, repeated Space, close, and existing identity-preserving Quick Look pass.

- [ ] **Step 5: Commit coordinator routing**

```bash
git add Sources/BloomFileManager/Support/QuickLookController.swift Sources/BloomFileManager/Support/WorkspacePreviewCoordinator.swift Tests/BloomFileManagerTests/WorkspaceCommandTests.swift Tests/BloomFileManagerTests/WorkspacePreviewCoordinatorTests.swift
git commit -m "feat: coordinate system and folder previews"
```

### Task 4: Read-only AppKit/SwiftUI folder panel

**Files:**
- Create: `Sources/BloomFileManager/Support/FolderPreviewController.swift`
- Create: `Sources/BloomFileManager/Views/FolderPreviewView.swift`
- Create: `Tests/BloomFileManagerTests/FolderPreviewPresentationTests.swift`
- Modify: `Sources/BloomFileManager/Support/AccessibilityIdentifiers.swift`
- Modify: `Tests/BloomFileManagerTests/AccessibilityPresentationTests.swift`

**Interfaces:**
- Consumes: Task 2 `FolderPreviewModel` and Task 3 coordinator close callback.
- Produces: one reusable key `NSPanel` with a SwiftUI folder preview and deterministic close handling.

- [ ] **Step 1: Write failing presentation and read-only tests**

```swift
@Test func folderPreviewHasRequiredAccessibleColumns() throws {
    let implementation = try source(named: "Views/FolderPreviewView.swift")
    #expect(implementation.contains("folderPreview.table"))
    #expect(implementation.contains("Name"))
    #expect(implementation.contains("Kind"))
    #expect(implementation.contains("Size"))
    #expect(implementation.contains("Modified"))
    #expect(!implementation.contains("onOpen"))
    #expect(!implementation.contains("onTrash"))
}

@Test @MainActor func escapeClosesPanelThroughCoordinator() {
    let close = CloseRecorder()
    let model = FolderPreviewModel(listing: EmptyFolderPreviewListing())
    let controller = FolderPreviewController(model: model, onClose: close.record)
    controller.handleEscape()
    #expect(close.count == 1)
}

private struct EmptyFolderPreviewListing: FolderPreviewListing {
    func snapshot(_ request: FolderPreviewRequest, progress: @escaping @Sendable (Int) -> Void) async throws -> FolderPreviewSnapshot {
        FolderPreviewSnapshot(request: request, entries: [])
    }
}

@MainActor private final class CloseRecorder {
    private(set) var count = 0
    func record() { count += 1 }
}

private func source(named relativePath: String) throws -> String {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let url = packageRoot.appending(path: "Sources/BloomFileManager").appending(path: relativePath)
    return try String(contentsOf: url, encoding: .utf8)
}
```

- [ ] **Step 2: Run presentation tests and verify RED**

Run: `xcrun swift test --filter FolderPreviewPresentationTests && xcrun swift test --filter AccessibilityPresentationTests`

Expected: compilation or assertions fail because the controller, view, and identifiers are absent.

- [ ] **Step 3: Implement the reusable panel and read-only view**

```swift
@MainActor
final class FolderPreviewController: NSObject, NSWindowDelegate {
    init(model: FolderPreviewModel, onClose: @escaping @MainActor () -> Void)
    func present(request: FolderPreviewRequest)
    func close()
    func handleEscape()
}

struct FolderPreviewView: View {
    @Bindable var model: FolderPreviewModel
    var body: some View {
        VStack(alignment: .leading) {
            Text(model.request?.url.lastPathComponent ?? "Folder")
                .font(.headline)
            Text(model.statusText)
                .accessibilityIdentifier("folderPreview.status")
            Table(model.entries) {
                TableColumn("Name", value: \.name)
                TableColumn("Kind") { Text($0.isDirectory ? "Folder" : "File") }
                TableColumn("Size") { Text($0.byteSize.map(String.init) ?? "—") }
                TableColumn("Modified") { Text($0.modifiedAt?.formatted() ?? "—") }
            }
            .accessibilityIdentifier("folderPreview.table")
        }
        .padding()
    }
}
```

Create one `NSPanel`, set its `contentView` to `NSHostingView(rootView:)`, use a minimum 640×420 content size, and make close notifications return to the coordinator once. Show basename plus a privacy-safe parent label, loading count, item count, and exact errors “Folder changed. Close the preview and try again.” or “Folder contents are unavailable without downloading.” Render a noneditable `Table` with name/kind/size/modified columns and folders-first rows supplied by the model. Add stable `folderPreview.*` identifiers and VoiceOver labels/value announcements. Do not attach default action, context menu, drag, drop, or mutation callbacks.

- [ ] **Step 4: Run panel and accessibility tests and verify GREEN**

Run: `xcrun swift test --filter FolderPreviewPresentationTests && xcrun swift test --filter AccessibilityPresentationTests`

Expected: panel reuse, single close callback, read-only surface, privacy-safe copy, identifiers, VoiceOver status, and Escape handling pass.

- [ ] **Step 5: Commit the panel UI**

```bash
git add Sources/BloomFileManager/Support/AccessibilityIdentifiers.swift Sources/BloomFileManager/Support/FolderPreviewController.swift Sources/BloomFileManager/Views/FolderPreviewView.swift Tests/BloomFileManagerTests/AccessibilityPresentationTests.swift Tests/BloomFileManagerTests/FolderPreviewPresentationTests.swift
git commit -m "feat: add accessible folder contents panel"
```

### Task 5: App, command, and selection-observer integration

**Files:**
- Modify: `Sources/BloomFileManager/App/BloomFileManagerApp.swift`
- Modify: `Sources/BloomFileManager/Support/WorkspaceCommands.swift`
- Modify: `Sources/BloomFileManager/Views/WorkspaceView.swift`
- Modify: `Sources/BloomFileManager/Views/AppKit/FileTableView.swift`
- Modify: `Tests/BloomFileManagerTests/WorkspaceCommandPolicyTests.swift`
- Modify: `Tests/BloomFileManagerTests/WorkspaceCommandTests.swift`
- Create: `Tests/BloomFileManagerTests/FolderPreviewIntegrationTests.swift`

**Interfaces:**
- Consumes: complete Tasks 1–4 subsystem.
- Produces: Space/Escape/editor-priority behavior and selection-change forwarding in the running app.

- [ ] **Step 1: Write failing integration tests**

```swift
@Test func workspaceObserverReferencesOnlyCoordinator() throws {
    let implementation = try source(named: "Views/WorkspaceView.swift")
    #expect(implementation.contains("previewCoordinator.selectionDidChange"))
    #expect(!implementation.contains("quickLookController.updateIfPresented"))
}

@Test func textEditingKeepsSpaceAndEscapePriority() {
    let folder = FileItem(
        url: URL(filePath: "/folder", directoryHint: .isDirectory),
        name: "folder",
        isDirectory: true,
        isPackage: false,
        modifiedAt: nil,
        byteSize: nil,
        typeDescription: "Folder"
    )
    let policy = WorkspaceCommandPolicy(
        selectionCount: 1,
        isOperationRunning: false,
        pasteboardHasFileURLs: false,
        selectedItems: [folder],
        isTextEditing: true
    )
    #expect(!policy.canQuickLook)
    #expect(!policy.canClosePreview)
}

private func source(named relativePath: String) throws -> String {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let url = packageRoot.appending(path: "Sources/BloomFileManager").appending(path: relativePath)
    return try String(contentsOf: url, encoding: .utf8)
}
```

- [ ] **Step 2: Run integration tests and verify RED**

Run: `xcrun swift test --filter FolderPreviewIntegrationTests && xcrun swift test --filter WorkspaceCommand`

Expected: assertions fail because the workspace and commands still call Quick Look directly and no close-preview policy exists.

- [ ] **Step 3: Wire the coordinator as the only preview entry point**

Create the folder listing/model/controller and workspace coordinator once in `BloomFileManagerApp`, then inject the coordinator into `WorkspaceView` and `WorkspaceCommands`. Replace the `WorkspaceView` Quick Look selection task body with:

```swift
.task(id: previewSelectionKey) {
    await previewCoordinator.selectionDidChange(
        to: WorkspacePreviewSelection(
            paneID: workspace.activePaneID,
            items: selectedItemsForPreview
        )
    )
}
```

Change the Space command to call `previewCoordinator.toggle(selection:)`. Add an editor-safe Escape route to `closeAndRestoreFocus`, while preserving `PaneActivatingTableView.onCancel` priority for filter/path/rename cancellation. Remove direct `QuickLookController` calls from ordinary workspace selection handling; storage inspector may retain its separate explicit file Quick Look route.

Add this explicit command-policy gate and require `previewCoordinator.mode != .closed`
at the Escape call site:

```swift
var canClosePreview: Bool { !isTextEditing }
```

- [ ] **Step 4: Run integration and regression tests and verify GREEN**

Run: `xcrun swift test --filter FolderPreview && xcrun swift test --filter WorkspaceCommand && xcrun swift test --filter FileTableViewLifecycleTests && xcrun swift test --filter CloudOperationGateTests`

Expected: Space routes correctly, Escape/editor precedence is deterministic, focus returns to the active table, selection changes cannot bypass the coordinator, and storage/file Quick Look regressions stay green.

- [ ] **Step 5: Commit app integration**

```bash
git add Sources/BloomFileManager/App/BloomFileManagerApp.swift Sources/BloomFileManager/Support/WorkspaceCommands.swift Sources/BloomFileManager/Views/AppKit/FileTableView.swift Sources/BloomFileManager/Views/WorkspaceView.swift Tests/BloomFileManagerTests/FolderPreviewIntegrationTests.swift Tests/BloomFileManagerTests/WorkspaceCommandPolicyTests.swift Tests/BloomFileManagerTests/WorkspaceCommandTests.swift
git commit -m "feat: restore Space folder contents preview"
```

### Task 6: Folder preview regression and provider evidence

**Files:**
- Modify: `README.md`
- Create: `docs/verification/2026-08-04-folder-preview.md`
- Modify only if a focused regression fails: the responsible source file and its new failing regression test.

**Interfaces:**
- Consumes: complete Tasks 1–5 feature.
- Produces: automated, local UI, Google Drive, OneDrive, and VoiceOver evidence.

- [ ] **Step 1: Run focused and full automated verification**

```bash
xcrun swift test --filter FolderPreview
xcrun swift test --filter FileSystemAccessTests
xcrun swift test --filter DirectoryListingServiceTests
xcrun swift test --filter WorkspaceCommand
xcrun swift test --filter CloudOperationGateTests
xcrun swift test --no-parallel
xcrun swift build -c release
```

Expected: every command exits 0 with no new warnings.

- [ ] **Step 2: Run and record local keyboard/VoiceOver verification**

Build and run the debug executable, then record actual observations in `docs/verification/2026-08-04-folder-preview.md`:

```markdown
- [ ] Space on one ordinary folder shows only immediate children.
- [ ] Space on a file, package, symlink, or multi-selection uses system Quick Look.
- [ ] Repeated Space and Escape close preview and restore active-table focus.
- [ ] Space/Escape typed during rename, path edit, or filter edit affects the editor first.
- [ ] A large folder shows loading progress and publishes rows once as a sorted snapshot.
- [ ] Replacing the folder during enumeration publishes no mixed rows and shows the changed message.
- [ ] VoiceOver reads folder name, safe location, loading/item count, columns, rows, and errors.
```

- [ ] **Step 3: Record Google Drive and OneDrive provider verification**

Add actual provider/client version, folder state, and observed result for each row:

```markdown
- [ ] Google Drive folder metadata appears without `CloudMaterializing` activity or online-only file download.
- [ ] OneDrive folder metadata appears without `CloudMaterializing` activity or online-only file download.
- [ ] A provider that refuses descriptor-relative metadata shows the read-only unavailable state.
- [ ] Closing or changing selection cancels provider work and stale rows never appear.
```

- [ ] **Step 4: Update README and commit evidence**

Document the Space routing matrix, one-level/read-only scope, hidden-item behavior, cloud metadata limitation, and unavailable-state wording.

```bash
git add README.md docs/verification/2026-08-04-folder-preview.md
git commit -m "docs: verify folder contents preview"
```
