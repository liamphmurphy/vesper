# The native macOS app. See ../docs/dev/native-mac-app.md.
# To rebuild images (if needed), build Vesper.app, and install to /Applications,
# run `make mac-app` from the repository root.
APP := build/Vesper.app
DMG := build/Vesper-arm64.dmg

.PHONY: build test dmg clean

build:
	swift build

test:
	swift test

# Builds build/Vesper.app and packs build/Vesper-arm64.dmg (+ .sha256) for releases.
# Used by .github/workflows/mac-release.yml and scripts/mac-release-local.sh.
# SKIP_STAGE=1 reuses macos/staged as-is; VESPER_CODESIGN_IDENTITY picks the signing identity.
dmg:
	./scripts/build-app.sh
	rm -rf build/dmg-root $(DMG)
	mkdir -p build/dmg-root
	ditto $(APP) build/dmg-root/Vesper.app
	ln -s /Applications build/dmg-root/Applications
	hdiutil create -volname Vesper -srcfolder build/dmg-root -fs HFS+ -format UDZO -ov $(DMG)
	rm -rf build/dmg-root
	cd build && shasum -a 256 Vesper-arm64.dmg > Vesper-arm64.dmg.sha256
	@echo "Built $(DMG)"

clean:
	rm -rf build .build
