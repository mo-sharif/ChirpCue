#!/bin/sh

set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
dist_root="$project_root/dist"
app_bundle="$dist_root/ChirpCue.app"
contents="$app_bundle/Contents"
macos_dir="$contents/MacOS"
resources_dir="$contents/Resources"
plist_source="$project_root/Packaging/Info.plist"
entitlements="$project_root/Packaging/PaceNote.entitlements"
sign_identity=${PACE_NOTE_SIGN_IDENTITY:--}
version=$(tr -d '[:space:]' < "$project_root/VERSION")
build_number=${PACE_NOTE_BUILD_NUMBER:-1}

case "$app_bundle" in
    "$project_root"/dist/ChirpCue.app) ;;
    *) printf '%s\n' "Refusing unsafe app bundle path: $app_bundle" >&2; exit 1 ;;
esac

"$project_root/Scripts/toolchain.sh" swift build \
    --package-path "$project_root" \
    --configuration release \
    --arch arm64

bin_dir=$("$project_root/Scripts/toolchain.sh" swift build \
    --package-path "$project_root" \
    --configuration release \
    --arch arm64 \
    --show-bin-path)

rm -rf "$app_bundle"
mkdir -p "$macos_dir" "$resources_dir"
install -m 0755 "$bin_dir/ChirpCue" "$macos_dir/ChirpCue"
install -m 0644 "$plist_source" "$contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" "$contents/Info.plist"

for bundle in "$bin_dir"/*.bundle; do
    test -d "$bundle" || continue
    ditto "$bundle" "$resources_dir/$(basename "$bundle")"
done

if [ -f "$project_root/Packaging/AppIcon.icns" ]; then
    install -m 0644 "$project_root/Packaging/AppIcon.icns" "$resources_dir/AppIcon.icns"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$contents/Info.plist" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon" "$contents/Info.plist"
fi

if [ "$sign_identity" = "-" ]; then
    codesign --force --options runtime --entitlements "$entitlements" --sign - "$app_bundle"
else
    codesign --force --options runtime --timestamp --entitlements "$entitlements" --sign "$sign_identity" "$app_bundle"
fi

printf '%s\n' "$app_bundle"
