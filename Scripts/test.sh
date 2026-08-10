#!/bin/sh

set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

# XCTest on the macOS 26 hosted runner can stall when state crosses test-class
# boundaries. Keep full coverage, but run every discovered class in a fresh
# process so subprocesses, actors, and framework state cannot contaminate the
# next class.
test_suites=$(
    "$project_root/Scripts/toolchain.sh" swift test list --package-path "$project_root" |
        sed -n 's#^\([^/]*Tests\.[^/]*Tests\)/.*#\1#p' |
        LC_ALL=C sort -u
)

if [ -z "$test_suites" ]; then
    echo "No test suites were discovered" >&2
    exit 1
fi

for test_suite in $test_suites; do
    "$project_root/Scripts/toolchain.sh" swift test \
        --package-path "$project_root" \
        --filter "$test_suite"
done
