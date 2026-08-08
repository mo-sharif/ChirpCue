#!/bin/zsh

set -euo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_PNG="${1:-$REPOSITORY_ROOT/Packaging/AppIcon-1024.png}"
OUTPUT_ICNS="${2:-$REPOSITORY_ROOT/Packaging/AppIcon.icns}"

if [[ ! -f "$SOURCE_PNG" ]]; then
  echo "Missing app-icon source: $SOURCE_PNG" >&2
  exit 1
fi

ICON_BUILD_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/chirpcue-icon.XXXXXX")"
ICONSET="$ICON_BUILD_ROOT/AppIcon.iconset"

cleanup() {
  /bin/rm -rf -- "$ICON_BUILD_ROOT"
}
trap cleanup EXIT

/bin/mkdir -p "$ICONSET"

render() {
  local pixels="$1"
  local filename="$2"
  /usr/bin/sips -z "$pixels" "$pixels" "$SOURCE_PNG" --out "$ICONSET/$filename" >/dev/null
}

render 16 icon_16x16.png
render 32 icon_16x16@2x.png
render 32 icon_32x32.png
render 64 icon_32x32@2x.png
render 128 icon_128x128.png
render 256 icon_128x128@2x.png
render 256 icon_256x256.png
render 512 icon_256x256@2x.png
render 512 icon_512x512.png
render 1024 icon_512x512@2x.png

/usr/bin/iconutil -c icns "$ICONSET" -o "$OUTPUT_ICNS"
echo "Built $OUTPUT_ICNS"
