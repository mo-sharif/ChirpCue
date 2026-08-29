#!/bin/sh

set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
app_bundle=${1:-"$project_root/dist/ChirpCue.app"}
plist="$app_bundle/Contents/Info.plist"
executable="$app_bundle/Contents/MacOS/ChirpCue"
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
test "$display_name" = "ChirpCue"
test "$bundle_name" = "ChirpCue"
test "$bundle_executable" = "ChirpCue"
test ! -e "$app_bundle/Contents/MacOS/PaceNote"
test ! -e "$app_bundle/Contents/MacOS/PrismCue"
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
if /usr/libexec/PlistBuddy -c 'Print :LSEnvironment' "$plist" >/dev/null 2>&1; then
    printf '%s\n' "Unexpected showcase environment in release app" >&2
    exit 1
fi
test -f "$app_bundle/Contents/Resources/AppIcon.icns"
test -f "$skill_root/SKILL.md"
test -f "$skill_root/agents/openai.yaml"

skill_hash=$(shasum -a 256 "$skill_root/SKILL.md" | awk '{print $1}')
metadata_hash=$(shasum -a 256 "$skill_root/agents/openai.yaml" | awk '{print $1}')
test "$skill_hash" = "88b01a2f2ce2acdd1e08fb9a079b42f169e6e748fa37df147e99f0fca0d34f46"
test "$metadata_hash" = "66b0d0648153cfcaf53ee8c6088e0cec1c50599f91cdf0118233630f19ecf94f"

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
if strings "$executable" | grep -q 'CHIRPCUE_SCREENSHOT_SCENE'; then
    printf '%s\n' "Screenshot showcase code leaked into the release executable" >&2
    exit 1
fi

printf '%s\n' "Verified $app_bundle"
