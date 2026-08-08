#!/bin/sh

set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
sources="$project_root/Sources"

# ChirpCue displays text for the user to choose and speak. Production code must not gain
# direct speech output, clipboard mutation, UI automation, Apple Events, or an ambient
# network client without an explicit product-boundary review.
forbidden_runtime_apis='NSSpeechSynthesizer|AVSpeechSynthesizer|AVAudioPlayer|AVPlayer|AVQueuePlayer|NSSound|AudioServicesPlaySystemSound|AudioQueueNewOutput|NSPasteboard|CGEvent|AXUIElement|IOHIDEventSystemClient|IOHIDPostEvent|NSAppleScript|ScriptingBridge|SBApplication|NSAppleEventDescriptor|/usr/bin/(say|pbcopy|osascript|curl)|URLSession|NSURLConnection|NWConnection|NWBrowser|NWListener|CFHTTP|CFStreamCreatePairWithSocketToHost|import[[:space:]]+(Network|CFNetwork)'

if LC_ALL=C /usr/bin/grep -ERq "$forbidden_runtime_apis" "$sources"; then
    printf '%s\n' "Production source contains an API that can speak, paste, automate, or bypass the reviewed provider path." >&2
    exit 1
else
    scan_status=$?
    if test "$scan_status" -ne 1; then
        printf '%s\n' "Product-boundary source scan could not be completed." >&2
        exit 1
    fi
fi

printf '%s\n' "Verified consent-first product API boundaries"
