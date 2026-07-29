#!/usr/bin/env bash
set -euo pipefail

tool_name="$(basename "$0")"
executable_name="BloomFileManager"

record() {
  echo "$*" >>"$FAKE_RELEASE_LOG"
}

case "$tool_name" in
  swift)
    is_icon_helper=false
    for argument in "$@"; do
      if [[ "$argument" == "-" ]]; then
        is_icon_helper=true
        break
      fi
    done
    if [[ "$is_icon_helper" == true ]]; then
      /bin/cat >/dev/null
      record "SWIFT_ICON_HELPER"
      [[ "${FAKE_SWIFT_ICON_HELPER_FAIL:-0}" != 1 ]] || exit 1
      [[ -n "${BLOOM_RELEASE_TEST_ICON_HELPER_DEST:-}" ]] || exit 64
      staged_icon="$BLOOM_RELEASE_TEST_ICON_HELPER_DEST"
      /bin/cat /dev/fd/8 >"$staged_icon"
      /bin/chmod 644 "$staged_icon"
      exit 0
    fi
    if [[ " $* " == *" --show-bin-path "* ]]; then
      echo "$FAKE_BUILD_BIN_DIR"
      exit 0
    fi
    if [[ " $* " == *" test "* ]]; then
      record "SWIFT_TEST"
      if [[ "${FAKE_SWIFT_SWAP_ICON_SOURCE_AFTER_OPEN:-0}" == 1 ]]; then
        [[ -n "${FAKE_ICON_SOURCE_PATH:-}" ]] || exit 64
        /bin/unlink "$FAKE_ICON_SOURCE_PATH"
        echo 'attacker-controlled replacement icon' >"$FAKE_ICON_SOURCE_PATH"
        record "SWIFT_TEST_SWAP_ICON_SOURCE_AFTER_OPEN"
      fi
      exit 0
    fi
    if [[ " $* " == *" build "* ]]; then
      record "SWIFT_BUILD"
      /bin/mkdir -p "$FAKE_BUILD_BIN_DIR"
      echo 'fake arm64 executable' >"$FAKE_BUILD_BIN_DIR/$executable_name"
      /bin/chmod +x "$FAKE_BUILD_BIN_DIR/$executable_name"
      exit 0
    fi
    exit 64
    ;;
  xcodebuild)
    record "XCODEBUILD"
    echo 'Xcode 99.0'
    ;;
  security)
    record "SECURITY_IDENTITY"
    echo "  1) ABCDEF0123456789 \"${DEVELOPER_ID_APPLICATION:-Developer ID Application: Test (TEAMID1234)}\""
    echo '     1 valid identities found'
    ;;
  xcrun)
    case "${1:-}" in
      --find)
        record "XCRUN_FIND ${2:-}"
        echo "$FAKE_TOOL_DIR/${2:-tool}"
        ;;
      notarytool)
        case "${2:-}" in
          history)
            record "NOTARY_HISTORY"
            echo '{"history":[]}'
            ;;
          submit)
            record "NOTARY_SUBMIT"
            case "${FAKE_NOTARY_SCHEMA:-complete}" in
              complete)
                echo "{\"id\":\"11111111-2222-3333-4444-555555555555\",\"status\":\"${FAKE_NOTARY_STATUS:-Accepted}\"}"
                ;;
              missing_id)
                echo "{\"status\":\"${FAKE_NOTARY_STATUS:-Accepted}\"}"
                ;;
              missing_status)
                echo '{"id":"11111111-2222-3333-4444-555555555555"}'
                ;;
              leading_dash_id)
                echo '{"id":"-11111111-2222-3333-4444-555555555555","status":"Invalid"}'
                ;;
              non_uuid_id)
                echo '{"id":"not-a-uuid","status":"Invalid"}'
                ;;
              *) exit 64 ;;
            esac
            ;;
          log)
            record "NOTARY_LOG"
            destination="${@: -1}"
            echo '{"issues":[{"message":"fake rejection"}]}' >"$destination"
            ;;
          *) exit 64 ;;
        esac
        ;;
      stapler)
        record "STAPLER ${2:-}"
        ;;
      *) exit 64 ;;
    esac
    ;;
  codesign)
    if [[ " $* " == *" -d"* || " $* " == *" -dvvv"* ]]; then
      echo "Authority=${FAKE_CODESIGN_AUTHORITY:-${DEVELOPER_ID_APPLICATION:-Developer ID Application: Test (TEAMID1234)}}" >&2
      echo "Timestamp=${FAKE_CODESIGN_TIMESTAMP:-Jul 21, 2026 at 12:00:00}" >&2
      echo "CodeDirectory v=20500 size=123 flags=${FAKE_CODESIGN_FLAGS:-0x10000(runtime)} hashes=1+7 location=embedded" >&2
      echo '<?xml version="1.0"?><plist><dict/></plist>'
      exit 0
    fi
    record "CODESIGN"
    ;;
  file)
    echo "${@: -1}: Mach-O 64-bit executable arm64"
    ;;
  lipo)
    record "LIPO"
    echo "${FAKE_LIPO_ARCHS:-arm64}"
    ;;
  getconf)
    if [[ "${1:-}" == DARWIN_USER_CACHE_DIR ]]; then
      echo "$FAKE_USER_CACHE_DIR"
    else
      /usr/bin/getconf "$@"
    fi
    ;;
  *)
    echo "unsupported fake tool: $tool_name" >&2
    exit 64
    ;;
esac
