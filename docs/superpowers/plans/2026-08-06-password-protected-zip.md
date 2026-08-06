# Password-Protected ZIP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add one-job-only password handling, WinZip AES-256 ZIP creation, AES/ZipCrypto extraction, root-confined publication, determinate progress, and accessible macOS UI without changing ordinary ZIP or TAR behavior.

**Architecture:** Pin minizip-ng 4.2.2 inside a narrow local C target that uses CommonCrypto and file descriptors, then wrap it with a Swift actor and an explicitly cleared secret buffer. Route only protected ZIP creation and detected encrypted ZIP extraction through the new service; retain `ditto` and `tar` for every ordinary archive path and preserve Pengrid's staging, identity, cancellation, queue, and recovery gates.

**Tech Stack:** Swift 6.1, Swift Testing, Swift Concurrency, SwiftUI, AppKit, Swift Package Manager C targets, minizip-ng 4.2.2, zlib, CommonCrypto, CoreFoundation, Security.framework, Darwin `openat` APIs, macOS 15+

## Global Constraints

- Work in `/Users/mac/Documents/Pengrid/.worktrees/safe-operation-center` on `codex/safe-operation-center`.
- Preserve package, executable, source-module, and bundle compatibility name `BloomFileManager`; the visible product name remains `Pengrid`.
- Vendor minizip-ng tag `4.2.2` at commit `7b2387161c542fa9f427352dcdef76097d0d692b`; do not use a floating dependency.
- Link protected ZIP code to Apple CommonCrypto/CoreFoundation/Security and system zlib; do not add an OpenSSL runtime dependency.
- Create only WinZip AES-256 protected archives; read AES-128, AES-192, AES-256, and ZipCrypto.
- Never put a password in command arguments, environment variables, logs, snapshots, operation history, retry closures, accessibility labels, pasteboard writes, Keychain, or durable storage.
- Obtain a password only after source materialization and private staging; destroy it on success, failure, incorrect-password retry, cancellation, and app termination.
- Retain ordinary ZIP on `/usr/bin/ditto` and TAR-family formats on `/usr/bin/tar`.
- Reject absolute/traversal paths, duplicate or topology-conflicting paths, escaping links, entries below archive links, special files, more than 100,000 entries, and output that exceeds declared or disk-capacity budgets.
- Reserve the larger of 512 MiB or ten percent of available important-usage capacity before protected extraction.
- Protected ZIP preserves bytes, directories, UTF-8 names, modification times, POSIX modes, ZIP64, and safe symbolic links; it does not promise complete resource-fork, ACL, Finder-metadata, quarantine, or arbitrary-xattr round trips.
- Use strict TDD: each production behavior begins with a focused test that is run and observed failing for the intended reason.
- Do not release or upload a DMG as part of this implementation plan; packaging verification prepares the next release task.

---

## File structure

New focused units:

- `Sources/EncryptedZIPCore/`: pinned C dependency plus Pengrid-owned descriptor, inspection, writer, and root-confined reader adapters.
- `Sources/BloomFileManager/Models/ProtectedZIPModels.swift`: non-secret protection, inspection, limits, password-request, progress, and error values.
- `Sources/BloomFileManager/Support/ProtectedZIPStrings.swift`: audited English/Korean protected-ZIP UI and error copy selected by locale.
- `Sources/BloomFileManager/Services/ArchiveSecret.swift`: one-attempt mutable password storage and explicit clearing.
- `Sources/BloomFileManager/Services/ArchiveSourcePreparationService.swift`: existing bounded aggregate staging extracted from the native runner for reuse.
- `Sources/BloomFileManager/Services/ProtectedZIPEngine.swift`: Swift actor boundary over the C API.
- `Sources/BloomFileManager/Services/ProtectedZIPOperationService.swift`: protected staging, prompt/retry, publication, and result mapping.
- `Sources/BloomFileManager/Services/ProtectedZIPLogger.swift`: stable-category diagnostics that cannot accept a password or raw engine error.
- `Sources/BloomFileManager/Services/RoutingArchiveOperationService.swift`: ordinary-versus-protected request routing with stable result order.
- `Sources/BloomFileManager/Stores/ArchivePasswordPromptCoordinator.swift`: one pending prompt and cancellation-aware continuation.
- `Sources/BloomFileManager/Views/ArchivePasswordSheet.swift`: secure creation and extraction forms only.

Existing large files receive only routing or presentation changes; core protected-ZIP logic does not enter `FileOperationController.swift`, `WorkspaceView.swift`, or `ArchiveCommandRunner.swift`.

---

### Task 1: Pin and build the minimal encrypted ZIP C core

**Files:**
- Modify: `Package.swift`
- Create: `Sources/EncryptedZIPCore/include/pengrid_encrypted_zip.h`
- Create: `Sources/EncryptedZIPCore/pengrid_encrypted_zip.c`
- Create: `Sources/EncryptedZIPCore/config/mz_config.h`
- Create: `Sources/EncryptedZIPCore/vendor/minizip-ng/LICENSE`
- Create: `Sources/EncryptedZIPCore/vendor/minizip-ng/{mz.h,mz_crypt.c,mz_crypt.h,mz_crypt_apple.c,mz_os.c,mz_os.h,mz_os_posix.c,mz_strm.c,mz_strm.h,mz_strm_buf.c,mz_strm_buf.h,mz_strm_mem.c,mz_strm_mem.h,mz_strm_os.h,mz_strm_os_posix.c,mz_strm_pkcrypt.c,mz_strm_pkcrypt.h,mz_strm_split.c,mz_strm_split.h,mz_strm_wzaes.c,mz_strm_wzaes.h,mz_strm_zlib.c,mz_strm_zlib.h,mz_zip.c,mz_zip.h,mz_zip_rw.c,mz_zip_rw.h}`
- Create: `Tests/BloomFileManagerTests/EncryptedZIPCoreBuildTests.swift`

**Interfaces:**
- Produces: C module `EncryptedZIPCore`
- Produces: `const char *pengrid_zip_core_version(void)`
- Produces: `void pengrid_secure_clear(void *bytes, size_t length)`

- [ ] **Step 1: Add a failing import and version test**

```swift
import EncryptedZIPCore
import Testing

@Test func encryptedZIPCoreIsPinnedAndClearsBuffers() {
    #expect(String(cString: pengrid_zip_core_version()) == "minizip-ng 4.2.2")
    var bytes = Array("public-test-secret".utf8)
    bytes.withUnsafeMutableBytes { buffer in
        pengrid_secure_clear(buffer.baseAddress, buffer.count)
    }
    #expect(bytes.allSatisfy { $0 == 0 })
}
```

- [ ] **Step 2: Run the focused test and verify RED**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --disable-sandbox --no-parallel \
  --filter EncryptedZIPCoreBuildTests
```

Expected: compilation fails because module `EncryptedZIPCore` does not exist.

- [ ] **Step 3: Import the exact upstream files**

Resolve the tag before copying any source:

```bash
test "$(git ls-remote https://github.com/zlib-ng/minizip-ng.git refs/tags/4.2.2 | awk '{print $1}')" \
  = "7b2387161c542fa9f427352dcdef76097d0d692b"
```

Copy only the files listed in this task from that commit. Retain upstream
contents byte-for-byte and put Pengrid compile definitions only in
`config/mz_config.h`:

```c
#define HAVE_DIRENT_H 1
#define HAVE_FSEEKO 1
#define HAVE_READLINK 1
#define HAVE_SYMLINK 1
#define HAVE_ZLIB 1
#define HAVE_PKCRYPT 1
#define HAVE_WZAES 1
#define _DARWIN_C_SOURCE 1
```

- [ ] **Step 4: Add the C target and narrow public header**

Configure `Package.swift` with the executable depending on `EncryptedZIPCore`
and the existing test target depending on both modules:

```swift
.target(
    name: "EncryptedZIPCore",
    path: "Sources/EncryptedZIPCore",
    exclude: ["vendor/minizip-ng/LICENSE"],
    publicHeadersPath: "include",
    cSettings: [
        .headerSearchPath("config"),
        .headerSearchPath("vendor/minizip-ng"),
        .define("HAVE_PKCRYPT"),
        .define("HAVE_WZAES"),
        .define("HAVE_ZLIB"),
        .define("_DARWIN_C_SOURCE")
    ],
    linkerSettings: [
        .linkedLibrary("z"),
        .linkedFramework("CoreFoundation"),
        .linkedFramework("Security")
    ]
)
```

Expose only the two Task 1 functions and implement clearing with
`explicit_bzero`:

```c
const char *pengrid_zip_core_version(void) { return "minizip-ng 4.2.2"; }

void pengrid_secure_clear(void *bytes, size_t length) {
    if (bytes != NULL && length > 0) explicit_bzero(bytes, length);
}
```

- [ ] **Step 5: Run the focused test and verify GREEN**

Run the Step 2 command. Expected: the test passes and the linker reports no
missing minizip or crypto symbols.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/EncryptedZIPCore \
  Tests/BloomFileManagerTests/EncryptedZIPCoreBuildTests.swift
git commit -m "build: vendor encrypted zip core"
```

### Task 2: Add descriptor-safe inspection and one-attempt secret storage

**Files:**
- Modify: `Sources/EncryptedZIPCore/include/pengrid_encrypted_zip.h`
- Modify: `Sources/EncryptedZIPCore/pengrid_encrypted_zip.c`
- Create: `Sources/EncryptedZIPCore/pengrid_fd_stream.c`
- Create: `Sources/EncryptedZIPCore/pengrid_fd_stream.h`
- Modify: `Sources/BloomFileManager/Services/FileSystemAccess.swift`
- Create: `Sources/BloomFileManager/Services/ArchiveSecret.swift`
- Create: `Tests/BloomFileManagerTests/ArchiveSecretTests.swift`
- Modify: `Tests/BloomFileManagerTests/FileSystemAccessTests.swift`
- Modify: `Tests/BloomFileManagerTests/EncryptedZIPCoreBuildTests.swift`

**Interfaces:**
- Produces: `OpenedFileSystemItem`
- Changes: `FileSystemAccess.openItem(_:kind:identifiedBy:)`
- Produces: `ArchiveSecret.creation(password:confirmation:)`
- Produces: `ArchiveSecret.extraction(password:)`
- Produces: `ArchiveSecret.withUnsafeBytes(_:)` and `invalidate()`
- Produces: `pengrid_zip_inspect_fd(int, pengrid_zip_inspection_t *)`

- [ ] **Step 1: Write failing secret, descriptor, and plain-ZIP inspection tests**

```swift
@Test func archiveSecretEnforcesModeLimitsAndBecomesUnavailable() throws {
    #expect(throws: ArchiveSecretError.confirmationMismatch) {
        try ArchiveSecret.creation(password: "abcdefgh", confirmation: "abcdefgi")
    }
    #expect(throws: ArchiveSecretError.containsNull) {
        try ArchiveSecret.extraction(password: "before\0after")
    }
    let secret = try ArchiveSecret.creation(
        password: "long-passphrase",
        confirmation: "long-passphrase"
    )
    #expect(try secret.withUnsafeBytes { $0.count } == 15)
    secret.invalidate()
    #expect(throws: ArchiveSecretError.unavailable) {
        try secret.withUnsafeBytes { $0.count }
    }
    #expect(secret.description == "<redacted archive secret>")
}
```

Add a live filesystem test that opens an identity-matched regular file with
`O_RDONLY | O_NOFOLLOW | O_CLOEXEC`, returns its descriptor, and rejects a
different identity. Verify that the returned descriptor remains valid while its
owner is retained and is closed exactly once when explicitly closed or released.
Add a core test that creates a plain ZIP with `ditto`, calls
`pengrid_zip_inspect_fd`, and expects `has_encrypted_entries == 0`.

- [ ] **Step 2: Run focused tests and verify RED**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --disable-sandbox --no-parallel \
  --filter 'ArchiveSecretTests|FileSystemAccessTests|EncryptedZIPCoreBuildTests'
```

Expected: compilation fails on all new APIs.

- [ ] **Step 3: Add identity-bound descriptor access**

Define:

```swift
enum OpenedFileSystemItemKind: Sendable, Equatable { case regularFile, directory }

final class OpenedFileSystemItem: @unchecked Sendable {
    let identity: FileIdentity
    func withUnsafeDescriptor<T>(_ body: (Int32) throws -> T) throws -> T
    func close()
}

func openItem(
    _ url: URL,
    kind: OpenedFileSystemItemKind,
    identifiedBy expectedIdentity: FileIdentity
) async throws -> OpenedFileSystemItem
```

The owner serializes descriptor access with a lock, closes exactly once from
`close()` or `deinit`, and never exposes the descriptor outside the synchronous
borrow. The live implementation opens the parent directory, uses `openat` with
`O_NOFOLLOW | O_CLOEXEC` plus `O_DIRECTORY` for directories, derives identity
from `fstat`, compares it with `expectedIdentity`, verifies the named entry still
has the same no-follow identity, and closes the descriptor on every failure.
Add `openItem` as a `FileSystemAccess` requirement with a default throwing
implementation so existing focused test doubles remain source-compatible;
protected-ZIP doubles that exercise the path implement it explicitly.

- [ ] **Step 4: Implement the mutable secret buffer**

Use one `NSLock`, `UnsafeMutableRawPointer.allocate`, and `pengrid_secure_clear`:

```swift
final class ArchiveSecret: @unchecked Sendable, CustomStringConvertible {
    static func creation(password: String, confirmation: String) throws -> ArchiveSecret
    static func extraction(password: String) throws -> ArchiveSecret
    func withUnsafeBytes<T>(_ body: (UnsafeRawBufferPointer) throws -> T) throws -> T
    func invalidate()
    var description: String { "<redacted archive secret>" }
}
```

Creation accepts `8...256` UTF-8 bytes and exact confirmation. Extraction
accepts `1...1_024` UTF-8 bytes. Both modes reject an embedded U+0000 scalar so
the pinned NUL-terminated minizip password API cannot silently truncate input.
The C adapters allocate one length-checked NUL-terminated temporary copy, clear
it before returning, and never convert it back to `String`. `deinit` calls
`invalidate()`. Do not conform to
`Equatable`, `Hashable`, `Codable`, or `Sendable` without the explicit lock.

- [ ] **Step 5: Implement fd-backed minizip inspection**

Add a custom minizip stream that duplicates the caller's descriptor and supports
read, seek, tell, and close without closing the caller's descriptor. Expose:

```c
typedef struct {
    uint64_t entry_count;
    uint64_t total_uncompressed_bytes;
    uint8_t has_encrypted_entries;
    uint8_t has_unsupported_encryption;
    uint8_t has_unsupported_compression;
    uint8_t strongest_aes_strength;
} pengrid_zip_inspection_t;

int32_t pengrid_zip_inspect_fd(int archive_fd, pengrid_zip_inspection_t *result);
```

Enumerate the entire central directory, detect Traditional PKWARE and WinZip
AES strengths 1, 2, and 3, and mark any method other than Store or Deflate as
unsupported when the archive needs the protected engine. Use checked `uint64_t`
addition and return a stable Pengrid overflow or malformed-archive code rather
than a raw minizip code.

- [ ] **Step 6: Run focused tests and verify GREEN**

Run the Step 2 command. Expected: all selected tests pass under normal SwiftPM
execution.

- [ ] **Step 7: Commit**

```bash
git add Sources/EncryptedZIPCore Sources/BloomFileManager/Services/FileSystemAccess.swift \
  Sources/BloomFileManager/Services/ArchiveSecret.swift \
  Tests/BloomFileManagerTests/ArchiveSecretTests.swift \
  Tests/BloomFileManagerTests/FileSystemAccessTests.swift \
  Tests/BloomFileManagerTests/EncryptedZIPCoreBuildTests.swift
git commit -m "feat: inspect zip encryption without exposing secrets"
```

### Task 3: Model protection, password requests, byte progress, and safe errors

**Files:**
- Create: `Sources/BloomFileManager/Models/ProtectedZIPModels.swift`
- Create: `Sources/BloomFileManager/Support/ProtectedZIPStrings.swift`
- Modify: `Sources/BloomFileManager/Models/ArchiveOperationModels.swift`
- Modify: `Sources/BloomFileManager/Models/FileOperationModels.swift`
- Modify: `Sources/BloomFileManager/Models/FileOperationJobModels.swift`
- Create: `Tests/BloomFileManagerTests/ProtectedZIPModelTests.swift`
- Modify: `Tests/BloomFileManagerTests/ArchiveFormatTests.swift`
- Modify: `Tests/BloomFileManagerTests/FileOperationJobModelsTests.swift`

**Interfaces:**
- Produces: `ArchiveProtection.none` and `.aes256`
- Produces: `ProtectedZIPInspection`, `ProtectedZIPLimits`, `ProtectedZIPProgress`
- Produces: `ArchivePasswordRequest` and `ArchivePasswordPurpose`
- Produces: `ProtectedZIPError`
- Produces: `ProtectedZIPDiagnosticEvent` with stable category, public archive basename, and outcome counts only
- Produces: audited English and Korean copy for each protected-ZIP error and password validation state
- Changes: `ArchiveRequest.protection` and `ArchiveDestinationPlan.protection`
- Adds: `ArchiveOperationPhase.processingBytes(completedByteCount:totalByteCount:)`
- Adds: `FileOperationJobState.waitingForPassword`

- [ ] **Step 1: Write failing value and redaction tests**

```swift
@Test func protectedCompressionPlanCarriesOnlyProtectionMetadata() throws {
    let plan = try #require(ArchiveDestinationPlanner.compression(
        selectedItems: [fixtureItem],
        in: root,
        occupiedNames: [],
        format: .zip,
        protection: .aes256
    ))
    #expect(plan.protection == .aes256)
    #expect(String(reflecting: plan).contains("password") == false)
}

@Test func protectedByteProgressClampsAndWaitStateIsAccessible() {
    let progress = ArchiveOperationProgress(
        kind: .extract,
        currentDisplayName: "자료.zip",
        phase: .processingBytes(completedByteCount: 50, totalByteCount: 100)
    )
    #expect(progress.fractionCompleted == 0.5)
    #expect(FileOperationJobState.waitingForPassword.label == "Waiting for password")
}

@Test func protectedErrorsHaveAuditedEnglishAndKoreanCopy() {
    #expect(ProtectedZIPStrings.message(for: .unsafeEntry, locale: Locale(identifier: "en"))
        == "The archive contains an unsafe item.")
    #expect(ProtectedZIPStrings.message(for: .unsafeEntry, locale: Locale(identifier: "ko"))
        == "압축 파일에 안전하지 않은 항목이 있습니다.")
}
```

- [ ] **Step 2: Run model tests and verify RED**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --disable-sandbox --no-parallel \
  --filter 'ProtectedZIPModelTests|ArchiveFormatTests|FileOperationJobModelsTests'
```

Expected: compilation fails because the protection and progress values are absent.

- [ ] **Step 3: Add exact non-secret value types**

```swift
enum ArchiveProtection: Sendable, Equatable { case none, aes256 }
enum ArchivePasswordPurpose: Sendable, Equatable { case createAES256, extract }

struct ArchivePasswordRequest: Identifiable, Sendable, Equatable {
    let id: UUID
    let purpose: ArchivePasswordPurpose
    let archiveBasename: String
    let previousAttemptFailed: Bool
}

struct ProtectedZIPProgress: Sendable, Equatable {
    let completedByteCount: Int64
    let totalByteCount: Int64?
}

struct ProtectedZIPLimits: Sendable, Equatable {
    static let maximumEntryCount = 100_000
    static let minimumCapacityReserve: Int64 = 512 * 1_024 * 1_024
    let maximumOutputByteCount: Int64
    let capacityReserveByteCount: Int64
}
```

`ProtectedZIPError` has closed cases for invalid password input, incorrect
password or damaged encrypted data, unsupported encryption or compression,
malformed archive,
unsafe entry, entry-count overflow, insufficient capacity, output-budget
overflow, identity change, cancellation, and recovery required. Its localized
messages never include raw upstream text or archive-entry names.

Keep the finite English/Korean strings in `ProtectedZIPStrings`, select Korean
only for a Korean language code and otherwise fall back to English, and inject a
locale in tests. Do not interpolate passwords, internal entry names, or raw C
errors into either language.

`ProtectedZIPDiagnosticEvent` is a closed, non-secret value with no free-form
message field. It may carry a stable category, the public archive basename,
duration, and outcome counts; it cannot carry an entry name, upstream error,
password, or secret-derived value.

- [ ] **Step 4: Thread protection and byte progress through existing models**

Add `protection: ArchiveProtection = .none` to planner, plan, and request
initializers. Reject `.aes256` unless `format == .zip && kind == .compress`.
Extend `fractionCompleted` so a positive known byte total is determinate and a
nil or zero total is indeterminate. Add `.waitingForPassword` without making it
a terminal state or retrying state.

- [ ] **Step 5: Run model tests and verify GREEN**

Run the Step 2 command. Expected: all selected tests pass and existing planner
call sites compile through the `.none` defaults.

- [ ] **Step 6: Commit**

```bash
git add Sources/BloomFileManager/Models \
  Sources/BloomFileManager/Support/ProtectedZIPStrings.swift \
  Tests/BloomFileManagerTests/ProtectedZIPModelTests.swift \
  Tests/BloomFileManagerTests/ArchiveFormatTests.swift \
  Tests/BloomFileManagerTests/FileOperationJobModelsTests.swift
git commit -m "feat: model protected zip operations"
```

### Task 4: Extract bounded source staging into a reusable service

**Files:**
- Create: `Sources/BloomFileManager/Services/ArchiveSourcePreparationService.swift`
- Modify: `Sources/BloomFileManager/Services/ArchiveCommandRunner.swift`
- Create: `Tests/BloomFileManagerTests/ArchiveSourcePreparationServiceTests.swift`
- Modify: `Tests/BloomFileManagerTests/ArchiveCommandRunnerTests.swift`
- Modify: `Tests/BloomFileManagerTests/ArchiveOperationIntegrationTests.swift`

**Interfaces:**
- Produces: `ArchiveSourcePreparing`
- Produces: `PreparedArchiveSources`
- Produces: `LiveArchiveSourcePreparationService.prepare(_:beside:parentIdentity:progress:)`
- Produces: `LiveArchiveSourcePreparationService.cleanup(_:)`

- [ ] **Step 1: Write a failing direct staging test**

```swift
@Test func sourcePreparationCopiesTopLevelItemsWithMonotonicProgress() async throws {
    let service = LiveArchiveSourcePreparationService(fileSystem: LiveFileSystemAccess())
    let phases = ArchivePhaseCollector()
    let prepared = try await service.prepare(
        identifiedArchiveTestSources([first, second]),
        beside: output,
        parentIdentity: archiveTestIdentity(for: root),
        progress: { await phases.append($0) }
    )
    #expect(Set(try FileManager.default.contentsOfDirectory(atPath: prepared.root.path))
        == ["First.txt", "Second.txt"])
    #expect(await phases.values == [
        .preparingSources(completedCount: 0, totalCount: 2),
        .preparingSources(completedCount: 1, totalCount: 2),
        .preparingSources(completedCount: 2, totalCount: 2)
    ])
    try await service.cleanup(prepared)
}
```

- [ ] **Step 2: Run focused archive tests and verify RED**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --disable-sandbox --no-parallel \
  --filter 'ArchiveSourcePreparationServiceTests|ArchiveCommandRunnerTests|ArchiveOperationIntegrationTests'
```

Expected: compilation fails because the reusable service is absent.

- [ ] **Step 3: Move, do not duplicate, the preparation actors**

```swift
protocol ArchiveSourcePreparing: Sendable {
    func prepare(
        _ sources: [IdentifiedFileRequest],
        beside destination: URL,
        parentIdentity: FileIdentity,
        progress: @escaping ArchiveCommandProgressHandler
    ) async throws -> PreparedArchiveSources
    func cleanup(_ prepared: PreparedArchiveSources) async throws
}
```

`PreparedArchiveSources` carries the aggregate root, staging reservation, and
identity-tracked copied entries. Move the existing maximum-four-worker queue,
progress reporter, identity/fingerprint checks, and reverse-order cleanup from
`ArchiveCommandRunner.swift` into this service unchanged.

- [ ] **Step 4: Make the native runner consume the service**

Inject `sourcePreparer` into `LiveArchiveCommandRunner`, call it for compression,
build the same `ditto`/`tar` arguments from `prepared.root`, and call cleanup on
every success and error path. Keep extraction behavior and public runner
signatures unchanged.

- [ ] **Step 5: Run focused tests and verify GREEN**

Run the Step 2 command. Expected: the direct service test and all existing
archive command/integration tests pass with identical phase order.

- [ ] **Step 6: Commit**

```bash
git add Sources/BloomFileManager/Services/ArchiveSourcePreparationService.swift \
  Sources/BloomFileManager/Services/ArchiveCommandRunner.swift \
  Tests/BloomFileManagerTests/ArchiveSourcePreparationServiceTests.swift \
  Tests/BloomFileManagerTests/ArchiveCommandRunnerTests.swift \
  Tests/BloomFileManagerTests/ArchiveOperationIntegrationTests.swift
git commit -m "refactor: share archive source staging"
```

### Task 5: Create AES-256 archives through the Swift engine

**Files:**
- Modify: `Sources/EncryptedZIPCore/include/pengrid_encrypted_zip.h`
- Modify: `Sources/EncryptedZIPCore/pengrid_encrypted_zip.c`
- Create: `Sources/EncryptedZIPCore/pengrid_zip_writer.c`
- Create: `Sources/EncryptedZIPCore/pengrid_zip_writer.h`
- Create: `Sources/BloomFileManager/Services/ProtectedZIPEngine.swift`
- Create: `Tests/BloomFileManagerTests/ProtectedZIPEngineWriterTests.swift`

**Interfaces:**
- Produces: `ProtectedZIPEngine`
- Produces: `LiveProtectedZIPEngine.inspect(archive:)`
- Produces: `LiveProtectedZIPEngine.createAES256(sourceRoot:destination:password:progress:)`
- Produces: C `pengrid_zip_create_aes256(...)`

- [ ] **Step 1: Write a failing encrypted-writer test**

```swift
@Test func writerCreatesAES256WithoutPuttingSecretInMetadata() async throws {
    let secretText = "public-writer-test-passphrase"
    let secret = try ArchiveSecret.creation(password: secretText, confirmation: secretText)
    let progress = ProtectedZIPProgressCollector()
    try await engine.createAES256(
        sourceRoot: openedSourceRoot,
        destination: openedArchive,
        password: secret,
        progress: { await progress.append($0) }
    )
    let inspection = try await engine.inspect(archive: openedArchiveForReading)
    #expect(inspection.hasEncryptedEntries)
    #expect(inspection.strongestAESStrength == 256)
    #expect(try Data(contentsOf: archiveURL).range(of: Data(secretText.utf8)) == nil)
    #expect(await progress.values.last?.completedByteCount == expectedByteCount)
}
```

Also test an empty file, nested Korean/emoji names, a selected symbolic link,
ZIP64 metadata, cancellation from the progress callback, and rejection of a
FIFO fixture.

- [ ] **Step 2: Run the writer tests and verify RED**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --disable-sandbox --no-parallel \
  --filter ProtectedZIPEngineWriterTests
```

Expected: compilation fails because `ProtectedZIPEngine` and the writer API do
not exist.

- [ ] **Step 3: Add the exact C writer contract**

```c
typedef int32_t (*pengrid_zip_progress_callback)(
    uint64_t completed, uint64_t total, void *context);

int32_t pengrid_zip_create_aes256(
    int source_root_fd,
    int destination_fd,
    const uint8_t *password,
    size_t password_length,
    pengrid_zip_progress_callback progress,
    void *progress_context);
```

Duplicate both descriptors, enumerate with `fdopendir`/`fstatat` using
`AT_SYMLINK_NOFOLLOW`, sort UTF-8 relative paths for deterministic tests, and
never follow links. Encode directories, regular files, and link-target bytes;
copy modification time and POSIX mode into ZIP metadata; choose AES strength 3;
use Deflate for regular files; use checked totals; clear every password copy and
derived temporary buffer on exit.

- [ ] **Step 4: Wrap the writer in a cancellation-aware actor**

```swift
protocol ProtectedZIPEngine: Sendable {
    func inspect(archive: OpenedFileSystemItem) async throws -> ProtectedZIPInspection
    func preflight(
        archive: OpenedFileSystemItem,
        destinationProbeRoot: OpenedEmptyFileSystemItem,
        limits: ProtectedZIPLimits
    ) async throws -> ProtectedZIPInspection
    func createAES256(
        sourceRoot: OpenedFileSystemItem,
        destination: OpenedEmptyFileSystemItem,
        password: ArchiveSecret,
        progress: @escaping @Sendable (ProtectedZIPProgress) async -> Void
    ) async throws
    func extract(
        archive: OpenedFileSystemItem,
        destinationRoot: OpenedEmptyFileSystemItem,
        password: ArchiveSecret,
        limits: ProtectedZIPLimits,
        progress: @escaping @Sendable (ProtectedZIPProgress) async -> Void
    ) async throws
}
```

Implement inspection and creation in `LiveProtectedZIPEngine`. Leave `preflight`
and `extract` returning `.unsupportedEncryption` until Task 6 supplies them. Run blocking C
work in a detached utility task, bridge callbacks through a lock-protected
context, return cancellation when `Task.isCancelled`, throttle Swift progress
delivery to at most ten updates per second while always delivering zero and the
final boundary, and `defer { password.invalidate() }` around the full call.

- [ ] **Step 5: Run writer tests and verify GREEN**

Run the Step 2 command. Expected: all writer, metadata, progress, cancellation,
and unsupported-entry tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/EncryptedZIPCore Sources/BloomFileManager/Services/ProtectedZIPEngine.swift \
  Tests/BloomFileManagerTests/ProtectedZIPEngineWriterTests.swift
git commit -m "feat: create aes256 zip archives"
```

### Task 6: Extract encrypted archives through a root-confined writer

**Files:**
- Modify: `Sources/EncryptedZIPCore/include/pengrid_encrypted_zip.h`
- Modify: `Sources/EncryptedZIPCore/pengrid_encrypted_zip.c`
- Create: `Sources/EncryptedZIPCore/pengrid_zip_reader.c`
- Create: `Sources/EncryptedZIPCore/pengrid_zip_reader.h`
- Create: `Sources/EncryptedZIPCore/pengrid_root_writer.c`
- Create: `Sources/EncryptedZIPCore/pengrid_root_writer.h`
- Modify: `Sources/BloomFileManager/Services/ProtectedZIPEngine.swift`
- Create: `Tests/BloomFileManagerTests/Fixtures/ProtectedZIP/README.md`
- Create: `Tests/BloomFileManagerTests/Fixtures/ProtectedZIP/7zip-aes256.zip`
- Create: `Tests/BloomFileManagerTests/Fixtures/ProtectedZIP/minizip-aes128.zip`
- Create: `Tests/BloomFileManagerTests/Fixtures/ProtectedZIP/minizip-aes192.zip`
- Create: `Tests/BloomFileManagerTests/Fixtures/ProtectedZIP/infozip-zipcrypto.zip`
- Create: `Tests/BloomFileManagerTests/Support/RawZIPFixtureBuilder.swift`
- Create: `Tests/BloomFileManagerTests/ProtectedZIPEngineReaderTests.swift`

**Interfaces:**
- Produces: C `pengrid_zip_extract(...)`
- Produces: C `pengrid_zip_preflight_fd(...)`
- Completes: `LiveProtectedZIPEngine.preflight(...)`
- Completes: `LiveProtectedZIPEngine.extract(...)`
- Produces: stable unsafe-entry, wrong-password-or-damage, limit, capacity, and cancellation statuses

- [ ] **Step 1: Create independent compatibility fixtures and provenance**

Use the official temporary 7-Zip 26.02 macOS console download
`https://github.com/ip7z/7zip/releases/download/26.02/7z2602-mac.tar.xz` and the
system Info-ZIP tool only to create committed test inputs:

```bash
7zz a -tzip -mem=AES256 -p'fixture-aes256-passphrase' 7zip-aes256.zip 자료.txt
/usr/bin/zip -P 'fixture-zipcrypto-password' infozip-zipcrypto.zip Legacy.txt
/usr/bin/shasum -a 256 7zip-aes256.zip minizip-aes128.zip \
  minizip-aes192.zip infozip-zipcrypto.zip
```

Generate the AES-128 and AES-192 reader fixtures with a temporary program linked
against the pinned source. The program opens a write stream and passes this
entry metadata to `mz_zip_entry_write_open`; run it once with strengths 1 and 2:

```c
mz_zip_file info = {0};
info.filename = "Strength.txt";
info.flag = MZ_ZIP_FLAG_UTF8 | MZ_ZIP_FLAG_ENCRYPTED;
info.compression_method = MZ_COMPRESS_METHOD_DEFLATE;
info.aes_version = MZ_AES_VERSION;
info.aes_strength = strength;
int32_t err = mz_zip_entry_write_open(zip, &info, 6, 0, password);
if (err == MZ_OK) err = mz_zip_entry_write(zip, contents, contents_length);
if (err == MZ_OK) err = mz_zip_entry_close(zip);
```

The temporary generator is not product code and is not committed. These two
fixtures verify reader strength handling; the independently created 7-Zip file
remains the cross-implementation AES-256 proof.

Record the tool versions, literal public fixture passwords, commands, expected
filenames/content, and hashes in the fixture README. Do not commit `7zz` or use
either fixture password in product copy.

- [ ] **Step 2: Write failing round-trip and hostile-entry tests**

```swift
@Test func readerExtractsIndependentAESAndLegacyFixtures() async throws {
    try await expectFixture("7zip-aes256.zip", password: "fixture-aes256-passphrase")
    try await expectFixture("infozip-zipcrypto.zip", password: "fixture-zipcrypto-password")
}

@Test func readerRejectsTraversalWithoutPublishingBytes() async throws {
    let fixture = try RawZIPFixtureBuilder.entry(name: "../escape.txt", bytes: [1, 2, 3])
    await #expect(throws: ProtectedZIPError.unsafeEntry) {
        try await extract(fixture, password: "fixture-password")
    }
    #expect(FileManager.default.fileExists(atPath: escapedURL.path) == false)
}
```

Add cases for absolute paths, NUL, exact duplicate, Unicode/case collision on
the actual test volume, file-versus-directory conflict, absolute/escaping link,
an entry below a link, block/FIFO/socket modes, 100,001 entries, checked-size
overflow, false declared size, truncated AES authentication data, wrong
password, byte-budget overflow, and cancellation during a large entry.

- [ ] **Step 3: Run the reader tests and verify RED**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --disable-sandbox --no-parallel \
  --filter ProtectedZIPEngineReaderTests
```

Expected: preflight and extraction report the Task 5 unsupported error and
hostile-fixture assertions fail.

- [ ] **Step 4: Implement full central-directory preflight**

Before opening a destination entry, enumerate every ZIP entry and build a trie
of normalized UTF-8 components. Reject empty, `.`, `..`, absolute, slash or
backslash traversal, NUL, component/path-length overflow, duplicates,
file/directory topology conflicts, special modes, more than 100,000 entries,
checked-size overflow, links outside the root, and descendants of link entries.
Reject compression methods other than Store and Deflate before requesting a
password.
Populate:

```c
typedef struct {
    uint64_t maximum_entry_count;
    uint64_t maximum_output_bytes;
    uint64_t capacity_reserve_bytes;
} pengrid_zip_limits_t;

int32_t pengrid_zip_preflight_fd(
    int archive_fd,
    int destination_probe_root_fd,
    pengrid_zip_limits_t limits,
    pengrid_zip_inspection_t *inspection);

int32_t pengrid_zip_extract(
    int archive_fd,
    int destination_root_fd,
    const uint8_t *password,
    size_t password_length,
    pengrid_zip_limits_t limits,
    pengrid_zip_progress_callback progress,
    void *progress_context);
```

- [ ] **Step 5: Implement root-confined creation and authenticated reads**

`pengrid_zip_preflight_fd` performs the complete path, topology, encryption,
entry-count, and declared-byte validation without a password. Against the empty
private probe root on the actual destination volume, use `fpathconf` for name and
path limits and create only zero-byte directories/regular placeholders with
`mkdirat`/exclusive `openat`; never create a symlink or write entry data. This
lets the destination filesystem itself reject case and Unicode canonical
collisions. Remove the entire probe reservation after preflight and treat an
unprovable cleanup as recovery-required.
`pengrid_zip_extract` repeats the same preflight in its supplied empty output
root, removes every probe placeholder, verifies the root is empty again, and
only then starts decryption, so future refactors cannot bypass the gate.

For every path component, use `mkdirat` or `openat` relative to a duplicated
root descriptor with `O_NOFOLLOW | O_CLOEXEC`; create leaves exclusively; never
call `chdir`; never traverse an archive link. Track per-entry and total actual
bytes and abort above the central-directory declaration or supplied budget.
Before each output chunk, use `fstatfs` on the opened root and abort if the write
would consume the supplied capacity reserve; never rely only on the initial
capacity snapshot.
Finish each AES entry so its authentication code is verified before success.
Map password-verifier and AES-authentication failure to one redacted status.
Remove all objects created during the current C call in reverse depth order on
failure; the Swift service will additionally destroy the whole attempt root.

- [ ] **Step 6: Complete the Swift extraction bridge**

Convert both `ProtectedZIPLimits` byte fields to the C limits with checked
integer conversion, reuse Task 5 cancellation/progress bridging, map only stable
Pengrid C statuses, and always invalidate `ArchiveSecret` in `defer`. Preflight
never accepts or obtains an `ArchiveSecret`.

- [ ] **Step 7: Run reader and writer tests and verify GREEN**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --disable-sandbox --no-parallel \
  --filter 'ProtectedZIPEngineReaderTests|ProtectedZIPEngineWriterTests'
```

Expected: both compatibility fixtures and every hostile/cancellation case pass;
no escaped or partial public output exists.

- [ ] **Step 8: Commit**

```bash
git add Sources/EncryptedZIPCore Sources/BloomFileManager/Services/ProtectedZIPEngine.swift \
  Tests/BloomFileManagerTests/Fixtures/ProtectedZIP \
  Tests/BloomFileManagerTests/Support/RawZIPFixtureBuilder.swift \
  Tests/BloomFileManagerTests/ProtectedZIPEngineReaderTests.swift
git commit -m "feat: safely extract encrypted zip archives"
```

### Task 7: Add the cancellation-aware password prompt coordinator and sheet

**Files:**
- Create: `Sources/BloomFileManager/Stores/ArchivePasswordPromptCoordinator.swift`
- Create: `Sources/BloomFileManager/Views/ArchivePasswordSheet.swift`
- Modify: `Sources/BloomFileManager/Support/AccessibilityIdentifiers.swift`
- Create: `Tests/BloomFileManagerTests/ArchivePasswordPromptCoordinatorTests.swift`
- Create: `Tests/BloomFileManagerTests/ArchivePasswordPresentationTests.swift`

**Interfaces:**
- Produces: `@MainActor protocol ArchivePasswordProviding`
- Produces: `ArchivePasswordPromptCoordinator.requestPassword(for:)`
- Produces: `submit(password:confirmation:)`, `cancel()`, and `cancel(requestID:)`
- Produces: `ArchivePasswordSheet`

- [ ] **Step 1: Write failing continuation, validation, cancellation, and copy tests**

```swift
@Test @MainActor func promptReturnsOneSecretAndRetainsNoPassword() async throws {
    let coordinator = ArchivePasswordPromptCoordinator()
    let task = Task { try await coordinator.requestPassword(for: creationRequest) }
    await Task.yield()
    #expect(coordinator.pendingRequest == creationRequest)
    coordinator.submit(password: "valid-passphrase", confirmation: "valid-passphrase")
    let secret = try await task.value
    #expect(coordinator.pendingRequest == nil)
    #expect(String(reflecting: coordinator).contains("valid-passphrase") == false)
    secret.invalidate()
}

@Test @MainActor func cancellingTaskDismissesMatchingPrompt() async {
    let coordinator = ArchivePasswordPromptCoordinator()
    let task = Task { try await coordinator.requestPassword(for: extractionRequest) }
    await Task.yield()
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(coordinator.pendingRequest == nil)
}
```

Presentation tests assert the exact title, filename-only subtitle, AES warning,
filename-visibility note, length copy, generic damaged-or-password error, Return
submit, Escape cancel, and VoiceOver labels contain no field value.

- [ ] **Step 2: Run prompt tests and verify RED**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --disable-sandbox --no-parallel \
  --filter 'ArchivePasswordPromptCoordinatorTests|ArchivePasswordPresentationTests'
```

Expected: compilation fails because coordinator and sheet presentation do not exist.

- [ ] **Step 3: Implement one pending continuation**

```swift
@MainActor
protocol ArchivePasswordProviding: AnyObject, Sendable {
    func requestPassword(for request: ArchivePasswordRequest) async throws -> ArchiveSecret
}

@MainActor @Observable
final class ArchivePasswordPromptCoordinator: ArchivePasswordProviding {
    private(set) var pendingRequest: ArchivePasswordRequest?
    private(set) var validationError: ArchivePasswordValidationError?
    func requestPassword(for request: ArchivePasswordRequest) async throws -> ArchiveSecret
    func submit(password: String, confirmation: String?)
    func cancel()
    func cancel(requestID: UUID)
}
```

Reject a second simultaneous request as a closed coordinator error. Use
`withTaskCancellationHandler` to resume exactly once, match cancellations by
request ID, and clear request/error state before resuming. The coordinator never
stores a submitted password or returned secret. Derive the generic inline
incorrect-password-or-damage presentation only from
`request.previousAttemptFailed`; never retain the prior error or secret.

- [ ] **Step 4: Implement secure SwiftUI forms**

Use view-local `@State` strings and `@FocusState`, two `SecureField`s for
creation and one for extraction. In the submit action, copy state to local
constants, immediately assign empty strings to both state properties, and then
call the coordinator. Do the same clearing before cancel. Do not add show,
remember, hint, or pasteboard-write controls.
Reject embedded U+0000 input through the same localized validation path as the
byte limits; Return submits only while the current mode is valid, Escape cancels,
and the first secure field receives initial focus.

- [ ] **Step 5: Run prompt tests and verify GREEN**

Run the Step 2 command. Expected: all tests pass and literal sentinel scans find
the password only in test source.

- [ ] **Step 6: Commit**

```bash
git add Sources/BloomFileManager/Stores/ArchivePasswordPromptCoordinator.swift \
  Sources/BloomFileManager/Views/ArchivePasswordSheet.swift \
  Sources/BloomFileManager/Support/AccessibilityIdentifiers.swift \
  Tests/BloomFileManagerTests/ArchivePasswordPromptCoordinatorTests.swift \
  Tests/BloomFileManagerTests/ArchivePasswordPresentationTests.swift
git commit -m "feat: prompt once for archive passwords"
```

### Task 8: Route protected jobs through staging, retry, and exclusive publication

**Files:**
- Create: `Sources/BloomFileManager/Services/ProtectedZIPOperationService.swift`
- Create: `Sources/BloomFileManager/Services/RoutingArchiveOperationService.swift`
- Create: `Sources/BloomFileManager/Services/ProtectedZIPLogger.swift`
- Modify: `Sources/BloomFileManager/Services/ArchiveCommandRunner.swift`
- Modify: `Sources/BloomFileManager/Services/FileOperationService.swift`
- Modify: `Sources/BloomFileManager/Models/ArchiveOperationModels.swift`
- Modify: `Sources/BloomFileManager/Models/FileOperationModels.swift`
- Create: `Tests/BloomFileManagerTests/ProtectedZIPOperationServiceTests.swift`
- Create: `Tests/BloomFileManagerTests/RoutingArchiveOperationServiceTests.swift`
- Modify: `Tests/BloomFileManagerTests/ArchiveOperationIntegrationTests.swift`

**Interfaces:**
- Produces: `ProtectedZIPOperating.classify(_:)` and `perform(_:progress:)`
- Produces: `RoutingArchiveOperationService`
- Produces: `FileOperationResult.merging(_:)`
- Produces: `ProtectedZIPLogging.record(_:)` and `LiveProtectedZIPLogger`
- Adds: `FileOperationService.makeRoutingArchiveOperationService(passwordProvider:protectedEngine:protectedLogger:) -> any ArchiveOperating`
- Adds: `ArchiveOperationPhase.waitingForPassword`

- [ ] **Step 1: Write failing routing and cleanup tests**

Test these literal routes with recording services:

```swift
#expect(await router.route(for: protectedCompression) == .protected)
#expect(await router.route(for: encryptedExtraction) == .protected)
#expect(await router.route(for: ordinaryZIPExtraction) == .ordinary)
#expect(await router.route(for: tarExtraction) == .ordinary)
```

Service tests assert password request happens after preparation, wrong-password
attempt one is fully removed before attempt two, the second secret differs by
identity, cancellation clears the prompt and staging, destination replacement
is refused, cleanup failure returns recovery-needed, and result ordering matches
input request ordering. Add a hostile encrypted archive test whose unsafe path
is rejected before the recording password provider receives any request.
Inject a recording protected-ZIP logger and assert its typed event projection
contains only the public basename and stable diagnostic category.

- [ ] **Step 2: Run service tests and verify RED**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --disable-sandbox --no-parallel \
  --filter 'ProtectedZIPOperationServiceTests|RoutingArchiveOperationServiceTests|ArchiveOperationIntegrationTests'
```

Expected: compilation fails because protected and routing services do not exist.

- [ ] **Step 3: Harden native extraction source copying**

In `prepareExtractionCommand`, fingerprint the identity-matched source before
copy, copy to private staging, then require the same identity and fingerprint
after copy. This makes the original-file inspection used by the router advisory
without permitting a same-inode content change before the native runner copies.
Add an integration test that mutates the archive in place during the copy hook
and expects failure with no output.

- [ ] **Step 4: Implement protected classification and byte budget**

`ProtectedZIPOperationService.classify` opens the identity-matched source,
captures a fingerprint before inspection, calls `engine.inspect`, rechecks
identity and fingerprint, and returns `.ordinary`, `.protected`, or
`.unsupported`. Retain the scoped-access lease for the full open/inspect/recheck
sequence and rely on `OpenedFileSystemItem` to close its descriptor exactly once.
For protected extraction compute:

```swift
let percentageReserve = availableCapacity / 10
let reserve = max(ProtectedZIPLimits.minimumCapacityReserve, percentageReserve)
guard availableCapacity > reserve else { throw ProtectedZIPError.insufficientCapacity }
let budget = availableCapacity - reserve
guard inspection.totalUncompressedByteCount <= budget else {
    throw ProtectedZIPError.insufficientCapacity
}
```

Construct `ProtectedZIPLimits(maximumOutputByteCount: budget,
capacityReserveByteCount: reserve)`. After copying the archive into private
identity-tracked staging, reopen that staged file, repeat inspection, reserve an
empty private probe directory beside the final destination, and call
`engine.preflight(archive:destinationProbeRoot:limits:)` before emitting
`.waitingForPassword` or requesting a secret. Close the probe descriptor and
remove the probe reservation before prompting; cleanup failure enters recovery
review. Hold the same staged archive descriptor owner through each retry; the
engine duplicates the descriptor for each blocking C call.

- [ ] **Step 5: Implement protected compression and retryable extraction**

Compression uses `ArchiveSourcePreparing`, emits `.waitingForPassword`, obtains
one creation secret, opens the staged root and staged output by identity, runs
AES-256 creation, then verifies and exclusively publishes through the same
identity/fingerprint sequence as `ArchiveOperationService`.

Extraction copies and preflights the archive in identity-tracked input staging.
Only after preflight succeeds, every attempt emits `.waitingForPassword`,
requests a fresh extraction secret, and
creates a fresh output staging reservation. On
`.incorrectPasswordOrDamagedData`, it destroys that attempt reservation and
requests again with `previousAttemptFailed == true`. Other failures terminate.
Success publishes only the successful fresh reservation. Close every
`OpenedEmptyFileSystemItem.descriptor` in a `defer` surrounding its awaited
engine call; the input `OpenedFileSystemItem` closes through its owner.
Record only `ProtectedZIPDiagnosticEvent` values. `LiveProtectedZIPLogger`
formats the closed event fields with explicit public privacy and has no API that
accepts an `ArchiveSecret`, password string, internal filename, or raw error.

- [ ] **Step 6: Implement stable request routing**

`RoutingArchiveOperationService` iterates requests in order. Protected ZIP
compression routes directly to the protected service. ZIP extraction calls
protected classification; `.ordinary` uses the existing service,
`.protected` uses the protected service, and `.unsupported` produces one safe
failure. TAR-family requests always use the existing service. Concatenate one
request's outcomes before starting the next. Add
`FileOperationResult.merging(_:)` to concatenate outcomes and merge safe paths,
undo identities, and undo fingerprints without discarding prior requests.

- [ ] **Step 7: Wire the factory**

```swift
nonisolated func makeRoutingArchiveOperationService(
    passwordProvider: any ArchivePasswordProviding,
    protectedEngine: any ProtectedZIPEngine = LiveProtectedZIPEngine(),
    protectedLogger: any ProtectedZIPLogging = LiveProtectedZIPLogger()
) -> any ArchiveOperating
```

Construct the existing ordinary service, the protected service with the shared
filesystem/access coordinator/source preparer, and the router. Tests may still
instantiate `ArchiveOperationService` directly, and the existing
`makeArchiveOperationService(commandRunner:)` remains source-compatible.

- [ ] **Step 8: Run service tests and verify GREEN**

Run the Step 2 command. Expected: all routes, retries, identity attacks,
cancellation, cleanup, publication, and ordering tests pass.

- [ ] **Step 9: Commit**

```bash
git add Sources/BloomFileManager/Services Sources/BloomFileManager/Models/ArchiveOperationModels.swift \
  Tests/BloomFileManagerTests/ProtectedZIPOperationServiceTests.swift \
  Tests/BloomFileManagerTests/RoutingArchiveOperationServiceTests.swift \
  Tests/BloomFileManagerTests/ArchiveOperationIntegrationTests.swift
git commit -m "feat: route protected zip operations safely"
```

### Task 9: Integrate protected jobs with queue, history, and retry semantics

**Files:**
- Modify: `Sources/BloomFileManager/Stores/FileOperationController.swift`
- Modify: `Sources/BloomFileManager/Models/FileOperationJobModels.swift`
- Modify: `Tests/BloomFileManagerTests/FileOperationControllerTests.swift`
- Modify: `Tests/BloomFileManagerTests/FileOperationCenterViewTests.swift`

**Interfaces:**
- Adds: `FileOperationController.compressSelection(_:format:protection:)`
- Changes: active snapshot state follows `.waitingForPassword`
- Changes: pause unavailable while waiting; cancel and history retry remain available

- [ ] **Step 1: Write failing controller state and retry tests**

```swift
@Test @MainActor func protectedJobWaitsWithoutRetainingSecretAndRetryPromptsAgain() async throws {
    #expect(await controller.compressSelection(
        workspace,
        format: .zip,
        protection: .aes256
    ))
    await recorder.emit(.waitingForPassword)
    #expect(controller.activeJob?.state == .waitingForPassword)
    await controller.pauseActiveJob()
    #expect(controller.isPaused == false)
    controller.cancelActiveJob()
    await waitUntilIdle(controller)
    let historyID = try #require(controller.operationHistory.first?.id)
    #expect(controller.retryJob(historyID))
    await waitUntil { passwordProvider.requestCount == 2 }
    #expect(passwordProvider.requestCount == 2)
    let visible = (controller.queuedJobs + controller.operationHistory)
        .map { "\($0.title)|\($0.itemDisplayName)|\($0.state.label)" }
        .joined(separator: "\n")
    #expect(visible.contains(passwordProvider.sentinel) == false)
}
```

Add tests that `.aes256` is rejected for TAR, protected job title is
`Compress Encrypted ZIP`, queued snapshots contain protection only, active
cancel dismisses the prompt, and a failed protected job remains retryable but
never undoable.

- [ ] **Step 2: Run controller tests and verify RED**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --disable-sandbox --no-parallel \
  --filter 'FileOperationControllerTests|FileOperationCenterViewTests'
```

Expected: the protected submission overload and waiting-state transitions fail.

- [ ] **Step 3: Carry protection metadata through submission only**

Pass `protection` into planner/request creation and map the job kind to a new
non-secret `FileOperationJobKind.compressProtectedZIP`. The pending operation
closure captures the plan, identity requests, services, and password provider
indirectly through the archive service; it never captures an `ArchiveSecret` or
password string.

- [ ] **Step 4: Map password wait and byte progress**

When published archive phase is `.waitingForPassword`, snapshot the active job
as `.waitingForPassword` with detail `Waiting for password`. When byte progress
arrives, return it to `.running` and expose bounded byte counts. Disable pause
for waiting jobs, leave cancel active, and let task cancellation unwind the
coordinator continuation and service staging.

- [ ] **Step 5: Make retry create a fresh non-secret attempt**

Keep the existing retry recipe's plan and identities, but ensure its new
`PendingFileOperation` ID causes a new `ArchivePasswordRequest` ID. Do not add a
secret field to `PendingFileOperation`, `retryOperations`, job snapshots, undo
recipes, or history.

- [ ] **Step 6: Run controller tests and verify GREEN**

Run the Step 2 command. Expected: state, cancel, queue, retry, title, and
sentinel-redaction tests pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/BloomFileManager/Stores/FileOperationController.swift \
  Sources/BloomFileManager/Models/FileOperationJobModels.swift \
  Tests/BloomFileManagerTests/FileOperationControllerTests.swift \
  Tests/BloomFileManagerTests/FileOperationCenterViewTests.swift
git commit -m "feat: queue protected zip jobs without secrets"
```

### Task 10: Present protected commands, prompt sheet, progress, and VoiceOver

**Files:**
- Modify: `Sources/BloomFileManager/App/BloomFileManagerApp.swift`
- Modify: `Sources/BloomFileManager/Views/WorkspaceView.swift`
- Modify: `Sources/BloomFileManager/Views/FilePaneView.swift`
- Modify: `Sources/BloomFileManager/Views/AppKit/FileTableView.swift`
- Modify: `Sources/BloomFileManager/Support/WorkspaceCommands.swift`
- Modify: `Sources/BloomFileManager/Views/OperationStatusView.swift`
- Modify: `Sources/BloomFileManager/Views/FileOperationCenterView.swift`
- Modify: `Sources/BloomFileManager/Support/AccessibilityIdentifiers.swift`
- Modify: `Tests/BloomFileManagerTests/WorkspaceCommandTests.swift`
- Modify: `Tests/BloomFileManagerTests/WorkspaceCommandPolicyTests.swift`
- Modify: `Tests/BloomFileManagerTests/OperationStatusViewTests.swift`
- Modify: `Tests/BloomFileManagerTests/AccessibilityPresentationTests.swift`

**Interfaces:**
- Adds: **Compress as Password-Protected ZIP…** to commands and context menus
- Presents: `ArchivePasswordSheet` from `WorkspaceView`
- Presents: waiting, encrypting, extracting, and determinate-byte status

- [ ] **Step 1: Write failing command and presentation tests**

```swift
@Test func protectedArchivePresentationNeverContainsSecret() {
    let progress = ArchiveOperationProgress(
        kind: .compress,
        currentDisplayName: "자료.zip",
        format: .zip,
        phase: .processingBytes(completedByteCount: 25, totalByteCount: 100)
    )
    let presentation = ArchiveOperationStatusPresentation(progress: progress)
    #expect(presentation.progressLabel == "Encrypting archive, 25 of 100 bytes")
    #expect(presentation.statusAccessibilityLabel.contains("자료.zip"))
    #expect(presentation.statusAccessibilityLabel.contains("password") == false)
}
```

Command tests assert the new action is enabled exactly when ordinary compression
is enabled, invokes `.zip/.aes256`, and AppKit context menu selection uses the
same route. Operation-center tests assert waiting rows show Cancel but no Pause.

- [ ] **Step 2: Run UI policy and presentation tests and verify RED**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --disable-sandbox --no-parallel \
  --filter 'WorkspaceCommandTests|WorkspaceCommandPolicyTests|OperationStatusViewTests|AccessibilityPresentationTests|FileOperationCenterViewTests'
```

Expected: protected command and byte/waiting presentation assertions fail.

- [ ] **Step 3: Construct one shared prompt coordinator**

In `BloomFileManagerApp.init`, create one
`ArchivePasswordPromptCoordinator`, pass it to
`makeRoutingArchiveOperationService(passwordProvider:)`, pass the returned
service into `FileOperationController`, store the coordinator in `@State`, and pass
it to `WorkspaceView`. Do not recreate the coordinator in a view body.

- [ ] **Step 4: Present the prompt by request identity**

Add one `.sheet(item:)` bound to `passwordCoordinator.pendingRequest`. Closing
the sheet calls `cancel(requestID:)`. Present `ArchivePasswordSheet` and ensure
the existing conflict and search sheets cannot simultaneously replace its
continuation; pending protected work waits until the password sheet can be
shown.

- [ ] **Step 5: Add command and context-menu routes**

Place **Compress as Password-Protected ZIP…** after ordinary ZIP compression in
`WorkspaceCommands` and the AppKit table context menu. Route both through:

```swift
Task {
    _ = await operationController.compressSelection(
        workspace,
        format: .zip,
        protection: .aes256
    )
}
```

Do not place protected choices inside TAR submenus.

- [ ] **Step 6: Render waiting and byte progress accessibly**

Add presentation branches for `.waitingForPassword` and `.processingBytes`.
Use determinate `ProgressView` only for a positive known byte total; otherwise
use an indeterminate indicator. Labels say `Encrypting archive` for protected
compression and `Extracting archive` for extraction. Format byte counts with
`ByteCountFormatter`; never use the password value or internal entry list.
Operation center suppresses Pause while waiting and keeps Cancel.

- [ ] **Step 7: Run UI tests and verify GREEN**

Run the Step 2 command. Expected: all command, policy, progress, operation-center,
and accessibility tests pass.

- [ ] **Step 8: Commit**

```bash
git add Sources/BloomFileManager/App/BloomFileManagerApp.swift \
  Sources/BloomFileManager/Views Sources/BloomFileManager/Support \
  Tests/BloomFileManagerTests/WorkspaceCommandTests.swift \
  Tests/BloomFileManagerTests/WorkspaceCommandPolicyTests.swift \
  Tests/BloomFileManagerTests/OperationStatusViewTests.swift \
  Tests/BloomFileManagerTests/AccessibilityPresentationTests.swift \
  Tests/BloomFileManagerTests/FileOperationCenterViewTests.swift
git commit -m "feat: present protected zip workflows"
```

### Task 11: Prove end-to-end secrecy, interoperability, recovery, and regression safety

**Files:**
- Create: `Tests/BloomFileManagerTests/ProtectedZIPEndToEndTests.swift`
- Modify: `Tests/BloomFileManagerTests/ArchiveOperationIntegrationTests.swift`
- Modify: `Tests/BloomFileManagerTests/CloudLocationScopedAccessTests.swift`
- Modify: `Tests/BloomFileManagerTests/Support/ArchiveTestSupport.swift`
- Create: `docs/verification/password-protected-zip.md`

**Interfaces:**
- Verifies: the complete menu-to-publication path
- Verifies: no observable model or diagnostic contains a sentinel secret
- Verifies: cloud materialization, retries, cancellation, recovery, and ordinary archive regressions

- [ ] **Step 1: Write the end-to-end tests before adding missing support hooks**

```swift
@Test @MainActor func protectedZIPEndToEndPublishesOnlyAuthenticatedOutput() async throws {
    let sentinel = "e2e-public-test-passphrase"
    passwordProvider.enqueueCreation(sentinel)
    #expect(await controller.compressSelection(workspace, format: .zip, protection: .aes256))
    await waitUntilIdle(controller)
    passwordProvider.enqueueExtraction(sentinel)
    pane.selection = [createdArchive]
    #expect(await controller.extractSelection(workspace))
    await waitUntilIdle(controller)
    #expect(try Data(contentsOf: extractedFile) == originalBytes)
    #expect(controller.observableTextForTesting.contains(sentinel) == false)
    #expect(String(reflecting: await logger.events).contains(sentinel) == false)
}
```

Add end-to-end cases for independent AES and ZipCrypto fixtures, wrong password
then correct password, cancellation while waiting, cancellation mid-entry,
cloud download before prompt, source identity change, destination collision,
cleanup failure and queue recovery, Korean names, symlink policy, mixed
encrypted/plain entries, and ordinary ZIP/TAR round trips.

- [ ] **Step 2: Run the new suite and verify RED for missing hooks or behavior**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --disable-sandbox --no-parallel \
  --filter 'ProtectedZIPEndToEndTests|ArchiveOperationIntegrationTests|CloudLocationScopedAccessTests'
```

Expected: the first run identifies any incomplete service hook, cleanup path,
or redaction assertion from Tasks 1-10.

- [ ] **Step 3: Add only the test seams required by the failing assertions**

Use internal recording password providers, progress collectors,
`RecordingProtectedZIPLogger`, and safe
observable-text projections in test support. A projection may return job title,
basename, state, and progress detail only:

```swift
var observableTextForTesting: String {
    ([activeJob].compactMap { $0 } + queuedJobs + operationHistory)
        .map { "\($0.title)|\($0.itemDisplayName)|\($0.state.label)|\($0.progress?.detail ?? "")" }
        .joined(separator: "\n")
}
```

Do not add a production API that reads an `ArchiveSecret` back into a `String`.

- [ ] **Step 4: Run the focused end-to-end suite and verify GREEN**

Run the Step 2 command. Expected: every protected and ordinary integration case
passes and staging scans find no orphan directories.

- [ ] **Step 5: Run the full automated suite**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --disable-sandbox --no-parallel
```

Expected: every suite passes with no test retry and no unexpected standard-error
output.

- [ ] **Step 6: Record automated and pending manual evidence**

In `docs/verification/password-protected-zip.md`, record the date, commit, exact
commands, suite/test counts, fixture hashes, encrypted/plain round-trip results,
sentinel scan, and any manual checks still pending. Use `NOT RUN` rather than
claiming VoiceOver, Finder, WinZip, DMG, process-list, or performance evidence
that was not physically observed.

- [ ] **Step 7: Commit**

```bash
git add Tests/BloomFileManagerTests/ProtectedZIPEndToEndTests.swift \
  Tests/BloomFileManagerTests/ArchiveOperationIntegrationTests.swift \
  Tests/BloomFileManagerTests/CloudLocationScopedAccessTests.swift \
  Tests/BloomFileManagerTests/Support/ArchiveTestSupport.swift \
  docs/verification/password-protected-zip.md
git commit -m "test: verify protected zip workflows"
```

### Task 12: Package notices, bilingual documentation, and final verification

**Files:**
- Create: `THIRD_PARTY_NOTICES.md`
- Modify: `script/build_and_run.sh`
- Modify: `script/package_release.sh`
- Modify: `script/tests/package_release_contract_tests.sh`
- Modify: `Tests/BloomFileManagerTests/BuildScriptTests.swift`
- Modify: `.github/workflows/ci.yml`
- Modify: `README.md`
- Modify: `README.ko.md`
- Modify: `docs/user-guide.md`
- Modify: `docs/user-guide.ko.md`
- Modify: `docs/release.md`
- Modify: `docs/release.ko.md`
- Modify: `docs/verification/password-protected-zip.md`

**Interfaces:**
- Packages: minizip-ng zlib-license notice inside `Pengrid.app/Contents/Resources`
- Verifies: no `libssl` or `libcrypto` dynamic dependency
- Documents: exact support, security, compatibility, metadata, and release status in English and Korean

- [ ] **Step 1: Write failing package-contract tests**

```swift
#expect(source.contains("THIRD_PARTY_NOTICES.md"))
#expect(source.contains("otool -L"))
#expect(source.contains("libssl") && source.contains("libcrypto"))
```

Extend the shell contract test to require
`Pengrid.app/Contents/Resources/THIRD_PARTY_NOTICES.md`, byte-compare it with the
repository notice, and confirm the fake release log records an `otool` check.

- [ ] **Step 2: Run package tests and verify RED**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --disable-sandbox --no-parallel \
  --filter BuildScriptTests
/bin/bash script/tests/package_release_contract_tests.sh
```

Expected: tests fail because the notice is not copied and OpenSSL linkage is not
checked.

- [ ] **Step 3: Add notice and linkage checks**

`THIRD_PARTY_NOTICES.md` names minizip-ng 4.2.2, pinned commit, upstream URL,
enabled crypto/compression backends, and the unmodified zlib license text. Copy
it with the same descriptor-anchored, identity-checked, exclusive publication
rules used for the app icon. In build and release verification run:

```bash
if /usr/bin/otool -L "$APP_BINARY" | /usr/bin/grep -Eiq 'libssl|libcrypto'; then
  die 'unexpected OpenSSL dependency in Pengrid binary'
fi
```

Update fake tools and CI inputs so this assertion executes in contract tests and
on the macOS CI runner.

- [ ] **Step 4: Update English and Korean documentation symmetrically**

State all of the following in both languages: source builds create AES-256 only;
AES and ZipCrypto with Store/Deflate entries are readable; filenames remain
visible; passwords are neither
saved nor recoverable; retries ask again; Finder/macOS tools may not open AES
ZIP; resource forks/ACL/xattrs are not guaranteed; unsafe/oversized archives
fail closed; 7z, RAR, protected TAR, Developer ID signing, and notarization
remain unsupported. Keep the existing v1.3 preview DMG link explicitly labeled
as predating this source feature until a later release task replaces it.

- [ ] **Step 5: Run package and documentation checks and verify GREEN**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --disable-sandbox --no-parallel \
  --filter BuildScriptTests
/bin/bash script/tests/package_release_contract_tests.sh
git diff --check
```

Expected: package contracts pass, notice bytes match, OpenSSL linkage is absent,
and the Markdown/shell diff has no whitespace error.

- [ ] **Step 6: Build and inspect the app without publishing a release**

```bash
./script/build_and_run.sh --verify
/usr/bin/otool -L dist/Pengrid.app/Contents/MacOS/BloomFileManager
/usr/bin/codesign --verify --deep --strict --verbose=2 dist/Pengrid.app
```

Expected: verification succeeds, `otool` lists no `libssl` or `libcrypto`, and
ad-hoc code-signature verification succeeds.

- [ ] **Step 7: Run the complete final suite**

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --disable-sandbox --no-parallel
/bin/bash script/tests/package_release_contract_tests.sh
git status --short
```

Expected: all tests pass and status lists only the documentation/evidence edits
intended for this task before commit.

- [ ] **Step 8: Complete the verification record and commit**

Append the exact final test counts, build result, `otool` result, codesign result,
and remaining physical manual checks to
`docs/verification/password-protected-zip.md`, then commit:

```bash
git add THIRD_PARTY_NOTICES.md script .github/workflows/ci.yml \
  Tests/BloomFileManagerTests/BuildScriptTests.swift README.md README.ko.md \
  docs/user-guide.md docs/user-guide.ko.md docs/release.md docs/release.ko.md \
  docs/verification/password-protected-zip.md
git commit -m "docs: document protected zip support"
```

---

## Final review gate

After Task 12, use `superpowers:verification-before-completion`, then
`superpowers:requesting-code-review`. The reviewer must inspect the pinned
dependency boundary, password lifetime, every cancellation/cleanup path,
descriptor ownership, path normalization, link topology, byte accounting,
observable redaction, ordinary-archive regressions, license packaging, and the
verification record before the branch is considered ready for a separate
release task.

## Final review progress — termination-safe Quit (2026-08-06)

- [x] Register the app's shared operation controller and password prompt
  coordinator with an AppKit termination coordinator.
- [x] Gate new work while Quit preparation is active; cancel active work and
  pending prompts; wait for operation and protected-staging cleanup before
  replying.
- [x] Reply `false` exactly once on the bounded timeout or recovery-required
  result, then clear the gate and resume the queue; keep a successful reply
  one-shot for the terminating process.
- [x] Add focused unit coverage for idle, active, prompt, timeout, recovery,
  cancellation, re-entrant Quit, and a real protected extraction that has
  already written plaintext to private staging.
- [x] Capture mutation evidence showing that an immediate reply leaves the
  controller running and plaintext/staging residue behind; restore the
  production wait gate before the final green run.
- [x] Append the command, result count, and mutation details to
  `docs/verification/2026-08-06-password-protected-zip.md`.

The broad repository test/build matrix and the final independent review remain
the parent task's integration gates.
