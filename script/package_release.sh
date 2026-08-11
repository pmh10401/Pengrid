#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "usage: $0 [--unsigned|--signed]" >&2
}

die() {
  echo "$*" >&2
  exit 1
}

if [[ $# -ne 1 ]]; then
  usage
  exit 2
fi

MODE="$1"
case "$MODE" in
  --unsigned|--signed) ;;
  *)
    usage
    exit 2
    ;;
esac

if [[ "$MODE" == "--signed" ]]; then
  missing_environment=()
  [[ -n "${DEVELOPER_ID_APPLICATION:-}" ]] || missing_environment+=(DEVELOPER_ID_APPLICATION)
  [[ -n "${NOTARY_PROFILE:-}" ]] || missing_environment+=(NOTARY_PROFILE)
  if (( ${#missing_environment[@]} > 0 )); then
    die "signed mode requires: ${missing_environment[*]}"
  fi
fi

TESTING="${BLOOM_RELEASE_TESTING:-0}"
TEST_TOOL_DIR="${BLOOM_RELEASE_TEST_TOOL_DIR:-}"
if [[ "$TESTING" == 1 ]]; then
  [[ -n "$TEST_TOOL_DIR" && -d "$TEST_TOOL_DIR" && ! -L "$TEST_TOOL_DIR" ]] \
    || die 'test tool directory must be a real directory'
  TEST_TOOL_DIR="$(cd -P "$TEST_TOOL_DIR" && pwd -P)"
fi

tool_path() {
  local production_path="$1"
  local test_path
  if [[ "$TESTING" == 1 ]]; then
    test_path="$TEST_TOOL_DIR/${production_path##*/}"
    if [[ -x "$test_path" ]]; then
      echo "$test_path"
      return
    fi
  fi
  echo "$production_path"
}

APP_DISPLAY_NAME="Pengrid"
EXECUTABLE_NAME="BloomFileManager"
ICON_NAME="Pengrid.icns"
NOTICE_NAME="THIRD_PARTY_NOTICES.md"
BUNDLE_ID="com.minho.BloomFileManager"
MIN_SYSTEM_VERSION="15.0"
APP_VERSION="1.3.0"
BUILD_VERSION="8"
DMG_FORMAT="UDBZ"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd -P "$SCRIPT_DIR/.." && pwd -P)"
ICON_SOURCE="$ROOT_DIR/Assets/Pengrid/$ICON_NAME"
NOTICE_SOURCE="$ROOT_DIR/$NOTICE_NAME"
DIST_DIR="$ROOT_DIR/dist"
RELEASE_DIR="$DIST_DIR/release"
APP_BUNDLE="$RELEASE_DIR/$APP_DISPLAY_NAME.app"
ZIP_PATH="$RELEASE_DIR/$APP_DISPLAY_NAME.zip"
DMG_PATH="$RELEASE_DIR/$APP_DISPLAY_NAME.dmg"

if [[ "$TESTING" == 1 ]]; then
  RAW_TEST_TEMP_DIR="$(/usr/bin/getconf DARWIN_USER_TEMP_DIR)"
  [[ -n "$RAW_TEST_TEMP_DIR" && -d "$RAW_TEST_TEMP_DIR" ]] \
    || die 'test mode requires DARWIN_USER_TEMP_DIR'
  TEST_TEMP_DIR="$(cd -P "$RAW_TEST_TEMP_DIR" && pwd -P)"
  [[ "$ROOT_DIR" == "$TEST_TEMP_DIR"/* && -f "$ROOT_DIR/.bloom-release-test-fixture" \
      && ! -L "$ROOT_DIR/.bloom-release-test-fixture" ]] \
    || die 'release test hooks are restricted to marked temporary fixtures'
fi

GETCONF="$(tool_path /usr/bin/getconf)"
HDIUTIL="$(tool_path /usr/bin/hdiutil)"
XATTR="$(tool_path /usr/bin/xattr)"
UNAME="$(tool_path /usr/bin/uname)"
XCODEBUILD="$(tool_path /usr/bin/xcodebuild)"
XCRUN="$(tool_path /usr/bin/xcrun)"
SECURITY="$(tool_path /usr/bin/security)"
FILE_TOOL="$(tool_path /usr/bin/file)"
LIPO="$(tool_path /usr/bin/lipo)"
CODESIGN="$(tool_path /usr/bin/codesign)"
OTOOL="$(tool_path /usr/bin/otool)"
PLUTIL="$(tool_path /usr/bin/plutil)"
DITTO="$(tool_path /usr/bin/ditto)"
ZIPINFO="$(tool_path /usr/bin/zipinfo)"
MKDIR="$(tool_path /bin/mkdir)"
CHMOD="$(tool_path /bin/chmod)"
CP="$(tool_path /bin/cp)"
MV="$(tool_path /bin/mv)"
LN="$(tool_path /bin/ln)"
UNLINK="$(tool_path /bin/unlink)"
FIND="$(tool_path /usr/bin/find)"
MKTEMP="$(tool_path /usr/bin/mktemp)"
CMP="$(tool_path /usr/bin/cmp)"
STAT="$(tool_path /usr/bin/stat)"
READLINK="$(tool_path /usr/bin/readlink)"
SHASUM="$(tool_path /usr/bin/shasum)"
CUT="$(tool_path /usr/bin/cut)"
GREP="$(tool_path /usr/bin/grep)"

if [[ "$TESTING" == 1 && -x "$TEST_TOOL_DIR/swift" ]]; then
  SWIFT_BIN="$TEST_TOOL_DIR/swift"
else
  SWIFT_BIN="$(command -v swift)"
fi

is_strict_child() {
  local candidate="$1"
  local allowed_root="$2"
  [[ "$candidate" == "$allowed_root"/* && "$candidate" != "$allowed_root" ]]
}

assert_strict_child() {
  is_strict_child "$1" "$2" || die "unsafe path escapes allowed root: $1"
}

has_no_symlink_components() {
  local target="$1"
  local current=''
  local component
  [[ "$target" == /* ]] || return 1
  IFS='/' read -r -a components <<<"${target#/}"
  for component in "${components[@]}"; do
    [[ -n "$component" ]] || continue
    current="$current/$component"
    if [[ -L "$current" ]]; then
      return 1
    fi
  done
  return 0
}

assert_no_symlink_components() {
  has_no_symlink_components "$1" || die "symbolic link component is not allowed: $1"
}

assert_no_symlink_parents() {
  local parent
  parent="$(dirname "$1")"
  assert_no_symlink_components "$parent"
}

validate_existing_directory_or_absent() {
  local path="$1"
  assert_no_symlink_components "$path"
  if [[ -e "$path" && ! -d "$path" ]]; then
    die "expected directory path: $path"
  fi
}

ensure_directory() {
  local path="$1"
  local allowed_root="$2"
  assert_strict_child "$path" "$allowed_root"
  assert_no_symlink_components "$path"
  "$MKDIR" -p "$path"
  assert_no_symlink_components "$path"
  [[ -d "$path" ]] || die "failed to create directory: $path"
}

safe_delete_leaf() {
  local target="$1"
  local allowed_root="$2"
  assert_strict_child "$target" "$allowed_root"
  assert_no_symlink_parents "$target"
  if [[ -L "$target" || -f "$target" ]]; then
    "$UNLINK" "$target"
  elif [[ -d "$target" ]]; then
    "$FIND" "$target" -depth -delete
  elif [[ -e "$target" ]]; then
    die "refusing to delete unsupported filesystem entry: $target"
  fi
}

safe_move() {
  local source="$1"
  local destination="$2"
  local source_root="$3"
  local destination_root="$4"
  assert_strict_child "$source" "$source_root"
  assert_strict_child "$destination" "$destination_root"
  assert_no_symlink_parents "$source"
  assert_no_symlink_parents "$destination"
  [[ -e "$source" || -L "$source" ]] || die "move source is absent: $source"
  [[ ! -e "$destination" && ! -L "$destination" ]] \
    || die "move destination already exists: $destination"
  "$MV" "$source" "$destination"
}

entry_identity() {
  "$STAT" -f '%d:%i' "$1" 2>/dev/null
}

nonfatal_delete_owned_leaf() {
  local target="$1"
  local allowed_root="$2"
  local expected_identity="$3"
  local actual_identity
  is_strict_child "$target" "$allowed_root" || return 1
  has_no_symlink_components "$(dirname "$target")" || return 1
  [[ -e "$target" || -L "$target" ]] || return 0
  actual_identity="$(entry_identity "$target" || true)"
  [[ -n "$expected_identity" && "$actual_identity" == "$expected_identity" ]] || return 1
  if [[ -L "$target" || -f "$target" ]]; then
    "$UNLINK" "$target"
  elif [[ -d "$target" ]]; then
    "$FIND" "$target" -depth -delete
  else
    return 1
  fi
}

nonfatal_restore_owned_backup() {
  local backup="$1"
  local destination="$2"
  local allowed_root="$3"
  local expected_identity="$4"
  local backup_identity
  is_strict_child "$backup" "$allowed_root" || return 1
  is_strict_child "$destination" "$allowed_root" || return 1
  has_no_symlink_components "$(dirname "$backup")" || return 1
  has_no_symlink_components "$(dirname "$destination")" || return 1
  [[ ! -e "$destination" && ! -L "$destination" ]] || return 1
  [[ -e "$backup" || -L "$backup" ]] || return 1
  backup_identity="$(entry_identity "$backup" || true)"
  [[ -n "$expected_identity" && "$backup_identity" == "$expected_identity" ]] || return 1
  "$MV" "$backup" "$destination"
}

is_file_provider_managed() {
  local candidate="$ROOT_DIR"
  local attributes
  if [[ "$TESTING" == 1 && "${BLOOM_RELEASE_TEST_FORCE_FILE_PROVIDER:-0}" == 1 ]]; then
    return 0
  fi
  while true; do
    attributes="$("$XATTR" "$candidate" 2>/dev/null || true)"
    if echo "$attributes" \
        | "$GREP" -Eq '^com\.apple\.(file-provider|fileprovider|icloud\.desktop)'; then
      return 0
    fi
    [[ "$candidate" == "/" ]] && return 1
    candidate="$(dirname "$candidate")"
  done
}

assert_no_symlink_components "$ROOT_DIR"
[[ "$ICON_SOURCE" == "$ROOT_DIR/Assets/Pengrid/$ICON_NAME" ]] \
  || die "unsafe app icon path: $ICON_SOURCE"
[[ -f "$ICON_SOURCE" && ! -L "$ICON_SOURCE" ]] \
  || die "app icon must be a regular file: $ICON_SOURCE"
assert_no_symlink_components "$ICON_SOURCE"
if ! exec 8<"$ICON_SOURCE" || ! exec 19<"$ICON_SOURCE" || ! exec 16<"$ICON_SOURCE"; then
  die "unable to open app icon: $ICON_SOURCE"
fi
[[ "$NOTICE_SOURCE" == "$ROOT_DIR/$NOTICE_NAME" ]] \
  || die "unsafe third-party notice path: $NOTICE_SOURCE"
[[ -f "$NOTICE_SOURCE" && ! -L "$NOTICE_SOURCE" ]] \
  || die "third-party notice must be a regular file: $NOTICE_SOURCE"
assert_no_symlink_components "$NOTICE_SOURCE"
if ! exec 9<"$NOTICE_SOURCE" || ! exec 20<"$NOTICE_SOURCE" || ! exec 21<"$NOTICE_SOURCE"; then
  die "unable to open third-party notice: $NOTICE_SOURCE"
fi
if ! icon_source_path_identity="$("$STAT" -f '%d:%i:%HT:%u:%l:%Lp' "$ICON_SOURCE")"; then
  die "unable to inspect app icon path: $ICON_SOURCE"
fi
if ! icon_source_copy_identity="$("$STAT" -f '%d:%i:%HT:%u:%l:%Lp' <&8)" \
    || ! icon_source_staged_cmp_identity="$("$STAT" -f '%d:%i:%HT:%u:%l:%Lp' <&19)" \
    || ! icon_source_archive_cmp_identity="$("$STAT" -f '%d:%i:%HT:%u:%l:%Lp' <&16)"; then
  die "unable to inspect opened app icon: $ICON_SOURCE"
fi
if ! notice_source_path_identity="$("$STAT" -f '%d:%i:%HT:%u:%l:%Lp' "$NOTICE_SOURCE")"; then
  die "unable to inspect third-party notice path: $NOTICE_SOURCE"
fi
if ! notice_source_copy_identity="$("$STAT" -f '%d:%i:%HT:%u:%l:%Lp' <&9)" \
    || ! notice_source_staged_cmp_identity="$("$STAT" -f '%d:%i:%HT:%u:%l:%Lp' <&20)" \
    || ! notice_source_archive_cmp_identity="$("$STAT" -f '%d:%i:%HT:%u:%l:%Lp' <&21)"; then
  die "unable to inspect opened third-party notice: $NOTICE_SOURCE"
fi
IFS=: read -r icon_source_device icon_source_inode icon_source_type \
  icon_source_uid icon_source_links icon_source_mode <<<"$icon_source_path_identity"
[[ "$icon_source_type" == "Regular File" \
    && "$icon_source_links" == 1 \
    && ! -L "$ICON_SOURCE" \
    && "$icon_source_path_identity" == "$icon_source_copy_identity" \
    && "$icon_source_path_identity" == "$icon_source_staged_cmp_identity" \
    && "$icon_source_path_identity" == "$icon_source_archive_cmp_identity" ]] \
  || die "app icon path changed or is not a unique regular file: $ICON_SOURCE"
IFS=: read -r notice_source_device notice_source_inode notice_source_type \
  notice_source_uid notice_source_links notice_source_mode <<<"$notice_source_path_identity"
[[ "$notice_source_type" == "Regular File" \
    && "$notice_source_links" == 1 \
    && ! -L "$NOTICE_SOURCE" \
    && "$notice_source_path_identity" == "$notice_source_copy_identity" \
    && "$notice_source_path_identity" == "$notice_source_staged_cmp_identity" \
    && "$notice_source_path_identity" == "$notice_source_archive_cmp_identity" ]] \
  || die "third-party notice path changed or is not a unique regular file: $NOTICE_SOURCE"
assert_strict_child "$DIST_DIR" "$ROOT_DIR"
assert_strict_child "$RELEASE_DIR" "$ROOT_DIR"
validate_existing_directory_or_absent "$DIST_DIR"
validate_existing_directory_or_absent "$RELEASE_DIR"

RAW_USER_CACHE_DIR="$("$GETCONF" DARWIN_USER_CACHE_DIR)"
[[ -n "$RAW_USER_CACHE_DIR" && -d "$RAW_USER_CACHE_DIR" ]] \
  || die 'DARWIN_USER_CACHE_DIR is unavailable'
USER_CACHE_DIR="$(cd -P "$RAW_USER_CACHE_DIR" && pwd -P)"
assert_no_symlink_components "$USER_CACHE_DIR"
ROOT_FINGERPRINT="$(echo "$ROOT_DIR" | "$SHASUM" -a 256 | "$CUT" -c1-12)"
CACHE_BASE="$USER_CACHE_DIR/$BUNDLE_ID"
PRIVATE_ROOT="$CACHE_BASE/release-$ROOT_FINGERPRINT"
STAGING_PARENT="$PRIVATE_ROOT/staging"
VERSIONS_DIR="$PRIVATE_ROOT/versions"
DIAGNOSTICS_ROOT="$PRIVATE_ROOT/notary-diagnostics"
ICON_COPY_MODULE_CACHE="$PRIVATE_ROOT/icon-copy-module-cache"
assert_strict_child "$CACHE_BASE" "$USER_CACHE_DIR"
assert_strict_child "$PRIVATE_ROOT" "$CACHE_BASE"
assert_strict_child "$STAGING_PARENT" "$PRIVATE_ROOT"
assert_strict_child "$VERSIONS_DIR" "$PRIVATE_ROOT"
assert_strict_child "$DIAGNOSTICS_ROOT" "$PRIVATE_ROOT"
assert_strict_child "$ICON_COPY_MODULE_CACHE" "$PRIVATE_ROOT"
validate_existing_directory_or_absent "$CACHE_BASE"
validate_existing_directory_or_absent "$PRIVATE_ROOT"
validate_existing_directory_or_absent "$STAGING_PARENT"
validate_existing_directory_or_absent "$VERSIONS_DIR"
validate_existing_directory_or_absent "$DIAGNOSTICS_ROOT"
validate_existing_directory_or_absent "$ICON_COPY_MODULE_CACHE"

CACHE_BACKED_RELEASE=false
if is_file_provider_managed; then
  CACHE_BACKED_RELEASE=true
fi

[[ "$("$UNAME" -m)" == arm64 ]] \
  || die "$APP_DISPLAY_NAME release packaging requires an Apple Silicon (arm64) host."

if [[ "$MODE" == "--signed" ]]; then
  [[ "$DEVELOPER_ID_APPLICATION" =~ ^Developer\ ID\ Application:\ .+\ \([A-Z0-9]{10}\)$ ]] \
    || die 'DEVELOPER_ID_APPLICATION must be an exact Developer ID Application identity label.'
  "$XCODEBUILD" -version >/dev/null 2>&1 \
    || die 'signed mode requires full Xcode to be selected with xcode-select.'
  "$XCRUN" --find notarytool >/dev/null 2>&1 \
    || die 'signed mode requires notarytool from full Xcode.'
  "$XCRUN" --find stapler >/dev/null 2>&1 \
    || die 'signed mode requires stapler from full Xcode.'
  identity_matches="$("$SECURITY" find-identity -p codesigning -v 2>/dev/null \
    | "$GREP" -F -c -- "\"$DEVELOPER_ID_APPLICATION\"" || true)"
  [[ "$identity_matches" == 1 ]] \
    || die 'the exact Developer ID Application identity is unavailable or ambiguous.'
  # Validate the keychain profile before tests, builds, or filesystem mutation.
  "$XCRUN" notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null \
    || die 'the notarytool keychain profile is unavailable.'
fi

echo 'Running tests...'
"$SWIFT_BIN" test --enable-swift-testing --no-parallel --filter BloomFileManagerTests --package-path "$ROOT_DIR"

echo 'Building arm64 release product...'
"$SWIFT_BIN" build --package-path "$ROOT_DIR" -c release --arch arm64
BUILD_BIN_DIR="$("$SWIFT_BIN" build --package-path "$ROOT_DIR" -c release --arch arm64 --show-bin-path)"
BUILD_BINARY="$BUILD_BIN_DIR/$EXECUTABLE_NAME"
[[ -x "$BUILD_BINARY" ]] || die "release executable not found: $BUILD_BINARY"

ensure_directory "$DIST_DIR" "$ROOT_DIR"
ensure_directory "$RELEASE_DIR" "$ROOT_DIR"
ensure_directory "$CACHE_BASE" "$USER_CACHE_DIR"
ensure_directory "$PRIVATE_ROOT" "$CACHE_BASE"
ensure_directory "$STAGING_PARENT" "$PRIVATE_ROOT"
ensure_directory "$VERSIONS_DIR" "$PRIVATE_ROOT"
ensure_directory "$DIAGNOSTICS_ROOT" "$PRIVATE_ROOT"
ensure_directory "$ICON_COPY_MODULE_CACHE" "$PRIVATE_ROOT"
"$CHMOD" 700 \
  "$CACHE_BASE" \
  "$PRIVATE_ROOT" \
  "$STAGING_PARENT" \
  "$VERSIONS_DIR" \
  "$DIAGNOSTICS_ROOT" \
  "$ICON_COPY_MODULE_CACHE"

STAGING_ROOT="$("$MKTEMP" -d "$STAGING_PARENT/transaction.XXXXXX")"
assert_strict_child "$STAGING_ROOT" "$STAGING_PARENT"
assert_no_symlink_components "$STAGING_ROOT"
STAGING_ROOT_ID="$(entry_identity "$STAGING_ROOT")"
TRANSACTION_ID="${STAGING_ROOT##*.}"
STAGING_APP="$STAGING_ROOT/$APP_DISPLAY_NAME.app"
STAGING_CONTENTS="$STAGING_APP/Contents"
STAGING_MACOS="$STAGING_CONTENTS/MacOS"
STAGING_RESOURCES="$STAGING_CONTENTS/Resources"
STAGING_BINARY="$STAGING_MACOS/$EXECUTABLE_NAME"
STAGING_ICON="$STAGING_RESOURCES/$ICON_NAME"
STAGING_NOTICE="$STAGING_RESOURCES/$NOTICE_NAME"
STAGING_INFO_PLIST="$STAGING_CONTENTS/Info.plist"
SUBMISSION_ZIP="$STAGING_ROOT/$APP_DISPLAY_NAME-submission.zip"
FINAL_STAGED_ZIP="$STAGING_ROOT/$APP_DISPLAY_NAME.zip"
FINAL_STAGED_DMG="$STAGING_ROOT/$APP_DISPLAY_NAME.dmg"
NOTARY_RESULT_JSON="$STAGING_ROOT/notary-result.json"
NOTARY_RESULT_PLIST="$STAGING_ROOT/notary-result.plist"
PUBLIC_NEW_APP=''
PUBLIC_BACKUP_APP=''
PUBLIC_NEW_ZIP=''
PUBLIC_BACKUP_ZIP=''
PUBLIC_NEW_DMG=''
PUBLIC_BACKUP_DMG=''
NEW_VERSION_DIR=''
NEW_VERSION_ID=''
OLD_OWNED_VERSION_DIR=''
OLD_OWNED_VERSION_ID=''
OLD_APP_ID=''
OLD_ZIP_ID=''
OLD_DMG_ID=''
NEW_APP_ID=''
NEW_ZIP_ID=''
NEW_DMG_ID=''
PUBLICATION_STARTED=false
PUBLICATION_COMMITTED=false
cleanup() {
  local cleanup_status=0
  trap - INT TERM
  if [[ "$PUBLICATION_STARTED" == true && "$PUBLICATION_COMMITTED" != true ]]; then
    rollback_publication || cleanup_status=1
  fi
  if [[ "$PUBLICATION_COMMITTED" != true ]]; then
    if [[ -n "$PUBLIC_NEW_APP" ]]; then
      nonfatal_delete_owned_leaf "$PUBLIC_NEW_APP" "$RELEASE_DIR" "$NEW_APP_ID" || cleanup_status=1
    fi
    if [[ -n "$PUBLIC_NEW_ZIP" ]]; then
      nonfatal_delete_owned_leaf "$PUBLIC_NEW_ZIP" "$RELEASE_DIR" "$NEW_ZIP_ID" || cleanup_status=1
    fi
    if [[ -n "$PUBLIC_NEW_DMG" ]]; then
      nonfatal_delete_owned_leaf "$PUBLIC_NEW_DMG" "$RELEASE_DIR" "$NEW_DMG_ID" || cleanup_status=1
    fi
    if [[ -n "$NEW_VERSION_DIR" ]]; then
      if [[ ! -L "$APP_BUNDLE" || "$("$READLINK" "$APP_BUNDLE" 2>/dev/null || true)" != "$NEW_VERSION_DIR/$APP_DISPLAY_NAME.app" ]]; then
        nonfatal_delete_owned_leaf "$NEW_VERSION_DIR" "$VERSIONS_DIR" "$NEW_VERSION_ID" || cleanup_status=1
      else
        cleanup_status=1
      fi
    fi
  fi
  if [[ -n "${STAGING_ROOT:-}" ]]; then
    nonfatal_delete_owned_leaf "$STAGING_ROOT" "$STAGING_PARENT" "$STAGING_ROOT_ID" || cleanup_status=1
  fi
  if [[ $cleanup_status -ne 0 ]]; then
    echo 'warning: release cleanup retained an entry whose ownership could not be proven.' >&2
  fi
}
trap cleanup EXIT

"$MKDIR" -p "$STAGING_MACOS" "$STAGING_RESOURCES"
assert_no_symlink_components "$STAGING_RESOURCES"
if ! exec 17<"$STAGING_RESOURCES"; then
  die "unable to open app resources directory: $STAGING_RESOURCES"
fi
if ! resources_path_identity="$("$STAT" -f '%d:%i:%HT:%u:%l:%Lp' "$STAGING_RESOURCES")"; then
  die "unable to inspect app resources path: $STAGING_RESOURCES"
fi
if ! resources_fd_identity="$("$STAT" -f '%d:%i:%HT:%u:%l:%Lp' <&17)"; then
  die "unable to inspect opened app resources directory: $STAGING_RESOURCES"
fi
IFS=: read -r resources_device resources_inode resources_type \
  resources_uid resources_links resources_mode <<<"$resources_path_identity"
[[ "$resources_type" == "Directory" && "$resources_path_identity" == "$resources_fd_identity" ]] \
  || die "app resources path changed or is not a directory: $STAGING_RESOURCES"

"$CP" "$BUILD_BINARY" "$STAGING_BINARY"
"$CHMOD" +x "$STAGING_BINARY"

publish_resource() {
  local resource_name="$1"
  local destination="$2"
  local -a swift_resource_helper_arguments
  swift_resource_helper_arguments=(-module-cache-path "$ICON_COPY_MODULE_CACHE" - "$resource_name")
  if [[ "$TESTING" == 1 ]]; then
    export BLOOM_RELEASE_TEST_ICON_HELPER_DEST="$destination"
  else
    unset BLOOM_RELEASE_TEST_ICON_HELPER_DEST
  fi
  if ! "$SWIFT_BIN" "${swift_resource_helper_arguments[@]}" <<'SWIFT'
import Darwin

let resourcesFD: Int32 = 17
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
    return 1
  fi
}

publish_resource "$ICON_NAME" "$STAGING_ICON" || die "unable to publish app icon"
exec 8<&-
exec 8<&9
publish_resource "$NOTICE_NAME" "$STAGING_NOTICE" \
  || die "unable to publish third-party notice"
exec 9<&-
unset BLOOM_RELEASE_TEST_ICON_HELPER_DEST
exec 8<&-
exec 17<&-

"$CMP" -s /dev/fd/19 "$STAGING_ICON" \
  || die 'staged app icon differs from the canonical icon.'
"$CMP" -s /dev/fd/20 "$STAGING_NOTICE" \
  || die 'staged third-party notice differs from the repository notice.'
exec 19<&-
exec 20<&-

cat >"$STAGING_INFO_PLIST" <<PLIST
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

assert_no_openssl_dependency() {
  local binary="$1"
  local dependencies
  # otool -L is required for release protected-ZIP verification.
  dependencies="$("$OTOOL" -L "$binary")" \
    || die "unable to inspect native linkage: $binary"
  if echo "$dependencies" | "$GREP" -Eiq 'libssl|libcrypto'; then
    die 'unexpected OpenSSL dependency in Pengrid binary'
  fi
}

"$PLUTIL" -lint "$STAGING_INFO_PLIST" >/dev/null
binary_description="$("$FILE_TOOL" "$STAGING_BINARY")"
echo "$binary_description"
[[ "$binary_description" == *arm64* ]] || die 'release executable lacks arm64.'
architectures="$("$LIPO" -archs "$STAGING_BINARY")"
[[ "$architectures" == arm64 ]] || die "release executable must be exactly arm64; found: $architectures"
assert_no_openssl_dependency "$STAGING_BINARY"

"$XATTR" -cr "$STAGING_APP"
if [[ "$MODE" == "--unsigned" ]]; then
  "$CODESIGN" --force --deep --sign - "$STAGING_APP"
else
  "$CODESIGN" --force --deep --options runtime --timestamp \
    --sign "$DEVELOPER_ID_APPLICATION" "$STAGING_APP"
fi
"$CODESIGN" --verify --deep --strict --verbose=2 "$STAGING_APP"
entitlements_output="$("$CODESIGN" -d --entitlements :- "$STAGING_APP" 2>&1 || true)"
[[ "$entitlements_output" != *com.apple.security.app-sandbox* ]] \
  || die 'App Sandbox entitlement is not permitted for direct distribution.'

if [[ "$MODE" == "--signed" ]]; then
  signing_details="$("$CODESIGN" -dvvv --verbose=4 "$STAGING_APP" 2>&1)"
  echo "$signing_details" | "$GREP" -Fqx "Authority=$DEVELOPER_ID_APPLICATION" \
    || die 'signed app authority does not match the requested Developer ID Application identity.'
  echo "$signing_details" | "$GREP" -Eq '^CodeDirectory .*flags=.*\(runtime\)' \
    || die 'signed app does not have hardened runtime enabled.'
  timestamp_line="$(echo "$signing_details" | "$GREP" -E '^Timestamp=.+$' || true)"
  [[ -n "$timestamp_line" && "$timestamp_line" != Timestamp=none ]] \
    || die 'signed app does not contain a secure timestamp.'
fi

verify_archive() {
  local archive="$1"
  local verification_root="$2"
  local extracted_app="$verification_root/$APP_DISPLAY_NAME.app"
  local extracted_binary="$extracted_app/Contents/MacOS/$EXECUTABLE_NAME"
  local extracted_icon="$extracted_app/Contents/Resources/$ICON_NAME"
  local extracted_notice="$extracted_app/Contents/Resources/$NOTICE_NAME"
  "$MKDIR" "$verification_root"
  first_entry="$("$ZIPINFO" -1 "$archive" | /usr/bin/head -1)"
  [[ "$first_entry" == "$APP_DISPLAY_NAME.app/" ]] || die 'archive does not keep the app as its top-level parent.'
  symlink_count="$("$ZIPINFO" -l "$archive" \
    | /usr/bin/awk '$1 ~ /^l/ {count++} END {print count+0}')"
  [[ "$symlink_count" == 0 ]] || die 'archive contains symbolic-link entries.'
  "$DITTO" -x -k "$archive" "$verification_root"
  [[ -d "$extracted_app" && ! -L "$extracted_app" ]] || die 'archive did not extract a real app bundle.'
  "$CODESIGN" --verify --deep --strict --verbose=2 "$extracted_app"
  assert_no_openssl_dependency "$extracted_binary"
  [[ "$("$LIPO" -archs "$extracted_binary")" == arm64 ]] \
    || die 'extracted archive executable is not exactly arm64.'
  "$PLUTIL" -lint "$extracted_app/Contents/Info.plist" >/dev/null
  "$CMP" -s /dev/fd/16 "$extracted_icon" \
    || die 'extracted archive icon differs from the canonical icon.'
  "$CMP" -s /dev/fd/21 "$extracted_notice" \
    || die 'extracted archive notice differs from the repository notice.'
  extracted_entitlements="$("$CODESIGN" -d --entitlements :- "$extracted_app" 2>&1 || true)"
  [[ "$extracted_entitlements" != *com.apple.security.app-sandbox* ]] \
    || die 'extracted archive unexpectedly contains App Sandbox entitlement.'
}

if [[ "$MODE" == "--signed" ]]; then
  "$DITTO" -c -k --keepParent "$STAGING_APP" "$SUBMISSION_ZIP"
  SUBMIT_COMMAND_SUCCEEDED=true
  if ! "$XCRUN" notarytool submit "$SUBMISSION_ZIP" \
      --keychain-profile "$NOTARY_PROFILE" --wait --output-format json >"$NOTARY_RESULT_JSON"; then
    SUBMIT_COMMAND_SUCCEEDED=false
  fi
  DIAGNOSTIC_RUN="$DIAGNOSTICS_ROOT/transaction-$TRANSACTION_ID"
  ensure_directory "$DIAGNOSTIC_RUN" "$DIAGNOSTICS_ROOT"
  "$CHMOD" 700 "$DIAGNOSTIC_RUN"
  "$CP" "$NOTARY_RESULT_JSON" "$DIAGNOSTIC_RUN/submission.json"
  "$CHMOD" 600 "$DIAGNOSTIC_RUN/submission.json"
  if ! "$PLUTIL" -convert xml1 -o "$NOTARY_RESULT_PLIST" "$NOTARY_RESULT_JSON"; then
    echo "notary diagnostics preserved at: $DIAGNOSTIC_RUN" >&2
    die 'notarytool did not return a valid structured result.'
  fi
  "$PLUTIL" -lint "$NOTARY_RESULT_PLIST" >/dev/null
  "$CP" "$NOTARY_RESULT_PLIST" "$DIAGNOSTIC_RUN/submission.plist"
  "$CHMOD" 600 "$DIAGNOSTIC_RUN/submission.plist"
  if ! NOTARY_STATUS="$("$PLUTIL" -extract status raw "$NOTARY_RESULT_PLIST" 2>/dev/null)"; then
    echo "notary diagnostics preserved at: $DIAGNOSTIC_RUN" >&2
    die 'notarytool structured result is missing required status.'
  fi
  if ! SUBMISSION_ID="$("$PLUTIL" -extract id raw "$NOTARY_RESULT_PLIST" 2>/dev/null)"; then
    echo "notary diagnostics preserved at: $DIAGNOSTIC_RUN" >&2
    die 'notarytool structured result is missing required id.'
  fi
  if [[ ! "$SUBMISSION_ID" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]; then
    echo "notary diagnostics preserved at: $DIAGNOSTIC_RUN" >&2
    die 'notarytool returned an unsafe submission identifier.'
  fi
  if [[ "$SUBMIT_COMMAND_SUCCEEDED" != true || "$NOTARY_STATUS" != Accepted ]]; then
    "$XCRUN" notarytool log "$SUBMISSION_ID" \
      --keychain-profile "$NOTARY_PROFILE" "$DIAGNOSTIC_RUN/notary-log.json" || true
    [[ ! -e "$DIAGNOSTIC_RUN/notary-log.json" ]] || "$CHMOD" 600 "$DIAGNOSTIC_RUN/notary-log.json"
    echo "notary diagnostics preserved at: $DIAGNOSTIC_RUN" >&2
    die "notarization was not accepted (submission $SUBMISSION_ID, status $NOTARY_STATUS)."
  fi
  echo "Notarization Accepted (submission $SUBMISSION_ID)."
  "$XCRUN" stapler staple "$STAGING_APP"
  "$XCRUN" stapler validate "$STAGING_APP"
  "$CODESIGN" --verify --deep --strict --verbose=2 "$STAGING_APP"
  "$DITTO" -c -k --keepParent "$STAGING_APP" "$FINAL_STAGED_ZIP"
  verify_archive "$FINAL_STAGED_ZIP" "$STAGING_ROOT/verified-archive"
fi

create_dmg() {
  local source_app="$1"
  local destination="$2"
  "$HDIUTIL" create -volname "$APP_DISPLAY_NAME" -srcfolder "$source_app" \
    -ov -format "$DMG_FORMAT" "$destination"
  "$HDIUTIL" verify "$destination" >/dev/null
}

create_dmg "$STAGING_APP" "$FINAL_STAGED_DMG"

owned_file_provider_version_dir() {
  local public_target target_parent canonical_target version_dir
  [[ "$CACHE_BACKED_RELEASE" == true && -L "$APP_BUNDLE" ]] || return 1
  public_target="$("$READLINK" "$APP_BUNDLE" 2>/dev/null || true)"
  [[ "$public_target" == /* && -d "$public_target" && ! -L "$public_target" ]] || return 1
  has_no_symlink_components "$public_target" || return 1
  target_parent="$(cd -P "$(dirname "$public_target")" && pwd -P)"
  canonical_target="$target_parent/$(basename "$public_target")"
  [[ "$canonical_target" == "$public_target" && "$(basename "$canonical_target")" == "$APP_DISPLAY_NAME.app" ]] \
    || return 1
  version_dir="$target_parent"
  [[ "$(dirname "$version_dir")" == "$VERSIONS_DIR" ]] || return 1
  is_strict_child "$version_dir" "$VERSIONS_DIR" || return 1
  echo "$version_dir"
}

if [[ -e "$APP_BUNDLE" || -L "$APP_BUNDLE" ]]; then
  OLD_APP_ID="$(entry_identity "$APP_BUNDLE")"
fi
if [[ -e "$ZIP_PATH" || -L "$ZIP_PATH" ]]; then
  OLD_ZIP_ID="$(entry_identity "$ZIP_PATH")"
fi
if [[ -e "$DMG_PATH" || -L "$DMG_PATH" ]]; then
  OLD_DMG_ID="$(entry_identity "$DMG_PATH")"
fi
OLD_OWNED_VERSION_DIR="$(owned_file_provider_version_dir || true)"
if [[ -n "$OLD_OWNED_VERSION_DIR" ]]; then
  OLD_OWNED_VERSION_ID="$(entry_identity "$OLD_OWNED_VERSION_DIR")"
fi

PUBLIC_NEW_APP="$RELEASE_DIR/.$APP_DISPLAY_NAME.app.new-$TRANSACTION_ID"
PUBLIC_BACKUP_APP="$RELEASE_DIR/.$APP_DISPLAY_NAME.app.backup-$TRANSACTION_ID"
PUBLIC_NEW_ZIP="$RELEASE_DIR/.$APP_DISPLAY_NAME.zip.new-$TRANSACTION_ID"
PUBLIC_BACKUP_ZIP="$RELEASE_DIR/.$APP_DISPLAY_NAME.zip.backup-$TRANSACTION_ID"
PUBLIC_NEW_DMG="$RELEASE_DIR/.$APP_DISPLAY_NAME.dmg.new-$TRANSACTION_ID"
PUBLIC_BACKUP_DMG="$RELEASE_DIR/.$APP_DISPLAY_NAME.dmg.backup-$TRANSACTION_ID"
for publication_path in "$PUBLIC_NEW_APP" "$PUBLIC_BACKUP_APP" "$PUBLIC_NEW_ZIP" "$PUBLIC_BACKUP_ZIP" "$PUBLIC_NEW_DMG" "$PUBLIC_BACKUP_DMG"; do
  assert_strict_child "$publication_path" "$RELEASE_DIR"
  assert_no_symlink_parents "$publication_path"
  [[ ! -e "$publication_path" && ! -L "$publication_path" ]] \
    || die "publication scratch path already exists: $publication_path"
done

if [[ "$CACHE_BACKED_RELEASE" == true ]]; then
  NEW_VERSION_DIR="$VERSIONS_DIR/$TRANSACTION_ID"
  ensure_directory "$NEW_VERSION_DIR" "$VERSIONS_DIR"
  NEW_VERSION_ID="$(entry_identity "$NEW_VERSION_DIR")"
  VERSION_APP="$NEW_VERSION_DIR/$APP_DISPLAY_NAME.app"
  safe_move "$STAGING_APP" "$VERSION_APP" "$STAGING_ROOT" "$NEW_VERSION_DIR"
  "$LN" -s "$VERSION_APP" "$PUBLIC_NEW_APP"
  "$CODESIGN" --verify --deep --strict --verbose=2 "$PUBLIC_NEW_APP"
else
  safe_move "$STAGING_APP" "$PUBLIC_NEW_APP" "$STAGING_ROOT" "$RELEASE_DIR"
  "$CODESIGN" --verify --deep --strict --verbose=2 "$PUBLIC_NEW_APP"
fi
NEW_APP_ID="$(entry_identity "$PUBLIC_NEW_APP")"

if [[ "$MODE" == "--signed" ]]; then
  "$CP" "$FINAL_STAGED_ZIP" "$PUBLIC_NEW_ZIP"
  "$CMP" -s "$FINAL_STAGED_ZIP" "$PUBLIC_NEW_ZIP" \
    || die 'public ZIP candidate differs from the verified private ZIP.'
  NEW_ZIP_ID="$(entry_identity "$PUBLIC_NEW_ZIP")"
fi
"$CP" "$FINAL_STAGED_DMG" "$PUBLIC_NEW_DMG"
"$HDIUTIL" verify "$PUBLIC_NEW_DMG" >/dev/null
NEW_DMG_ID="$(entry_identity "$PUBLIC_NEW_DMG")"

publication_checkpoint() {
  local checkpoint="$1"
  local failure_mode
  if [[ "$TESTING" == 1 && -n "${BLOOM_RELEASE_TEST_PUBLICATION_LOG:-}" ]]; then
    [[ "$BLOOM_RELEASE_TEST_PUBLICATION_LOG" == "$TEST_TEMP_DIR"/* \
        && ! -L "$BLOOM_RELEASE_TEST_PUBLICATION_LOG" ]] \
      || die 'publication test log must remain inside the marked temporary fixture'
    printf 'PUBLICATION_CHECKPOINT %s\n' "$checkpoint" \
      >>"$BLOOM_RELEASE_TEST_PUBLICATION_LOG"
  fi
  [[ "$TESTING" == 1 && "${BLOOM_RELEASE_TEST_FAIL_POINT:-}" == "$checkpoint" ]] \
    || return 0
  failure_mode="${BLOOM_RELEASE_TEST_FAIL_MODE:-return}"
  case "$failure_mode" in
    return)
      return 1
      ;;
    die)
      die "injected publication exit at $checkpoint"
      ;;
    term)
      kill -TERM "$$"
      return 1
      ;;
    int)
      kill -INT "$$"
      return 1
      ;;
    *)
      die "unsupported publication test failure mode: $failure_mode"
      ;;
  esac
}

rollback_artifact() {
  local final_path="$1"
  local backup_path="$2"
  local candidate_path="$3"
  local old_identity="$4"
  local new_identity="$5"
  local label="$6"
  local rollback_status=0
  local current_identity=''

  if [[ -e "$final_path" || -L "$final_path" ]]; then
    current_identity="$(entry_identity "$final_path" || true)"
    if [[ -n "$old_identity" && "$current_identity" == "$old_identity" ]]; then
      :
    elif [[ -n "$new_identity" && "$current_identity" == "$new_identity" ]]; then
      nonfatal_delete_owned_leaf "$final_path" "$RELEASE_DIR" "$new_identity" \
        || rollback_status=1
    else
      echo "warning: refusing to replace an unrecognized public $label during rollback: $final_path" >&2
      rollback_status=1
    fi
  fi

  if [[ ! -e "$final_path" && ! -L "$final_path" && -n "$old_identity" ]]; then
    nonfatal_restore_owned_backup \
      "$backup_path" "$final_path" "$RELEASE_DIR" "$old_identity" \
      || rollback_status=1
  fi

  if [[ -e "$candidate_path" || -L "$candidate_path" ]]; then
    nonfatal_delete_owned_leaf "$candidate_path" "$RELEASE_DIR" "$new_identity" \
      || rollback_status=1
  fi

  if [[ -n "$old_identity" ]]; then
    current_identity="$(entry_identity "$final_path" || true)"
    if [[ "$current_identity" != "$old_identity" ]]; then
      echo "warning: previous public $label could not be restored exactly: $final_path" >&2
      rollback_status=1
    fi
  elif [[ -e "$final_path" || -L "$final_path" ]]; then
    echo "warning: rollback retained an unexpected public $label: $final_path" >&2
    rollback_status=1
  fi

  return "$rollback_status"
}

rollback_publication() {
  local rollback_status=0
  rollback_artifact \
    "$DMG_PATH" "$PUBLIC_BACKUP_DMG" "$PUBLIC_NEW_DMG" \
    "$OLD_DMG_ID" "$NEW_DMG_ID" 'DMG' \
    || rollback_status=1
  if [[ "$MODE" == "--signed" ]]; then
    rollback_artifact \
      "$ZIP_PATH" "$PUBLIC_BACKUP_ZIP" "$PUBLIC_NEW_ZIP" \
      "$OLD_ZIP_ID" "$NEW_ZIP_ID" 'ZIP' \
      || rollback_status=1
  fi
  rollback_artifact \
    "$APP_BUNDLE" "$PUBLIC_BACKUP_APP" "$PUBLIC_NEW_APP" \
    "$OLD_APP_ID" "$NEW_APP_ID" 'app' \
    || rollback_status=1
  return "$rollback_status"
}

publish_release() {
  if [[ -e "$APP_BUNDLE" || -L "$APP_BUNDLE" ]]; then
    safe_move "$APP_BUNDLE" "$PUBLIC_BACKUP_APP" "$RELEASE_DIR" "$RELEASE_DIR" || return 1
  fi
  publication_checkpoint after_app_backup || return 1
  safe_move "$PUBLIC_NEW_APP" "$APP_BUNDLE" "$RELEASE_DIR" "$RELEASE_DIR" || return 1
  publication_checkpoint after_app_install || return 1

  if [[ -e "$DMG_PATH" || -L "$DMG_PATH" ]]; then
    safe_move "$DMG_PATH" "$PUBLIC_BACKUP_DMG" "$RELEASE_DIR" "$RELEASE_DIR" || return 1
  fi
  publication_checkpoint after_dmg_backup || return 1
  publication_checkpoint before_dmg_install || return 1
  safe_move "$PUBLIC_NEW_DMG" "$DMG_PATH" "$RELEASE_DIR" "$RELEASE_DIR" || return 1
  publication_checkpoint after_dmg_install || return 1

  if [[ "$MODE" == "--signed" ]]; then
    if [[ -e "$ZIP_PATH" || -L "$ZIP_PATH" ]]; then
      safe_move "$ZIP_PATH" "$PUBLIC_BACKUP_ZIP" "$RELEASE_DIR" "$RELEASE_DIR" || return 1
    fi
    publication_checkpoint after_zip_backup || return 1
    publication_checkpoint before_zip_install || return 1
    safe_move "$PUBLIC_NEW_ZIP" "$ZIP_PATH" "$RELEASE_DIR" "$RELEASE_DIR" || return 1
    publication_checkpoint after_zip_install || return 1
  fi

  "$CODESIGN" --verify --deep --strict --verbose=2 "$APP_BUNDLE" || return 1
  "$CMP" -s /dev/fd/21 "$APP_BUNDLE/Contents/Resources/$NOTICE_NAME" || return 1
  assert_no_openssl_dependency "$APP_BUNDLE/Contents/MacOS/$EXECUTABLE_NAME" || return 1
  "$HDIUTIL" verify "$DMG_PATH" >/dev/null || return 1
  if [[ "$MODE" == "--signed" ]]; then
    "$CMP" -s "$FINAL_STAGED_ZIP" "$ZIP_PATH" || return 1
  fi
  return 0
}

trap 'exit 130' INT
trap 'exit 143' TERM
publication_checkpoint before_publication || die 'release publication preflight checkpoint failed.'
PUBLICATION_STARTED=true
if ! publish_release; then
  die 'release publication failed; EXIT cleanup will restore previous artifacts.'
fi
PUBLICATION_COMMITTED=true
trap - INT TERM

# Publication is committed. Old release backups are no longer public artifacts.
if [[ -n "$OLD_APP_ID" ]]; then
  nonfatal_delete_owned_leaf "$PUBLIC_BACKUP_APP" "$RELEASE_DIR" "$OLD_APP_ID" || \
    echo "warning: previous app backup retained at $PUBLIC_BACKUP_APP" >&2
fi
if [[ -n "$OLD_DMG_ID" ]]; then
  nonfatal_delete_owned_leaf "$PUBLIC_BACKUP_DMG" "$RELEASE_DIR" "$OLD_DMG_ID" || \
    echo "warning: previous DMG backup retained at $PUBLIC_BACKUP_DMG" >&2
fi
if [[ "$MODE" == "--signed" && -n "$OLD_ZIP_ID" ]]; then
  nonfatal_delete_owned_leaf "$PUBLIC_BACKUP_ZIP" "$RELEASE_DIR" "$OLD_ZIP_ID" || \
    echo "warning: previous ZIP backup retained at $PUBLIC_BACKUP_ZIP" >&2
fi

if [[ -n "$OLD_OWNED_VERSION_DIR" && "$OLD_OWNED_VERSION_DIR" != "$NEW_VERSION_DIR" ]]; then
  current_public_target="$("$READLINK" "$APP_BUNDLE" 2>/dev/null || true)"
  if [[ -L "$APP_BUNDLE" \
      && "$current_public_target" != "$OLD_OWNED_VERSION_DIR/$APP_DISPLAY_NAME.app" ]]; then
    nonfatal_delete_owned_leaf \
      "$OLD_OWNED_VERSION_DIR" "$VERSIONS_DIR" "$OLD_OWNED_VERSION_ID" || \
      echo "warning: previous cache-backed app version retained at $OLD_OWNED_VERSION_DIR" >&2
  else
    echo "warning: previous cache-backed app version is still public and was retained." >&2
  fi
fi

if [[ "$CACHE_BACKED_RELEASE" == true ]]; then
  echo 'File Provider workspace detected; published app path is cache-backed.'
fi
if [[ "$MODE" == "--unsigned" ]]; then
  echo "Unsigned local package ready: $APP_BUNDLE"
  echo "Unsigned DMG package ready: $DMG_PATH"
else
  echo "Signed and notarized package ready: $ZIP_PATH"
  echo "Signed DMG package ready: $DMG_PATH"
fi
