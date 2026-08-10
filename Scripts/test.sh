#!/bin/sh

set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

# XCTest on the macOS 26 hosted runner can stall at class boundaries around the
# subprocess-heavy Codex client and generator suites. Keep full coverage, but
# isolate those suites and the adjacent output-schema suite in fresh processes.
"$project_root/Scripts/toolchain.sh" swift test \
    --package-path "$project_root" \
    --skip 'CodexAppServerClientTests|CodexMeetingResponseGeneratorTests|CodexOutputTests'

"$project_root/Scripts/toolchain.sh" swift test \
    --package-path "$project_root" \
    --filter CodexAppServerClientTests

"$project_root/Scripts/toolchain.sh" swift test \
    --package-path "$project_root" \
    --filter CodexMeetingResponseGeneratorTests

exec "$project_root/Scripts/toolchain.sh" swift test \
    --package-path "$project_root" \
    --filter CodexOutputTests
