#!/bin/sh

set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

# XCTest on the macOS 26 hosted runner can stall at class boundaries around the
# Codex suites. Keep full coverage, but run every Codex class in a fresh process.
"$project_root/Scripts/toolchain.sh" swift test \
    --package-path "$project_root" \
    --skip 'Codex.*Tests'

codex_test_suites=$(
    "$project_root/Scripts/toolchain.sh" swift test list --package-path "$project_root" |
        sed -n 's#^\([^/]*\.Codex[^/]*Tests\)/.*#\1#p' |
        LC_ALL=C sort -u
)

if [ -z "$codex_test_suites" ]; then
    echo "No Codex test suites were discovered" >&2
    exit 1
fi

for test_suite in $codex_test_suites; do
    "$project_root/Scripts/toolchain.sh" swift test \
        --package-path "$project_root" \
        --filter "$test_suite"
done
