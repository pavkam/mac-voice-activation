#!/bin/bash

# SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
# SPDX-License-Identifier: MIT

# Clears whatever macOS TCC has on file for YapOps across every privacy
# service it requests, then reports the toggles to re-grant. See
# "Accessibility or another privacy grant stops working after a rebuild" in
# docs/troubleshooting.md for why this is occasionally needed even with a
# stable, persistent signing identity.
set -euo pipefail

bundle_id="dev.alex.yapops"
services=(Accessibility Microphone SpeechRecognition)

for service in "${services[@]}"; do
    printf 'Resetting %s for %s...\n' "$service" "$bundle_id"
    tccutil reset "$service" "$bundle_id"
done

cat <<EOF

Cleared. Re-grant YapOps now:
  - Accessibility: open YapOps > Settings > General > Mac context and
    choose "Enable Accessibility...".
  - Microphone and Speech Recognition: say a command once YapOps is running;
    both are requested together on the first spoken utterance.
EOF
