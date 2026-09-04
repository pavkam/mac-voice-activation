#!/bin/bash

# SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
# SPDX-License-Identifier: MIT

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd -P)"
project_dir="$(cd "$script_dir/.." && pwd -P)"
configuration="${CONFIGURATION:-release}"
sign_identity="${SIGN_IDENTITY:--}"

cd "$project_dir"
swift build -c "$configuration" --product VoiceActivation
binary_dir="$(swift build -c "$configuration" --show-bin-path)"
app_path="$project_dir/.build/VoiceActivation.app"
contents_path="$app_path/Contents"

rm -rf "$app_path"
mkdir -p "$contents_path/MacOS" "$contents_path/Resources"
cp "$binary_dir/VoiceActivation" "$contents_path/MacOS/VoiceActivation"
cp "$project_dir/Sources/VoiceActivationApp/Resources/Info.plist" "$contents_path/Info.plist"
cp "$project_dir/Sources/VoiceActivationApp/Resources/VoiceActivation.icns" "$contents_path/Resources/VoiceActivation.icns"
for sound_name in AgentThinking CaptureEnd CaptureStart ToolComplete ToolFailed ToolStart; do
    cp "$project_dir/Sources/VoiceActivationApp/Resources/$sound_name.wav" \
        "$contents_path/Resources/$sound_name.wav"
done

plutil -lint "$contents_path/Info.plist"
codesign --force --deep --sign "$sign_identity" "$app_path"
codesign --verify --deep --strict "$app_path"

printf 'Built %s\n' "$app_path"
