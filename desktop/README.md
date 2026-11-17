# Vesper Desktop (macOS)

A thin, native-feeling macOS Electron client and self-contained runtime for Vesper. It connects to either:

- **Built-in local Vesper (`vesper app`, default):** launches bundled Unix-socket PostgreSQL 17, Next.js standalone UI, local directory blob store, and Apple `Virtualization.framework` (`vz`) Linux microVMs per run (`agent-base.erofs` is verified/downloaded on first launch; zero Docker dependency).
- **A remote Vesper host** (for example over Tailscale, `https://vesper.tailnet.ts.net`), skipping the local embedded stack automatically.

All tabs share a persistent `persist:vesper` cookie session (automatically signed in via one-time `vesper sign-in-link -code` in local mode), native Cocoa window tabs (`tabbingIdentifier: "vesper"`), standard macOS tab/navigation shortcuts, trackpad swipe navigation, **File → Import Backup…** for migrating `.zip` archives from Docker/server installs, menu bar tray lifecycle while microVMs are running, Playground `getDisplayMedia()` screenshot/recording support, Dock badge Needs-you counts, and macOS Notification Center alerts.

## Prerequisites

- **macOS on Apple Silicon (`arm64`)**
- **Node.js 24+**, **npm**, **Go**, and **Nix** (`nixpkgs#postgresql_17`, for building the relocatable Postgres 17 bundle)
- **`vmlinux` kernel image** cached at `~/.cache/vesper/images/vmlinux` (via `bash deploy/microvm/build-images.sh --kernel`)

## Build the `.dmg` on macOS

From the repository root:

```sh
make desktop-dmg            # Stage Postgres + Next standalone + signed vesper binary -> desktop/release/Vesper-arm64.dmg
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
