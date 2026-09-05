#!/bin/bash

# SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
# SPDX-License-Identifier: MIT

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd -P)"
project_dir="$(cd "$script_dir/.." && pwd -P)"
line_limit=150
failed=0

cd "$project_dir"

check_line_limit() {
    local path="$1"
    local lines
    lines="$(wc -l < "$path" | tr -d ' ')"
    if ((lines > line_limit)); then
        printf '%s has %s lines; limit is %s\n' "$path" "$lines" "$line_limit" >&2
        failed=1
    fi
}

check_line_limit AGENTS.md
while IFS= read -r -d '' path; do
    if [[ ! -s "$path" ]] || LC_ALL=C grep -Iq '' "$path"; then
        check_line_limit "$path"
    fi
done < <(find .agents/skills -type f -print0)

while IFS= read -r -d '' skill; do
    skill_dir="$(dirname "$skill")"
    skill_name="$(basename "$skill_dir")"
    declared_name="$(sed -n 's/^name: //p' "$skill" | head -n 1)"
    description="$(sed -n 's/^description: //p' "$skill" | head -n 1)"

    if [[ "$declared_name" != "$skill_name" ]]; then
        printf '%s declares mismatched name %s\n' "$skill" "$declared_name" >&2
        failed=1
    fi
    if [[ "$skill_name" == *voice-activation* ]]; then
        printf '%s redundantly repeats the project name\n' "$skill" >&2
        failed=1
    fi
    if [[ "$description" != "Use when "* ]]; then
        printf '%s description must start with Use when\n' "$skill" >&2
        failed=1
    fi
    if ! grep -Fq "$skill" AGENTS.md; then
        printf 'AGENTS.md does not route project skill: %s\n' "$skill" >&2
        failed=1
    fi

    while IFS= read -r reference; do
        [[ -z "$reference" ]] && continue
        if [[ ! -f "$skill_dir/$reference" ]]; then
            printf '%s routes missing reference: %s\n' "$skill" "$reference" >&2
            failed=1
        fi
    done < <(grep -Eo 'references/[A-Za-z0-9._/-]+\.md' "$skill" | sort -u)

    if [[ -d "$skill_dir/references" ]]; then
        while IFS= read -r -d '' reference_path; do
            relative="references/${reference_path#"$skill_dir/references/"}"
            if ! grep -Fq "$relative" "$skill"; then
                printf '%s is not routed from %s\n' "$reference_path" "$skill" >&2
                failed=1
            fi
        done < <(find "$skill_dir/references" -type f -name '*.md' -print0)
    fi
done < <(find .agents/skills -mindepth 2 -maxdepth 2 -name SKILL.md -print0)

if rg -n 'TODO|TBD|\[TODO|<<<<<<<|=======|>>>>>>>' AGENTS.md .agents/skills; then
    printf 'Agent guidance contains unfinished or conflicted text\n' >&2
    failed=1
fi

if ((failed)); then
    exit 1
fi

printf 'Agent guidance verified: routed and at most %s lines per text file.\n' \
    "$line_limit"
