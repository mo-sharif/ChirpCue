#!/bin/sh

set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_suite=${1:-}

case "$test_suite" in
    PaceNoteCoreTests.CodexAppServerClientTests | PaceNoteCoreTests.CodexProcessTransportTests)
        ;;
    *)
        echo "Unsupported hosted process test suite: $test_suite" >&2
        exit 1
        ;;
esac

exec "$project_root/Scripts/toolchain.sh" swift test \
    --package-path "$project_root" \
    --filter "$test_suite"
