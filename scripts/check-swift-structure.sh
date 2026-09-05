#!/bin/bash

# SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
# SPDX-License-Identifier: MIT

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd -P)"
project_dir="$(cd "$script_dir/.." && pwd -P)"
maximum_lines=700
failed=0

cd "$project_dir"

while IFS= read -r -d '' path; do
    line_count="$(LC_ALL=C awk 'END { print NR }' "$path")"
    if ((line_count > maximum_lines)); then
        printf '%s has %s lines; Swift files may contain at most %s.\n' \
            "$path" "$line_count" "$maximum_lines" >&2
        failed=1
    fi
done < <(find Sources Tests -type f -name '*.swift' -print0)

if ((failed)); then
    exit 1
fi

printf 'Swift structure verified: every source and test file is at most %s lines.\n' \
    "$maximum_lines"
