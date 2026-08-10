#!/bin/sh

set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

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
    case "$test_suite" in
        PaceNoteCoreTests.CodexAppServerClientTests | PaceNoteCoreTests.CodexProcessTransportTests)
            continue
            ;;
    esac

    "$project_root/Scripts/toolchain.sh" swift test \
        --package-path "$project_root" \
        --filter "$test_suite"
done
