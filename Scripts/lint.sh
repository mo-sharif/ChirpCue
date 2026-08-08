#!/bin/sh

set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

exec "$project_root/Scripts/toolchain.sh" xcrun swift-format lint \
    --configuration "$project_root/.swift-format" \
    --recursive \
    --parallel \
    --strict \
    "$project_root/Sources" \
    "$project_root/Tests"
