# SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
# SPDX-License-Identifier: MIT

.PHONY: build test app run check-license

check-license:
	./scripts/check-license-headers.sh

build:
	swift build

test:
	swift test

app:
	./scripts/build-app.sh

run: app
	open .build/VoiceActivation.app
