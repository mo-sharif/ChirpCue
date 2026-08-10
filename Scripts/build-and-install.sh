#!/bin/sh

set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

"$project_root/Scripts/package-app.sh"
"$project_root/Scripts/verify-app.sh"
"$project_root/Scripts/install-personal-app.sh"

printf '%s\n' "ChirpCue is installed. Open it from Applications or run: open /Applications/ChirpCue.app"
