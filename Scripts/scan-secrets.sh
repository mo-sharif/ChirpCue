#!/bin/sh

set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

if ! command -v gitleaks >/dev/null 2>&1; then
    printf '%s\n' "gitleaks is required for the public-history secret scan." >&2
    printf '%s\n' "Install it with: brew install gitleaks" >&2
    exit 1
fi

exec gitleaks git --no-banner --redact "$project_root"
