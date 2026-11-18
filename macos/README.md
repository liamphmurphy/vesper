# Vesper for macOS (native shell)

Swift app that supervises the bundled `vesper app` and shows the web UI in native windows. Design,
contracts and the parity checklist: [`docs/dev/native-mac-app.md`](../docs/dev/native-mac-app.md).

```
make -C macos test                  # swift test (VesperCore)
make -C macos app                   # stage resources, assemble and sign build/Vesper.app
make -C macos app SKIP_STAGE=1      # reuse macos/staged as it is (fast)
make -C macos run                   # run build/Vesper.app in the foreground, output in this terminal
make -C macos dmg                   # pack build/Vesper-arm64.dmg (+ .sha256): the app and an /Applications link
make -C macos reinstall             # quit Vesper and replace /Applications/Vesper.app
VESPER_STACK_IT=1 swift test --filter StackIntegrationTests   # starts the real stack (needs macos/staged)
```

The app's data is `~/Library/Application Support/vesper-desktop` (one Postgres data dir, so run one
Vesper at a time). `VESPER_USER_DATA_DIR` points the app somewhere else.

`scripts/gen-icon.mjs` and `scripts/gen-tray-icons.mjs` regenerate `Resources/AppIcon.icns` and
`Resources/tray/` from `web/public/logo.svg` (they use `@resvg/resvg-js` from `web/node_modules`).

## Signing with a stable identity

`make app` signs ad hoc (`-`) by default. An ad hoc signature changes with every build, so macOS
forgets Keychain "Always Allow" choices and privacy grants (Screen Recording, Notifications,
Automation) each time you rebuild. A self-signed code-signing certificate gives every build the same
identity, so those grants stick.

Create one once, in Keychain Access:

1. Keychain Access, menu **Keychain Access > Certificate Assistant > Create a Certificate…**
2. Name: `Vesper Local Signing`. Identity Type: **Self Signed Root**. Certificate Type: **Code Signing**.
   Click **Create**.
3. Find it under **My Certificates** in the login keychain, double-click it, open **Trust**, and set
   **Code Signing** to **Always Trust** (you'll be asked for your password).
4. Check that it's usable: `security find-identity -v -p codesigning` lists `Vesper Local Signing`.

Then build with it:

```
VESPER_CODESIGN_IDENTITY="Vesper Local Signing" make -C macos app
```

Put the variable in your shell profile to use it for every build. The first launch after switching
identity asks again for Keychain and privacy access; after that it doesn't. `bin/vesper` always gets
`deploy/microvm/vz.entitlements` (Virtualization.framework), whichever identity signs it.

This is for local builds. It isn't a Developer ID signature and the app is not notarised, so
Gatekeeper still asks on a Mac that downloaded it.
