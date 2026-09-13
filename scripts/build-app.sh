#!/bin/bash

# SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
# SPDX-License-Identifier: MIT

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd -P)"
project_dir="$(cd "$script_dir/.." && pwd -P)"
configuration="${CONFIGURATION:-release}"
sign_identity="${SIGN_IDENTITY:-YapOps Local Development}"

cd "$project_dir"
swift build -c "$configuration" --product YapOps
binary_dir="$(swift build -c "$configuration" --show-bin-path)"
app_path="$project_dir/.build/YapOps.app"
staging_dir="$(mktemp -d "$project_dir/.build/YapOps-package.XXXXXX")"
staged_app="$staging_dir/YapOps.app"
contents_path="$staged_app/Contents"

cleanup() {
    if [[ -d "$staging_dir/previous-contents" && ! -e "$app_path/Contents" ]]; then
        mv "$staging_dir/previous-contents" "$app_path/Contents"
    fi
    rm -rf "$staging_dir"
}
trap cleanup EXIT

mkdir -p "$contents_path/MacOS" "$contents_path/Resources"
cp "$binary_dir/YapOps" "$contents_path/MacOS/YapOps"
cp "$project_dir/Sources/YapOpsApp/Resources/Info.plist" "$contents_path/Info.plist"
cp "$project_dir/Sources/YapOpsApp/Resources/YapOps.icns" "$contents_path/Resources/YapOps.icns"
for sound_name in AgentThinking CaptureEnd CaptureStart ToolComplete ToolFailed ToolStart; do
    cp "$project_dir/Sources/YapOpsApp/Resources/$sound_name.wav" \
        "$contents_path/Resources/$sound_name.wav"
done

plutil -lint "$contents_path/Info.plist"
if ! codesign --force --deep --sign "$sign_identity" "$staged_app"; then
    printf 'Signing failed. The existing app has been preserved.\n' >&2
    if [[ "$sign_identity" == "YapOps Local Development" ]]; then
        printf 'Run make setup-signing once, then retry. Ad-hoc builds require SIGN_IDENTITY=-.\n' >&2
    fi
    exit 1
fi
codesign --verify --deep --strict "$staged_app"

# Update the bundle's contents in place rather than swapping the whole .app
# directory in with mv. That swap gave .build/YapOps.app a new directory inode
# on every single rebuild; macOS Accessibility/TCC trust for a locally signed
# dev build can fail to carry over across that change even with an identical,
# persistent signing identity (docs/troubleshooting.md has the recovery
# command if this still happens). The bundle directory itself is created once
# and never re-created afterward - only Contents/ is replaced.
mkdir -p "$app_path"
if [[ -d "$app_path/Contents" ]]; then
    mv "$app_path/Contents" "$staging_dir/previous-contents"
fi
mv "$contents_path" "$app_path/Contents"

printf 'Built %s\n' "$app_path"
