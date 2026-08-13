#!/usr/bin/env bash
set -euo pipefail

SOURCE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SOURCE_SCRIPT="$SOURCE_ROOT/script/package_release.sh"
SOURCE_BUILD_SCRIPT="$SOURCE_ROOT/script/build_and_run.sh"
SOURCE_FAKE_TOOL="$SOURCE_ROOT/script/tests/fake_release_tool.sh"
SOURCE_ICON="$SOURCE_ROOT/Assets/Pengrid/Pengrid.icns"
SOURCE_NOTICE="$SOURCE_ROOT/THIRD_PARTY_NOTICES.md"
SOURCE_PACKAGE="$SOURCE_ROOT/Package.swift"
CI_WORKFLOW="$SOURCE_ROOT/.github/workflows/ci.yml"
VERSION_1_CHECKLIST="$SOURCE_ROOT/docs/verification/version-1-checklist.md"
VERSION_11_CHECKLIST="$SOURCE_ROOT/docs/verification/version-1.1-checklist.md"
VERSION_12_CHECKLIST="$SOURCE_ROOT/docs/verification/version-1.2-checklist.md"
VERSION_13_CHECKLIST="$SOURCE_ROOT/docs/verification/version-1.3-archive-checklist.md"
RELEASE_GUIDE="$SOURCE_ROOT/docs/release.md"
RAW_TEST_TEMP_DIR="$(/usr/bin/getconf DARWIN_USER_TEMP_DIR)"
TEST_TEMP_DIR="$(cd -P "$RAW_TEST_TEMP_DIR" && pwd -P)"
TEST_ROOT="$(/usr/bin/mktemp -d "$TEST_TEMP_DIR/bloom-release-contracts.XXXXXX")"

cleanup() {
  /usr/bin/find "$TEST_ROOT" -depth -delete
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_file_contains() {
  /usr/bin/grep -q -- "$2" "$1" || fail "$1 does not contain $2"
}

assert_file_not_contains() {
  ! /usr/bin/grep -q -- "$2" "$1" || fail "$1 unexpectedly contains $2"
}

assert_file_exists() {
  [[ -f "$1" ]] || fail "$1 does not exist"
}

assert_files_equal() {
  /usr/bin/cmp -s "$1" "$2" || fail "$1 differs from $2"
}

assert_no_publication_scratch() {
  local release_dir="$1"
  if /usr/bin/find "$release_dir" -maxdepth 1 -mindepth 1 \
      \( -name '.*.new-*' -o -name '.*.backup-*' \) -print | /usr/bin/grep -q .; then
    fail "publication scratch remains in $release_dir"
  fi
}

assert_old_release_is_intact() {
  local release_dir="$1"
  assert_file_contains "$release_dir/Pengrid.app/marker" 'old app'
  assert_file_contains "$release_dir/Pengrid.zip" 'old zip'
  assert_no_publication_scratch "$release_dir"
}

test_version_11_release_contract_is_documented() {
  [[ -f "$VERSION_11_CHECKLIST" ]] || fail 'version 1.1 verification checklist is absent'
  assert_file_contains "$VERSION_11_CHECKLIST" '## Automated evidence'
  assert_file_contains "$VERSION_11_CHECKLIST" '## Static-source evidence'
  assert_file_contains "$VERSION_11_CHECKLIST" '## Physical manual evidence'
  assert_file_contains "$VERSION_11_CHECKLIST" 'MANUAL NOT RUN'
  assert_file_contains "$VERSION_1_CHECKLIST" 'version-1.1-checklist.md'
}

test_version_12_release_contract_is_documented() {
  [[ -f "$VERSION_12_CHECKLIST" ]] || fail 'version 1.2 verification checklist is absent'
  assert_file_contains "$VERSION_12_CHECKLIST" '## Release gate'
  assert_file_contains "$RELEASE_GUIDE" 'Version 1.2 release gates'
  assert_file_contains "$RELEASE_GUIDE" 'Developer Preview'
}

test_version_13_release_contract_is_documented() {
  [[ -f "$VERSION_13_CHECKLIST" ]] || fail 'version 1.3 verification checklist is absent'
  assert_file_contains "$VERSION_13_CHECKLIST" '## Release gate'
  assert_file_contains "$RELEASE_GUIDE" 'Version 1.3 release gates'
  assert_file_contains "$RELEASE_GUIDE" 'Developer Preview'
}

test_release_tests_run_nonparallel() {
  assert_file_contains "$SOURCE_SCRIPT" 'test --enable-swift-testing --no-parallel --filter BloomFileManagerTests --package-path'
  assert_file_contains "$CI_WORKFLOW" 'swift test --enable-swift-testing --no-parallel --filter BloomFileManagerTests'
}

test_version_13_bundle_version_is_declared() {
  assert_file_contains "$SOURCE_SCRIPT" 'APP_VERSION="1.3.0"'
  assert_file_contains "$SOURCE_SCRIPT" 'BUILD_VERSION="9"'
  assert_file_contains "$SOURCE_BUILD_SCRIPT" 'APP_VERSION="1.3.0"'
  assert_file_contains "$SOURCE_BUILD_SCRIPT" 'BUILD_VERSION="9"'
}

test_notice_and_native_linkage_contract_is_declared() {
  assert_file_contains "$SOURCE_SCRIPT" 'THIRD_PARTY_NOTICES.md'
  assert_file_contains "$SOURCE_SCRIPT" 'otool -L'
  assert_file_contains "$SOURCE_SCRIPT" 'libssl'
  assert_file_contains "$SOURCE_SCRIPT" 'libcrypto'
  assert_file_contains "$SOURCE_BUILD_SCRIPT" 'THIRD_PARTY_NOTICES.md'
  assert_file_contains "$SOURCE_BUILD_SCRIPT" 'otool -L'
  assert_file_contains "$SOURCE_BUILD_SCRIPT" 'libssl'
  assert_file_contains "$SOURCE_BUILD_SCRIPT" 'libcrypto'
  assert_file_exists "$SOURCE_NOTICE"
  assert_file_contains "$SOURCE_PACKAGE" 'vendor/minizip-ng/mz_crypt.c'
  assert_file_contains "$SOURCE_PACKAGE" 'vendor/minizip-ng/mz_crypt_apple.c'
  assert_file_contains "$SOURCE_PACKAGE" 'vendor/minizip-ng/mz_strm_wzaes.c'
  assert_file_exists "$SOURCE_ROOT/Sources/EncryptedZIPCore/pengrid_crypt.c"
  assert_file_exists "$SOURCE_ROOT/Sources/EncryptedZIPCore/pengrid_crypt_apple.c"
  assert_file_exists "$SOURCE_ROOT/Sources/EncryptedZIPCore/pengrid_strm_wzaes.c"
  assert_file_contains "$SOURCE_NOTICE" 'Store entries use raw stream bytes and do not use zlib.'
  assert_file_contains "$SOURCE_NOTICE" 'Deflate entries use the system zlib backend'
  assert_file_contains "$SOURCE_NOTICE" 'Pengrid-owned replacements'
  assert_file_contains "$SOURCE_NOTICE" 'vendor/minizip-ng/mz_strm_pkcrypt.c'
  assert_file_not_contains "$SOURCE_NOTICE" 'built-in minizip-ng WinZip AES'
  assert_file_contains "$CI_WORKFLOW" 'script/tests/package_release_contract_tests.sh'
  assert_file_contains "$CI_WORKFLOW" './script/build_and_run.sh --verify'
}

new_fixture() {
  local fixture="$TEST_ROOT/$1"
  /bin/mkdir -p \
    "$fixture/repo/script" \
    "$fixture/repo/Assets/Pengrid" \
    "$fixture/tools" \
    "$fixture/cache" \
    "$fixture/build"
  /bin/cp "$SOURCE_SCRIPT" "$fixture/repo/script/package_release.sh"
  /bin/chmod +x "$fixture/repo/script/package_release.sh"
  /bin/cp "$SOURCE_ICON" "$fixture/repo/Assets/Pengrid/Pengrid.icns"
  /bin/cp "$SOURCE_NOTICE" "$fixture/repo/THIRD_PARTY_NOTICES.md"
  echo 'test fixture' >"$fixture/repo/.bloom-release-test-fixture"
  /bin/cp "$SOURCE_FAKE_TOOL" "$fixture/tools/fake_release_tool.sh"
  /bin/chmod +x "$fixture/tools/fake_release_tool.sh"
  local tool
  for tool in swift xcodebuild security xcrun codesign file lipo hdiutil getconf; do
    /bin/ln -s "$fixture/tools/fake_release_tool.sh" "$fixture/tools/$tool"
  done
  /bin/cat >"$fixture/tools/otool" <<'OTOOL'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == '-L' && $# -eq 2 ]] || exit 64
echo "OTOOL $*" >>"$FAKE_RELEASE_LOG"
if [[ "${FAKE_OTOOL_OPENSSL:-0}" == 1 ]]; then
  echo '/usr/lib/libcrypto.dylib'
else
  echo '/usr/lib/libz.1.dylib'
fi
OTOOL
  /bin/chmod +x "$fixture/tools/otool"
  /bin/cat >"$fixture/tools/cmp" <<'CMP'
#!/usr/bin/env bash
set -euo pipefail
printf 'CMP' >>"$FAKE_RELEASE_LOG"
for argument in "$@"; do
  printf ' %s' "$argument" >>"$FAKE_RELEASE_LOG"
done
printf '\n' >>"$FAKE_RELEASE_LOG"
exec /usr/bin/cmp "$@"
CMP
  /bin/chmod +x "$fixture/tools/cmp"
  echo "$fixture"
}

test_pengrid_release_identity_preserves_legacy_executable_and_icon() {
  local fixture release_dir extracted
  fixture="$(new_fixture pengrid-identity)"
  release_dir="$fixture/repo/dist/release"
  if ! run_fixture "$fixture" FAKE_NOTARY_STATUS=Accepted -- --signed >"$fixture/output" 2>&1; then
    /bin/cat "$fixture/output" >&2
    fail 'signed Pengrid identity fixture failed'
  fi

  assert_file_exists "$release_dir/Pengrid.app/Contents/MacOS/BloomFileManager"
  assert_file_exists "$release_dir/Pengrid.app/Contents/Resources/Pengrid.icns"
  assert_file_contains "$release_dir/Pengrid.app/Contents/Info.plist" \
    '<key>CFBundleDisplayName</key><string>Pengrid</string>'
  assert_file_contains "$release_dir/Pengrid.app/Contents/Info.plist" \
    '<key>CFBundleName</key><string>Pengrid</string>'
  assert_file_contains "$release_dir/Pengrid.app/Contents/Info.plist" \
    '<key>CFBundleExecutable</key><string>BloomFileManager</string>'
  assert_file_contains "$release_dir/Pengrid.app/Contents/Info.plist" \
    '<key>CFBundleIconFile</key><string>Pengrid.icns</string>'
  assert_file_contains "$release_dir/Pengrid.app/Contents/Info.plist" \
    '<key>CFBundleIdentifier</key><string>com.minho.BloomFileManager</string>'
  assert_files_equal \
    "$fixture/repo/Assets/Pengrid/Pengrid.icns" \
    "$release_dir/Pengrid.app/Contents/Resources/Pengrid.icns"
  assert_file_exists "$release_dir/Pengrid.zip"
  assert_file_exists "$release_dir/Pengrid.dmg"
  [[ "$(/usr/bin/zipinfo -1 "$release_dir/Pengrid.zip" | /usr/bin/head -1)" == 'Pengrid.app/' ]] \
    || fail 'signed archive top-level leaf is not Pengrid.app'

  extracted="$fixture/extracted"
  /bin/mkdir "$extracted"
  /usr/bin/ditto -x -k "$release_dir/Pengrid.zip" "$extracted"
  assert_files_equal \
    "$fixture/repo/Assets/Pengrid/Pengrid.icns" \
    "$extracted/Pengrid.app/Contents/Resources/Pengrid.icns"
}

test_icon_source_symlink_is_rejected() {
  local fixture external
  fixture="$(new_fixture icon-source-symlink)"
  external="$fixture/external.icns"
  /bin/cp "$SOURCE_ICON" "$external"
  /bin/unlink "$fixture/repo/Assets/Pengrid/Pengrid.icns"
  /bin/ln -s "$external" "$fixture/repo/Assets/Pengrid/Pengrid.icns"
  if run_fixture "$fixture" -- --unsigned >"$fixture/output" 2>&1; then
    fail 'symbolic-link icon source was accepted'
  fi
  assert_file_contains "$fixture/output" 'app icon must be a regular file'
  [[ ! -e "$fixture/repo/dist/release/Pengrid.app" ]] \
    || fail 'release was published from a symbolic-link icon'
}

test_icon_source_replacement_cannot_change_staged_bytes() {
  local fixture expected icon_source original_identity replacement_identity
  fixture="$(new_fixture icon-source-replacement)"
  expected="$fixture/expected.icns"
  icon_source="$fixture/repo/Assets/Pengrid/Pengrid.icns"
  /bin/cp "$icon_source" "$expected"
  original_identity="$(/usr/bin/stat -f '%d:%i' "$icon_source")"

  if ! run_fixture "$fixture" \
      FAKE_SWIFT_SWAP_ICON_SOURCE_AFTER_OPEN=1 \
      "FAKE_ICON_SOURCE_PATH=$icon_source" \
      -- --unsigned >"$fixture/output" 2>&1; then
    /bin/cat "$fixture/output" >&2
    fail 'icon source replacement fixture failed'
  fi

  assert_file_contains "$fixture/commands.log" 'SWIFT_TEST_SWAP_ICON_SOURCE_AFTER_OPEN'
  assert_file_contains "$icon_source" 'attacker-controlled replacement icon'
  replacement_identity="$(/usr/bin/stat -f '%d:%i' "$icon_source")"
  [[ "$replacement_identity" != "$original_identity" ]] \
    || fail 'fake Swift hook did not replace the canonical icon entry identity'
  assert_files_equal \
    "$expected" \
    "$fixture/repo/dist/release/Pengrid.app/Contents/Resources/Pengrid.icns"
  if /usr/bin/cmp -s \
      "$icon_source" \
      "$fixture/repo/dist/release/Pengrid.app/Contents/Resources/Pengrid.icns"; then
    fail 'published icon adopted the replacement source bytes'
  fi
}

test_selected_swift_invokes_icon_helper() {
  local fixture
  fixture="$(new_fixture selected-swift-icon-helper)"

  if ! run_fixture "$fixture" -- --unsigned >"$fixture/output" 2>&1; then
    /bin/cat "$fixture/output" >&2
    fail 'selected Swift icon helper fixture failed'
  fi

  assert_file_contains "$fixture/commands.log" 'SWIFT_ICON_HELPER'
  assert_files_equal \
    "$fixture/repo/Assets/Pengrid/Pengrid.icns" \
    "$fixture/repo/dist/release/Pengrid.app/Contents/Resources/Pengrid.icns"
}

test_icon_helper_failure_preserves_public_release() {
  local fixture release_dir old_app_identity old_zip_identity
  fixture="$(new_fixture icon-helper-failure)"
  release_dir="$fixture/repo/dist/release"
  /bin/mkdir -p "$release_dir/Pengrid.app"
  echo 'old app' >"$release_dir/Pengrid.app/marker"
  echo 'old zip' >"$release_dir/Pengrid.zip"
  old_app_identity="$(/usr/bin/stat -f '%d:%i' "$release_dir/Pengrid.app")"
  old_zip_identity="$(/usr/bin/stat -f '%d:%i' "$release_dir/Pengrid.zip")"

  if run_fixture "$fixture" \
      FAKE_SWIFT_ICON_HELPER_FAIL=1 \
      -- --unsigned >"$fixture/output" 2>&1; then
    fail 'injected Swift icon helper failure unexpectedly succeeded'
  fi

  assert_file_contains "$fixture/commands.log" 'SWIFT_ICON_HELPER'
  assert_file_contains "$fixture/output" 'unable to publish app icon'
  assert_old_release_is_intact "$release_dir"
  [[ "$(/usr/bin/stat -f '%d:%i' "$release_dir/Pengrid.app")" == "$old_app_identity" ]] \
    || fail 'icon helper failure replaced the existing app entry'
  [[ "$(/usr/bin/stat -f '%d:%i' "$release_dir/Pengrid.zip")" == "$old_zip_identity" ]] \
    || fail 'icon helper failure replaced the existing ZIP entry'
}

test_real_swift_helper_fallback_receives_production_arguments() {
  local fixture
  fixture="$(new_fixture real-swift-helper-fallback)"
  /bin/unlink "$fixture/tools/swift"
  [[ ! -e "$fixture/tools/swift" && ! -L "$fixture/tools/swift" ]] \
    || fail 'real Swift fallback fixture retained a fake swift tool'
  /bin/mkdir -p \
    "$fixture/cache/clang" \
    "$fixture/repo/Sources/BloomFileManager" \
    "$fixture/repo/Tests/BloomFileManagerTests"
  /bin/cat >"$fixture/repo/Package.swift" <<'PACKAGE'
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BloomFileManager",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "BloomFileManager", targets: ["BloomFileManager"])
    ],
    targets: [
        .executableTarget(name: "BloomFileManager"),
        .testTarget(name: "BloomFileManagerTests")
    ]
)
PACKAGE
  /bin/cat >"$fixture/repo/Sources/BloomFileManager/main.swift" <<'SOURCE'
print("fixture")
SOURCE
  /bin/cat >"$fixture/repo/Tests/BloomFileManagerTests/SmokeTests.swift" <<'TEST'
let fixtureBuilds = true
TEST

  if ! run_fixture "$fixture" \
      "CLANG_MODULE_CACHE_PATH=$fixture/cache/clang" \
      -- --unsigned >"$fixture/output" 2>&1; then
    /bin/cat "$fixture/output" >&2
    fail 'real Swift helper fallback fixture failed'
  fi

  assert_file_exists "$fixture/repo/dist/release/Pengrid.app/Contents/MacOS/BloomFileManager"
  assert_files_equal \
    "$fixture/repo/Assets/Pengrid/Pengrid.icns" \
    "$fixture/repo/dist/release/Pengrid.app/Contents/Resources/Pengrid.icns"
}

run_fixture() {
  local fixture="$1"
  shift
  local -a extra_environment=(BLOOM_RELEASE_FAKE_UNUSED=1)
  while [[ "${1:-}" != "--" ]]; do
    extra_environment+=("$1")
    shift
  done
  shift
  : >"$fixture/commands.log"
  env \
    BLOOM_RELEASE_TESTING=1 \
    BLOOM_RELEASE_TEST_TOOL_DIR="$fixture/tools" \
    FAKE_TOOL_DIR="$fixture/tools" \
    FAKE_RELEASE_LOG="$fixture/commands.log" \
    FAKE_BUILD_BIN_DIR="$fixture/build" \
    FAKE_USER_CACHE_DIR="$fixture/cache" \
    BLOOM_RELEASE_TEST_PUBLICATION_LOG="$fixture/commands.log" \
    DEVELOPER_ID_APPLICATION='Developer ID Application: Test (TEAMID1234)' \
    NOTARY_PROFILE='BloomNotaryTest' \
    "${extra_environment[@]}" \
    "$fixture/repo/script/package_release.sh" "$@"
}

test_repo_parent_symlink_is_rejected() {
  local fixture external output
  fixture="$(new_fixture repo-parent-symlink)"
  external="$fixture/external"
  /bin/mkdir "$external"
  echo 'do not touch' >"$external/sentinel"
  /bin/ln -s "$external" "$fixture/repo/dist"
  output="$fixture/output"
  if run_fixture "$fixture" -- --unsigned >"$output" 2>&1; then
    fail 'repo parent symlink was accepted'
  fi
  assert_file_contains "$output" 'symbolic link component'
  assert_file_contains "$external/sentinel" 'do not touch'
  [[ ! -s "$fixture/commands.log" ]] || fail 'commands ran before path rejection'
}

test_cache_parent_symlink_is_rejected() {
  local fixture external output
  fixture="$(new_fixture cache-parent-symlink)"
  external="$fixture/external"
  /bin/mkdir "$external"
  echo 'do not touch' >"$external/sentinel"
  /bin/ln -s "$external" "$fixture/cache/com.minho.BloomFileManager"
  output="$fixture/output"
  if run_fixture "$fixture" BLOOM_RELEASE_TEST_FORCE_FILE_PROVIDER=1 -- --unsigned >"$output" 2>&1; then
    fail 'cache parent symlink was accepted'
  fi
  assert_file_contains "$output" 'symbolic link component'
  assert_file_contains "$external/sentinel" 'do not touch'
}

test_signed_preflight_precedes_build() {
  local fixture history_line test_line
  fixture="$(new_fixture signed-preflight-order)"
  run_fixture "$fixture" FAKE_NOTARY_STATUS=Accepted -- --signed >"$fixture/output" 2>&1
  history_line="$(/usr/bin/grep -n '^NOTARY_HISTORY$' "$fixture/commands.log" | /usr/bin/cut -d: -f1)"
  test_line="$(/usr/bin/grep -n '^SWIFT_TEST$' "$fixture/commands.log" | /usr/bin/cut -d: -f1)"
  [[ -n "$history_line" && -n "$test_line" && "$history_line" -lt "$test_line" ]] \
    || fail 'notary history did not precede build mutation'
}

test_signed_identity_type_is_exact() {
  local fixture
  fixture="$(new_fixture signed-identity-type)"
  if run_fixture "$fixture" \
      'DEVELOPER_ID_APPLICATION=Apple Development: Test (TEAMID1234)' \
      -- --signed >"$fixture/output" 2>&1; then
    fail 'non-Developer-ID identity label was accepted'
  fi
  assert_file_contains "$fixture/output" 'exact Developer ID Application identity label'
  [[ ! -s "$fixture/commands.log" ]] || fail 'preflight commands ran for invalid identity type'
}

test_extra_architecture_is_rejected_before_publication() {
  local fixture
  fixture="$(new_fixture extra-architecture)"
  /bin/mkdir -p "$fixture/repo/dist/release/Pengrid.app"
  echo 'old app' >"$fixture/repo/dist/release/Pengrid.app/marker"
  if run_fixture "$fixture" FAKE_LIPO_ARCHS='arm64 x86_64' -- --unsigned >"$fixture/output" 2>&1; then
    fail 'multi-architecture executable was accepted'
  fi
  assert_file_contains "$fixture/output" 'must be exactly arm64'
  assert_file_contains "$fixture/repo/dist/release/Pengrid.app/marker" 'old app'
}

test_signed_timestamp_is_required() {
  local fixture
  fixture="$(new_fixture signed-timestamp)"
  if run_fixture "$fixture" FAKE_CODESIGN_TIMESTAMP=none -- --signed >"$fixture/output" 2>&1; then
    fail 'signed artifact without a secure timestamp was accepted'
  fi
  assert_file_contains "$fixture/output" 'secure timestamp'
  ! /usr/bin/grep -q '^NOTARY_SUBMIT$' "$fixture/commands.log" \
    || fail 'notary submission ran without a secure timestamp'
}

test_signed_authority_is_required() {
  local fixture
  fixture="$(new_fixture signed-authority)"
  if run_fixture "$fixture" \
      'FAKE_CODESIGN_AUTHORITY=Developer ID Application: Other (OTHERID1234)' \
      -- --signed >"$fixture/output" 2>&1; then
    fail 'artifact signed by a different authority was accepted'
  fi
  assert_file_contains "$fixture/output" 'authority does not match'
  ! /usr/bin/grep -q '^NOTARY_SUBMIT$' "$fixture/commands.log" \
    || fail 'notary submission ran with the wrong signing authority'
}

test_hardened_runtime_is_required() {
  local fixture
  fixture="$(new_fixture signed-runtime)"
  if run_fixture "$fixture" \
      'FAKE_CODESIGN_FLAGS=0x0(none)' \
      -- --signed >"$fixture/output" 2>&1; then
    fail 'artifact without hardened runtime was accepted'
  fi
  assert_file_contains "$fixture/output" 'hardened runtime'
  ! /usr/bin/grep -q '^NOTARY_SUBMIT$' "$fixture/commands.log" \
    || fail 'notary submission ran without hardened runtime'
}

test_unsigned_preserves_existing_signed_zip() {
  local fixture
  fixture="$(new_fixture unsigned-preserves-zip)"
  /bin/mkdir -p "$fixture/repo/dist/release"
  echo 'existing signed zip' >"$fixture/repo/dist/release/Pengrid.zip"
  run_fixture "$fixture" -- --unsigned >"$fixture/output" 2>&1
  assert_file_contains "$fixture/repo/dist/release/Pengrid.zip" 'existing signed zip'
}

test_unsigned_creates_a_verified_dmg() {
  local fixture
  fixture="$(new_fixture unsigned-dmg)"
  run_fixture "$fixture" -- --unsigned >"$fixture/output" 2>&1
  assert_file_exists "$fixture/repo/dist/release/Pengrid.dmg"
  /usr/bin/grep -q '^HDIUTIL$' "$fixture/commands.log" || fail 'hdiutil was not invoked'
}

test_unsigned_notice_is_byte_identical_and_otool_executes() {
  local fixture release_dir log staged_cmp otool_line first_checkpoint app_install public_cmp
  fixture="$(new_fixture unsigned-notice-otool)"
  release_dir="$fixture/repo/dist/release"
  run_fixture "$fixture" -- --unsigned >"$fixture/output" 2>&1
  assert_file_exists "$release_dir/Pengrid.app/Contents/Resources/THIRD_PARTY_NOTICES.md"
  assert_files_equal \
    "$fixture/repo/THIRD_PARTY_NOTICES.md" \
    "$release_dir/Pengrid.app/Contents/Resources/THIRD_PARTY_NOTICES.md"
  assert_file_contains "$fixture/commands.log" 'OTOOL -L '
  assert_file_contains "$fixture/commands.log" 'CMP -s /dev/fd/20 '
  assert_file_contains "$fixture/commands.log" 'CMP -s /dev/fd/21 '
  assert_file_contains "$fixture/commands.log" 'PUBLICATION_CHECKPOINT before_publication'
  assert_file_contains "$fixture/commands.log" 'PUBLICATION_CHECKPOINT after_app_install'
  log="$fixture/commands.log"
  staged_cmp="$(/usr/bin/grep -n -m1 -F 'CMP -s /dev/fd/20 ' "$log" | /usr/bin/cut -d: -f1)"
  otool_line="$(/usr/bin/grep -n -m1 -F 'OTOOL -L ' "$log" | /usr/bin/cut -d: -f1)"
  first_checkpoint="$(/usr/bin/grep -n -m1 -F 'PUBLICATION_CHECKPOINT ' "$log" | /usr/bin/cut -d: -f1)"
  app_install="$(/usr/bin/grep -n -m1 -F 'PUBLICATION_CHECKPOINT after_app_install' "$log" | /usr/bin/cut -d: -f1)"
  public_cmp="$(/usr/bin/grep -n -m1 -F 'CMP -s /dev/fd/21 ' "$log" | /usr/bin/cut -d: -f1)"
  [[ "$staged_cmp" -lt "$first_checkpoint" ]] || fail 'staged notice cmp ran after publication checkpoint'
  [[ "$otool_line" -lt "$first_checkpoint" ]] || fail 'staged otool ran after publication checkpoint'
  [[ "$app_install" -lt "$public_cmp" ]] || fail 'public notice cmp ran before app install checkpoint'
}

test_openssl_dependency_is_rejected_before_publication() {
  local fixture release_dir
  fixture="$(new_fixture openssl-linkage-rejected)"
  release_dir="$fixture/repo/dist/release"
  /bin/mkdir -p "$release_dir/Pengrid.app"
  echo 'old app' >"$release_dir/Pengrid.app/marker"
  echo 'old dmg' >"$release_dir/Pengrid.dmg"
  if run_fixture "$fixture" FAKE_OTOOL_OPENSSL=1 -- --unsigned >"$fixture/output" 2>&1; then
    fail 'OpenSSL-linked executable was accepted'
  fi
  assert_file_contains "$fixture/commands.log" 'OTOOL -L '
  assert_file_contains "$fixture/output" 'unexpected OpenSSL dependency'
  assert_file_contains "$release_dir/Pengrid.app/marker" 'old app'
  assert_file_contains "$release_dir/Pengrid.dmg" 'old dmg'
  ! /usr/bin/grep -q '^PUBLICATION_CHECKPOINT ' "$fixture/commands.log" \
    || fail 'OpenSSL-linked executable reached a publication checkpoint'
  assert_no_publication_scratch "$release_dir"
}

test_rejected_notary_preserves_release_and_diagnostics() {
  local fixture diagnostic_path
  fixture="$(new_fixture rejected-notary)"
  /bin/mkdir -p "$fixture/repo/dist/release/Pengrid.app"
  echo 'old app' >"$fixture/repo/dist/release/Pengrid.app/marker"
  echo 'old zip' >"$fixture/repo/dist/release/Pengrid.zip"
  if run_fixture "$fixture" FAKE_NOTARY_STATUS=Invalid -- --signed >"$fixture/output" 2>&1; then
    fail 'rejected notarization was accepted'
  fi
  assert_file_contains "$fixture/repo/dist/release/Pengrid.app/marker" 'old app'
  assert_file_contains "$fixture/repo/dist/release/Pengrid.zip" 'old zip'
  assert_no_publication_scratch "$fixture/repo/dist/release"
  assert_file_contains "$fixture/commands.log" 'NOTARY_SUBMIT'
  assert_file_contains "$fixture/commands.log" 'NOTARY_LOG'
  ! /usr/bin/grep -q '^STAPLER' "$fixture/commands.log" || fail 'stapler ran after rejection'
  assert_file_contains "$fixture/output" 'notary diagnostics preserved at:'
  diagnostic_path="$(/usr/bin/grep 'notary diagnostics preserved at:' "$fixture/output" \
    | /usr/bin/tail -1 | /usr/bin/sed 's/^.*notary diagnostics preserved at: //')"
  [[ -f "$diagnostic_path/submission.json" ]] || fail 'structured JSON diagnostic was not preserved'
  [[ -f "$diagnostic_path/submission.plist" ]] || fail 'structured plist diagnostic was not preserved'
  [[ -f "$diagnostic_path/notary-log.json" ]] || fail 'notary rejection log was not preserved'
}

test_publish_failure_rolls_back_both_artifacts() {
  local fixture
  fixture="$(new_fixture publish-rollback)"
  /bin/mkdir -p "$fixture/repo/dist/release/Pengrid.app"
  echo 'old app' >"$fixture/repo/dist/release/Pengrid.app/marker"
  echo 'old zip' >"$fixture/repo/dist/release/Pengrid.zip"
  if run_fixture "$fixture" \
      FAKE_NOTARY_STATUS=Accepted \
      BLOOM_RELEASE_TEST_FAIL_POINT=before_zip_install \
      -- --signed >"$fixture/output" 2>&1; then
    fail 'injected publication failure unexpectedly succeeded'
  fi
  assert_file_contains "$fixture/repo/dist/release/Pengrid.app/marker" 'old app'
  assert_file_contains "$fixture/repo/dist/release/Pengrid.zip" 'old zip'
  assert_no_publication_scratch "$fixture/repo/dist/release"
  assert_file_contains "$fixture/commands.log" 'NOTARY_SUBMIT'
  assert_file_contains "$fixture/commands.log" 'STAPLER staple'
}

test_abrupt_publication_exit_rolls_back() {
  local mode point fixture release_dir exit_code old_app_identity old_zip_identity
  for mode in die term int; do
    for point in after_app_backup after_app_install after_zip_backup after_zip_install; do
      fixture="$(new_fixture "abrupt-$mode-$point")"
      release_dir="$fixture/repo/dist/release"
      /bin/mkdir -p "$release_dir/Pengrid.app"
      echo 'old app' >"$release_dir/Pengrid.app/marker"
      echo 'old zip' >"$release_dir/Pengrid.zip"
      old_app_identity="$(/usr/bin/stat -f '%d:%i' "$release_dir/Pengrid.app")"
      old_zip_identity="$(/usr/bin/stat -f '%d:%i' "$release_dir/Pengrid.zip")"
      set +e
      run_fixture "$fixture" \
        FAKE_NOTARY_STATUS=Accepted \
        BLOOM_RELEASE_TEST_FORCE_FILE_PROVIDER=1 \
        BLOOM_RELEASE_TEST_FAIL_POINT="$point" \
        BLOOM_RELEASE_TEST_FAIL_MODE="$mode" \
        -- --signed >"$fixture/output" 2>&1
      exit_code=$?
      set -e
      [[ $exit_code -ne 0 ]] || fail "$mode at $point unexpectedly succeeded"
      assert_old_release_is_intact "$release_dir"
      [[ "$(/usr/bin/stat -f '%d:%i' "$release_dir/Pengrid.app")" == "$old_app_identity" ]] \
        || fail "$mode at $point did not restore the exact old app entry"
      [[ "$(/usr/bin/stat -f '%d:%i' "$release_dir/Pengrid.zip")" == "$old_zip_identity" ]] \
        || fail "$mode at $point did not restore the exact old ZIP entry"
      if [[ -L "$release_dir/Pengrid.app" ]]; then
        [[ -e "$release_dir/Pengrid.app" ]] || fail "$mode at $point left a dangling app link"
      fi
      if /usr/bin/find "$fixture/cache" -type d -path '*/versions/*' -print \
          | /usr/bin/grep -q .; then
        fail "$mode at $point retained an unpublished cache-backed version"
      fi
    done
  done
}

test_owned_old_file_provider_version_is_reclaimed() {
  local fixture old_target old_version new_target
  fixture="$(new_fixture owned-version-reclaim)"
  run_fixture "$fixture" BLOOM_RELEASE_TEST_FORCE_FILE_PROVIDER=1 -- --unsigned >"$fixture/first-output" 2>&1
  old_target="$(/usr/bin/readlink "$fixture/repo/dist/release/Pengrid.app")"
  old_version="$(/usr/bin/dirname "$old_target")"
  [[ -d "$old_version" ]] || fail 'first owned cache version is absent'
  run_fixture "$fixture" BLOOM_RELEASE_TEST_FORCE_FILE_PROVIDER=1 -- --unsigned >"$fixture/second-output" 2>&1
  new_target="$(/usr/bin/readlink "$fixture/repo/dist/release/Pengrid.app")"
  [[ "$new_target" != "$old_target" && -d "$new_target" ]] || fail 'new cache version was not published'
  [[ ! -e "$old_version" && ! -L "$old_version" ]] || fail 'old owned cache version leaked'
}

test_external_file_provider_target_is_never_deleted() {
  local fixture external release_dir
  fixture="$(new_fixture external-version-preserved)"
  external="$fixture/external-app"
  release_dir="$fixture/repo/dist/release"
  /bin/mkdir -p "$external" "$release_dir"
  echo 'external sentinel' >"$external/sentinel"
  /bin/ln -s "$external" "$release_dir/Pengrid.app"
  run_fixture "$fixture" BLOOM_RELEASE_TEST_FORCE_FILE_PROVIDER=1 -- --unsigned >"$fixture/output" 2>&1
  assert_file_contains "$external/sentinel" 'external sentinel'
}

test_missing_notary_fields_preserve_diagnostics() {
  local schema fixture release_dir diagnostic_path
  for schema in missing_id missing_status; do
    fixture="$(new_fixture "notary-$schema")"
    release_dir="$fixture/repo/dist/release"
    /bin/mkdir -p "$release_dir/Pengrid.app"
    echo 'old app' >"$release_dir/Pengrid.app/marker"
    echo 'old zip' >"$release_dir/Pengrid.zip"
    if run_fixture "$fixture" FAKE_NOTARY_SCHEMA="$schema" -- --signed >"$fixture/output" 2>&1; then
      fail "$schema notary response was accepted"
    fi
    assert_old_release_is_intact "$release_dir"
    assert_file_contains "$fixture/output" 'notary diagnostics preserved at:'
    assert_file_contains "$fixture/output" 'missing required'
    diagnostic_path="$(/usr/bin/grep 'notary diagnostics preserved at:' "$fixture/output" \
      | /usr/bin/tail -1 | /usr/bin/sed 's/^.*notary diagnostics preserved at: //')"
    [[ -f "$diagnostic_path/submission.json" ]] || fail "$schema raw JSON was not preserved"
    [[ -f "$diagnostic_path/submission.plist" ]] || fail "$schema plist was not preserved"
    if [[ "$schema" == missing_id ]]; then
      ! /usr/bin/grep -q '^NOTARY_LOG$' "$fixture/commands.log" \
        || fail 'notary log was fetched without a submission id'
    fi
  done
}

test_malformed_notary_ids_are_never_used_for_log_requests() {
  local schema fixture release_dir diagnostic_path
  for schema in leading_dash_id non_uuid_id; do
    fixture="$(new_fixture "notary-$schema")"
    release_dir="$fixture/repo/dist/release"
    /bin/mkdir -p "$release_dir/Pengrid.app"
    echo 'old app' >"$release_dir/Pengrid.app/marker"
    echo 'old zip' >"$release_dir/Pengrid.zip"
    if run_fixture "$fixture" FAKE_NOTARY_SCHEMA="$schema" -- --signed >"$fixture/output" 2>&1; then
      fail "$schema notary response was accepted"
    fi
    assert_old_release_is_intact "$release_dir"
    assert_file_contains "$fixture/output" 'notary diagnostics preserved at:'
    assert_file_contains "$fixture/output" 'unsafe submission identifier'
    diagnostic_path="$(/usr/bin/grep 'notary diagnostics preserved at:' "$fixture/output" \
      | /usr/bin/tail -1 | /usr/bin/sed 's/^.*notary diagnostics preserved at: //')"
    [[ -f "$diagnostic_path/submission.json" ]] || fail "$schema raw JSON was not preserved"
    [[ -f "$diagnostic_path/submission.plist" ]] || fail "$schema plist was not preserved"
    ! /usr/bin/grep -q '^NOTARY_LOG$' "$fixture/commands.log" \
      || fail "$schema identifier was used for a notary log request"
  done
}

run_all_contract_tests() {
  test_version_11_release_contract_is_documented
  test_version_12_release_contract_is_documented
  test_version_13_release_contract_is_documented
  test_release_tests_run_nonparallel
  test_version_13_bundle_version_is_declared
  test_notice_and_native_linkage_contract_is_declared
  test_pengrid_release_identity_preserves_legacy_executable_and_icon
  test_icon_source_symlink_is_rejected
  test_icon_source_replacement_cannot_change_staged_bytes
  test_selected_swift_invokes_icon_helper
  test_icon_helper_failure_preserves_public_release
  test_real_swift_helper_fallback_receives_production_arguments
  test_repo_parent_symlink_is_rejected
  test_cache_parent_symlink_is_rejected
  test_signed_preflight_precedes_build
  test_signed_identity_type_is_exact
  test_extra_architecture_is_rejected_before_publication
  test_signed_timestamp_is_required
  test_signed_authority_is_required
  test_hardened_runtime_is_required
  test_unsigned_preserves_existing_signed_zip
  test_unsigned_creates_a_verified_dmg
  test_unsigned_notice_is_byte_identical_and_otool_executes
  test_openssl_dependency_is_rejected_before_publication
  test_rejected_notary_preserves_release_and_diagnostics
  test_publish_failure_rolls_back_both_artifacts
  test_abrupt_publication_exit_rolls_back
  test_owned_old_file_provider_version_is_reclaimed
  test_external_file_provider_target_is_never_deleted
  test_missing_notary_fields_preserve_diagnostics
  test_malformed_notary_ids_are_never_used_for_log_requests
}

case "${1:-all}" in
  all)
    run_all_contract_tests
    ;;
  icon-source-replacement)
    test_icon_source_replacement_cannot_change_staged_bytes
    ;;
  icon-helper)
    test_selected_swift_invokes_icon_helper
    ;;
  icon-helper-failure)
    test_icon_helper_failure_preserves_public_release
    ;;
  real-swift-helper-fallback)
    test_real_swift_helper_fallback_receives_production_arguments
    ;;
  notice-otool)
    test_unsigned_notice_is_byte_identical_and_otool_executes
    ;;
  openssl-linkage)
    test_openssl_dependency_is_rejected_before_publication
    ;;
  *)
    fail "unknown contract test selection: $1"
    ;;
esac

echo 'package release contract tests: PASS'
