#!/bin/bash

# SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
# SPDX-License-Identifier: MIT

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd -P)"
project_dir="$(cd "$script_dir/.." && pwd -P)"
spdx_prefix="SPDX"
copyright_line="${spdx_prefix}-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)"
license_line="${spdx_prefix}-License-Identifier: MIT"
expected_app_copyright="Copyright © 2026 Alexandru Ciobanu (alex+git@ciobanu.org)"
failed=0

cd "$project_dir"

while IFS= read -r -d '' path; do
    case "$path" in
        LICENSE | LICENSES/*.txt | Package.resolved | *.icns | *.wav)
            continue
            ;;
        .gitignore | Makefile | REUSE.toml | *.md | *.plist | *.sh | *.swift | *.yaml | *.yml)
            header="$(LC_ALL=C sed -n '1,12p' "$path")"
            if ! grep -Fq "$copyright_line" <<< "$header"; then
                printf 'Missing copyright header: %s\n' "$path" >&2
                failed=1
            fi
            if ! grep -Fq "$license_line" <<< "$header"; then
                printf 'Missing MIT SPDX header: %s\n' "$path" >&2
                failed=1
            fi
            ;;
        *)
            printf 'Unclassified tracked file: %s\n' "$path" >&2
            failed=1
            ;;
    esac
done < <(git ls-files --cached --others --exclude-standard -z)

if [[ ! -f LICENSE ]]; then
    printf 'Missing LICENSE\n' >&2
    failed=1
elif ! grep -Fxq 'MIT License' LICENSE \
    || ! grep -Fxq 'Copyright (c) 2026 Alexandru Ciobanu (alex+git@ciobanu.org)' LICENSE
then
    printf 'LICENSE does not contain the expected MIT grant and copyright\n' >&2
    failed=1
fi

if [[ ! -f LICENSES/MIT.txt ]] || ! cmp -s LICENSE LICENSES/MIT.txt; then
    printf 'LICENSES/MIT.txt must match the root MIT license\n' >&2
    failed=1
fi

if [[ ! -f REUSE.toml ]]; then
    printf 'Missing REUSE.toml annotations for non-commentable files\n' >&2
    failed=1
else
    for path in \
        Package.resolved \
        Sources/VoiceActivationApp/Resources/CaptureEnd.wav \
        Sources/VoiceActivationApp/Resources/CaptureStart.wav \
        Sources/VoiceActivationApp/Resources/VoiceActivation.icns
    do
        if ! grep -Fq "\"$path\"" REUSE.toml; then
            printf 'Missing REUSE annotation: %s\n' "$path" >&2
            failed=1
        fi
    done
fi

app_copyright="$(
    plutil -extract NSHumanReadableCopyright raw \
        Sources/VoiceActivationApp/Resources/Info.plist 2>/dev/null || true
)"
if [[ "$app_copyright" != "$expected_app_copyright" ]]; then
    printf 'Incorrect app copyright: %s\n' "$app_copyright" >&2
    failed=1
fi

if ((failed)); then
    exit 1
fi

printf 'MIT license metadata and headers verified.\n'
