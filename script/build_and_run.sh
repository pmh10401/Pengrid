#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_DISPLAY_NAME="Pengrid"
EXECUTABLE_NAME="BloomFileManager"
ICON_NAME="Pengrid.icns"
BUNDLE_ID="com.minho.BloomFileManager"
MIN_SYSTEM_VERSION="15.0"
APP_VERSION="1.3.0"
BUILD_VERSION="4"

die() { echo "$*" >&2; exit 1; }

has_no_symlink_components() {
  local target="$1" current='' component
  [[ "$target" == /* ]] || return 1
  IFS='/' read -r -a components <<<"${target#/}"
  for component in "${components[@]}"; do
    [[ -n "$component" ]] || continue
    current="$current/$component"
    [[ ! -L "$current" ]] || return 1
  done
}

assert_no_symlink_components() {
  has_no_symlink_components "$1" || die "symbolic link component is not allowed: $1"
}

is_strict_child() {
  [[ "$1" == "$2"/* && "$1" != "$2" ]]
}

safe_delete_leaf() {
  local target="$1" allowed_root="$2"
  is_strict_child "$target" "$allowed_root" || die "unsafe cleanup target: $target"
  assert_no_symlink_components "$(dirname "$target")"
  if [[ -L "$target" || -f "$target" ]]; then
    /bin/unlink "$target"
  elif [[ -d "$target" ]]; then
    /usr/bin/find "$target" -depth -delete
  elif [[ -e "$target" ]]; then
    die "refusing unsupported cleanup target: $target"
  fi
}

SCRIPT_PATH="${BASH_SOURCE[0]}"
[[ "$SCRIPT_PATH" == /* ]] || SCRIPT_PATH="$PWD/$SCRIPT_PATH"
assert_no_symlink_components "$(dirname "$SCRIPT_PATH")"
SCRIPT_DIR="$(cd -P "$(dirname "$SCRIPT_PATH")" && pwd -P)"
ROOT_DIR="$(cd -P "$SCRIPT_DIR/.." && pwd -P)"
assert_no_symlink_components "$ROOT_DIR"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_DISPLAY_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_BUNDLE/Contents/Resources"
APP_BINARY="$APP_MACOS/$EXECUTABLE_NAME"
ICON_SOURCE="$ROOT_DIR/Assets/Pengrid/$ICON_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
is_strict_child "$DIST_DIR" "$ROOT_DIR" || die "unsafe dist path"
assert_no_symlink_components "$ROOT_DIR"
if [[ -e "$DIST_DIR" || -L "$DIST_DIR" ]]; then
  assert_no_symlink_components "$DIST_DIR"
  [[ -d "$DIST_DIR" ]] || die "dist path must be a directory"
fi

if [[ "$(uname -m)" != "arm64" ]]; then
  echo "$EXECUTABLE_NAME requires an Apple Silicon (arm64) host." >&2
  exit 1
fi

pkill -x "$EXECUTABLE_NAME" >/dev/null 2>&1 || true
swift build --package-path "$ROOT_DIR"
BUILD_BINARY="$(swift build --package-path "$ROOT_DIR" --show-bin-path)/$EXECUTABLE_NAME"
[[ "$ICON_SOURCE" == "$ROOT_DIR/Assets/Pengrid/$ICON_NAME" ]] \
  || die "unsafe app icon path: $ICON_SOURCE"
assert_no_symlink_components "$ICON_SOURCE"
if ! exec 8<"$ICON_SOURCE"; then
  die "unable to open app icon: $ICON_SOURCE"
fi
if ! icon_source_path_identity="$(/usr/bin/stat -f '%d:%i:%HT:%u:%l:%Lp' "$ICON_SOURCE")"; then
  die "unable to inspect app icon path: $ICON_SOURCE"
fi
if ! icon_source_fd_identity="$(/usr/bin/stat -f '%d:%i:%HT:%u:%l:%Lp' <&8)"; then
  die "unable to inspect opened app icon: $ICON_SOURCE"
fi
IFS=: read -r source_device source_inode source_type source_uid source_links source_mode \
  <<<"$icon_source_path_identity"
[[ "$source_type" == "Regular File" && "$icon_source_path_identity" == "$icon_source_fd_identity" ]] \
  || die "app icon path changed or is not a regular file: $ICON_SOURCE"

safe_delete_leaf "$APP_BUNDLE" "$DIST_DIR"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
assert_no_symlink_components "$APP_RESOURCES"
if ! exec 7<"$APP_RESOURCES"; then
  die "unable to open app resources directory: $APP_RESOURCES"
fi
if ! resources_path_identity="$(/usr/bin/stat -f '%d:%i:%HT:%u:%l:%Lp' "$APP_RESOURCES")"; then
  die "unable to inspect app resources path: $APP_RESOURCES"
fi
if ! resources_fd_identity="$(/usr/bin/stat -f '%d:%i:%HT:%u:%l:%Lp' <&7)"; then
  die "unable to inspect opened app resources directory: $APP_RESOURCES"
fi
IFS=: read -r resources_device resources_inode resources_type resources_uid resources_links resources_mode \
  <<<"$resources_path_identity"
[[ "$resources_type" == "Directory" && "$resources_path_identity" == "$resources_fd_identity" ]] \
  || die "app resources path changed or is not a directory: $APP_RESOURCES"

cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"

if ! /usr/bin/swift - "$ICON_NAME" <<'SWIFT'
import Darwin

let resourcesFD: Int32 = 7
let sourceFD: Int32 = 8
guard CommandLine.arguments.count == 2 else {
    exit(64)
}
let iconName = CommandLine.arguments[1]
guard !iconName.isEmpty,
      iconName != ".",
      iconName != "..",
      !iconName.contains("/") else {
    exit(64)
}

var stageFD: Int32 = -1
var stageBasename = ""
var published = false

func unlinkAnchored(_ name: String) {
    name.withCString { pointer in
        _ = unlinkat(resourcesFD, pointer, 0)
    }
}

func cleanup() {
    if !stageBasename.isEmpty {
        unlinkAnchored(published ? iconName : stageBasename)
    }
    if stageFD >= 0 {
        _ = close(stageFD)
        stageFD = -1
    }
}

func fail(_ message: String) -> Never {
    let savedErrno = errno
    cleanup()
    errno = savedErrno == 0 ? EINVAL : savedErrno
    message.withCString { pointer in
        perror(pointer)
    }
    exit(1)
}

func sameIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
    lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
}

func isUniqueRegularFile(_ value: stat) -> Bool {
    (value.st_mode & S_IFMT) == S_IFREG && value.st_nlink == 1
}

func hasPermissions(_ value: stat, _ permissions: mode_t) -> Bool {
    (value.st_mode & mode_t(0o777)) == permissions
}

for _ in 0..<64 {
    let candidate = ".\(iconName).tmp.\(String(arc4random(), radix: 16))\(String(arc4random(), radix: 16))"
    let descriptor = candidate.withCString { pointer in
        openat(resourcesFD, pointer,
            O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW,
            mode_t(0o600)
        )
    }
    if descriptor >= 0 {
        stageFD = descriptor
        stageBasename = candidate
        break
    }
    if errno != EEXIST {
        fail("unable to create staged icon")
    }
}
guard stageFD >= 0 else {
    fail("unable to allocate unique staged icon name")
}

var stagedCreated = stat()
guard fstat(stageFD, &stagedCreated) == 0,
      isUniqueRegularFile(stagedCreated),
      stagedCreated.st_uid == geteuid(),
      hasPermissions(stagedCreated, mode_t(0o600)) else {
    fail("staged icon is not a uniquely owned regular file")
}

guard lseek(sourceFD, 0, SEEK_SET) == 0 else {
    fail("unable to rewind source icon")
}
var buffer = [UInt8](repeating: 0, count: 64 * 1024)
while true {
    let bytesRead = buffer.withUnsafeMutableBytes { bytes in
        read(sourceFD, bytes.baseAddress, bytes.count)
    }
    if bytesRead == 0 {
        break
    }
    if bytesRead < 0 {
        if errno == EINTR {
            continue
        }
        fail("unable to read source icon")
    }

    var offset = 0
    while offset < bytesRead {
        let bytesWritten = buffer.withUnsafeBytes { bytes in
            write(stageFD,
                bytes.baseAddress!.advanced(by: offset),
                bytesRead - offset
            )
        }
        if bytesWritten < 0 {
            if errno == EINTR {
                continue
            }
            fail("unable to write staged icon")
        }
        if bytesWritten == 0 {
            errno = EIO
            fail("staged icon write made no progress")
        }
        offset += bytesWritten
    }
}

guard fsync(stageFD) == 0 else {
    fail("unable to sync staged icon")
}
guard fchmod(stageFD, mode_t(0o644)) == 0 else {
    fail("unable to set staged icon permissions")
}

var stagedReady = stat()
guard fstat(stageFD, &stagedReady) == 0,
      isUniqueRegularFile(stagedReady),
      hasPermissions(stagedReady, mode_t(0o644)) else {
    fail("staged icon failed pre-publication validation")
}
var stagedEntry = stat()
let stagedEntryResult = stageBasename.withCString { pointer in
    fstatat(resourcesFD, pointer, &stagedEntry, AT_SYMLINK_NOFOLLOW)
}
guard stagedEntryResult == 0,
      sameIdentity(stagedReady, stagedEntry),
      isUniqueRegularFile(stagedEntry),
      hasPermissions(stagedEntry, mode_t(0o644)) else {
    fail("staged icon entry changed before publication")
}

let renameResult = stageBasename.withCString { sourcePointer in
    iconName.withCString { destinationPointer in
        renameat(resourcesFD, sourcePointer, resourcesFD, destinationPointer)
    }
}
guard renameResult == 0 else {
    fail("unable to publish staged icon")
}
published = true

var stagedAfter = stat()
guard fstat(stageFD, &stagedAfter) == 0 else {
    fail("unable to revalidate staged icon descriptor")
}
var publishedEntry = stat()
let publishedEntryResult = iconName.withCString { pointer in
    fstatat(resourcesFD, pointer, &publishedEntry, AT_SYMLINK_NOFOLLOW)
}
guard publishedEntryResult == 0,
      sameIdentity(stagedAfter, publishedEntry),
      isUniqueRegularFile(publishedEntry),
      hasPermissions(publishedEntry, mode_t(0o644)) else {
    fail("published icon identity verification failed")
}

guard close(stageFD) == 0 else {
    fail("unable to close published icon")
}
stageFD = -1
stageBasename = ""
SWIFT
then
  die "unable to publish app icon"
fi

exec 8<&-
exec 7<&-

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>$EXECUTABLE_NAME</string>
<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
<key>CFBundleName</key><string>$APP_DISPLAY_NAME</string>
<key>CFBundleDisplayName</key><string>$APP_DISPLAY_NAME</string>
<key>CFBundleIconFile</key><string>$ICON_NAME</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$APP_VERSION</string>
<key>CFBundleVersion</key><string>$BUILD_VERSION</string>
<key>LSMinimumSystemVersion</key><string>$MIN_SYSTEM_VERSION</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST

/usr/bin/codesign --force --deep --sign - "$APP_BUNDLE"

open_app() { /usr/bin/open -n "$APP_BUNDLE"; }
case "$MODE" in
  run) open_app ;;
  --debug|debug) lldb -- "$APP_BINARY" ;;
  --logs|logs) open_app; /usr/bin/log stream --info --style compact --predicate "process == \"$EXECUTABLE_NAME\"" ;;
  --telemetry|telemetry) open_app; /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\"" ;;
  --verify|verify) open_app; sleep 1; pgrep -x "$EXECUTABLE_NAME" >/dev/null ;;
  *) echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2; exit 2 ;;
esac
