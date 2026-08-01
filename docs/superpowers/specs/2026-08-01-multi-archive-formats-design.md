# Multi-Format Archive Operations Design

## Goal

Extend Pengrid archive operations beyond ZIP and make multi-item archive preparation faster without adding third-party command-line dependencies.

## Scope

Supported formats in this iteration:

- ZIP (`.zip`), using `/usr/bin/ditto` so existing macOS metadata and symbolic-link behavior remain unchanged.
- TAR (`.tar`), GZip TAR (`.tar.gz`, `.tgz`), BZip2 TAR (`.tar.bz2`, `.tbz`, `.tbz2`), and XZ TAR (`.tar.xz`, `.txz`), using `/usr/bin/tar`/`bsdtar`.

RAR and 7z are intentionally deferred. macOS does not ship a stable `/usr/bin` encoder/decoder for them, and silently depending on Homebrew or another user-installed tool would make cloud-provider and release behavior non-reproducible. Password-protected archives are also out of scope for this iteration.

## User experience

- `Compress to ZIP` remains the default command and keeps its existing keyboard/menu behavior.
- `Compress as…` is added to the File Operations menu and the table context menu with one entry per supported format.
- The selected format determines the destination suffix and the command runner arguments. Existing keep-both naming remains in force.
- `Extract Archive` accepts every supported suffix, including case-insensitive aliases, and chooses the extraction command from the captured archive format.
- Progress and VoiceOver labels identify the format (for example, `Compressing TAR.GZ archive`).

## Architecture

### Format model

`ArchiveFormat` is a `CaseIterable`, `Hashable`, `Sendable` value with a display name, canonical suffix, command-line compression flag, and case-insensitive filename detection. `ArchiveRequest` carries the format explicitly, defaulting to `.zip` for source compatibility. Extraction plans retain one detected format per selected archive so mixed selections remain valid.

### Command runner

`ArchiveCommandRunning` receives the explicit format. ZIP continues to use `ditto`; TAR variants use `tar` with `-c`/`-x`, the matching compression flag, and an explicit `-C` root. All arguments remain an array, never a shell command. The runner waits for `Process.terminationHandler` through a cancellation-aware latch instead of blocking on `waitUntilExit`, avoiding an intermittent Swift concurrency/CFRunLoop hang observed in the existing live integration test.

### Parallel preparation

When compressing multiple sources, the runner creates one private aggregate root as before. It validates unique basenames first, then copies independent source entries through a bounded task group. The worker count is `min(4, max(1, activeProcessorCount), sourceCount)` so large selections do not create unbounded I/O pressure. Cancellation is checked before each copy and the aggregate root is identity-free private staging that is removed on every exit path. The native archive process still runs as one command; no unbundled parallel compressor is introduced.

### Safety and publication

ArchiveOperationService continues to stage the final archive, verify output, and publish with exclusive move. TAR extraction happens inside the private staged directory and is not visible until the existing publication gate succeeds. `bsdtar` rejects unsafe `..` archive entries on the target macOS toolchain; malformed archives remain failures with staging cleanup.

## Testing

- Unit tests cover every format's suffix/detection and command arguments, including aliases and invalid mixed requests.
- Planner and command-policy tests cover format-specific destination names and all supported extraction suffixes.
- Live integration tests round-trip a representative file through TAR, TAR.GZ, TAR.BZ2, and TAR.XZ, plus existing ZIP/symbolic-link coverage.
- A multi-source integration test exercises the bounded aggregate-copy path.
- The live runner termination regression must complete repeatedly without hanging.
- The full SwiftPM test suite, package contract tests, and arm64 release build remain required gates.

## Non-goals

- No external package manager dependency, bundled 7z/RAR binary, password UI, archive browsing, or compression-level preference.
- No claim that TAR compression itself is multi-threaded; parallelism is applied where Pengrid controls independent source preparation.
