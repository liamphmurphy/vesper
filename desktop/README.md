# Vesper Desktop (macOS)

A thin, native-feeling macOS Electron client for Vesper. It connects to either:

- **Your local Vesper Docker / OrbStack stack** (`http://localhost:8080`, the default), or
- **A remote Vesper host** (for example over Tailscale, `https://vesper.tailnet.ts.net`).

All tabs share a persistent `persist:vesper` cookie session, native Cocoa window tabs (`tabbingIdentifier: "vesper"`), standard macOS tab/navigation shortcuts, trackpad swipe navigation, Dock badge Needs-you counts, macOS Notification Center alerts, and optional one-click `docker compose up -d` startup when targeting `localhost`.

## Prerequisites

- **Node.js 24+** and **npm**
- **Running Vesper backend** (OrbStack / Docker Desktop running `docker compose up -d` locally, or a remote Vesper server)
- Building `.dmg` installers must be run on **macOS** (Apple Silicon or Intel, or via the `desktop-macos` GitHub Actions workflow).

## Build the `.dmg` on macOS

From the repository root:

```sh
make desktop-dmg            # Apple Silicon (arm64) → desktop/release/Vesper-arm64.dmg
```

Or for a universal (Apple Silicon + Intel) installer:

```sh
make desktop-dmg-universal  # → desktop/release/Vesper-universal.dmg
```

Or directly inside `desktop/`:

```sh
cd desktop
npm ci
npm run dmg                 # or: npm run dmg:universal
```

### Installing an unsigned personal build (Gatekeeper)

Personal local builds are unsigned (`CSC_IDENTITY_AUTO_DISCOVERY=false`). When you drag `Vesper.app` into `/Applications` and launch it for the first time, macOS Gatekeeper may warn that the app is from an unidentified developer:

1. Remove the quarantine attribute once:
   ```sh
   xattr -cr /Applications/Vesper.app
   ```
   *(Or right-click `Vesper.app` → **Open**, or go to **System Settings → Privacy & Security → Open Anyway**.)*

## Running in development

```sh
make desktop-dev
```

You can override the default server URL at launch for testing:

```sh
VESPER_SERVER_URL=http://localhost:3000 npm --prefix desktop start
```

## Regenerating app icons

`build/icon.icns` and `build/icon.png` are generated from [`web/public/logo.svg`](../web/public/logo.svg):

```sh
cd desktop
npm run gen:icon
```

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| `⌘T` | New tab |
| `⌘W` | Close tab |
| `⇧⌘T` | Reopen closed tab |
| `⌘N` | New window |
| `⌃Tab` / `⇧⌘]` | Next tab |
| `⌃⇧Tab` / `⇧⌘[` | Previous tab |
| `⌘1`–`⌘9` | Switch to tab 1–8 (`⌘9` switches to last tab) |
| `⌘[` / `⌘]` | Back / Forward (also trackpad swipe) |
| `⌘R` / `⇧⌘R` | Reload / Force reload |
| `⌘,` | Server URL & local checkout settings |
