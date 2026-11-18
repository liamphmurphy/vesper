# The native macOS app. See ../docs/dev/native-mac-app.md.
APP := build/Vesper.app

.PHONY: build test app run reinstall clean

build:
	swift build

test:
	swift test

# Assembles and signs build/Vesper.app. SKIP_STAGE=1 reuses desktop/resources as it is;
# VESPER_CODESIGN_IDENTITY picks the signing identity (default: ad hoc).
app:
	./scripts/build-app.sh

# Runs the built app in the foreground, so its output is in this terminal.
run: $(APP)
	$(APP)/Contents/MacOS/Vesper

$(APP):
	./scripts/build-app.sh

# Quits Vesper and replaces /Applications/Vesper.app with the built one.
reinstall: app
	-osascript -e 'tell application "Vesper" to quit' >/dev/null 2>&1
	@for i in 1 2 3 4 5 6 7 8 9 10; do pgrep -x Vesper >/dev/null || break; sleep 1; done
	rm -rf /Applications/Vesper.app
	ditto $(APP) /Applications/Vesper.app
	@echo "Installed /Applications/Vesper.app"

clean:
	rm -rf build .build
