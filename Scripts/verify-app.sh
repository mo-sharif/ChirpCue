#!/bin/sh

set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
app_bundle=${1:-"$project_root/dist/PrismCue.app"}
plist="$app_bundle/Contents/Info.plist"
executable="$app_bundle/Contents/MacOS/PrismCue"
skill_root="$app_bundle/Contents/Resources/PaceNote_PaceNoteCore.bundle/Resources/Skills/pacenote-meeting-coach"

test -d "$app_bundle"
test -x "$executable"
plutil -lint "$plist"

bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")
display_name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$plist")
bundle_name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$plist")
bundle_executable=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist")
minimum_os=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$plist")
microphone_reason=$(/usr/libexec/PlistBuddy -c 'Print :NSMicrophoneUsageDescription' "$plist")
audio_reason=$(/usr/libexec/PlistBuddy -c 'Print :NSAudioCaptureUsageDescription' "$plist")
speech_reason=$(/usr/libexec/PlistBuddy -c 'Print :NSSpeechRecognitionUsageDescription' "$plist")
icon_file=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$plist")
bundle_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")
expected_version=$(tr -d '[:space:]' < "$project_root/VERSION")

test "$bundle_id" = "com.mosharif.pacenote"
test "$display_name" = "PrismCue"
test "$bundle_name" = "PrismCue"
test "$bundle_executable" = "PrismCue"
test ! -e "$app_bundle/Contents/MacOS/PaceNote"
test "$minimum_os" = "26.0"
test -n "$microphone_reason"
test -n "$audio_reason"
test -n "$speech_reason"
test "$icon_file" = "AppIcon"
test -n "$expected_version"
test "$bundle_version" = "$expected_version"
if /usr/libexec/PlistBuddy -c 'Print :NSAppleEventsUsageDescription' "$plist" >/dev/null 2>&1; then
    printf '%s\n' "Unexpected Apple Events usage description" >&2
    exit 1
fi
test -f "$app_bundle/Contents/Resources/AppIcon.icns"
test -f "$skill_root/SKILL.md"
test -f "$skill_root/agents/openai.yaml"

skill_hash=$(shasum -a 256 "$skill_root/SKILL.md" | awk '{print $1}')
metadata_hash=$(shasum -a 256 "$skill_root/agents/openai.yaml" | awk '{print $1}')
test "$skill_hash" = "bd28c282bcc2021b1495d23c16e377557b13a5699005c7df47f15308f88d5db6"
test "$metadata_hash" = "0cb4fd04ec760d0aa274ac3b499826bd8a4d4782a02674b94b49912815552b4c"

codesign --verify --strict --verbose=2 "$app_bundle"
codesign -d --verbose=4 "$app_bundle" 2>&1 \
    | grep -Eq '^CodeDirectory .*flags=.*\(.*runtime.*\)'
codesign -d --entitlements - "$app_bundle" 2>&1 \
    | grep -q 'com.apple.security.device.audio-input'
if codesign -d --entitlements - "$app_bundle" 2>&1 \
    | grep -Eq 'com.apple.security.automation.apple-events|com.apple.security.get-task-allow'
then
    printf '%s\n' "Unexpected automation or debug entitlement" >&2
    exit 1
fi

file "$executable" | grep -q 'arm64'

printf '%s\n' "Verified $app_bundle"
