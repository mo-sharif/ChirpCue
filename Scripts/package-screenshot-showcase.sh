#!/bin/sh

set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
scene=${1:-meeting}

case "$scene" in
    meeting|setup|privacy) ;;
    *) printf '%s\n' "Scene must be meeting, setup, or privacy." >&2; exit 1 ;;
esac

showcase_root="$project_root/.build/showcase"
app_bundle="$showcase_root/ChirpCue-$scene.app"
contents="$app_bundle/Contents"
macos_dir="$contents/MacOS"
resources_dir="$contents/Resources"

"$project_root/Scripts/toolchain.sh" swift build --package-path "$project_root" --configuration debug --arch arm64
bin_dir=$("$project_root/Scripts/toolchain.sh" swift build --package-path "$project_root" --configuration debug --arch arm64 --show-bin-path)

case "$app_bundle" in
    "$project_root"/.build/showcase/ChirpCue-*.app) ;;
    *) printf '%s\n' "Refusing unsafe showcase path." >&2; exit 1 ;;
esac

rm -rf "$app_bundle"
mkdir -p "$macos_dir" "$resources_dir"
install -m 0755 "$bin_dir/ChirpCue" "$macos_dir/ChirpCue"
install -m 0644 "$project_root/Packaging/Info.plist" "$contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.mosharif.chirpcue.showcase.$scene" "$contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName ChirpCue Showcase" "$contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName ChirpCue Showcase" "$contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :LSEnvironment dict" "$contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :LSEnvironment:CHIRPCUE_SCREENSHOT_SCENE string $scene" "$contents/Info.plist"

for bundle in "$bin_dir"/*.bundle; do
    test -d "$bundle" || continue
    ditto "$bundle" "$resources_dir/$(basename "$bundle")"
done
install -m 0644 "$project_root/Packaging/AppIcon.icns" "$resources_dir/AppIcon.icns"
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$contents/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon" "$contents/Info.plist"

codesign --force --options runtime --entitlements "$project_root/Packaging/PaceNote.entitlements" --sign - "$app_bundle"
printf '%s\n' "$app_bundle"
