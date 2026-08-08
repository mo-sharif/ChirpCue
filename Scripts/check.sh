#!/bin/sh

set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

"$project_root/Scripts/lint.sh"
"$project_root/Scripts/test.sh"
"$project_root/Scripts/package-app.sh"
"$project_root/Scripts/verify-app.sh"
