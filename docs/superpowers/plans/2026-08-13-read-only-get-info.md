# Read-Only Get Info Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a reusable nonmodal Command-I Get Info panel that presents identity-validated entry metadata and calculates SHA-256 only after an explicit user request.

**Architecture:** Keep inspection data out of `FileItem`. A new inspection service captures exact identity, reads no-follow entry metadata under scoped access, and revalidates identity before publishing an immutable report. A main-actor model owns cancellation and checksum progress, while a reusable AppKit panel hosts a read-only SwiftUI view.

**Tech Stack:** Swift 6.1, SwiftUI/AppKit, Observation, Darwin `lstat`/`readlink`, Foundation URL resource values, Swift Testing, existing `FileSystemAccess`, `ChecksumService`, and scoped-access APIs on macOS 15.

## Global Constraints

- Prefix Swift verification commands with `env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun`.
- `FileItem`, `ChecksumService`, `ComparisonModels`, `FileSystemAccess`, `StorageScanService`, and cloud-materialization implementations remain unchanged.
- Opening Get Info reads metadata only; it never invokes `ChecksumService`, `CloudMaterializing`, `NSFileCoordinator`, `FileHandle`, or another file-content API.
- `Calculate SHA-256` is available only for exactly one regular, non-symbolic-link file with a captured `ComparisonFingerprint`.
- Only the explicit checksum action can invoke the existing `ChecksumService`; closing or replacing the panel request cancels that work.
- Every item is inspected under scoped access with exact identity captured before metadata reads and revalidated afterward using `==`.
- A missing, replaced, or unreadable item yields a visible per-item failure and cannot publish stale metadata.
- Directory byte values describe the directory entry, never a recursive directory total.
- The first version is read-only: it does not mutate tags, permissions, ownership, dates, extended attributes, or names.
- `Command-I` and context-menu invocation use the active/captured selection in visible table order and fail closed when selection capture is incomplete or text editing is active.
- Follow RED → observed expected failure → minimal GREEN → focused pass for every production behavior.

---

### Task 1: Immutable metadata report and identity-safe inspection

**Files:**
- Create: `Sources/BloomFileManager/Models/GetInfoModels.swift`
- Create: `Sources/BloomFileManager/Services/GetInfoInspectionService.swift`
- Create: `Tests/BloomFileManagerTests/GetInfoModelsTests.swift`
- Create: `Tests/BloomFileManagerTests/GetInfoInspectionServiceTests.swift`

**Interfaces:**
- Consumes: `FileItem`, `FileIdentity`, `ComparisonFingerprint`, `FileSystemAccess`, and `CloudLocationScopedAccessCoordinator`.
- Produces: `GetInfoEntryKind`, `GetInfoItemSnapshot`, `GetInfoInspectionFailure`, `GetInfoInspectionReport`, `GetInfoSelectionSummary`, `GetInfoInspecting`, and `LiveGetInfoInspectionService`.

- [ ] **Step 1: Add failing value-model tests**

Prove that summaries use literal totals, preserve input order, count failures separately, return a common parent only when all successful items share one, and expose checksum eligibility only for one regular file:

```swift
@Test func selectionSummaryUsesKnownEntryBytesAndPreservesFailures() {
    let report = GetInfoInspectionReport(
        outcomes: [
            .success(.fixture(name: "a.txt", logicalByteSize: 10, allocatedByteSize: 512)),
            .failure(.init(url: URL(filePath: "/tmp/b.txt"), reason: .itemChanged))
        ]
    )
    #expect(report.summary.selectedCount == 2)
    #expect(report.summary.inspectedCount == 1)
    #expect(report.summary.failedCount == 1)
    #expect(report.summary.knownLogicalByteTotal == 10)
    #expect(report.summary.knownAllocatedByteTotal == 512)
}
```

- [ ] **Step 2: Run model tests and verify RED**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --enable-swift-testing --no-parallel --filter GetInfoModelsTests
```

Expected: compilation fails because the Get Info models do not exist.

- [ ] **Step 3: Implement the immutable models**

Use these core shapes:

```swift
enum GetInfoEntryKind: String, Equatable, Sendable {
    case regularFile, directory, package, symbolicLink, special
}

struct GetInfoItemSnapshot: Identifiable, Equatable, Sendable {
    var id: URL { url }
    let url: URL
    let name: String
    let kind: GetInfoEntryKind
    let typeDescription: String
    let typeIdentifier: String?
    let logicalByteSize: Int64?
    let allocatedByteSize: Int64?
    let createdAt: Date?
    let modifiedAt: Date?
    let ownerID: UInt32
    let groupID: UInt32
    let posixMode: UInt16
    let finderTags: [String]
    let symbolicLinkDestination: String?
    let availability: CloudItemAvailability
    let identity: FileIdentity
    let checksumRequest: ChecksumRequest?
}

enum GetInfoInspectionOutcome: Equatable, Sendable {
    case success(GetInfoItemSnapshot)
    case failure(GetInfoInspectionFailure)
}

struct GetInfoInspectionReport: Equatable, Sendable {
    let outcomes: [GetInfoInspectionOutcome]
    var summary: GetInfoSelectionSummary {
        GetInfoSelectionSummary(outcomes: outcomes)
    }
}
```

`GetInfoInspectionFailure.Reason` has `itemChanged`, `accessDenied`, and `metadataUnavailable` cases. Snapshot and summary formatting remains outside these data models.

- [ ] **Step 4: Add failing live inspection tests**

Use real temporary entries plus narrow injected readers to prove:

```swift
@Test func regularFileMetadataProducesIdentityBoundChecksumRequest() async throws
@Test func openingInspectionNeverCallsChecksumOrMaterializer() async throws
@Test func symbolicLinkReportsItsDestinationAndCannotCalculateChecksum() async throws
@Test func replacementBetweenMetadataAndFinalIdentityReturnsItemChanged() async throws
@Test func scopedAccessBalancesForSuccessFailureAndCancellation() async throws
@Test func multipleOutcomesRemainInCapturedSelectionOrder() async throws
```

- [ ] **Step 5: Run service tests and verify RED**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --enable-swift-testing --no-parallel --filter GetInfoInspectionServiceTests
```

Expected: compilation fails because `GetInfoInspecting` and `LiveGetInfoInspectionService` do not exist.

- [ ] **Step 6: Implement no-follow metadata inspection**

Expose:

```swift
protocol GetInfoInspecting: Sendable {
    func inspect(_ items: [FileItem]) async -> GetInfoInspectionReport
}

struct LiveGetInfoInspectionService: GetInfoInspecting {
    init(
        fileSystem: any FileSystemAccess = LiveFileSystemAccess(),
        accessCoordinator: CloudLocationScopedAccessCoordinator = .init()
    )
}
```

For each captured item, acquire scoped access, capture `FileIdentity`, read `lstat`
fields on a detached utility task, read type identifier/description, tags, and dates
from URL resource values, use `readlink` only for a symbolic link, then capture exact
identity again. Construct `ChecksumRequest` only when `lstat` identifies a regular
file; use the captured identity, `st_size`, and nanosecond modification timestamp in
its `ComparisonFingerprint`. Convert cancellation to `CancellationError` at the
report level and map ordinary per-item failures without discarding other outcomes.

- [ ] **Step 7: Run model/service tests and verify GREEN**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --enable-swift-testing --no-parallel --filter 'GetInfoModelsTests|GetInfoInspectionServiceTests'
git diff --check
```

Require zero failures and a clean whitespace check.

- [ ] **Step 8: Commit the inspection task**

```bash
git add Sources/BloomFileManager/Models/GetInfoModels.swift Sources/BloomFileManager/Services/GetInfoInspectionService.swift Tests/BloomFileManagerTests/GetInfoModelsTests.swift Tests/BloomFileManagerTests/GetInfoInspectionServiceTests.swift
git commit -m "feat: add identity-safe file inspection"
```

### Task 2: Inspector model, explicit checksum, and reusable panel

**Files:**
- Create: `Sources/BloomFileManager/Stores/GetInfoInspectorModel.swift`
- Create: `Sources/BloomFileManager/Views/GetInfoInspectorView.swift`
- Create: `Sources/BloomFileManager/Support/GetInfoInspectorController.swift`
- Create: `Sources/BloomFileManager/Support/GetInfoAccessibilityIdentifiers.swift`
- Create: `Tests/BloomFileManagerTests/GetInfoInspectorModelTests.swift`
- Create: `Tests/BloomFileManagerTests/GetInfoPresentationTests.swift`
- Create: `Tests/BloomFileManagerTests/GetInfoInspectorControllerTests.swift`

**Interfaces:**
- Consumes: `GetInfoInspecting`, `ChecksumService`, and `GetInfoInspectionReport`.
- Produces: `GetInfoInspectorModel`, `GetInfoInspectorView`, and `GetInfoInspectorController.present(items:)`.

- [ ] **Step 1: Add failing model lifecycle and checksum tests**

Cover generation and user-observable behavior:

```swift
@Test func replacementInspectionCannotPublishAfterNewerSelection() async throws
@Test func closingCancelsInspectionAndClearsPublishedReport() async throws
@Test func inspectionAloneNeverRequestsChecksum() async throws
@Test func explicitChecksumPublishesProgressAndLowercaseHexDigest() async throws
@Test func explicitChecksumRejectsChangedIdentityAndShowsFailure() async throws
@Test func closingCancelsAnActiveChecksum() async throws
```

- [ ] **Step 2: Run model tests and verify RED**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --enable-swift-testing --no-parallel --filter GetInfoInspectorModelTests
```

Expected: compilation fails because the inspector model does not exist.

- [ ] **Step 3: Implement the main-actor model**

Use explicit phases and generation-bound publication:

```swift
enum GetInfoInspectorPhase: Equatable, Sendable {
    case idle, loading, loaded, failed
}

enum GetInfoChecksumPhase: Equatable, Sendable {
    case unavailable
    case ready
    case calculating(progress: Double)
    case complete(hexDigest: String)
    case failed
}

@MainActor @Observable
final class GetInfoInspectorModel {
    private(set) var phase: GetInfoInspectorPhase = .idle
    private(set) var report: GetInfoInspectionReport?
    private(set) var checksumPhase: GetInfoChecksumPhase = .unavailable

    func inspect(_ items: [FileItem])
    func calculateSHA256()
    func cancelAndClear()
}
```

`inspect` cancels both prior tasks, advances a generation, and publishes only if the
generation still matches. `calculateSHA256` requires one successful snapshot with a
checksum request and sends it to the injected existing checksum service. Clamp progress
to `0...1` and render `digest.map { String(format: "%02x", $0) }.joined()`.

- [ ] **Step 4: Add failing view and controller tests**

Prove the view renders single and multi-selection summaries, labels directory values as
entry sizes, exposes failure rows, hides checksum for ineligible selection, and exposes
the explicit checksum button and copy action when eligible. Prove one controller reuses
one panel, a second `present` replaces model work, Escape/close cancels the model, and
the panel is nonmodal.

- [ ] **Step 5: Run presentation/controller tests and verify RED**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --enable-swift-testing --no-parallel --filter 'GetInfoPresentationTests|GetInfoInspectorControllerTests'
```

Expected: compilation fails because the view, controller, and accessibility identifiers do not exist.

- [ ] **Step 6: Implement the read-only view and reusable NSPanel**

Follow the existing `FolderPreviewController` panel ownership pattern. Create a titled,
closable, resizable utility `NSPanel` with `isReleasedWhenClosed = false`, an
`NSHostingView(rootView: GetInfoInspectorView(model: model))`, and minimum content size
of 420×460. `present(items:)` calls `model.inspect(items)` and
`makeKeyAndOrderFront(nil)`. Escape and `windowWillClose` call `cancelAndClear()`.

The view displays basename, path, type, entry kind, sizes, dates, numeric ownership,
octal mode, tags, availability, and symlink destination. Multi-selection uses the
derived summary and ordered outcome list. It never starts checksum from `onAppear`.

- [ ] **Step 7: Run Task 2 focused tests and verify GREEN**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --enable-swift-testing --no-parallel --filter 'GetInfoInspectorModelTests|GetInfoPresentationTests|GetInfoInspectorControllerTests'
git diff --check
```

Require zero failures.

- [ ] **Step 8: Commit the panel task**

```bash
git add Sources/BloomFileManager/Stores/GetInfoInspectorModel.swift Sources/BloomFileManager/Views/GetInfoInspectorView.swift Sources/BloomFileManager/Support/GetInfoInspectorController.swift Sources/BloomFileManager/Support/GetInfoAccessibilityIdentifiers.swift Tests/BloomFileManagerTests/GetInfoInspectorModelTests.swift Tests/BloomFileManagerTests/GetInfoPresentationTests.swift Tests/BloomFileManagerTests/GetInfoInspectorControllerTests.swift
git commit -m "feat: add read-only Get Info panel"
```

### Task 3: Command-I, context menu, app composition, and documentation

**Files:**
- Modify: `Sources/BloomFileManager/App/BloomFileManagerApp.swift`
- Modify: `Sources/BloomFileManager/Support/WorkspaceCommands.swift`
- Modify: `Sources/BloomFileManager/Views/WorkspaceView.swift`
- Modify: `Sources/BloomFileManager/Views/FilePaneView.swift`
- Modify: `Sources/BloomFileManager/Views/AppKit/FileTableView.swift`
- Modify: `Tests/BloomFileManagerTests/FileTableViewLifecycleTests.swift`
- Modify: `Tests/BloomFileManagerTests/WorkspaceCommandTests.swift`
- Modify: `Tests/BloomFileManagerTests/WorkspaceCommandPolicyTests.swift`
- Modify: `Tests/BloomFileManagerTests/AccessibilityPresentationTests.swift`
- Modify: `README.md`
- Modify: `README.ko.md`
- Modify: `docs/user-guide.md`
- Modify: `docs/user-guide.ko.md`
- Modify: `docs/current-limitations.md`
- Modify: `docs/current-limitations.ko.md`

**Interfaces:**
- Consumes: `GetInfoInspectorModel` and `GetInfoInspectorController` from Task 2.
- Produces: active-pane Command-I dispatch and captured-selection `Get Info` context-menu dispatch.

- [ ] **Step 1: Add failing command and menu tests**

Prove that Command-I is enabled only for a complete, nonempty active-pane selection
outside text editing, captures visible order, and invokes the shared controller. Prove
that the AppKit context menu updates selection first, captures the same ordered items,
adds one `Get Info` item with a stable identifier, and dispatches the captured values
rather than a later selection.

- [ ] **Step 2: Run integration tests and verify RED**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --enable-swift-testing --no-parallel --filter 'FileTableViewLifecycleTests|WorkspaceCommandTests|WorkspaceCommandPolicyTests|AccessibilityPresentationTests'
```

Expected: compilation or assertions fail because the Get Info command and menu route do not exist.

- [ ] **Step 3: Add the narrow shared wiring**

The app constructs one inspection service, one checksum service from
`cloudDependencies.makeChecksumService()`, one model, and one controller, then passes
the controller to both `WorkspaceView` and `WorkspaceCommands`.

Add a standalone `GetInfoSelectionPolicy` with this behavior:

```swift
struct GetInfoSelectionPolicy: Equatable {
    let isVisible: Bool
    let isEnabled: Bool

    init(selectionCount: Int, capturedItemCount: Int, isTextEditing: Bool) {
        isVisible = selectionCount > 0
        isEnabled = selectionCount > 0
            && capturedItemCount == selectionCount
            && !isTextEditing
    }
}
```

Do not add a `ContextActionKind` case. Add a dedicated `onGetInfo: ([FileItem]) -> Void`
callback to `FileTableView`, route it through `FilePaneView`, and append `Get Info` to
the menu using the captured `contextMenuItems`. Add the standard `.keyboardShortcut("i", modifiers: .command)` command using `selectedItemsForCommands`.

- [ ] **Step 4: Update English and Korean documentation**

Document Command-I, the context-menu item, single/multiple selection fields, entry-size
semantics, explicit SHA-256 behavior, cloud download boundary, and read-only scope.
Correct the stale Preview 5 wording in both limitations documents while editing them.

- [ ] **Step 5: Run focused, full, build, and bundle verification**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --enable-swift-testing --no-parallel --filter 'GetInfoModelsTests|GetInfoInspectionServiceTests|GetInfoInspectorModelTests|GetInfoPresentationTests|GetInfoInspectorControllerTests|ChecksumServiceTests|FileTableViewLifecycleTests|WorkspaceCommandTests|WorkspaceCommandPolicyTests|AccessibilityPresentationTests'
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test --enable-swift-testing --no-parallel
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift build -c release
./script/build_and_run.sh --verify
git diff --check
```

Require every command to exit zero.

- [ ] **Step 6: Commit integration**

```bash
git add Sources/BloomFileManager/App/BloomFileManagerApp.swift Sources/BloomFileManager/Support/WorkspaceCommands.swift Sources/BloomFileManager/Views/WorkspaceView.swift Sources/BloomFileManager/Views/FilePaneView.swift Sources/BloomFileManager/Views/AppKit/FileTableView.swift Tests/BloomFileManagerTests/FileTableViewLifecycleTests.swift Tests/BloomFileManagerTests/WorkspaceCommandTests.swift Tests/BloomFileManagerTests/WorkspaceCommandPolicyTests.swift Tests/BloomFileManagerTests/AccessibilityPresentationTests.swift README.md README.ko.md docs/user-guide.md docs/user-guide.ko.md docs/current-limitations.md docs/current-limitations.ko.md
git commit -m "feat: integrate Get Info inspector"
```
