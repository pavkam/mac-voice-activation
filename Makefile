# SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
# SPDX-License-Identifier: MIT

.PHONY: build test app run check-license check-agent-guidance check-structure check-documentation check

check-license:
	./scripts/check-license-headers.sh

check-agent-guidance:
	./scripts/check-agent-guidance.sh

check-structure:
	./scripts/check-swift-structure.sh

check-documentation:
	./scripts/check-swift-documentation.swift

check: check-license check-agent-guidance check-structure check-documentation

build:
	swift build

test:
	swift test

app:
	./scripts/build-app.sh

run: app
	open .build/VoiceActivation.app
