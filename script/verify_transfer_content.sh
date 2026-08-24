#!/usr/bin/env bash
set -euo pipefail

die() {
  echo "FAIL: $*" >&2
  exit 1
}

is_strict_child() {
  local candidate="$1"
  local allowed_root="$2"
  [[ "$candidate" == "$allowed_root"/* && "$candidate" != "$allowed_root" ]]
}

has_no_symlink_components() {
  local target="$1"
  local current=''
  local component
  local -a components
  [[ "$target" == /* ]] || return 1
  IFS='/' read -r -a components <<<"${target#/}"
  for component in "${components[@]}"; do
    [[ -n "$component" ]] || continue
    current="$current/$component"
    [[ ! -L "$current" ]] || return 1
  done
}

is_allowlisted_device() {
  [[ "$1" =~ ^/dev/disk[0-9]+(s[0-9]+)*$ ]]
}

SCRIPT_DIR="$(cd -P "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd -P "$SCRIPT_DIR/.." && pwd -P)"
TESTING="${PENGRID_TRANSFER_HARNESS_TESTING:-0}"
TEST_TOOL_DIR="${PENGRID_TRANSFER_HARNESS_TOOL_DIR:-}"

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

if [[ "$TESTING" == 1 ]]; then
  [[ -n "$TEST_TOOL_DIR" && -d "$TEST_TOOL_DIR" && ! -L "$TEST_TOOL_DIR" ]] \
    || die 'test tool directory must be a real directory'
  TEST_TOOL_DIR="$(cd -P "$TEST_TOOL_DIR" && pwd -P)"
  [[ -f "$ROOT_DIR/.pengrid-transfer-harness-test-fixture" \
      && ! -L "$ROOT_DIR/.pengrid-transfer-harness-test-fixture" ]] \
    || die 'test hooks are restricted to marked temporary fixtures'
  export PENGRID_TRANSFER_HARNESS_TEST_TARGET_PID="$$"
fi

GETCONF="$(tool_path /usr/bin/getconf)"
HDIUTIL="$(tool_path /usr/bin/hdiutil)"
PLUTIL="$(tool_path /usr/bin/plutil)"
STAT="$(tool_path /usr/bin/stat)"
XCRUN="$(tool_path /usr/bin/xcrun)"
MKTEMP="$(tool_path /usr/bin/mktemp)"
MKDIR="$(tool_path /bin/mkdir)"
FIND="$(tool_path /usr/bin/find)"
PERL=/usr/bin/perl

RAW_SYSTEM_TEMP_DIR="$($GETCONF DARWIN_USER_TEMP_DIR)"
[[ -n "$RAW_SYSTEM_TEMP_DIR" && -d "$RAW_SYSTEM_TEMP_DIR" ]] \
  || die 'Darwin user temporary directory is unavailable'
SYSTEM_TEMP_DIR="$(cd -P "$RAW_SYSTEM_TEMP_DIR" && pwd -P)"

if [[ "$TESTING" == 1 ]]; then
  RAW_TEMP_BASE="${PENGRID_TRANSFER_HARNESS_TEMP_BASE:-}"
  [[ -n "$RAW_TEMP_BASE" && -d "$RAW_TEMP_BASE" && ! -L "$RAW_TEMP_BASE" ]] \
    || die 'test temporary base must be a real directory'
  TEMP_BASE="$(cd -P "$RAW_TEMP_BASE" && pwd -P)"
  is_strict_child "$TEMP_BASE" "$SYSTEM_TEMP_DIR" \
    || die 'test temporary base must remain below the Darwin user temporary directory'
else
  TEMP_BASE="$SYSTEM_TEMP_DIR"
fi

[[ "$TEMP_BASE" != / && "$TEMP_BASE" != "$ROOT_DIR" \
    && "$TEMP_BASE" != "${HOME:-}" ]] \
  || die 'unsafe temporary base'
has_no_symlink_components "$TEMP_BASE" || die 'temporary base contains a symbolic link'

TEMP_ROOT=''
TEMP_ROOT_IDENTITY=''
TEMP_ROOT_FILESYSTEM=''
IMAGE_PATH=''
IMAGE_IDENTITY=''
MOUNT_POINT=''
MOUNT_DIRECTORY_IDENTITY=''
MOUNT_IDENTITY=''
MOUNT_FILESYSTEM=''
VALIDATED_DEVICE=''
ATTACH_ATTEMPTED=0
CLEANUP_RAN=0
ACTIVE_CHILD_PID=''
STARTING_CHILD=0
CHILD_GROUP_UNDRAINED=0
REQUESTED_SIGNAL_STATUS=0
ATTACH_CAPTURE_OPEN=0

open_attach_capture() {
  local capture_path capture_inode path_inode write_inode read_inode
  capture_path="$($MKTEMP "$TEMP_ROOT/attach-output.XXXXXX")"
  is_strict_child "$capture_path" "$TEMP_ROOT" || return 1
  has_no_symlink_components "$capture_path" || return 1
  [[ -f "$capture_path" && ! -L "$capture_path" ]] || return 1
  capture_inode="$($STAT -f '%i' "$capture_path" 2>/dev/null || true)"
  [[ -n "$capture_inode" ]] || return 1

  exec 8<>"$capture_path" || return 1
  exec 9<"$capture_path" || {
    exec 8>&-
    return 1
  }
  ATTACH_CAPTURE_OPEN=1
  path_inode="$($STAT -f '%i' "$capture_path" 2>/dev/null || true)"
  write_inode="$($STAT -f '%i' /dev/fd/8 2>/dev/null || true)"
  read_inode="$($STAT -f '%i' /dev/fd/9 2>/dev/null || true)"
  if [[ "$path_inode" != "$capture_inode" \
      || "$write_inode" != "$capture_inode" \
      || "$read_inode" != "$capture_inode" ]]; then
    close_attach_capture
    return 1
  fi
  /bin/rm "$capture_path" || {
    close_attach_capture
    return 1
  }
}

close_attach_capture() {
  if [[ "$ATTACH_CAPTURE_OPEN" == 1 ]]; then
    exec 8>&-
    exec 9<&-
    ATTACH_CAPTURE_OPEN=0
  fi
}

finish_attach_capture() {
  local captured=''
  [[ "$ATTACH_CAPTURE_OPEN" == 1 ]] || return 1
  exec 8>&-
  captured="$(/bin/cat <&9)" || {
    exec 9<&-
    ATTACH_CAPTURE_OPEN=0
    return 1
  }
  exec 9<&-
  ATTACH_CAPTURE_OPEN=0
  ATTACH_PLIST="$captured"
}

begin_managed_child_start() {
  [[ -z "$ACTIVE_CHILD_PID" && "$STARTING_CHILD" == 0 \
      && "$CHILD_GROUP_UNDRAINED" == 0 ]] || return 1
  STARTING_CHILD=1
}

cancel_unlaunched_managed_child_if_signaled() {
  if [[ "$REQUESTED_SIGNAL_STATUS" -ne 0 ]]; then
    STARTING_CHILD=0
    exit "$REQUESTED_SIGNAL_STATUS"
  fi
}

start_managed_child() {
  [[ -z "$ACTIVE_CHILD_PID" && "$STARTING_CHILD" == 1 ]] || return 1
  "$PERL" -MPOSIX -e \
    'POSIX::setpgid(0, 0) == 0 or die "setpgid failed: $!\n"; exec {$ARGV[0]} @ARGV; die "exec failed: $!\n"' \
    "$@" &
  ACTIVE_CHILD_PID=$!
  STARTING_CHILD=0
  if [[ "$REQUESTED_SIGNAL_STATUS" -ne 0 ]]; then
    terminate_active_child
  fi
}

terminate_active_child() {
  [[ -n "$ACTIVE_CHILD_PID" ]] || return 0
  /bin/kill -TERM -- "-$ACTIVE_CHILD_PID" 2>/dev/null \
    || /bin/kill -TERM "$ACTIVE_CHILD_PID" 2>/dev/null \
    || true
}

managed_group_exists() {
  local group_id="$1"
  /bin/kill -0 -- "-$group_id" 2>/dev/null
}

drain_managed_group() {
  local group_id="$1"
  local attempt
  managed_group_exists "$group_id" || return 0

  /bin/kill -TERM -- "-$group_id" 2>/dev/null || true
  for attempt in {1..20}; do
    managed_group_exists "$group_id" || return 0
    /bin/sleep 0.05
  done

  /bin/kill -KILL -- "-$group_id" 2>/dev/null || true
  for attempt in {1..20}; do
    managed_group_exists "$group_id" || return 0
    /bin/sleep 0.05
  done
  return 1
}

wait_for_managed_child() {
  local child_pid="$ACTIVE_CHILD_PID"
  local child_status=0
  [[ -n "$child_pid" ]] || return 1
  while true; do
    if wait "$child_pid"; then
      child_status=0
    else
      child_status=$?
    fi
    if /bin/kill -0 "$child_pid" 2>/dev/null; then
      continue
    fi
    break
  done
  if ! drain_managed_group "$child_pid"; then
    CHILD_GROUP_UNDRAINED=1
    child_status=1
  fi
  ACTIVE_CHILD_PID=''
  return "$child_status"
}

exit_if_signal_requested() {
  if [[ "$REQUESTED_SIGNAL_STATUS" -ne 0 ]]; then
    exit "$REQUESTED_SIGNAL_STATUS"
  fi
}

request_signal_exit() {
  local requested_status="$1"
  if [[ "$REQUESTED_SIGNAL_STATUS" -eq 0 ]]; then
    REQUESTED_SIGNAL_STATUS="$requested_status"
  fi
  if [[ -n "$ACTIVE_CHILD_PID" ]]; then
    terminate_active_child
    return 0
  fi
  if [[ "$STARTING_CHILD" == 1 ]]; then
    return 0
  fi
  exit "$REQUESTED_SIGNAL_STATUS"
}

plist_value() {
  local plist="$1"
  local key_path="$2"
  /usr/bin/printf '%s' "$plist" \
    | "$PLUTIL" -extract "$key_path" raw -o - - 2>/dev/null
}

plist_is_valid() {
  /usr/bin/printf '%s' "$1" | "$PLUTIL" -lint - >/dev/null 2>&1
}

device_from_attach_plist() {
  local plist="$1"
  local candidate=''
  local device mount
  local match_count=0
  local index
  plist_is_valid "$plist" || return 1
  for index in {0..63}; do
    device="$(plist_value "$plist" "system-entities.$index.dev-entry" || true)"
    mount="$(plist_value "$plist" "system-entities.$index.mount-point" || true)"
    if [[ "$mount" == "$MOUNT_POINT" ]]; then
      is_allowlisted_device "$device" || return 1
      candidate="$device"
      match_count=$((match_count + 1))
    fi
  done
  [[ "$match_count" -eq 1 ]] || return 1
  echo "$candidate"
}

device_from_info_plist() {
  local plist="$1"
  local candidate=''
  local image device mount
  local image_match_count=0
  local entity_match_count=0
  local image_index entity_index
  plist_is_valid "$plist" || return 1
  for image_index in {0..63}; do
    image="$(plist_value "$plist" "images.$image_index.image-path" || true)"
    [[ "$image" == "$IMAGE_PATH" ]] || continue
    image_match_count=$((image_match_count + 1))
    for entity_index in {0..63}; do
      device="$(plist_value \
        "$plist" \
        "images.$image_index.system-entities.$entity_index.dev-entry" || true)"
      mount="$(plist_value \
        "$plist" \
        "images.$image_index.system-entities.$entity_index.mount-point" || true)"
      if [[ "$mount" == "$MOUNT_POINT" ]]; then
        is_allowlisted_device "$device" || return 1
        candidate="$device"
        entity_match_count=$((entity_match_count + 1))
      fi
    done
  done
  [[ "$image_match_count" -eq 1 && "$entity_match_count" -eq 1 ]] || return 1
  echo "$candidate"
}

validate_owned_paths() {
  local current_image_identity
  is_strict_child "$IMAGE_PATH" "$TEMP_ROOT" || return 1
  is_strict_child "$MOUNT_POINT" "$TEMP_ROOT" || return 1
  has_no_symlink_components "$IMAGE_PATH" || return 1
  has_no_symlink_components "$MOUNT_POINT" || return 1
  [[ -f "$IMAGE_PATH" && ! -L "$IMAGE_PATH" ]] || return 1
  [[ -d "$MOUNT_POINT" && ! -L "$MOUNT_POINT" ]] || return 1
  [[ "$(cd -P "$MOUNT_POINT" && pwd -P)" == "$MOUNT_POINT" ]] || return 1
  [[ "$(cd -P "$(/usr/bin/dirname "$IMAGE_PATH")" && pwd -P)/$(/usr/bin/basename "$IMAGE_PATH")" \
      == "$IMAGE_PATH" ]] || return 1
  current_image_identity="$($STAT -f '%d:%i' "$IMAGE_PATH" 2>/dev/null || true)"
  [[ -n "$IMAGE_IDENTITY" && "$current_image_identity" == "$IMAGE_IDENTITY" ]]
}

refresh_info_device() {
  local info_plist=''
  DISCOVERED_DEVICE=''
  info_plist="$("$HDIUTIL" info -plist 2>/dev/null)" || return 1
  DISCOVERED_DEVICE="$(device_from_info_plist "$info_plist" || true)"
  [[ -n "$DISCOVERED_DEVICE" ]]
}

discover_cleanup_candidate() {
  local mount_identity mount_filesystem
  validate_owned_paths || return 1
  refresh_info_device || return 1
  is_allowlisted_device "$DISCOVERED_DEVICE" || return 1
  mount_identity="$($STAT -f '%d:%i' "$MOUNT_POINT" 2>/dev/null || true)"
  mount_filesystem="$($STAT -f '%d' "$MOUNT_POINT" 2>/dev/null || true)"
  [[ -n "$mount_identity" && -n "$mount_filesystem" \
      && "$mount_filesystem" != "$TEMP_ROOT_FILESYSTEM" ]] || return 1
  VALIDATED_DEVICE="$DISCOVERED_DEVICE"
  MOUNT_IDENTITY="$mount_identity"
  MOUNT_FILESYSTEM="$mount_filesystem"
}

revalidate_mounted_device() {
  local current_identity current_filesystem
  [[ -n "$VALIDATED_DEVICE" ]] || return 1
  validate_owned_paths || return 1
  refresh_info_device || return 1
  [[ "$DISCOVERED_DEVICE" == "$VALIDATED_DEVICE" ]] || return 1
  current_identity="$($STAT -f '%d:%i' "$MOUNT_POINT" 2>/dev/null || true)"
  current_filesystem="$($STAT -f '%d' "$MOUNT_POINT" 2>/dev/null || true)"
  [[ "$current_identity" == "$MOUNT_IDENTITY" \
      && "$current_filesystem" == "$MOUNT_FILESYSTEM" \
      && "$current_filesystem" != "$TEMP_ROOT_FILESYSTEM" ]]
}

safe_delete_temp_root() {
  local current_identity current_image_identity
  local current_mount_identity current_mount_filesystem
  [[ -n "$TEMP_ROOT" && -n "$TEMP_ROOT_IDENTITY" ]] || return 0
  is_strict_child "$TEMP_ROOT" "$TEMP_BASE" || return 1
  has_no_symlink_components "$TEMP_ROOT" || return 1
  [[ -d "$TEMP_ROOT" && ! -L "$TEMP_ROOT" ]] || return 1
  (
    cd -P "$TEMP_ROOT" || exit 1
    current_identity="$($STAT -f '%d:%i' . 2>/dev/null || true)"
    [[ "$current_identity" == "$TEMP_ROOT_IDENTITY" ]] || exit 1
    [[ "$(pwd -P)" == "$TEMP_ROOT" ]] || exit 1

    [[ -f "./$(/usr/bin/basename "$IMAGE_PATH")" \
        && ! -L "./$(/usr/bin/basename "$IMAGE_PATH")" ]] || exit 1
    current_image_identity="$($STAT \
      -f '%d:%i' \
      "./$(/usr/bin/basename "$IMAGE_PATH")" \
      2>/dev/null || true)"
    [[ "$current_image_identity" == "$IMAGE_IDENTITY" ]] || exit 1

    [[ -d "./$(/usr/bin/basename "$MOUNT_POINT")" \
        && ! -L "./$(/usr/bin/basename "$MOUNT_POINT")" ]] || exit 1
    current_mount_identity="$($STAT \
      -f '%d:%i' \
      "./$(/usr/bin/basename "$MOUNT_POINT")" \
      2>/dev/null || true)"
    current_mount_filesystem="$($STAT \
      -f '%d' \
      "./$(/usr/bin/basename "$MOUNT_POINT")" \
      2>/dev/null || true)"
    [[ "$current_mount_identity" == "$MOUNT_DIRECTORY_IDENTITY" \
        && "$current_mount_filesystem" == "$TEMP_ROOT_FILESYSTEM" ]] || exit 1

    "$FIND" -x . -mindepth 1 -depth -delete
  ) || return 1

  [[ -d "$TEMP_ROOT" && ! -L "$TEMP_ROOT" ]] || return 1
  current_identity="$($STAT -f '%d:%i' "$TEMP_ROOT" 2>/dev/null || true)"
  [[ "$current_identity" == "$TEMP_ROOT_IDENTITY" ]] || return 1
  /bin/rmdir "$TEMP_ROOT"
}

cleanup_harness() {
  local cleanup_failed=0
  if [[ "$CLEANUP_RAN" == 1 ]]; then
    return 0
  fi
  CLEANUP_RAN=1

  if [[ "$CHILD_GROUP_UNDRAINED" == 1 ]]; then
    return 1
  fi

  if [[ -z "$VALIDATED_DEVICE" && "$ATTACH_ATTEMPTED" == 1 ]]; then
    discover_cleanup_candidate || cleanup_failed=1
  fi

  if [[ -n "$VALIDATED_DEVICE" ]]; then
    if revalidate_mounted_device \
        && "$HDIUTIL" detach "$MOUNT_POINT" >/dev/null 2>&1; then
      VALIDATED_DEVICE=''
    else
      cleanup_failed=1
    fi
  fi

  if [[ -z "$VALIDATED_DEVICE" && "$cleanup_failed" == 0 ]]; then
    safe_delete_temp_root || cleanup_failed=1
  fi
  [[ "$cleanup_failed" == 0 ]]
}

on_exit() {
  local status=$?
  trap - EXIT
  trap '' INT TERM
  STARTING_CHILD=0
  if [[ -n "$ACTIVE_CHILD_PID" ]]; then
    terminate_active_child
    wait_for_managed_child || true
  fi
  close_attach_capture
  if ! cleanup_harness; then
    echo 'FAIL: APFS harness cleanup could not be safely completed' >&2
    if [[ "$status" -eq 0 ]]; then
      status=1
    fi
  fi
  exit "$status"
}

on_int() {
  request_signal_exit 130
}

on_term() {
  request_signal_exit 143
}

trap on_exit EXIT
trap on_int INT
trap on_term TERM

TEMP_ROOT="$($MKTEMP -d "$TEMP_BASE/pengrid-transfer-verification.XXXXXX")"
TEMP_ROOT="$(cd -P "$TEMP_ROOT" && pwd -P)"
is_strict_child "$TEMP_ROOT" "$TEMP_BASE" || die 'unsafe temporary root'
has_no_symlink_components "$TEMP_ROOT" || die 'temporary root contains a symbolic link'
TEMP_ROOT_IDENTITY="$($STAT -f '%d:%i' "$TEMP_ROOT")"
TEMP_ROOT_FILESYSTEM="$($STAT -f '%d' "$TEMP_ROOT")"
[[ -n "$TEMP_ROOT_IDENTITY" && -n "$TEMP_ROOT_FILESYSTEM" ]] \
  || die 'temporary root identity is unavailable'

IMAGE_PATH="$TEMP_ROOT/transfer-verification.sparseimage"
MOUNT_POINT="$TEMP_ROOT/mount"
is_strict_child "$IMAGE_PATH" "$TEMP_ROOT" || die 'unsafe image path'
is_strict_child "$MOUNT_POINT" "$TEMP_ROOT" || die 'unsafe mount path'
"$MKDIR" "$MOUNT_POINT"
has_no_symlink_components "$MOUNT_POINT" || die 'mount path contains a symbolic link'
MOUNT_DIRECTORY_IDENTITY="$($STAT -f '%d:%i' "$MOUNT_POINT")"
[[ -n "$MOUNT_DIRECTORY_IDENTITY" \
    && "$($STAT -f '%d' "$MOUNT_POINT")" == "$TEMP_ROOT_FILESYSTEM" ]] \
  || die 'mount directory identity is unavailable'

"$HDIUTIL" create \
  -quiet \
  -size 4g \
  -fs APFS \
  -volname PengridTransferVerification \
  -type SPARSE \
  "$IMAGE_PATH" >/dev/null
[[ -f "$IMAGE_PATH" && ! -L "$IMAGE_PATH" ]] || die 'disk image was not created safely'
IMAGE_IDENTITY="$($STAT -f '%d:%i' "$IMAGE_PATH")"
[[ -n "$IMAGE_IDENTITY" ]] || die 'disk image identity is unavailable'

ATTACH_PLIST=''
attach_status=0
open_attach_capture || die 'attach output capture could not be opened safely'
begin_managed_child_start || die 'attach process could not be prepared safely'
ATTACH_ATTEMPTED=1

if [[ "$TESTING" == 1 ]]; then
  case "${PENGRID_TRANSFER_HARNESS_TEST_SIGNAL_BEFORE_ATTACH_LAUNCH:-}" in
    '') ;;
    INT) /bin/kill -INT "$$" ;;
    TERM) /bin/kill -TERM "$$" ;;
    *) die 'unsupported pre-attach test signal' ;;
  esac
fi

if [[ "$REQUESTED_SIGNAL_STATUS" -ne 0 ]]; then
  ATTACH_ATTEMPTED=0
  cancel_unlaunched_managed_child_if_signaled
fi
start_managed_child "$HDIUTIL" attach \
    -plist \
    -nobrowse \
    -noautoopen \
    -mountpoint "$MOUNT_POINT" \
    "$IMAGE_PATH" >&8 2>/dev/null
if wait_for_managed_child; then
  attach_status=0
else
  attach_status=$?
fi
[[ "$CHILD_GROUP_UNDRAINED" == 0 ]] \
  || die 'managed attach process group could not be drained'
finish_attach_capture || die 'attach output capture could not be read safely'
exit_if_signal_requested

if [[ "$TESTING" == 1 ]]; then
  case "${PENGRID_TRANSFER_HARNESS_TEST_SIGNAL_AFTER_ATTACH:-}" in
    '') ;;
    INT) /bin/kill -INT "$$" ;;
    TERM) /bin/kill -TERM "$$" ;;
    *) die 'unsupported post-attach test signal' ;;
  esac
fi

discover_cleanup_candidate || true
[[ "$attach_status" -eq 0 ]] || die 'disk image attach failed'
ATTACH_DEVICE="$(device_from_attach_plist "$ATTACH_PLIST" || true)"
[[ -n "$ATTACH_DEVICE" ]] || die 'disk image attach plist is invalid'
[[ -n "$VALIDATED_DEVICE" && "$ATTACH_DEVICE" == "$VALIDATED_DEVICE" ]] \
  || die 'attached disk identity did not match the temporary image'
revalidate_mounted_device || die 'mounted disk identity changed before verification'

if [[ "$TESTING" == 1 ]]; then
  case "${PENGRID_TRANSFER_HARNESS_TEST_SIGNAL_BEFORE_TEST:-}" in
    '') ;;
    INT) /bin/kill -INT "$$" ;;
    TERM) /bin/kill -TERM "$$" ;;
    *) die 'unsupported test signal' ;;
  esac
fi

swift_status=0
begin_managed_child_start || die 'Swift test process could not be prepared safely'
cancel_unlaunched_managed_child_if_signaled
start_managed_child /usr/bin/env \
  DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
  PENGRID_TRANSFER_APFS_ROOT="$MOUNT_POINT" \
  "$XCRUN" swift test \
    --enable-swift-testing \
    --no-parallel \
    --filter TransferVerificationAPFSTests \
    --package-path "$ROOT_DIR"
if wait_for_managed_child; then
  swift_status=0
else
  swift_status=$?
fi
[[ "$CHILD_GROUP_UNDRAINED" == 0 ]] \
  || die 'managed Swift test process group could not be drained'
exit_if_signal_requested

if [[ "$swift_status" -ne 0 ]]; then
  echo 'FAIL: TransferVerificationAPFSTests' >&2
  exit "$swift_status"
fi

echo 'PASS: TransferVerificationAPFSTests'
