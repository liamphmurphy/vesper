# The native macOS app. See ../docs/dev/native-mac-app.md.
APP := build/Vesper.app
DMG := build/Vesper-arm64.dmg

.PHONY: build test app dmg run reinstall clean

build:
	swift build

test:
	swift test

# Assembles and signs build/Vesper.app. SKIP_STAGE=1 reuses macos/staged as it is;
# VESPER_CODESIGN_IDENTITY picks the signing identity (default: ad hoc).
app:
	./scripts/build-app.sh

# Packs the signed app into build/Vesper-arm64.dmg (the app plus an /Applications link, volume "Vesper")
# and writes build/Vesper-arm64.dmg.sha256. Builds the app first (SKIP_STAGE=1 and the signing
# identity apply as for `app`).
dmg: app
	rm -rf build/dmg-root $(DMG)
	mkdir -p build/dmg-root
	ditto $(APP) build/dmg-root/Vesper.app
	ln -s /Applications build/dmg-root/Applications
	hdiutil create -volname Vesper -srcfolder build/dmg-root -fs HFS+ -format UDZO -ov $(DMG)
	rm -rf build/dmg-root
	cd build && shasum -a 256 Vesper-arm64.dmg > Vesper-arm64.dmg.sha256
	@echo "Built $(DMG)"

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
