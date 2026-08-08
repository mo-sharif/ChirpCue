#!/bin/sh

set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
app_bundle="$project_root/dist/PaceNote.app"
notary_zip="$project_root/dist/PaceNote-notary.zip"
release_zip="$project_root/dist/PaceNote-arm64.zip"

: "${PACE_NOTE_SIGN_IDENTITY:?PACE_NOTE_SIGN_IDENTITY is required}"
: "${PACE_NOTE_NOTARY_KEY_PATH:?PACE_NOTE_NOTARY_KEY_PATH is required}"
: "${PACE_NOTE_NOTARY_KEY_ID:?PACE_NOTE_NOTARY_KEY_ID is required}"
: "${PACE_NOTE_NOTARY_ISSUER_ID:?PACE_NOTE_NOTARY_ISSUER_ID is required}"

PACE_NOTE_SIGN_IDENTITY="$PACE_NOTE_SIGN_IDENTITY" "$project_root/Scripts/package-app.sh"
"$project_root/Scripts/verify-app.sh" "$app_bundle"

rm -f "$notary_zip" "$release_zip" "$project_root/dist/SHA256SUMS"
ditto -c -k --sequesterRsrc --keepParent "$app_bundle" "$notary_zip"

xcrun notarytool submit "$notary_zip" \
    --key "$PACE_NOTE_NOTARY_KEY_PATH" \
    --key-id "$PACE_NOTE_NOTARY_KEY_ID" \
    --issuer "$PACE_NOTE_NOTARY_ISSUER_ID" \
    --wait \
    --timeout 20m

xcrun stapler staple "$app_bundle"
xcrun stapler validate "$app_bundle"
spctl --assess --type execute --verbose=4 "$app_bundle"

ditto -c -k --sequesterRsrc --keepParent "$app_bundle" "$release_zip"
(cd "$project_root/dist" && shasum -a 256 "$(basename "$release_zip")" > SHA256SUMS)

printf '%s\n' "$release_zip"
