# Transfer Content Verification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task-by-task. Steps use
> checkbox syntax for tracking.

**Goal:** Add optional SHA-256 verification of privately staged file contents
before copy, duplicate, cross-volume move, and reviewed folder-sync results are
published.

**Architecture:** A transfer-verification session owns descriptor-anchored
source and staging manifests, one operation-scoped two-pair permit pool, paired
SHA-256 reads, and ephemeral receipts. File operations and synchronization
capture policy at enqueue, reuse their existing access leases and staging
rollback, and publish only after immediate receipt revalidation. Settings,
progress, accessibility, and history consume bounded privacy-safe models; no
digest or path list enters persistent state.

**Tech Stack:** Swift 6.1, Swift Testing, SwiftUI, Observation, CryptoKit,
Darwin descriptor APIs, SwiftPM, AppKit accessibility, APFS disk images, and
Pengrid's identity-bound staging and rollback services.

**Spec:** docs/superpowers/specs/2026-08-24-transfer-content-verification-design.md

## Global Constraints

- Work only in /Users/mac/Documents/Pengrid/.worktrees/safe-operation-center on
  branch codex/transfer-content-verification. Do not modify the divergent
  primary checkout.
- Use apply_patch for source, test, plan, and documentation edits.
- Write and run a failing focused Swift test before every production behavior
  change. A test must fail for the intended missing behavior, not for a typo.
- Use the full Xcode toolchain for Swift commands:

~~~bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --enable-swift-testing --no-parallel
~~~

- The persisted preference defaults to off. Only the policy value is captured
  when a job is enqueued; source enumeration remains lazy.
- Enabled policy is SHA-256 with at most two concurrently active source/staging
  file pairs for the whole operation.
- Verify regular-file data forks, recursive structure, and symbolic-link
  payload bytes. Do not claim verification of resource forks, xattrs, ACLs,
  ownership, hard-link relationships, sparse allocation, or remote provider
  upload bytes.
- Same-volume move without replacement performs no manifest or hash and records
  one top-level no-byte-transfer item.
- A manifest allows 250,000 descendants, root depth zero, and deepest
  descendant depth 256. Budget overflow fails closed without an unverified
  fallback.
- Traversal uses openat, fstatat with AT_SYMLINK_NOFOLLOW, fdopendir/readdir,
  and readlinkat. Path-only recursive FileManager enumeration is forbidden.
- Retain raw filename bytes for descriptor access. Lossless UTF-8 conversion
  and the captured destination FilenameComparisonPolicy determine cross-root
  keys; collisions fail before staging.
- The ordinary transfer controller remains the only transfer materializer.
  The verifier creates no materialization request or security-scoped lease.
- Digests, absolute paths, and relative path lists never enter results,
  snapshots, logs, history, accessibility values, or documentation evidence.
- Retry preserves its original captured policy. Folder synchronization remains
  non-retryable and non-Undoable.
- Verification failure removes only identity-owned private staging. Cleanup
  uncertainty becomes Recovery Needed and blocks queue continuation.
- Progress is phase-local and unit-aware. VoiceOver receives phase, percentage,
  file count, and a sanitized basename, never raw byte totals.
- Manual File Provider and VoiceOver rows remain NOT RUN unless they are
  actually exercised and recorded.
- Each task ends with focused tests, diff validation, a local commit, and an
  independent task review before the next task begins.

## Baseline and Execution Setup

- [ ] Verify HEAD is the approved design commit plus this plan commit and the
  worktree has no unrelated changes.
- [ ] Run the complete nonparallel Swift suite and record the exact test/suite
  count and pre-existing warnings in the SDD ledger.
- [ ] Resolve this plan's SDD workspace with the subagent-driven-development
  scripts, create its ledger, and record the task-interface preflight table.
- [ ] Use one implementation agent at a time. Mechanical isolated tasks use
  Luna Max; descriptor, concurrency, rollback, and final review use a
  higher-reasoning agent. GPT-family agents run only through the installed
  local `codex` CLI, and Gemini runs only through the installed local `agy`
  CLI; never select an OpenRouter GPT or Gemini model. OpenRouter Ox Alpha
  Ultra performs a read-only independent review after the core engine and
  final branch are complete.

---

### Task 1: Add policy, report, and unit-aware progress contracts

**Files:**

- Create: Sources/BloomFileManager/Models/TransferVerificationModels.swift
- Modify: Sources/BloomFileManager/Models/FileOperationModels.swift
- Modify: Sources/BloomFileManager/Models/FileOperationJobModels.swift
- Modify: Sources/BloomFileManager/Services/OperationLogger.swift
- Create: Tests/BloomFileManagerTests/TransferVerificationModelsTests.swift
- Modify: Tests/BloomFileManagerTests/FileOperationModelsTests.swift
- Modify: Tests/BloomFileManagerTests/FileOperationJobModelsTests.swift
- Create: Tests/BloomFileManagerTests/OperationLoggerTests.swift

**Interfaces:**

~~~swift
enum TransferVerificationPolicy: Sendable, Equatable {
    case disabled
    case sha256(maxConcurrentPairs: Int)

    var effectivePairLimit: Int? { get } // nil, or the enabled input clamped to 1...2
}

enum TransferVerificationPhase: Sendable, Equatable {
    case preparingManifest
    case hashing
    case finalValidation
}

struct TransferVerificationProgress: Sendable, Equatable {
    let phase: TransferVerificationPhase
    let fractionCompleted: Double
    let completedFileCount: Int
    let totalFileCount: Int
    let completedLogicalByteCount: Int64
    let totalLogicalByteCount: Int64
    let currentName: String
}

struct TransferVerificationSummary: Sendable, Equatable {
    let verifiedFileCount: Int
    let verifiedLogicalByteCount: Int64
    let noByteTransferItemCount: Int
}

struct TransferVerificationReport: Sendable, Equatable {
    let verifiedFileCount: Int
    let verifiedLogicalByteCount: Int64
    let noByteTransferItemCount: Int
    let failedVerificationItemCount: Int

    func merging(_ other: Self) -> Self
}

enum TransferVerificationFailureCategory: String, Sendable, Equatable {
    case sourceChanged
    case stagedOutputChanged
    case structureMismatch
    case contentMismatch
    case unsupportedItem
    case unsupportedName
    case identityUnavailable
    case readFailed
    case scopeTooLarge
    case cancelled
}

struct TransferVerificationFailure: LocalizedError, Sendable, Equatable {
    let category: TransferVerificationFailureCategory
    let safeName: String?

    var errorDescription: String? { get }
}

struct TransferVerificationLogEvent: Sendable, Equatable {
    let enabled: Bool
    let verifiedFileCount: Int
    let verifiedLogicalByteCount: Int64
    let noByteTransferItemCount: Int
    let failedVerificationItemCount: Int
    let failureCategory: TransferVerificationFailureCategory?
}

enum FileOperationJobProgressUnit: Sendable, Equatable {
    case items
    case fraction
}

extension OperationLogging {
    func recordTransferVerification(
        _ event: TransferVerificationLogEvent
    ) async
}
~~~

`FileOperationJobProgress` retains its existing memberwise call shape by adding
defaulted `unit: .items` and `normalizedFraction: nil` parameters. For
`.fraction`, completed/total counts mean files and `fractionCompleted` reads the
clamped normalized fraction. `FileOperationJobSnapshot` gains an optional
verification report with a default of nil. All verification model initializers
clamp negative counters, replace nonfinite fractions, and sanitize `currentName`
or `safeName` to one newline-free basename. Failure descriptions are fixed
localized text selected by the enum plus that optional basename; they never
interpolate an underlying error, URL, relative path, or digest.

- [ ] **Step 1: Write failing model tests.**

Add literal expectations for disabled and enabled pair limits, clamping
injected limits below one and above two (`0` and negative values both become
one for an enabled policy), nonnegative summary/report fields, saturating Int
and Int64 merge, nil-versus-zero report equality, `.items` compatibility,
finite/clamped `.fraction` values, safe basename normalization, and the exact
accessibility string:

~~~swift
#expect(snapshot.accessibilityLabel.contains(
    "Verifying contents, 42 percent, 8 of 20 files, Report.txt"
))
#expect(!snapshot.accessibilityLabel.contains("1048576"))
#expect(!snapshot.accessibilityLabel.contains("/Users/"))
~~~

- [ ] **Step 2: Run RED.**

~~~bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --enable-swift-testing --no-parallel \
  --filter 'TransferVerificationModelsTests|FileOperationModelsTests|FileOperationJobModelsTests'
~~~

Expected: compilation or assertion failure because the policy, report, and
unit-aware progress contracts do not exist.

- [ ] **Step 3: Implement the minimal contracts.**

Normalize negative counts to zero in initializers. Implement saturated addition
with `addingReportingOverflow`; overflow returns the corresponding maximum.
Add `verificationReport` to `FileOperationResult`, preserve it through
`addingSafeRelativePaths`, merge it with nil semantics, and include it in the
existing custom equality without changing Undo metadata equality behavior. Add
unit-aware snapshot accessibility directly from a constructed
`FileOperationJobProgress`; Task 1 does not add a `FileOperationStage` case, so
existing exhaustive controller/view switches stay compiling until Task 6
updates them atomically.
Add a typed transfer-verification logging event. Keep the existing
`OperationLogging.record` requirement source-compatible and provide a default
no-op implementation for the new `recordTransferVerification` requirement so
unrelated test loggers do not need mechanical edits. `LiveOperationLogger`
emits only the Boolean, bounded aggregate counters, logical-byte count, and
enum raw value. `OperationLoggerTests` inspect the formatting seam and prove
that it cannot accept or emit a path, basename, digest, or free-form error.

- [ ] **Step 4: Run GREEN and mutation-check.**

Run the focused command above. Then temporarily reason through mutations:
dropping report preservation, treating nil as zero, or reading byte totals as
item counts must each fail at least one named test.

- [ ] **Step 5: Validate and commit.**

~~~bash
git diff --check
git add Sources/BloomFileManager/Models/TransferVerificationModels.swift \
  Sources/BloomFileManager/Models/FileOperationModels.swift \
  Sources/BloomFileManager/Models/FileOperationJobModels.swift \
  Sources/BloomFileManager/Services/OperationLogger.swift \
  Tests/BloomFileManagerTests/TransferVerificationModelsTests.swift \
  Tests/BloomFileManagerTests/FileOperationModelsTests.swift \
  Tests/BloomFileManagerTests/FileOperationJobModelsTests.swift \
  Tests/BloomFileManagerTests/OperationLoggerTests.swift
git commit -m "feat: add transfer verification models"
~~~

---

### Task 2: Build descriptor-anchored recursive manifests

**Files:**

- Create: Sources/BloomFileManager/Services/TransferVerificationManifest.swift
- Create: Tests/BloomFileManagerTests/TransferVerificationManifestTests.swift

**Interfaces:**

~~~swift
struct TransferVerificationLimits: Sendable, Equatable {
    static let production = Self(maxDescendants: 250_000, maxDepth: 256)
    let maxDescendants: Int
    let maxDepth: Int
}

struct TransferVerificationManifest: @unchecked Sendable {
    let rootURL: URL
    let rootIdentity: FileIdentity
    let comparisonPolicy: FilenameComparisonPolicy
    let regularFileCount: Int
    let logicalByteCount: Int64
}

protocol TransferVerificationManifestBuilding: Sendable {
    func capture(
        at rootURL: URL,
        identifiedBy expectedIdentity: FileIdentity,
        comparisonPolicy: FilenameComparisonPolicy
    ) async throws -> TransferVerificationManifest

    func recapture(
        _ manifest: TransferVerificationManifest
    ) async throws -> TransferVerificationManifest

    func requireStable(
        _ current: TransferVerificationManifest,
        against captured: TransferVerificationManifest
    ) throws

    func requireEquivalentContentShape(
        source: TransferVerificationManifest,
        staged: TransferVerificationManifest
    ) throws
}

struct LiveTransferVerificationManifestBuilder:
    TransferVerificationManifestBuilding {
    init(limits: TransferVerificationLimits = .production)
}
~~~

The following Task 2-only internal handoff is fixed now so Task 3 never
reconstructs a path or invents descriptor lifetime rules:

~~~swift
enum TransferVerificationManifestError: Error, Equatable {
    case changed
    case structureMismatch
    case unsupportedItem
    case unsupportedName
    case readFailed
    case scopeTooLarge
    case cancelled
}

struct TransferVerificationRegularFileEntry: @unchecked Sendable {
    var comparisonKey: [String] { get }
    let device: UInt64
    let inode: UInt64
    let mode: UInt32
    let logicalByteCount: Int64
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let changeSeconds: Int64
    let changeNanoseconds: Int64

    func withReaderDescriptor<T: Sendable>(
        _ body: @escaping @Sendable (Int32) async throws -> T
    ) async throws -> T
}

struct TransferVerificationRegularFilePair: @unchecked Sendable {
    let source: TransferVerificationRegularFileEntry
    let staged: TransferVerificationRegularFileEntry
}

extension TransferVerificationManifest {
    var regularFiles: [TransferVerificationRegularFileEntry] { get }
    func regularFilePairs(
        matching staged: TransferVerificationManifest
    ) throws -> [TransferVerificationRegularFilePair]
    func close()
}
~~~

`close()` deterministically releases the retained root authority, is
idempotent, and makes later reader acquisition fail closed; backing-storage
deinitialization remains a fallback. `withReaderDescriptor` performs the
component walk and validation synchronously, hands the async body an owned
`F_DUPFD_CLOEXEC` duplicate, and closes that duplicate only after the body
returns. `comparisonKey` is computed on demand from the shared parent-linked
component storage and is intended for bounded diagnostics and tests. Task 3
uses `regularFilePairs(matching:)`, which walks the two comparison trees without
materializing a dictionary of full path arrays. It constructs each
`RawFileFingerprint` directly from the listed fields. Same-root comparison,
content-shape comparison, and pair materialization check task cancellation
throughout their bounded scans, including wide sibling dictionaries. Manifest code throws the
neutral internal error above; Task 3 maps
`.changed` to source or staged-output failure according to the side it was
processing, while the other cases map directly to their bounded public
categories.

The root parent path and raw basename come from one
`rootURL.withUnsafeFileSystemRepresentation` byte sequence split at its final
slash, not from `lastPathComponent`. An absent representation, empty basename,
`.`/`..`, embedded NUL, or a basename that is not lossless UTF-8 fails with
`.unsupportedName`. The raw parent bytes are used to open the parent descriptor;
the raw basename is retained for every `*at` call.

The manifest stores each raw component, lossless display component, normalized
comparison component, item kind, identity, mode, size, mtime/ctime stability
data, and raw symlink payload once in a shared parent-linked path graph. It does
not retain a full component array per entry or regular-file handle, so retained
path storage remains linear in the entry count and actual component bytes.
Regular entries expose an internal opaque node handle and all fields needed to
construct Task 3's `RawFileFingerprint`; callers never rebuild a path string to
open them. `TransferVerificationRootAuthority` always
owns an open parent descriptor plus the raw root basename. A directory root
also owns its open root descriptor. At initial capture, recapture, and receipt
revalidation it compares `fstatat(parentFD, rootName, AT_SYMLINK_NOFOLLOW)`
with `fstat(rootFD)` before trusting a directory-root namespace entry. It opens
regular entries component-by-component relative to verified directory
descriptors, duplicates descriptors for readers, and closes each owned
descriptor exactly once. Directory capture uses an FD-free iterative worklist;
it reopens and validates each directory component from the retained root while
closing the previous component immediately, so depth 256 does not require 256
simultaneously open descriptors. Nofollow identity checks compare the captured entry
identity/device/inode, never `FileIdentity.refersToSameItem`, because that
helper intentionally uses the resolved target identity and is unsafe for a
symbolic-link root.

- [ ] **Step 1: Write failing budget and manifest tests.**

Use in-memory `TransferVerificationBudget` tests to prove the production
boundary accepts entry 250,000 and depth 256, then rejects entry 250,001 and
depth 257 without creating 250,001 real files. Use synthetic sizes to prove
logical-byte accounting rejects `Int64` overflow instead of wrapping. Use real
temporary filesystem fixtures for a regular-file root, empty file, nested
directory, package,
single-symlink root, nested and non-UTF-8 symlink payload bytes, FIFO rejection, root replacement,
directory-root namespace replacement while its old descriptor remains open,
regular-file-to-FIFO replacement between nofollow inspection and open,
symlink replacement versus target replacement, child replacement,
addition/removal, and type transition.
Use a synthetic parent-linked tree at the full 250,000-descendant and depth-256
boundary to exercise retained storage and regular-file pairing without creating
250,000 filesystem entries or retaining one full path array per file.

- [ ] **Step 2: Add filename-policy RED cases.**

Feed synthetic losslessly decoded entry components containing canonically
equivalent spellings and case variants into the comparison-key builder, so the
test does not depend on the host volume's case/normalization behavior. Assert
both `caseSensitiveCanonical` and `caseInsensitiveCanonical` outcomes and
collision rejection. The production path arena must use the same tested unique-
key insertion primitive rather than duplicate collision logic. Separately create an invalid UTF-8 filename with POSIX
`openat`; assert capture fails with `.unsupportedName` and does not emit
replacement characters.

- [ ] **Step 3: Run RED.**

~~~bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --enable-swift-testing --no-parallel \
  --filter TransferVerificationManifestTests
~~~

Expected: compilation failure because the manifest builder is absent.

- [ ] **Step 4: Implement descriptor ownership and traversal.**

Open the root parent with `O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC |
O_DIRECTORY`. Open directory roots and children with those flags and
`O_DIRECTORY`; open regular-file candidates with `O_RDONLY | O_NOFOLLOW |
O_NONBLOCK | O_CLOEXEC`, then immediately use `fstat` to reject a type or
fingerprint change before any read. This prevents a file-to-FIFO race from
blocking. Duplicate enumeration and reader descriptors with
`fcntl(F_DUPFD_CLOEXEC)` and pass the owned
enumeration duplicate to `fdopendir`; extract `dirent.d_name` bytes up to the first NUL;
strictly decode UTF-8; sort raw byte sequences deterministically; inspect entries
by calling `fstatat` with `AT_SYMLINK_NOFOLLOW`; open children with `openat`; and obtain
symlink bytes with a resizing `readlinkat` loop that rejects truncation. Run the
blocking traversal in a utility-priority detached worker with cancellation
propagated from the async caller. Reset/check `errno` around `readdir` so an
enumeration error is not mistaken for end-of-directory. Skip only literal `.`
and `..` raw names.

- [ ] **Step 5: Implement the two comparisons.**

Same-root stability includes identity and per-entry stability data. Cross-root
content shape includes normalized relative key, kind, regular-file size, and
symlink payload but excludes inode and non-approved metadata. Reject two source
entries that map to one destination comparison key. Check cancellation before
and during node comparison, wide child matching, and regular-file pair
materialization so a 250,000-entry operation cannot monopolize its worker after
the task is cancelled.

- [ ] **Step 6: Run GREEN, leak checks, and commit.**

Run the focused tests twice. Assert descriptor-owner test probes report one
close per descriptor on success, error, and cancellation, and assert every
duplicated descriptor retains `FD_CLOEXEC`. The directory-root replacement and
file-to-FIFO race cases must finish within a bounded test gate and fail closed;
neither may hang or traverse the replacement.

~~~bash
git diff --check
git add Sources/BloomFileManager/Services/TransferVerificationManifest.swift \
  Tests/BloomFileManagerTests/TransferVerificationManifestTests.swift
git commit -m "feat: add descriptor anchored transfer manifests"
~~~

---

### Task 3: Add shared raw hashing and operation-scoped verification sessions

**Files:**

- Create: Sources/BloomFileManager/Services/RawFileHashing.swift
- Create: Sources/BloomFileManager/Services/TransferVerificationService.swift
- Modify: Sources/BloomFileManager/Services/ChecksumService.swift
- Create: Tests/BloomFileManagerTests/RawFileHashingTests.swift
- Create: Tests/BloomFileManagerTests/TransferVerificationServiceTests.swift
- Modify: Tests/BloomFileManagerTests/ChecksumServiceTests.swift

**Interfaces:**

~~~swift
struct RawFileFingerprint: Sendable, Equatable {
    let device: UInt64
    let inode: UInt64
    let mode: UInt32
    let logicalByteCount: Int64
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let changeSeconds: Int64
    let changeNanoseconds: Int64
}

enum RawFileReadResult: Sendable, Equatable {
    case bytes(Int)
    case interrupted
    case failed(POSIXErrorCode)
}

protocol RawFileReadDriving: Sendable {
    func read(
        descriptor: Int32,
        into buffer: UnsafeMutableRawBufferPointer
    ) -> RawFileReadResult
}

struct DarwinRawFileReadDriver: RawFileReadDriving {
    init()
}

protocol RawFileHashing: Sendable {
    /// `checksum` returns one file's digest for the existing ChecksumResult;
    /// `checksumPair` returns ephemeral buffers for immediate equality testing
    /// inside TransferVerificationSession and neither digest may be retained
    /// or exposed after that comparison.
    func checksum(
        descriptor: Int32,
        expected: RawFileFingerprint,
        chunkSize: Int,
        progress: @escaping @Sendable (Int64) async -> Void
    ) async throws -> Data

    func checksumPair(
        sourceDescriptor: Int32,
        sourceExpected: RawFileFingerprint,
        stagedDescriptor: Int32,
        stagedExpected: RawFileFingerprint,
        chunkSize: Int,
        progress: @escaping @Sendable (Int64) async -> Void
    ) async throws -> (source: Data, staged: Data)
}

struct LiveRawFileHasher: RawFileHashing {
    init(readDriver: any RawFileReadDriving = DarwinRawFileReadDriver())
}

protocol TransferVerificationSessionFactory: Sendable {
    func makeSession(
        policy: TransferVerificationPolicy
    ) -> (any TransferVerificationSession)?
}

protocol TransferVerificationSession: Sendable {
    func captureSource(
        at url: URL,
        identifiedBy identity: FileIdentity,
        comparisonPolicy: FilenameComparisonPolicy
    ) async throws -> TransferVerificationManifest

    func verify(
        source: TransferVerificationManifest,
        stagedURL: URL,
        stagedIdentity: FileIdentity,
        progress: @escaping @Sendable (TransferVerificationProgress) async -> Void
    ) async throws -> TransferVerificationCompletion

    func revalidate(_ receipt: TransferVerificationReceipt) async throws
}

struct TransferVerificationReceipt: @unchecked Sendable {
    let source: TransferVerificationManifest
    let staged: TransferVerificationManifest
}

struct TransferVerificationCompletion: @unchecked Sendable {
    let receipt: TransferVerificationReceipt
    let summary: TransferVerificationSummary
}

struct LiveTransferVerificationSessionFactory:
    TransferVerificationSessionFactory {
    init(
        manifestBuilder: any TransferVerificationManifestBuilding =
            LiveTransferVerificationManifestBuilder(),
        hasher: any RawFileHashing = LiveRawFileHasher(),
        chunkSize: Int = 1_048_576
    )
}
~~~

Descriptor arguments remain owned by the caller; `RawFileHashing` neither
closes nor retains them after the async call returns. For `checksum`, progress
is a nonnegative delta of logical bytes newly consumed from the single file,
and `LiveChecksumService` converts those deltas to bounded fractions while
feeding the returned digest into the existing `ChecksumResult`. For
`checksumPair`, progress is instead a nonnegative delta of logical bytes newly
matched in the two-sided common prefix, and the returned digest buffers are
compared immediately and discarded. Before and after reading, the raw hasher
requires regular-file descriptors and matches all fields of each supplied
fingerprint.

The factory returns nil for `.disabled`. Each enabled session owns one
`AsyncPermitPool`; its requested limit is clamped to `1...2`, so zero and
negative enabled inputs still fail closed through a live one-pair verifier
rather than silently disabling verification or creating zero workers. Receipts
retain only the final source and staged manifests and are never Codable or
exposed outside the operation layer.

- [ ] **Step 1: Write failing raw hasher tests.**

Cover equal SHA-256 output, empty file, short read, EINTR retry, read failure,
cancellation, descriptor type/identity/size/mtime change, paired alternating
reads, and delta progress that counts one logical byte only after both sides
have supplied it.

- [ ] **Step 2: Write failing session tests.**

Use real files to cover equal and unequal content, structure mismatch,
source/staging mutation during hashing, mutation after hashing caught by
receipt revalidation, zero-byte-tree completion, at most two active pairs,
enabled pair limits of zero and a negative value clamping to one active pair,
permit release after failure/cancellation, a large synthetic pair list creating
only a bounded worker set rather than one task per file, phase-local monotonic
progress, and no digest/path exposure in error descriptions or summaries.

- [ ] **Step 3: Run RED.**

~~~bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --enable-swift-testing --no-parallel \
  --filter 'RawFileHashingTests|TransferVerificationServiceTests'
~~~

- [ ] **Step 4: Extract the raw checksum boundary.**

Move descriptor validation and chunk reads out of private
`ChecksumService.swift` functions into `LiveRawFileHasher`. Keep
`LiveChecksumService` responsible for its existing `.checksum`
materialization, scoped access, and global single-file permits. It opens the
path no-follow, calls the raw hasher for one file, adapts its byte deltas to
bounded single-file progress, and returns that digest through the existing
`ChecksumResult`; paired verification alone uses common-prefix progress and
ephemeral immediate comparison. It then reopens and validates the path. The
blocking read loop runs in a utility-priority detached worker wrapped by a task
cancellation handler; the caller keeps descriptors alive until that worker has
fully returned. `TransferVerificationService` compares returned digest buffers
immediately and releases them before any receipt, result, logger, snapshot, or
history value is formed.

- [ ] **Step 5: Implement paired verification.**

Obtain matching entries from `source.regularFilePairs(matching: staged)`; do not
build a dictionary keyed by `comparisonKey`. For every returned regular-file
pair, duplicate descriptor authority, acquire
one pair permit, alternate source/staging chunks, compare SHA-256 digests, and
release the permit in every path. Each verify invocation starts only
`min(pairLimit, pairCount)` workers; workers pull the next index from a bounded
actor so a 250,000-file manifest never creates 250,000 tasks. The session's
single permit pool still enforces two active pairs when multiple root verifies
run concurrently. Before a raw reader receives a descriptor, the authority
uses the Task 2 nonblocking no-follow open and immediate `fstat` validation;
the raw hasher revalidates the supplied fingerprint before and after reads.
After all pairs finish, recapture both roots, require
same-root stability and cross-root shape, discard earlier manifest generations,
and return the final receipt and summary.

- [ ] **Step 6: Implement immediate receipt revalidation.**

`revalidate` descriptor-recaptures both roots, compares them with the receipt,
checks cancellation, and returns no digest. It makes no claim that the
remaining syscall interval is atomic.

- [ ] **Step 7: Run GREEN and checksum regression.**

~~~bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --enable-swift-testing --no-parallel \
  --filter 'RawFileHashingTests|TransferVerificationServiceTests|ChecksumServiceTests'
~~~

- [ ] **Step 8: Commit and request core-engine review.**

~~~bash
git diff --check
git add Sources/BloomFileManager/Services/RawFileHashing.swift \
  Sources/BloomFileManager/Services/TransferVerificationService.swift \
  Sources/BloomFileManager/Services/ChecksumService.swift \
  Tests/BloomFileManagerTests/RawFileHashingTests.swift \
  Tests/BloomFileManagerTests/TransferVerificationServiceTests.swift \
  Tests/BloomFileManagerTests/ChecksumServiceTests.swift
git commit -m "feat: verify staged transfer contents"
~~~

Run one task review and one read-only OpenRouter Ox Alpha Ultra review of Tasks
2–3. Resolve Critical/Important findings through the SDD fix loop before Task 4.

---

### Task 4: Integrate verification into copy, duplicate, and move

**Files:**

- Modify: Sources/BloomFileManager/Services/FileOperationService.swift
- Create: Tests/BloomFileManagerTests/Support/RecordingTransferVerificationSession.swift
- Modify: Tests/BloomFileManagerTests/FileTransferTests.swift
- Modify: Tests/BloomFileManagerTests/FileOperationMutationTests.swift
- Modify: Tests/BloomFileManagerTests/CloudLocationScopedAccessTests.swift

**Interfaces:**

~~~swift
typealias TransferVerificationProgressHandler =
    @Sendable (TransferVerificationProgress) async -> Void

extension FileOperationService {
    func transfer(
        _ sources: [URL],
        to directory: URL,
        mode: TransferMode,
        resolveConflict: ConflictResolver,
        verificationPolicy: TransferVerificationPolicy = .disabled,
        progress: OperationProgressHandler,
        verificationProgress: @escaping TransferVerificationProgressHandler = { _ in }
    ) async -> FileOperationResult

    func transfer(
        _ requests: [IdentifiedTransferRequest],
        mode: TransferMode,
        resolveConflict: ConflictResolver,
        verificationPolicy: TransferVerificationPolicy = .disabled,
        progress: OperationProgressHandler,
        verificationProgress: @escaping TransferVerificationProgressHandler = { _ in }
    ) async -> FileOperationResult

    func duplicate(
        _ requests: [IdentifiedTransferRequest],
        verificationPolicy: TransferVerificationPolicy = .disabled,
        progress: OperationProgressHandler = { _ in },
        verificationProgress: @escaping TransferVerificationProgressHandler = { _ in }
    ) async -> FileOperationResult
}
~~~

`FileOperationService.init` receives this final defaulted parameter:

~~~swift
verificationSessionFactory: any TransferVerificationSessionFactory =
    LiveTransferVerificationSessionFactory()
~~~

URL-based compatibility overloads forward policy
and progress to the identified path. Their existing `legacyTransfer` fallback
remains available only for `.disabled`; an enabled request that cannot capture
source or destination identity fails closed with a present verification report
instead of performing an unverified legacy copy.

- [ ] **Step 1: Write failing disabled-path, policy, and order tests.**

Assert disabled transfer and duplicate never ask the factory for a session and
retain existing events/results. Assert enabled operations capture the
destination root's `FilenameComparisonPolicy` after conflict/capacity checks
and pass that exact policy into source capture. For enabled copy, assert event
order: capacity → destination policy capture → source capture → staging
reserve/copy → verify → receipt revalidate → identity-bound publish. Cover the
URL compatibility overload: disabled identity failure retains legacy behavior,
while enabled identity failure never calls `legacyTransfer`.

- [ ] **Step 2: Write failing safety tests.**

Cover content mismatch, structure mismatch, read failure, cancellation,
receipt mismatch, cleanup failure, replacement preserving old destination,
cross-volume move preserving source until verified publication, same-volume
move without replacement producing exactly one no-byte-transfer count with no
verifier call, same-volume move with replacement taking the verified staging
path, skip and capacity failure producing no capture, duplicate EEXIST creating
a fresh capture/verification, and partial batch report aggregation. Use a
recording logger to assert exactly one typed terminal verification event per
enabled ordinary operation. Its aggregate values and bounded enum category
must match the result, while disabled operations emit no verification event.

- [ ] **Step 3: Write failing lease tests.**

Use the recording scope driver to assert service access leases remain active
during capture, hash, revalidation, publication, and cleanup, and are balanced
after success, failure, and cancellation. Assert the verifier creates no
materialization call.

- [ ] **Step 4: Run RED.**

~~~bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --enable-swift-testing --no-parallel \
  --filter 'FileTransferTests|FileOperationMutationTests|CloudLocationScopedAccessTests'
~~~

- [ ] **Step 5: Split pre-reservation capture from staging ownership.**

Keep conflict resolution and capacity checks first. Create one session for the
whole batch. For eligible items, read and retain the destination root's
comparison policy, then capture the source with that policy immediately before
calling the reservation/copy helper. Store `TransferVerificationCompletion` in
`PreparedStagedCopy` together with a `@Sendable () async throws -> Void`
revalidation closure that captures the same active session and receipt. Invoke
that closure inside `commit` immediately before `move`, `moveExclusively`, or
`replace`; do not look up, recreate, or pass an ad-hoc session at commit time.

- [ ] **Step 6: Integrate duplicate and report handling.**

Capture and verify inside each Keep Both candidate loop. On EEXIST, clean the
verified private candidate and start a new manifest/copy/verification cycle.
Count only successfully verified files/bytes, same-volume no-copy moves, and
verification-category failures. Preserve reports through
`addingSafeRelativePaths`. Emit the typed terminal logger event from the
normalized bounded report and failure category only; never pass `URL`, safe
name, digest, localized description, or an underlying error to that logging
boundary.

- [ ] **Step 7: Run GREEN and commit.**

~~~bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --enable-swift-testing --no-parallel \
  --filter 'FileTransferTests|FileOperationMutationTests|CloudLocationScopedAccessTests|TransferVerificationServiceTests'
git diff --check
git add Sources/BloomFileManager/Services/FileOperationService.swift \
  Tests/BloomFileManagerTests/Support/RecordingTransferVerificationSession.swift \
  Tests/BloomFileManagerTests/FileTransferTests.swift \
  Tests/BloomFileManagerTests/FileOperationMutationTests.swift \
  Tests/BloomFileManagerTests/CloudLocationScopedAccessTests.swift
git commit -m "feat: verify file operation staging"
~~~

---

### Task 5: Integrate verification into reviewed folder synchronization

**Files:**

- Modify: Sources/BloomFileManager/Services/FolderSynchronizationTransactionService.swift
- Modify: Sources/BloomFileManager/Services/FileOperationService.swift
- Modify: Tests/BloomFileManagerTests/FolderSynchronizationTransactionServiceTests.swift
- Modify: Tests/BloomFileManagerTests/FolderSynchronizationPreparationServiceTests.swift
- Modify: Tests/BloomFileManagerTests/FileOperationControllerTests.swift

**Interfaces:**

~~~swift
protocol FolderSynchronizationExecuting: Sendable {
    func execute(
        _ plan: PreparedFolderSynchronizationPlan,
        verificationPolicy: TransferVerificationPolicy,
        progress: @escaping @Sendable (FolderSynchronizationProgress) async -> Void,
        verificationProgress:
            @escaping TransferVerificationProgressHandler
    ) async -> FileOperationResult
}

extension FolderSynchronizationExecuting {
    func execute(
        _ plan: PreparedFolderSynchronizationPlan,
        progress: @escaping @Sendable (FolderSynchronizationProgress) async -> Void
    ) async -> FileOperationResult
}
~~~

The convenience overload delegates with `.disabled` and a no-op verification
callback, preserving existing callers. `StagedItem` uses an explicit
verification state transition: it initially owns the lazy source manifest;
after successful verification it replaces and releases that manifest and owns
only the final receipt. It never retains the earlier manifest alongside the
receipt.

- [ ] **Step 1: Write failing disabled and lazy-capture tests.**

Assert review preparation performs no SHA traversal. Disabled transaction
events and reports remain unchanged. Enabled source capture occurs after
preflight and immediately before each staging reservation.

- [ ] **Step 2: Write failing transaction-order tests.**

Cover all staged action roots verified before the first quarantine, one shared
two-pair limit across concurrent action verification, per-action
`verifyingStaging` completion only after content verification, mismatch before
quarantine, a large action list using a bounded root-worker set, and separate
byte/fraction progress. Add descriptor-close and manifest-backing-storage
release probes that must fire after every action installs its final receipt and
before quarantine begins. Assert one typed terminal verification logger event
uses only the aggregate report and bounded category.

- [ ] **Step 3: Write failing rollback tests.**

Cover cancellation/read failure cleanup, cleanup failure becoming Recovery
Needed, receipt failure for action N rolling back published actions 1 through
N−1, and no source/destination removal merely because verification failed.

- [ ] **Step 4: Run RED.**

~~~bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --enable-swift-testing --no-parallel \
  --filter 'FolderSynchronizationTransactionServiceTests|FolderSynchronizationPreparationServiceTests|FileOperationControllerTests'
~~~

- [ ] **Step 5: Implement shared-session staging and verification.**

Create one session for the transaction. Capture each manifest immediately
before reservation. After metadata staging checks, verify action roots with a
throwing task group containing at most two root workers; workers pull the next
staged action from an actor rather than creating one task per action. Every
verify call shares the session permit pool. Aggregate per-root absolute
progress through a separate actor that publishes monotonic operation totals
without placing bytes in action counters. Pass the same injected session
factory through `FileOperationService.makeFolderSynchronizationTransactionService`
so app-created sync services and ordinary transfers use the same dependency
boundary while still creating a distinct session per operation. Pass the
operation logger through that maker as well. As each completion is installed,
replace the staged item's source-manifest state with its receipt so the earlier
descriptor authority and backing storage are released before quarantine.

- [ ] **Step 6: Revalidate at publication and preserve rollback.**

After destination absence and parent identity checks, revalidate that action's
receipt as the last awaited safety step before `moveExclusively`. Record each
publication before later awaits so existing detached rollback owns it.

- [ ] **Step 7: Run GREEN and commit.**

~~~bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --enable-swift-testing --no-parallel \
  --filter 'FolderSynchronizationTransactionServiceTests|FolderSynchronizationPreparationServiceTests|FileOperationControllerTests|TransferVerificationServiceTests'
git diff --check
git add Sources/BloomFileManager/Services/FolderSynchronizationTransactionService.swift \
  Sources/BloomFileManager/Services/FileOperationService.swift \
  Tests/BloomFileManagerTests/FolderSynchronizationTransactionServiceTests.swift \
  Tests/BloomFileManagerTests/FolderSynchronizationPreparationServiceTests.swift \
  Tests/BloomFileManagerTests/FileOperationControllerTests.swift
git commit -m "feat: verify folder synchronization staging"
~~~

---

### Task 6: Persist preference and capture policy in the operation queue

**Files:**

- Create: Sources/BloomFileManager/Stores/TransferVerificationPreference.swift
- Modify: Sources/BloomFileManager/Stores/FileOperationController.swift
- Modify: Sources/BloomFileManager/Models/FileOperationJobModels.swift
- Modify: Sources/BloomFileManager/Views/OperationStatusView.swift
- Create: Tests/BloomFileManagerTests/TransferVerificationPreferenceTests.swift
- Modify: Tests/BloomFileManagerTests/FileOperationControllerTests.swift
- Modify: Tests/BloomFileManagerTests/OperationStatusViewTests.swift

**Interfaces:**

~~~swift
@MainActor
protocol TransferVerificationPreferencePersisting {
    func loadEnabled() -> Bool?
    func saveEnabled(_ enabled: Bool)
}

@MainActor @Observable
final class TransferVerificationPreference {
    var isEnabled: Bool
    var policy: TransferVerificationPolicy { get }
}

enum FileOperationStage: Equatable {
    case preparing(CloudMaterializationProgress)
    case operating(FileOperationProgress)
    case archiving(ArchiveOperationProgress)
    case batchRenaming(BatchRenameTransactionProgress)
    case enclosingSelection(SelectionFolderTransactionProgress)
    case synchronizing(FolderSynchronizationProgress)
    case verifying(TransferVerificationProgress)
}
~~~

`policy` returns `.disabled` when `isEnabled` is false and returns exactly
`.sha256(maxConcurrentPairs: 2)` when it is true. No other pair limit is
user-selectable.

Modify the existing designated `FileOperationController` initializer to add
this final defaulted parameter, store it as an immutable closure, and leave all
existing parameters and defaults unchanged:

~~~swift
verificationPolicyProvider:
    @escaping @MainActor () -> TransferVerificationPolicy = { .disabled }
~~~

Both `PendingFileOperation` and `RetryFileOperation` store the captured policy.
The operation closure captures the same immutable local value. Terminal
snapshot recreation and Undo-eligibility projection preserve the optional
report.

- [ ] **Step 1: Write failing persistence tests.**

Use an in-memory persistence fake. Cover missing/malformed storage → false,
true/false round trips, disabled policy, enabled pair limit exactly two, and no
read from `UserDefaults.standard` in default controller tests.

- [ ] **Step 2: Write failing queue and Retry tests.**

Queue enabled work, change preference before execution, and assert enabled
policy runs. Fail it, switch preference off, Retry, and assert the original
enabled policy runs. Repeat disabled→enabled. Cover queued cancellation,
cancelled-before-start, identity-preparation failure, normal completion,
duplicate, transfer, and synchronization; enabled jobs that never reach
verification retain a present all-zero report. For every terminal path, assert
`lastResult`, the history snapshot, Retry metadata, Undo projection, and
`onCompletion` observe the same normalized report-bearing value.

- [ ] **Step 3: Write failing progress/snapshot tests.**

Assert verification callbacks publish `.verifying`, are throttled to roughly
100ms except phase and 0/100% boundaries, pause checkpoints occur before
throttling, `.verifying` is never converted to legacy item progress, and report
survives completion, history insertion, retry metadata, and Undo-eligibility
reprojection. Compile and exercise every exhaustive stage switch: controller
legacy `progress` returns nil for verification, job projection uses the
fraction unit, and the status view presents a minimal truthful verification
label until Task 7 adds the full presentation component.

- [ ] **Step 4: Run RED.**

~~~bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --enable-swift-testing --no-parallel \
  --filter 'TransferVerificationPreferenceTests|FileOperationControllerTests|FileOperationJobModelsTests|OperationStatusViewTests'
~~~

- [ ] **Step 5: Implement preference and immutable capture.**

The UserDefaults key is
`fileOperations.verifyTransferredContents.v1`. Read with
`object(forKey:) as? Bool`; every other value becomes false. Add a defaulted
`verificationPolicy: TransferVerificationPolicy = .disabled` parameter to
`beginOperation`. For identified transfer, duplicate, synchronization, and
their early-failure jobs, read `verificationPolicyProvider()` into a local
value immediately before `beginOperation` and pass that value into the pending
operation and execution closure. Never read the provider from an execution or
Retry closure.

- [ ] **Step 6: Implement stage publication and terminal normalization.**

Map verification callbacks to `.verifying`; normalize enabled results to a
present zero report only when no service report exists. Introduce one
policy-aware terminal-result normalization helper and call it for queued
cancellation, cancelled-before-start, early preparation failure, and normal
execution. Use that one returned value—not the pre-normalized result—for
`completeOperation`, `lastResult`, history creation, Retry metadata, Undo
projection, and `onCompletion`. Preserve the report in every snapshot copy
initializer and never reread the current preference while normalizing. Add the
stage case and update all exhaustive switches in the same commit: controller
legacy item progress returns nil, `jobProgress` emits the unit-aware fraction,
and `OperationStatusView` renders a minimal correct phase/percentage/count
status. Task 7 refactors that minimal branch into the richer reusable
presentation without introducing the enum case later.

- [ ] **Step 7: Run GREEN and commit.**

~~~bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --enable-swift-testing --no-parallel \
  --filter 'TransferVerificationPreferenceTests|FileOperationControllerTests|FileOperationJobModelsTests|OperationStatusViewTests'
git diff --check
git add Sources/BloomFileManager/Stores/TransferVerificationPreference.swift \
  Sources/BloomFileManager/Stores/FileOperationController.swift \
  Sources/BloomFileManager/Models/FileOperationJobModels.swift \
  Sources/BloomFileManager/Views/OperationStatusView.swift \
  Tests/BloomFileManagerTests/TransferVerificationPreferenceTests.swift \
  Tests/BloomFileManagerTests/FileOperationControllerTests.swift \
  Tests/BloomFileManagerTests/OperationStatusViewTests.swift
git commit -m "feat: capture transfer verification policy"
~~~

---

### Task 7: Add Settings, verification status, history, and accessibility UI

**Files:**

- Create: Sources/BloomFileManager/Views/FileOperationsSettingsView.swift
- Modify: Sources/BloomFileManager/App/BloomFileManagerApp.swift
- Modify: Sources/BloomFileManager/Views/OperationStatusView.swift
- Modify: Sources/BloomFileManager/Views/FileOperationCenterView.swift
- Modify: Sources/BloomFileManager/Support/AccessibilityIdentifiers.swift
- Create: Tests/BloomFileManagerTests/FileOperationsSettingsPresentationTests.swift
- Modify: Tests/BloomFileManagerTests/OperationStatusViewTests.swift
- Modify: Tests/BloomFileManagerTests/FileOperationCenterViewTests.swift
- Modify: Tests/BloomFileManagerTests/AccessibilityPresentationTests.swift

**Interfaces:**

~~~swift
struct FileOperationsSettingsView: View {
    @Bindable var preference: TransferVerificationPreference
}

struct TransferVerificationOperationStatusPresentation:
    Equatable, Sendable {
    let title: String
    let percentage: Int
    let completedFileCount: Int
    let totalFileCount: Int
    let currentName: String
    let accessibilityLabel: String
}

enum FileOperationHistoryPresentation {
    static func verificationDetail(
        job: FileOperationJobSnapshot
    ) -> String?
}
~~~

- [ ] **Step 1: Write failing Settings presentation tests.**

Assert two Settings tabs in File Operations → Cloud Locations order. Assert the
toggle label, off/on value, stable identifier, and help text disclose extra
elapsed time/read I/O, provider availability, byte-weighted percentage, and
file-weighted count.

- [ ] **Step 2: Write failing status and history tests.**

Cover all three verification phases, 0/42/100% clamping, zero-byte completion,
dominant-large-file percentage with independent file count, verified summary,
No byte transfer, mixed failure wording that never implies total success,
disabled nil detail, and enabled zero detail.

- [ ] **Step 3: Write failing accessibility tests.**

Assert safe basenames, no newline injection, no absolute path, raw byte total,
digest, or relative tree list. Preserve the existing exact occurrence count of
the common `operationStatus` identifier. Test phase announcements immediately
and intermediate percentage announcements through bounded buckets.

- [ ] **Step 4: Run RED.**

~~~bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --enable-swift-testing --no-parallel \
  --filter 'FileOperationsSettingsPresentationTests|OperationStatusViewTests|FileOperationCenterViewTests|AccessibilityPresentationTests'
~~~

- [ ] **Step 5: Wire one app preference instance.**

Create the preference before `FileOperationController`, store it in `@State`,
pass its policy provider to the controller, and pass the same instance to the
Settings view. Add stable identifiers `fileOperationsSettings` and
`verifyTransferredContents`.

- [ ] **Step 6: Implement visual and VoiceOver presentation.**

Refactor Task 6's minimal `.verifying` status branch into
`TransferVerificationOperationStatusPresentation`. Use normalized fraction in
both status bar and Operation Center even when file/byte totals are zero.
History appends bounded verification detail to existing Undo/Retry guidance.
Announce phase boundaries and throttled percentage buckets without duplicating
the common status identifier.

- [ ] **Step 7: Run GREEN and commit.**

~~~bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --enable-swift-testing --no-parallel \
  --filter 'FileOperationsSettingsPresentationTests|OperationStatusViewTests|FileOperationCenterViewTests|AccessibilityPresentationTests|FileOperationControllerTests'
git diff --check
git add Sources/BloomFileManager/Views/FileOperationsSettingsView.swift \
  Sources/BloomFileManager/App/BloomFileManagerApp.swift \
  Sources/BloomFileManager/Views/OperationStatusView.swift \
  Sources/BloomFileManager/Views/FileOperationCenterView.swift \
  Sources/BloomFileManager/Support/AccessibilityIdentifiers.swift \
  Tests/BloomFileManagerTests/FileOperationsSettingsPresentationTests.swift \
  Tests/BloomFileManagerTests/OperationStatusViewTests.swift \
  Tests/BloomFileManagerTests/FileOperationCenterViewTests.swift \
  Tests/BloomFileManagerTests/AccessibilityPresentationTests.swift
git commit -m "feat: present transfer verification controls"
~~~

---

### Task 8: Add APFS verification harness and bilingual source documentation

**Files:**

- Create: Tests/BloomFileManagerTests/TransferVerificationAPFSTests.swift
- Create: script/verify_transfer_content.sh
- Create: script/tests/verify_transfer_content_contract_tests.sh
- Modify: README.md
- Modify: README.ko.md
- Modify: docs/user-guide.md
- Modify: docs/user-guide.ko.md
- Modify: docs/current-limitations.md
- Modify: docs/current-limitations.ko.md
- Modify: docs/architecture.md
- Create: docs/verification/transfer-content-verification.md
- Create: docs/verification/transfer-content-verification.ko.md

**Interfaces:**

The opt-in test reads `PENGRID_TRANSFER_APFS_ROOT`. Without it, the suite records
a skip. The script creates a temporary APFS disk image under a `mktemp -d`
directory, attaches it, runs only the opt-in test with the mounted root, and
detaches/removes through a trap. It never targets `/`, `$HOME`, a workspace
root, or an unresolved variable. It attaches with `hdiutil attach -plist`,
accepts only an allowlisted `/dev/disk[0-9]+(s[0-9]+)*` device whose plist image
path and mount point match the canonical temporary image and strict-child
mount directory, and rechecks mount identity before test execution and detach.

- [ ] **Step 1: Write the failing shell harness contract.**

The dedicated shell contract tests execute the absent script against fake
`hdiutil`/Swift tools and assert attach, test, detach, and failure cleanup
ordering. They also reject malformed plist, a non-allowlisted device, an image
or mountpoint mismatch, mountpoint symlink substitution, and partial attach.
Signal cases prove INT/TERM terminate after cleanup rather than continuing into
the Swift test.

- [ ] **Step 2: Run the meaningful shell-contract RED.**

~~~bash
/bin/bash script/tests/verify_transfer_content_contract_tests.sh
~~~

Expected: failure because `script/verify_transfer_content.sh` does not exist.
Do not manufacture a Swift RED by adding a test target after Tasks 4–5 already
implemented the production behavior.

- [ ] **Step 3: Implement the safe harness.**

Use explicit absolute tool paths, validated canonical temporary children, a
unique image and mountpoint, and `hdiutil attach -plist`. Parse the plist
without `eval`; validate the device allowlist, exact image path, strict-child
mountpoint, and mounted filesystem identity before use and again before
detach. Use one idempotent EXIT cleanup trap plus separate INT/TERM handlers
that preserve a nonzero signal exit after cleanup. Cleanup may detach only the
validated attached image device and may delete only the validated temporary
root. The script reports exact PASS/FAIL rows but stores no user paths or
hashes in the repository. Run the shell contract to GREEN before continuing.

- [ ] **Step 4: Add post-implementation physical APFS verification.**

Create `TransferVerificationAPFSTests.swift` as an opt-in integration suite,
not as RED evidence for already implemented production code. The real service
test copies a nested directory to the mounted volume with enabled verification,
performs a cross-volume move and proves source removal only after success,
and verifies a single symlink root without following it. Add deterministic
phase gates: one cancels during verification and proves source preservation;
another mutates owned staging immediately before verification or receipt
revalidation and proves no publication, source/old-destination preservation,
and cleanup of only owned staging. Run the focused Swift test through the real
harness and require GREEN.

- [ ] **Step 5: Update bilingual documentation.**

Document default-off Settings behavior, eligible operations, recursive and
symlink scope, two-pair limit, progress interpretation, Retry behavior,
same-volume no-copy, File Provider local-byte limitation, excluded metadata,
manifest budgets, privacy, residual syscall race, and Recovery Needed. State
that current source contains the feature while the last published Developer
Preview DMG does not until a new release is actually published.

- [ ] **Step 6: Create verification checklists.**

Both checklists contain Automated evidence, Static-source evidence, Physical
manual evidence, and Release gate sections. Mark provider and VoiceOver rows
`MANUAL NOT RUN` until observed.

- [ ] **Step 7: Run GREEN and commit.**

~~~bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --enable-swift-testing --no-parallel \
  --filter TransferVerificationAPFSTests
/bin/bash script/tests/verify_transfer_content_contract_tests.sh
git diff --check
git add Tests/BloomFileManagerTests/TransferVerificationAPFSTests.swift \
  script/verify_transfer_content.sh \
  script/tests/verify_transfer_content_contract_tests.sh \
  README.md README.ko.md docs
git commit -m "docs: document transfer content verification"
~~~

---

### Task 9: Complete regression, candidate packaging, and release readiness

**Files:**

- Modify:
  docs/verification/transfer-content-verification.md
- Modify:
  docs/verification/transfer-content-verification.ko.md
- Modify for the next candidate build:
  script/build_and_run.sh
- Modify for the next candidate build:
  script/package_release.sh
- Modify for the next candidate build:
  script/tests/package_release_contract_tests.sh
- Create for the verified candidate:
  docs/release-notes-v1.3.0-developer-preview.8.md
- Modify after the public asset is verified:
  README.md
- Modify after the public asset is verified:
  README.ko.md
- Modify after the public asset is verified:
  docs/release.md
- Modify after the public asset is verified:
  docs/release.ko.md

**Interfaces:**

The next unsigned candidate keeps app version `1.3.0`, increments build from
`9` to `10`, and remains ad-hoc signed/not notarized. Remote tags were checked
before implementation and `v1.3.0-developer-preview.8` was unclaimed; check it
again immediately before publication and fail closed on a collision. The
GitHub release is created only after merge and public CI success. Published
documentation must use the actual tag, commit, test count, and SHA-256, never
an anticipated value. A pre-merge candidate DMG is disposable validation
evidence: its checksum is never committed as the public DP8 checksum. The
public checksum is computed only from the one DMG packaged from the exact
merged commit and uploaded byte-for-byte.

- [ ] **Step 1: Bump and test the build contract.**

Write the failing contract expectation for build 10 first, run the contract
suite to see build 9 fail, then update both packaging scripts to build 10 and
rerun:

~~~bash
/bin/bash script/tests/package_release_contract_tests.sh
~~~

- [ ] **Step 2: Run the focused safety suites.**

~~~bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --enable-swift-testing --no-parallel \
  --filter 'TransferVerification|FileTransferTests|FileOperationMutationTests|FolderSynchronizationTransactionServiceTests|FileOperationControllerTests|CloudLocationScopedAccessTests|OperationStatusViewTests|FileOperationCenterViewTests'
~~~

- [ ] **Step 3: Run the complete nonparallel suite twice around release build.**

~~~bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --enable-swift-testing --no-parallel
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift build -c release --arch arm64
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  /usr/bin/xcrun swift test --enable-swift-testing --no-parallel
~~~

- [ ] **Step 4: Run the physical APFS harness.**

~~~bash
/bin/bash script/verify_transfer_content.sh
~~~

Record actual automated evidence. Keep physical File Provider and VoiceOver
rows NOT RUN unless performed separately.

- [ ] **Step 5: Build and verify unsigned app/DMG artifacts.**

~~~bash
./script/build_and_run.sh --verify
./script/package_release.sh --unsigned
/usr/bin/codesign --verify --deep --strict --verbose=2 dist/release/Pengrid.app
/usr/bin/shasum -a 256 dist/release/Pengrid.dmg
~~~

Verify app icon resources, bundle identifier, app version 1.3.0, build 10,
arm64 architecture, mounted-DMG app equality, and expected Gatekeeper rejection
for an ad-hoc unsigned Developer Preview. Treat this pre-merge DMG as a
disposable candidate and do not copy its checksum into public release notes.

- [ ] **Step 6: Update evidence and candidate notes with only observed values.**

Insert the exact test/suite totals, APFS result, build result, and signature
result into both checklists and the bilingual sections of
`docs/release-notes-v1.3.0-developer-preview.8.md`. Clearly label the notes as
pre-merge candidate evidence, the future artifact as ad-hoc signed and not
notarized, and the public checksum as intentionally pending creation of the
merged-commit artifact. Do not publish or commit the disposable candidate
checksum, and do not turn unrun manual rows into PASS.

~~~bash
git diff --check
git status --short
git add script/build_and_run.sh script/package_release.sh \
  script/tests/package_release_contract_tests.sh \
  docs/verification/transfer-content-verification.md \
  docs/verification/transfer-content-verification.ko.md \
  docs/release-notes-v1.3.0-developer-preview.8.md
git commit -m "build: prepare transfer verification candidate"
~~~

- [ ] **Step 7: Run final independent review.**

Generate a full merge-base review package. Use the highest-capability built-in
reviewer and wait for a read-only OpenRouter Ox Alpha Ultra review. Resolve
Critical/Important findings through one final fix wave and scoped re-review,
then rerun every affected focused suite plus the complete suite.

- [ ] **Step 8: Hand off to branch completion.**

Use superpowers:finishing-a-development-branch. After the already-authorized
push, public CI, and merge, check out the exact merged commit and package it
once. Repeat the release build, bundle/icon/version/architecture, mounted-DMG
equality, signature, Gatekeeper, and APFS checks against that exact state;
compute the SHA-256 only for this final DMG. Enumerate Pengrid app bundles in
`/Applications`, resolve their bundle identifiers and versions, and remove only
an explicitly identified older duplicate after the verified build-10 bundle is
ready. Install `/Applications/Pengrid.app`, verify its
identity/version/signature, and launch that exact bundle. Recheck that
`v1.3.0-developer-preview.8` is unclaimed, generate the GitHub release body from
the observed merged commit, test totals, and final-DMG SHA-256, create the
prerelease, upload that same already-verified DMG without repackaging, and
verify an unauthenticated public redownload byte-for-byte and checksum-for-
checksum. Update `README.md`,
`README.ko.md`, `docs/release.md`, and `docs/release.ko.md` in a follow-up PR
with the actual merge commit, release tag, test totals, public URL, and DMG
SHA-256; run link/contract checks and merge that documentation PR only after
its public CI passes.

## Plan Self-Review Checklist

- Every goal and non-goal in the design maps to at least one task.
- Task 1 produces policy/report/progress types consumed by Tasks 3–7.
- Task 2 produces manifests and authorities consumed by Task 3.
- Task 3 produces session factory/session/receipt interfaces consumed by Tasks
  4–6.
- Task 4 produces ordinary-operation reports consumed by Tasks 6–7.
- Task 5 produces synchronization callbacks/reports consumed by Tasks 6–7.
- Task 6 produces preference, policy capture, stage, and snapshots consumed by
  Task 7.
- Task 7 completes Settings, status, history, and accessibility.
- Tasks 8–9 complete source docs, APFS evidence, packaging, installation, and
  release handoff without claiming unrun manual validation.
- No task enumerates source content while queued, creates verifier-owned cloud
  leases, persists digests/paths, or weakens cleanup ownership.
