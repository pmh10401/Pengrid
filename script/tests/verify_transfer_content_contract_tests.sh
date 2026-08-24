#!/usr/bin/env bash
set -euo pipefail

SOURCE_ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
SOURCE_SCRIPT="$SOURCE_ROOT/script/verify_transfer_content.sh"
ENGLISH_VERIFICATION="$SOURCE_ROOT/docs/verification/transfer-content-verification.md"
KOREAN_VERIFICATION="$SOURCE_ROOT/docs/verification/transfer-content-verification.ko.md"
RAW_TEST_TEMP_DIR="$(/usr/bin/getconf DARWIN_USER_TEMP_DIR)"
TEST_TEMP_DIR="$(cd -P "$RAW_TEST_TEMP_DIR" && pwd -P)"
TEST_ROOT="$(/usr/bin/mktemp -d "$TEST_TEMP_DIR/pengrid-transfer-contracts.XXXXXX")"

cleanup() {
  /usr/bin/find "$TEST_ROOT" -depth -delete
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[[ -f "$SOURCE_SCRIPT" ]] \
  || fail 'script/verify_transfer_content.sh does not exist'

assert_file_contains() {
  /usr/bin/grep -Fq -- "$2" "$1" \
    || fail "$1 does not contain: $2"
}

assert_file_not_contains() {
  ! /usr/bin/grep -Fq -- "$2" "$1" \
    || fail "$1 unexpectedly contains: $2"
}

assert_event_order() {
  local log="$1"
  local first="$2"
  local second="$3"
  local first_line second_line
  first_line="$(/usr/bin/grep -n -m 1 -F -- "$first" "$log" | /usr/bin/cut -d: -f1 || true)"
  second_line="$(/usr/bin/grep -n -m 1 -F -- "$second" "$log" | /usr/bin/cut -d: -f1 || true)"
  [[ -n "$first_line" && -n "$second_line" && "$first_line" -lt "$second_line" ]] \
    || fail "expected '$first' before '$second' in $log"
}

assert_no_harness_root() {
  local fixture="$1"
  local remaining
  remaining="$(/usr/bin/find \
    "$fixture/temp" \
    -mindepth 1 \
    -maxdepth 1 \
    -type d \
    -name 'pengrid-transfer-verification.*' \
    -print \
    -quit)"
  [[ -z "$remaining" ]] || fail "harness root remained: $remaining"
}

test_bilingual_verification_contract_is_documented() {
  local document
  for document in "$ENGLISH_VERIFICATION" "$KOREAN_VERIFICATION"; do
    [[ -f "$document" ]] || fail "$document does not exist"
    assert_file_contains "$document" '## Automated evidence'
    assert_file_contains "$document" '## Static-source evidence'
    assert_file_contains "$document" '## Physical manual evidence'
    assert_file_contains "$document" '## Release gate'
    assert_file_contains "$document" 'MANUAL NOT RUN'
    assert_file_contains "$document" 'PENGRID_TRANSFER_APFS_ROOT'
    assert_file_contains "$document" 'maxConcurrentPairs: 2'
    assert_file_contains "$document" '250,000'
    assert_file_contains "$document" '256'
  done
}

new_fixture() {
  local name="$1"
  local fixture="$TEST_ROOT/$name"
  /bin/mkdir -p \
    "$fixture/repo/script" \
    "$fixture/tools" \
    "$fixture/temp" \
    "$fixture/state" \
    "$fixture/external"
  /bin/cp "$SOURCE_SCRIPT" "$fixture/repo/script/verify_transfer_content.sh"
  /bin/chmod +x "$fixture/repo/script/verify_transfer_content.sh"
  : >"$fixture/repo/.pengrid-transfer-harness-test-fixture"
  : >"$fixture/events.log"

  /usr/bin/awk '/^__FAKE_HDIUTIL__$/ { emit = 1; next } /^__END_FAKE_HDIUTIL__$/ { exit } emit' \
    "$SOURCE_ROOT/script/tests/verify_transfer_content_contract_tests.sh" \
    | /usr/bin/sed \
        -e "s|__FAKE_STATE__|$fixture/state|g" \
        -e "s|__FAKE_LOG__|$fixture/events.log|g" \
        -e "s|__FAKE_EXTERNAL__|$fixture/external|g" \
        >"$fixture/tools/hdiutil"
  /bin/chmod +x "$fixture/tools/hdiutil"

  /usr/bin/awk '/^__FAKE_XCRUN__$/ { emit = 1; next } /^__END_FAKE_XCRUN__$/ { exit } emit' \
    "$SOURCE_ROOT/script/tests/verify_transfer_content_contract_tests.sh" \
    | /usr/bin/sed \
        -e "s|__FAKE_STATE__|$fixture/state|g" \
        -e "s|__FAKE_LOG__|$fixture/events.log|g" \
        >"$fixture/tools/xcrun"
  /bin/chmod +x "$fixture/tools/xcrun"

  /usr/bin/awk '/^__FAKE_STAT__$/ { emit = 1; next } /^__END_FAKE_STAT__$/ { exit } emit' \
    "$SOURCE_ROOT/script/tests/verify_transfer_content_contract_tests.sh" \
    | /usr/bin/sed \
        -e "s|__FAKE_STATE__|$fixture/state|g" \
        -e "s|__FAKE_LOG__|$fixture/events.log|g" \
        -e "s|__FAKE_EXTERNAL__|$fixture/external|g" \
        >"$fixture/tools/stat"
  /bin/chmod +x "$fixture/tools/stat"
  echo "$fixture"
}

run_fixture() {
  local fixture="$1"
  shift
  env \
    PENGRID_TRANSFER_HARNESS_TESTING=1 \
    PENGRID_TRANSFER_HARNESS_TOOL_DIR="$fixture/tools" \
    PENGRID_TRANSFER_HARNESS_TEMP_BASE="$fixture/temp" \
    FAKE_TRANSFER_HARNESS_CASE="${FAKE_TRANSFER_HARNESS_CASE:-success}" \
    "$@" \
    /bin/bash "$fixture/repo/script/verify_transfer_content.sh"
}

test_success_orders_attach_test_and_cleanup() {
  local fixture mount
  fixture="$(new_fixture success)"
  : >"$fixture/temp/sibling-sentinel"
  : >"$fixture/external/external-sentinel"
  if ! run_fixture "$fixture" >"$fixture/output" 2>&1; then
    /bin/cat "$fixture/output" >&2
    fail 'success fixture failed'
  fi
  mount="$(/bin/cat "$fixture/state/mount")"
  assert_event_order "$fixture/events.log" 'ATTACH' 'SWIFT_TEST'
  assert_event_order "$fixture/events.log" 'SWIFT_TEST' "DETACH:$mount"
  assert_file_not_contains "$fixture/events.log" 'DETACH:/dev/'
  assert_file_contains "$fixture/output" 'PASS: TransferVerificationAPFSTests'
  assert_file_contains "$fixture/events.log" '--filter TransferVerificationAPFSTests'
  [[ -f "$fixture/temp/sibling-sentinel" ]] \
    || fail 'cleanup removed a sibling sentinel'
  [[ -f "$fixture/external/external-sentinel" ]] \
    || fail 'cleanup removed an external sentinel'
  assert_no_harness_root "$fixture"
}

test_swift_failure_still_detaches_before_failure() {
  local fixture mount
  fixture="$(new_fixture swift-failure)"
  if FAKE_TRANSFER_HARNESS_CASE=swift_failure run_fixture "$fixture" \
      >"$fixture/output" 2>&1; then
    fail 'Swift failure fixture unexpectedly succeeded'
  fi
  mount="$(/bin/cat "$fixture/state/mount")"
  assert_event_order "$fixture/events.log" 'SWIFT_TEST' "DETACH:$mount"
  assert_file_contains "$fixture/output" 'FAIL: TransferVerificationAPFSTests'
}

test_malformed_attach_plist_is_rejected_and_discovered_device_is_cleaned() {
  local fixture mount
  fixture="$(new_fixture malformed-plist)"
  if FAKE_TRANSFER_HARNESS_CASE=malformed_attach run_fixture "$fixture" \
      >"$fixture/output" 2>&1; then
    fail 'malformed attach plist was accepted'
  fi
  assert_file_not_contains "$fixture/events.log" 'SWIFT_TEST'
  mount="$(/bin/cat "$fixture/state/mount")"
  assert_event_order "$fixture/events.log" 'ATTACH' "DETACH:$mount"
}

test_non_allowlisted_device_is_rejected_without_detach() {
  local fixture
  fixture="$(new_fixture invalid-device)"
  if FAKE_TRANSFER_HARNESS_CASE=invalid_device run_fixture "$fixture" \
      >"$fixture/output" 2>&1; then
    fail 'non-allowlisted device was accepted'
  fi
  assert_file_not_contains "$fixture/events.log" 'SWIFT_TEST'
  assert_file_not_contains "$fixture/events.log" 'DETACH:'
}

test_image_path_mismatch_is_rejected_without_detach() {
  local fixture
  fixture="$(new_fixture image-mismatch)"
  if FAKE_TRANSFER_HARNESS_CASE=image_mismatch run_fixture "$fixture" \
      >"$fixture/output" 2>&1; then
    fail 'image-path mismatch was accepted'
  fi
  assert_file_not_contains "$fixture/events.log" 'SWIFT_TEST'
  assert_file_not_contains "$fixture/events.log" 'DETACH:'
}

test_mountpoint_mismatch_is_rejected_without_detach() {
  local fixture
  fixture="$(new_fixture mount-mismatch)"
  if FAKE_TRANSFER_HARNESS_CASE=mount_mismatch run_fixture "$fixture" \
      >"$fixture/output" 2>&1; then
    fail 'mountpoint mismatch was accepted'
  fi
  assert_file_not_contains "$fixture/events.log" 'SWIFT_TEST'
  assert_file_not_contains "$fixture/events.log" 'DETACH:'
}

test_mountpoint_symlink_substitution_is_rejected() {
  local fixture
  fixture="$(new_fixture mount-symlink)"
  if FAKE_TRANSFER_HARNESS_CASE=mount_symlink run_fixture "$fixture" \
      >"$fixture/output" 2>&1; then
    fail 'mountpoint symlink substitution was accepted'
  fi
  assert_file_not_contains "$fixture/events.log" 'SWIFT_TEST'
  assert_file_not_contains "$fixture/events.log" 'DETACH:'
}

test_partial_attach_failure_cleans_validated_device_without_running_test() {
  local fixture mount
  fixture="$(new_fixture partial-attach)"
  if FAKE_TRANSFER_HARNESS_CASE=partial_attach run_fixture "$fixture" \
      >"$fixture/output" 2>&1; then
    fail 'partial attach failure unexpectedly succeeded'
  fi
  assert_file_not_contains "$fixture/events.log" 'SWIFT_TEST'
  mount="$(/bin/cat "$fixture/state/mount")"
  assert_event_order "$fixture/events.log" 'ATTACH' "DETACH:$mount"
}

test_int_cleans_then_terminates_before_swift() {
  local fixture mount status
  fixture="$(new_fixture signal-int)"
  status=0
  run_fixture "$fixture" PENGRID_TRANSFER_HARNESS_TEST_SIGNAL_AFTER_ATTACH=INT \
    >"$fixture/output" 2>&1 || status=$?
  [[ "$status" -eq 130 ]] || fail "INT returned $status instead of 130"
  mount="$(/bin/cat "$fixture/state/mount")"
  assert_file_not_contains "$fixture/events.log" 'SWIFT_TEST'
  assert_file_contains "$fixture/events.log" "DETACH:$mount"
}

test_term_cleans_then_terminates_before_swift() {
  local fixture mount status
  fixture="$(new_fixture signal-term)"
  status=0
  run_fixture "$fixture" PENGRID_TRANSFER_HARNESS_TEST_SIGNAL_BEFORE_TEST=TERM \
    >"$fixture/output" 2>&1 || status=$?
  [[ "$status" -eq 143 ]] || fail "TERM returned $status instead of 143"
  mount="$(/bin/cat "$fixture/state/mount")"
  assert_file_not_contains "$fixture/events.log" 'SWIFT_TEST'
  assert_file_contains "$fixture/events.log" "DETACH:$mount"
}

test_plist_symlink_targets_are_never_opened_for_output() {
  local fixture
  fixture="$(new_fixture plist-symlink)"
  if ! FAKE_TRANSFER_HARNESS_CASE=plist_symlink run_fixture "$fixture" \
      >"$fixture/output" 2>&1; then
    /bin/cat "$fixture/output" >&2
    fail 'plist symlink fixture failed'
  fi
  [[ "$(/bin/cat "$fixture/external/attach-sentinel")" == 'keep-attach' ]] \
    || fail 'attach plist output followed a symlink'
  [[ "$(/bin/cat "$fixture/external/info-sentinel")" == 'keep-info' ]] \
    || fail 'info plist output followed a symlink'
}

test_random_capture_symlink_is_rejected_without_truncating_target() {
  local fixture status
  fixture="$(new_fixture random-capture-symlink)"
  status=0
  FAKE_TRANSFER_HARNESS_CASE=random_capture_symlink run_fixture "$fixture" \
    >"$fixture/output" 2>&1 || status=$?
  [[ "$status" -ne 0 ]] || fail 'random capture symlink was accepted'
  [[ "$(/bin/cat "$fixture/external/capture-sentinel")" == 'keep-capture' ]] \
    || fail 'random capture open truncated a symlink target'
  assert_file_not_contains "$fixture/events.log" 'ATTACH'
}

test_signal_before_attach_launch_cancels_without_claiming_partial_attach() {
  local fixture status
  fixture="$(new_fixture signal-before-attach-launch)"
  status=0
  run_fixture "$fixture" \
    PENGRID_TRANSFER_HARNESS_TEST_SIGNAL_BEFORE_ATTACH_LAUNCH=INT \
    >"$fixture/output" 2>&1 || status=$?
  [[ "$status" -eq 130 ]] \
    || fail "pre-launch INT returned $status instead of 130"
  assert_file_not_contains "$fixture/events.log" 'ATTACH'
  assert_file_not_contains "$fixture/events.log" 'SWIFT_TEST'
  assert_no_harness_root "$fixture"
}

test_mount_identity_change_before_detach_fails_closed() {
  local fixture status
  fixture="$(new_fixture mount-identity-change)"
  status=0
  FAKE_TRANSFER_HARNESS_CASE=mount_identity_change run_fixture "$fixture" \
    >"$fixture/output" 2>&1 || status=$?
  [[ "$status" -ne 0 ]] || fail 'changed mount identity was accepted before detach'
  assert_file_not_contains "$fixture/events.log" 'DETACH:'
  assert_file_contains "$fixture/output" \
    'FAIL: APFS harness cleanup could not be safely completed'
}

test_cleanup_root_substitution_preserves_replacement_tree() {
  local fixture status replacement
  fixture="$(new_fixture cleanup-root-substitution)"
  status=0
  FAKE_TRANSFER_HARNESS_CASE=cleanup_root_substitution run_fixture "$fixture" \
    >"$fixture/output" 2>&1 || status=$?
  [[ "$status" -ne 0 ]] || fail 'cleanup root substitution unexpectedly succeeded'
  replacement="$(/bin/cat "$fixture/state/replacement-root")"
  [[ -f "$replacement/victim-sentinel" ]] \
    || fail 'cleanup deleted the substituted replacement tree'
}

test_external_int_while_attach_is_blocked_cleans_and_stops() {
  local fixture mount status
  fixture="$(new_fixture blocked-attach-int)"
  status=0
  FAKE_TRANSFER_HARNESS_CASE=blocked_attach_int run_fixture "$fixture" \
    >"$fixture/output" 2>&1 || status=$?
  if [[ "$status" -ne 130 ]]; then
    /bin/cat "$fixture/output" >&2
    /bin/cat "$fixture/events.log" >&2
    fail "blocked attach INT returned $status instead of 130"
  fi
  mount="$(/bin/cat "$fixture/state/mount")"
  assert_file_not_contains "$fixture/events.log" 'SWIFT_TEST'
  assert_file_contains "$fixture/events.log" "DETACH:$mount"
  assert_file_contains "$fixture/events.log" 'ATTACH_CHILD_FORWARDED_TERM'
  assert_file_not_contains "$fixture/events.log" 'ATTACH_CHILD_TIMEOUT'
  assert_no_harness_root "$fixture"
}

test_external_term_while_swift_is_blocked_cleans_and_stops() {
  local fixture mount status
  fixture="$(new_fixture blocked-swift-term)"
  status=0
  FAKE_TRANSFER_HARNESS_CASE=blocked_swift_term run_fixture "$fixture" \
    >"$fixture/output" 2>&1 || status=$?
  if [[ "$status" -ne 143 ]]; then
    /bin/cat "$fixture/output" >&2
    /bin/cat "$fixture/events.log" >&2
    fail "blocked Swift TERM returned $status instead of 143"
  fi
  mount="$(/bin/cat "$fixture/state/mount")"
  assert_event_order "$fixture/events.log" 'SWIFT_TEST_BLOCKED' "DETACH:$mount"
  assert_file_contains "$fixture/events.log" 'SWIFT_CHILD_FORWARDED_TERM'
  assert_file_not_contains "$fixture/events.log" 'SWIFT_CHILD_TIMEOUT'
  assert_file_not_contains "$fixture/output" 'PASS: TransferVerificationAPFSTests'
  assert_no_harness_root "$fixture"
}

test_repeated_signals_during_blocked_detach_do_not_interrupt_cleanup() {
  local fixture mount status
  fixture="$(new_fixture repeated-cleanup-signals)"
  status=0
  FAKE_TRANSFER_HARNESS_CASE=repeated_cleanup_signals run_fixture "$fixture" \
    PENGRID_TRANSFER_HARNESS_TEST_SIGNAL_BEFORE_TEST=TERM \
    >"$fixture/output" 2>&1 || status=$?
  [[ "$status" -eq 143 ]] \
    || fail "repeated cleanup signals returned $status instead of 143"
  mount="$(/bin/cat "$fixture/state/mount")"
  assert_file_contains "$fixture/events.log" "DETACH:$mount"
  assert_file_contains "$fixture/events.log" 'DETACH_BLOCKED_FOR_REPEATED_SIGNALS'
  assert_file_contains "$fixture/events.log" 'DETACH_FINISHED_AFTER_REPEATED_SIGNALS'
  assert_no_harness_root "$fixture"
}

test_managed_group_drain_kills_term_ignoring_descendant() {
  local fixture descendant process_still_live=0
  fixture="$(new_fixture orphan-descendant)"
  if ! FAKE_TRANSFER_HARNESS_CASE=orphan_descendant run_fixture "$fixture" \
      >"$fixture/output" 2>&1; then
    /bin/cat "$fixture/output" >&2
    fail 'orphan descendant fixture failed'
  fi
  descendant="$(/bin/cat "$fixture/state/descendant-pid")"
  for _ in {1..20}; do
    if ! /bin/kill -0 "$descendant" 2>/dev/null; then
      process_still_live=0
      break
    fi
    process_still_live=1
    /bin/sleep 0.05
  done
  if [[ "$process_still_live" == 1 ]]; then
    /bin/kill -KILL "$descendant" 2>/dev/null || true
    fail 'managed child descendant survived group drain'
  fi
  assert_no_harness_root "$fixture"
}

tests=(
  test_bilingual_verification_contract_is_documented
  test_success_orders_attach_test_and_cleanup
  test_swift_failure_still_detaches_before_failure
  test_malformed_attach_plist_is_rejected_and_discovered_device_is_cleaned
  test_non_allowlisted_device_is_rejected_without_detach
  test_image_path_mismatch_is_rejected_without_detach
  test_mountpoint_mismatch_is_rejected_without_detach
  test_mountpoint_symlink_substitution_is_rejected
  test_partial_attach_failure_cleans_validated_device_without_running_test
  test_int_cleans_then_terminates_before_swift
  test_term_cleans_then_terminates_before_swift
  test_plist_symlink_targets_are_never_opened_for_output
  test_random_capture_symlink_is_rejected_without_truncating_target
  test_signal_before_attach_launch_cancels_without_claiming_partial_attach
  test_mount_identity_change_before_detach_fails_closed
  test_cleanup_root_substitution_preserves_replacement_tree
  test_external_int_while_attach_is_blocked_cleans_and_stops
  test_external_term_while_swift_is_blocked_cleans_and_stops
  test_repeated_signals_during_blocked_detach_do_not_interrupt_cleanup
  test_managed_group_drain_kills_term_ignoring_descendant
)

if [[ -n "${PENGRID_TRANSFER_CONTRACT_TEST:-}" ]]; then
  requested_test="$PENGRID_TRANSFER_CONTRACT_TEST"
  matched_test=''
  for test_name in "${tests[@]}"; do
    if [[ "$test_name" == "$requested_test" ]]; then
      matched_test="$test_name"
      break
    fi
  done
  [[ -n "$matched_test" ]] || fail "unknown contract test: $requested_test"
  tests=("$matched_test")
fi

passed=0
for test_name in "${tests[@]}"; do
  "$test_name"
  echo "PASS: $test_name"
  passed=$((passed + 1))
done
echo "PASS: $passed transfer verification harness contracts"
exit 0

__FAKE_HDIUTIL__
#!/usr/bin/env bash
set -euo pipefail
STATE='__FAKE_STATE__'
LOG='__FAKE_LOG__'
EXTERNAL='__FAKE_EXTERNAL__'
CASE_NAME="${FAKE_TRANSFER_HARNESS_CASE:-success}"
command_name="${1:-}"
shift || true

xml_attach() {
  local device="$1"
  local mount="$2"
  /bin/cat <<XML
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>system-entities</key><array><dict>
<key>dev-entry</key><string>$device</string>
<key>mount-point</key><string>$mount</string>
</dict></array></dict></plist>
XML
}

xml_info() {
  local device="$1"
  local image="$2"
  local mount="$3"
  /bin/cat <<XML
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>images</key><array><dict>
<key>image-path</key><string>$image</string>
<key>system-entities</key><array><dict>
<key>dev-entry</key><string>$device</string>
<key>mount-point</key><string>$mount</string>
</dict></array>
</dict></array></dict></plist>
XML
}

case "$command_name" in
  create)
    image="${!#}"
    echo "CREATE" >>"$LOG"
    /usr/bin/printf '%s' "$image" >"$STATE/image"
    /usr/bin/printf '%s' "$(/usr/bin/dirname "$image")" >"$STATE/root"
    : >"$image"
    if [[ "$CASE_NAME" == plist_symlink ]]; then
      /usr/bin/printf '%s' 'keep-attach' >"$EXTERNAL/attach-sentinel"
      /usr/bin/printf '%s' 'keep-info' >"$EXTERNAL/info-sentinel"
      /bin/ln -s "$EXTERNAL/attach-sentinel" \
        "$(/usr/bin/dirname "$image")/hdiutil-attach.plist"
      /bin/ln -s "$EXTERNAL/info-sentinel" \
        "$(/usr/bin/dirname "$image")/hdiutil-info.plist"
    fi
    ;;
  attach)
    mount=''
    image="${!#}"
    arguments=("$@")
    for ((index = 0; index < ${#arguments[@]}; index += 1)); do
      if [[ "${arguments[$index]}" == '-mountpoint' ]]; then
        mount="${arguments[$((index + 1))]}"
      fi
    done
    [[ -n "$mount" ]]
    echo "ATTACH" >>"$LOG"
    /bin/mkdir -p "$mount"
    /usr/bin/printf '%s' "$mount" >"$STATE/mount"
    device='/dev/disk42s1'
    [[ "$CASE_NAME" == invalid_device ]] && device='/dev/not-a-disk'
    /usr/bin/printf '%s' "$device" >"$STATE/device"
    output_mount="$mount"
    [[ "$CASE_NAME" == mount_mismatch ]] && output_mount="$STATE/foreign-mount"
    if [[ "$CASE_NAME" == mount_symlink ]]; then
      /bin/rmdir "$mount"
      /bin/ln -s "$EXTERNAL" "$mount"
    fi
    if [[ "$CASE_NAME" == malformed_attach ]]; then
      echo '<not-a-plist'
    else
      xml_attach "$device" "$output_mount"
    fi
    if [[ "$CASE_NAME" == blocked_attach_int ]]; then
      echo 'ATTACH_BLOCKED' >>"$LOG"
      trap 'echo ATTACH_CHILD_FORWARDED_TERM >>"$LOG"; exit 143' TERM
      /bin/kill -INT "${PENGRID_TRANSFER_HARNESS_TEST_TARGET_PID:?}"
      /bin/sleep 5
      echo 'ATTACH_CHILD_TIMEOUT' >>"$LOG"
      exit 124
    fi
    [[ "$CASE_NAME" != partial_attach ]] || exit 70
    ;;
  info)
    echo "INFO" >>"$LOG"
    image="$(/bin/cat "$STATE/image")"
    mount="$(/bin/cat "$STATE/mount")"
    device="$(/bin/cat "$STATE/device")"
    [[ "$CASE_NAME" == image_mismatch ]] && image="$STATE/foreign.dmg"
    [[ "$CASE_NAME" == mount_mismatch ]] && mount="$STATE/foreign-mount"
    xml_info "$device" "$image" "$mount"
    ;;
  detach)
    target="${1:-}"
    echo "DETACH:$target" >>"$LOG"
    [[ "$target" == "$(/bin/cat "$STATE/mount")" ]] || exit 66
    [[ ! -L "$target" ]] || exit 67
    if [[ "$CASE_NAME" == repeated_cleanup_signals ]]; then
      echo 'DETACH_BLOCKED_FOR_REPEATED_SIGNALS' >>"$LOG"
      /bin/kill -INT "${PENGRID_TRANSFER_HARNESS_TEST_TARGET_PID:?}"
      /bin/kill -TERM "${PENGRID_TRANSFER_HARNESS_TEST_TARGET_PID:?}"
      /bin/sleep 0.2
      echo 'DETACH_FINISHED_AFTER_REPEATED_SIGNALS' >>"$LOG"
    fi
    : >"$STATE/detached"
    ;;
  *)
    exit 64
    ;;
esac
__END_FAKE_HDIUTIL__

__FAKE_XCRUN__
#!/usr/bin/env bash
set -euo pipefail
STATE='__FAKE_STATE__'
LOG='__FAKE_LOG__'
expected_root="$(/bin/cat "$STATE/mount")"
[[ "${PENGRID_TRANSFER_APFS_ROOT:-}" == "$expected_root" ]] || exit 65
if [[ "${FAKE_TRANSFER_HARNESS_CASE:-success}" == blocked_swift_term ]]; then
  echo "SWIFT_TEST_BLOCKED:$*" >>"$LOG"
  trap 'echo SWIFT_CHILD_FORWARDED_TERM >>"$LOG"; exit 143' TERM
  /bin/kill -TERM "${PENGRID_TRANSFER_HARNESS_TEST_TARGET_PID:?}"
  /bin/sleep 5
  echo 'SWIFT_CHILD_TIMEOUT' >>"$LOG"
  exit 124
fi
if [[ "${FAKE_TRANSFER_HARNESS_CASE:-success}" == orphan_descendant ]]; then
  /bin/bash -c \
    'trap "" TERM; while :; do /bin/sleep 10; done' \
    >/dev/null 2>&1 &
  /usr/bin/printf '%s' "$!" >"$STATE/descendant-pid"
  echo "SWIFT_TEST:$*" >>"$LOG"
  : >"$STATE/swift-complete"
  exit 0
fi
echo "SWIFT_TEST:$*" >>"$LOG"
: >"$STATE/swift-complete"
[[ "${FAKE_TRANSFER_HARNESS_CASE:-success}" != swift_failure ]] || exit 42
__END_FAKE_XCRUN__

__FAKE_STAT__
#!/usr/bin/env bash
set -euo pipefail
STATE='__FAKE_STATE__'
LOG='__FAKE_LOG__'
EXTERNAL='__FAKE_EXTERNAL__'
CASE_NAME="${FAKE_TRANSFER_HARNESS_CASE:-success}"
target="${!#}"
mount=''
[[ ! -f "$STATE/mount" ]] || mount="$(/bin/cat "$STATE/mount")"
echo "STAT:$target" >>"$LOG"
root=''
[[ ! -f "$STATE/root" ]] || root="$(/bin/cat "$STATE/root")"
candidate="$target"
if [[ "$target" == '.' ]]; then
  candidate="$(pwd -P)"
fi
if [[ "$CASE_NAME" == cleanup_root_substitution \
    && -n "$root" \
    && "$candidate" == "$root" \
    && ! -f "$STATE/root-substituted" ]]; then
  identity="$(/usr/bin/stat -f '%d:%i' "$target")"
  /bin/mv "$root" "$EXTERNAL/original-root"
  /bin/mkdir "$root"
  : >"$root/victim-sentinel"
  /usr/bin/printf '%s' "$root" >"$STATE/replacement-root"
  : >"$STATE/root-substituted"
  echo "$identity"
  exit 0
fi
if [[ "$CASE_NAME" == random_capture_symlink \
    && "$target" == */attach-output.* \
    && ! -f "$STATE/capture-substituted" ]]; then
  identity="$(/usr/bin/stat -f '%i' "$target")"
  /bin/mv "$target" "$EXTERNAL/original-capture"
  /usr/bin/printf '%s' 'keep-capture' >"$EXTERNAL/capture-sentinel"
  /bin/ln -s "$EXTERNAL/capture-sentinel" "$target"
  : >"$STATE/capture-substituted"
  echo "$identity"
  exit 0
fi
if [[ -n "$mount" \
    && "$target" == "$mount" \
    && ! -L "$target" \
    && ! -f "$STATE/detached" ]]; then
  case "$*" in
    *'%d:%i'*)
      if [[ "$CASE_NAME" == mount_identity_change \
          && -f "$STATE/swift-complete" ]]; then
        echo '4242:99'
      else
        echo '4242:1'
      fi
      ;;
    *'%d'*) echo '4242' ;;
    *) exec /usr/bin/stat "$@" ;;
  esac
else
  exec /usr/bin/stat "$@"
fi
__END_FAKE_STAT__
