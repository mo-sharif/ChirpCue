#!/bin/sh

set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

"$project_root/Scripts/verify-product-boundaries.sh"

exec "$project_root/Scripts/toolchain.sh" xcrun swift-format lint \
    --configuration "$project_root/.swift-format" \
    --recursive \
    --parallel \
    --strict \
    "$project_root/Sources" \
    "$project_root/Tests"
