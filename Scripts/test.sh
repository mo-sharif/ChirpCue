#!/bin/sh

set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

exec "$project_root/Scripts/toolchain.sh" swift test --package-path "$project_root"
