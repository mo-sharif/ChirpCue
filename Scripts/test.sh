#!/bin/sh

set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

# XCTest on the macOS 26 hosted runner can stall after the subprocess-heavy Codex
# generator suite. Keep full coverage, but isolate that suite and its adjacent
# output-schema suite in fresh processes.
"$project_root/Scripts/toolchain.sh" swift test \
    --package-path "$project_root" \
    --skip 'CodexMeetingResponseGeneratorTests|CodexOutputTests'

"$project_root/Scripts/toolchain.sh" swift test \
    --package-path "$project_root" \
    --filter CodexMeetingResponseGeneratorTests

exec "$project_root/Scripts/toolchain.sh" swift test \
    --package-path "$project_root" \
    --filter CodexOutputTests
