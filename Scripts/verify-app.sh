#!/bin/sh

set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
app_bundle=${1:-"$project_root/dist/PaceNote.app"}
plist="$app_bundle/Contents/Info.plist"
executable="$app_bundle/Contents/MacOS/PaceNote"
skill_root="$app_bundle/Contents/Resources/PaceNote_PaceNoteCore.bundle/Resources/Skills/pacenote-meeting-coach"

test -d "$app_bundle"
test -x "$executable"
plutil -lint "$plist"

bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")
minimum_os=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$plist")
microphone_reason=$(/usr/libexec/PlistBuddy -c 'Print :NSMicrophoneUsageDescription' "$plist")
audio_reason=$(/usr/libexec/PlistBuddy -c 'Print :NSAudioCaptureUsageDescription' "$plist")
speech_reason=$(/usr/libexec/PlistBuddy -c 'Print :NSSpeechRecognitionUsageDescription' "$plist")
icon_file=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$plist")

test "$bundle_id" = "com.mosharif.pacenote"
test "$minimum_os" = "26.0"
test -n "$microphone_reason"
test -n "$audio_reason"
test -n "$speech_reason"
test "$icon_file" = "AppIcon"
test -f "$app_bundle/Contents/Resources/AppIcon.icns"
test -f "$skill_root/SKILL.md"
test -f "$skill_root/agents/openai.yaml"

skill_hash=$(shasum -a 256 "$skill_root/SKILL.md" | awk '{print $1}')
metadata_hash=$(shasum -a 256 "$skill_root/agents/openai.yaml" | awk '{print $1}')
test "$skill_hash" = "79d00fac8c5c01f1c0e9216e7864355a88a2e6db4b970e98ce4f041935db3269"
test "$metadata_hash" = "42d8729a9b32fa85b97845efbfa1dc6e5359780bec5161680b858b7fdeada4aa"

codesign --verify --strict --verbose=2 "$app_bundle"
codesign -d --entitlements - "$app_bundle" 2>&1 \
    | grep -q 'com.apple.security.device.audio-input'

file "$executable" | grep -q 'arm64'

printf '%s\n' "Verified $app_bundle"
