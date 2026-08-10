#!/bin/sh

set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

# XCTest on the macOS 26 hosted runner can stall when CodexOutputTests follows the
# subprocess-heavy Codex generator suite in the same process. Keep full coverage,
# but give the small output-schema suite a fresh process.
"$project_root/Scripts/toolchain.sh" swift test \
    --package-path "$project_root" \
    --skip CodexOutputTests

exec "$project_root/Scripts/toolchain.sh" swift test \
    --package-path "$project_root" \
    --filter CodexOutputTests
