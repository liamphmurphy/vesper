# Vesper Desktop (macOS)

A thin, native-feeling macOS Electron client and self-contained runtime for Vesper. It connects to either:

- **Built-in local Vesper (`vesper app`, default):** launches bundled Unix-socket PostgreSQL 17, static web UI (served by Go, with a node design worker), local directory blob store, and Apple `Virtualization.framework` (`vz`) Linux microVMs per run (`agent-base.erofs` is verified/downloaded on first launch; zero Docker dependency).
- **A remote Vesper host** (for example over Tailscale, `https://vesper.tailnet.ts.net`), skipping the local embedded stack automatically.

All tabs share a persistent `persist:vesper` cookie session (automatically signed in via one-time `vesper sign-in-link -code` in local mode), native Cocoa window tabs (`tabbingIdentifier: "vesper"`), standard macOS tab/navigation shortcuts, trackpad swipe navigation, **File → Import Backup…** for migrating `.zip` archives from Docker/server installs, menu bar tray lifecycle while microVMs are running, Playground `getDisplayMedia()` screenshot/recording support, Dock badge Needs-you counts, and macOS Notification Center alerts.

## Native macOS features

Everything below has its own switch in **Vesper › Settings… (⌘,)**. Details, defaults, security notes and the manual Mac checklist: [`docs/dev/desktop-native.md`](../docs/dev/desktop-native.md).

- **Menu bar icon**: stack status (running / starting / error), the Needs-you count, the newest items waiting on you and the runs that are working, plus Open, Quick Capture, Pause/Resume Runs, Restart Stack, Show Logs and Quit. Choose whether closing the last window keeps Vesper in the Dock, only in the menu bar, or quits.
- **Notifications**: Approve / Decline on approvals and inline Reply on agent questions (set Vesper's notification style to *Alerts* to see the buttons), grouped by ticket or run, a once-per-run "run finished" alert, per-kind switches and quiet hours.
- **Open at login**, optionally starting in the menu bar with no window; a failed background start is reported with a notification.
- **Quick capture** from any app with a global shortcut (default ⌥⇧Space, off until you turn it on): a note to your Knowledge inbox, a message to a persona, or a ticket.
- **`vesper://` links**: `vesper://run/<id>`, `ticket/<KEY-1>`, `epic/<id>`, `page/<id>`, `chat/<id>`, `inbox`, `capture`. Anything else is ignored.
- **Power**: keeps the Mac awake while runs work; optionally pauses runs on sleep and resumes them on wake; warns on battery and before quitting with runs working ([`docs/dev/desktop-power.md`](../docs/dev/desktop-power.md)).
- **Stack health**: first-run download progress, named failures with a next step (virtualization, disk, port, database, Keychain), a logs window, Restart Stack, and bounded auto-restart after a crash.
- **Files in**: drop files on the Dock icon or a window, use Open With, or install the *Send to Vesper* Quick Actions, then pick a chat to send them to.
- **Touch ID for approvals** (opt-in, per kind). A local check in this app only; the server doesn't verify it.
- **Screenshot to Chat** (opt-in, default ⌥⇧S): capture a region with the macOS picker, then pick a chat to send it to.
- **Backups**: VM disks, caches and downloaded images are kept out of Time Machine; optionally save a whole-instance export to a folder (iCloud Drive, a NAS…) on a schedule, keeping the newest N.
- **Ease off when hot**: in Low Power Mode or under thermal pressure the local runner takes fewer runs at once; running work finishes.
- **Runs at once** (Power & Stack): how many runs the local runner works on together (1–32, default 2). It applies when the local stack restarts; `RUNNER_MAX_CONCURRENT` in the environment still wins.
- **Open workspace folders**: with host-folder workspaces on, a run's or chat's folder opens in Finder, your terminal, or your editor (`nvim` in Terminal by default).
- **Dock**: right-click the Dock icon for what needs you, a new chat with any persona, Quick Capture and Screenshot to Chat; the icon shows the run image download's progress on first launch.
- **Show/Hide shortcut** (opt-in, default ⌥⇧V): bring Vesper forward from any app, or hide it when it's in front.
- **Update check** (opt-in): tells you when a newer DMG is published. The app can't update itself while it's unsigned ([`docs/dev/desktop-updates.md`](../docs/dev/desktop-updates.md)).

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

### Publishing a release

Push a version tag (`git tag v0.2.0 && git push origin v0.2.0`). The `desktop-release` workflow builds the kernel and agent image on Linux arm64, the DMG on macOS, and publishes a GitHub release with both; installed apps with the daily update check on are told about it. Details: [`docs/dev/desktop-updates.md`](../docs/dev/desktop-updates.md).

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

## Regenerating app and menu bar icons

`build/icon.icns` and `build/icon.png` are generated from [`web/public/logo.svg`](../web/public/logo.svg):

```sh
cd desktop
npm run gen:icon
npm run gen:tray-icons   # menu bar icons → renderer/tray/ (packed into the app)
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
| `⌘,` | Settings (native features; **Change Server URL…** inside, or under Help) |
