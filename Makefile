.PHONY: build test app run

build:
	swift build

test:
	swift test

app:
	./scripts/build-app.sh

run: app
	open .build/VoiceActivation.app
