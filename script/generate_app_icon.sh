#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd -P "$SCRIPT_DIR/.." && pwd -P)"
SOURCE="$ROOT_DIR/Assets/Pengrid/AppIcon-1024.png"
OUTPUT="$ROOT_DIR/Assets/Pengrid/Pengrid.icns"
OUTPUT_DIR="$(/usr/bin/dirname "$OUTPUT")"

[[ -f "$SOURCE" && ! -L "$SOURCE" ]] || {
  echo "icon source must be a regular file: $SOURCE" >&2
  exit 1
}
[[ ! -L "$OUTPUT" ]] || {
  echo "icon output must not be a symbolic link: $OUTPUT" >&2
  exit 1
}
[[ ! -e "$OUTPUT" || -f "$OUTPUT" ]] || {
  echo "icon output must be absent or a regular file: $OUTPUT" >&2
  exit 1
}
[[ "$(/usr/bin/sips -g pixelWidth "$SOURCE" | /usr/bin/awk '/pixelWidth/{print $2}')" == 1024 ]]
[[ "$(/usr/bin/sips -g pixelHeight "$SOURCE" | /usr/bin/awk '/pixelHeight/{print $2}')" == 1024 ]]
[[ "$(/usr/bin/sips -g hasAlpha "$SOURCE" | /usr/bin/awk '/hasAlpha/{print $2}')" == "yes" ]]

TEMP_ROOT="${TMPDIR:-/tmp}"
WORK_DIR="$(/usr/bin/mktemp -d "${TEMP_ROOT%/}/Pengrid-icon.XXXXXX")"
PUBLISH_TEMP=""
cleanup() {
  /usr/bin/find "$WORK_DIR" -depth -delete
  [[ -z "${PUBLISH_TEMP:-}" ||
     (! -e "$PUBLISH_TEMP" && ! -L "$PUBLISH_TEMP") ]] ||
    /usr/bin/find "$PUBLISH_TEMP" -depth -delete
}
trap cleanup EXIT
ICONSET="$WORK_DIR/Pengrid.iconset"
CANDIDATE="$WORK_DIR/Pengrid.icns"
PUBLISH_TEMP="$(/usr/bin/mktemp "$OUTPUT_DIR/.Pengrid.icns.XXXXXX")"
/bin/mkdir "$ICONSET"

resolve_developer_dir() {
  local selected="${DEVELOPER_DIR:-}"
  local actool=""

  if [[ -z "$selected" ]]; then
    selected="$(/usr/bin/xcode-select -p 2>/dev/null || true)"
  fi
  if [[ -z "$selected" || ! -d "$selected" ]] ||
     ! actool="$(DEVELOPER_DIR="$selected" /usr/bin/xcrun --find actool 2>/dev/null)" ||
     [[ ! -x "$actool" ]]; then
    echo "Pengrid icon generation requires full Xcode with actool; select it with xcode-select or set DEVELOPER_DIR." >&2
    return 1
  fi
  printf '%s\n' "$selected"
}

make_png() {
  local pixels="$1" name="$2"
  /usr/bin/sips -z "$pixels" "$pixels" "$SOURCE" \
    --out "$ICONSET/$name" >/dev/null
}

make_png 16 icon_16x16.png
make_png 32 icon_16x16@2x.png
make_png 32 icon_32x32.png
make_png 64 icon_32x32@2x.png
make_png 128 icon_128x128.png
make_png 256 icon_128x128@2x.png
make_png 256 icon_256x256.png
make_png 512 icon_256x256@2x.png
make_png 512 icon_512x512.png
make_png 1024 icon_512x512@2x.png

if ! /usr/bin/iconutil -c icns "$ICONSET" -o "$CANDIDATE"; then
  # macOS 26.5 iconutil rejects even iconsets extracted from Apple's own ICNS
  # files. Compile the same images as an asset catalog, then ask iconutil to
  # export AppIcon from the compiled catalog with all ten representations.
  ASSET_CATALOG="$WORK_DIR/Pengrid.xcassets/AppIcon.appiconset"
  COMPILED_ASSETS="$WORK_DIR/compiled"
  /bin/mkdir -p "$ASSET_CATALOG" "$COMPILED_ASSETS"
  /bin/cp "$ICONSET"/*.png "$ASSET_CATALOG/"
  /bin/cat >"$ASSET_CATALOG/Contents.json" <<'JSON'
{
  "images": [
    { "filename": "icon_16x16.png", "idiom": "mac", "scale": "1x", "size": "16x16" },
    { "filename": "icon_16x16@2x.png", "idiom": "mac", "scale": "2x", "size": "16x16" },
    { "filename": "icon_32x32.png", "idiom": "mac", "scale": "1x", "size": "32x32" },
    { "filename": "icon_32x32@2x.png", "idiom": "mac", "scale": "2x", "size": "32x32" },
    { "filename": "icon_128x128.png", "idiom": "mac", "scale": "1x", "size": "128x128" },
    { "filename": "icon_128x128@2x.png", "idiom": "mac", "scale": "2x", "size": "128x128" },
    { "filename": "icon_256x256.png", "idiom": "mac", "scale": "1x", "size": "256x256" },
    { "filename": "icon_256x256@2x.png", "idiom": "mac", "scale": "2x", "size": "256x256" },
    { "filename": "icon_512x512.png", "idiom": "mac", "scale": "1x", "size": "512x512" },
    { "filename": "icon_512x512@2x.png", "idiom": "mac", "scale": "2x", "size": "512x512" }
  ],
  "info": { "author": "xcode", "version": 1 }
}
JSON
  SELECTED_DEVELOPER_DIR="$(resolve_developer_dir)"
  DEVELOPER_DIR="$SELECTED_DEVELOPER_DIR" \
    /usr/bin/xcrun actool "$WORK_DIR/Pengrid.xcassets" \
      --compile "$COMPILED_ASSETS" \
      --platform macosx \
      --minimum-deployment-target 15.0 \
      --app-icon AppIcon \
      --output-partial-info-plist "$WORK_DIR/asset-info.plist" >/dev/null
  /usr/bin/iconutil -c icns "$COMPILED_ASSETS/Assets.car" AppIcon \
    -o "$CANDIDATE"
fi

/usr/bin/iconutil -c iconset "$CANDIDATE" \
  -o "$WORK_DIR/Pengrid-validation.iconset"

validate_png() {
  local pixels="$1" name="$2"
  local image="$WORK_DIR/Pengrid-validation.iconset/$name"
  [[ "$(/usr/bin/sips -g pixelWidth "$image" | /usr/bin/awk '/pixelWidth/{print $2}')" == "$pixels" ]]
  [[ "$(/usr/bin/sips -g pixelHeight "$image" | /usr/bin/awk '/pixelHeight/{print $2}')" == "$pixels" ]]
  [[ "$(/usr/bin/sips -g hasAlpha "$image" | /usr/bin/awk '/hasAlpha/{print $2}')" == "yes" ]]
}

validate_png 16 icon_16x16.png
validate_png 32 icon_16x16@2x.png
validate_png 32 icon_32x32.png
validate_png 64 icon_32x32@2x.png
validate_png 128 icon_128x128.png
validate_png 256 icon_128x128@2x.png
validate_png 256 icon_256x256.png
validate_png 512 icon_256x256@2x.png
validate_png 512 icon_512x512.png
validate_png 1024 icon_512x512@2x.png
/bin/cp "$CANDIDATE" "$PUBLISH_TEMP"
/bin/chmod 0644 "$PUBLISH_TEMP"
/bin/mv -f "$PUBLISH_TEMP" "$OUTPUT"
