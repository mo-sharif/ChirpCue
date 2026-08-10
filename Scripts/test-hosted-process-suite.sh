#!/bin/sh

set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_filter=${1:-}

case "$test_filter" in
    PaceNoteCoreTests.CodexAppServerClientTests \
        | PaceNoteCoreTests.CodexProcessTransportTests/testMalformedProtocolOutputTerminatesTheEntireProcessGroup \
        | PaceNoteCoreTests.CodexProcessTransportTests/testPostLaunchAttestationFailsBeforeAnyProtocolInput \
        | PaceNoteCoreTests.CodexProcessTransportTests/testStopEscalatesAfterTermIgnoringProcessAndReapsPID \
        | PaceNoteCoreTests.CodexProcessTransportTests/testStopTerminatesDescendantsHoldingInheritedPipes \
        | PaceNoteCoreTests.CodexProcessTransportTests/testStopWaitsForGracefulProcessExitAndIsIdempotent)
        ;;
    *)
        echo "Unsupported hosted process test filter: $test_filter" >&2
        exit 1
        ;;
esac

echo "Running isolated hosted test: $test_filter"

exec "$project_root/Scripts/toolchain.sh" swift test \
    --package-path "$project_root" \
    --filter "$test_filter"
