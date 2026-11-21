# Native macOS app (Swift shell)

Status: the Mac app. It replaced the earlier Electron app (`desktop/`, since removed); the person
signed off on it against real data. Related: [mac-native-features.md](mac-native-features.md),
[mac-power.md](mac-power.md), [mac-updates.md](mac-updates.md).

## Where it stands

Everything in the parity checklist below is implemented, with these deliberate gaps:

- **Web-only shell chrome removed**: `web/` no longer renders the browser left sidebar, fallback
  column, mobile tab bar, web top bars, `HistoryNav`, right rail popovers, or web DOM fallbacks
  for `native`/`companion`/`panel` inspector tabs; the web app publishes `NavModel`, toolbar
  actions, rail state, and `InspectorModel` directly and only keeps `web`-kind inspector slot
  support and parent breadcrumbs in-page.
- **Right-click menus** in the content area are native only where a screen asks for one with
  `useNativeContextMenu` (chat messages and board cards so far); elsewhere WebKit's menu shows.
- **Keyboard focus** between the sidebar, toolbar and page relies on AppKit's defaults; Tab
  inside the page stays inside it.
- **No layout signal to the page**: a page can't tell the separate layout from the compact one, so
  anything that must show in both (Knowledge's folder path) stays in the page rather than in the
  window subtitle, which compact hides.
- **UI runtime**: the UI is a static Vite build that `vesper app` serves itself; the only node
  process is the design worker (`web/design-worker`).
- **Touch ID** is strict: with the gate on and no usable sensor it asks for the
  account password instead of skipping.

Verified by the person, not by automation: notification banners and actions (ad hoc builds need
notifications allowed in System Settings), the Touch ID prompt, sleep/wake pausing, Screenshot to
Chat, the unsaved-changes alert, playground windows, and the first launch against real data
(Keychain migration of the secrets key the Electron app stored).

## Goal

A first-class, native-feeling Mac app that keeps every existing feature. Layout like Apple Mail:

- **Native, full-height sidebar** (traffic lights sit in it). Its top is fixed navigation
  (areas, Apps); its middle is the current screen's list, which the page *describes* as data
  (`NavModel`) and the shell draws as a native source list.
- **Native unified toolbar** over the content: back/forward, title and subtitle, search (opens the
  page's ⌘K menu), tracking separators (`vesper.sidebarSeparator`, `vesper.inspectorSeparator`),
  a stationary trailing inspector toggle (`⌘\`), plus items the page contributes. New Chat sits in
  the sidebar instead, on the first day's header in Chats (a labelled section action).
- **Native, full-height inspector**: a 3-pane `NSSplitViewController` (`Sidebar | Content | Inspector`)
  hosted in `WindowRootController` beside the stationary full-height `RailBarView` (whose backdrop
  extends under the unified toolbar while its divider and buttons start below `safeAreaLayoutGuide`).
  The trailing pane uses `NSSplitViewItem(inspectorWithViewController:)` with `allowsFullHeightLayout`,
  `.sidebar` Liquid Glass vibrancy, width classes (`regular` 280–640 pt, `wide` 360–960 pt, `max`
  420–1120 pt), transparent `NSPanel` floating pop-out/re-dock, and unified native tab kinds:
  `native` (declarative SwiftUI `InspectorView`), `companion` (persistent `/companion` `WKWebView`),
  and `panel` (persistent `/inspector-panel` `WKWebView` with transparent Liquid Glass CSS). Every
  app dock renders inside the native inspector in native mode (leaving only `web` as a fallback).
- **Native menus, context menus, windows and system surfaces**: menu bar extra, notifications with
  actions, Dock badge and menu, Quick Capture, Settings, Screenshot to Chat, files in, Touch ID,
  power, backups, updates, deep links, logs.
- **One WKWebView per tab for the content area**, plus window-level persistent `/companion`
  (`CompanionWebController`) and `/inspector-panel` (`InspectorPanelWebController`) `WKWebView`s
  shared across tabs so companion work chats and web-rich inspector panels (Playground, Code,
  Design, Canvas, Thread, Knowledge/Custom App/Editor chats, Slides review) stay mounted across
  tab switches and let AppKit vibrancy shine through.

The Go backend is unchanged in role: the shell launches the bundled `vesper app` as a child
process and supervises it.

## Processes and files

```
Vesper.app/Contents/
  MacOS/Vesper                    Swift app (macos/)
  Resources/bin/vesper            Go binary, ad-hoc signed with deploy/microvm/vz.entitlements
  Resources/postgres/             relocatable Postgres 17 (scripts/bundle-postgres-darwin.sh)
  Resources/web/                  static UI (index.html, assets/) + design-worker/ (server.mjs, resvg addon)
  Resources/node/bin/node         official Node 24 darwin-arm64 binary (runs the design worker)
  Resources/images/vmlinux        kernel (agent-base.erofs is downloaded on first launch)
```

Built by `macos/scripts/build-app.sh` (`scripts/stage-mac-resources.sh` builds bin,
postgres, web, images into the git-ignored `macos/staged/`). Signing: `VESPER_CODESIGN_IDENTITY` (a self-signed code-signing cert, so
Keychain and privacy grants survive rebuilds) or ad hoc (`-`) when unset.

### Data and migration (must not lose the existing instance)

- Data dir: `~/Library/Application Support/vesper-desktop` (the earlier Electron app's name, kept so existing data carries over), passed as
  `vesper app -data-dir`. Same Postgres, blobs, images, logs. Override with `VESPER_USER_DATA_DIR`.
- Settings: the same `config.json` in the data dir, same `native` key and schema
  (`VesperCore/Settings/NativeSettings.swift`: defaults and normalisation rules). Tabs: same `session.json`.
- Secrets key: Electron stored it in `secrets-key.enc`, encrypted with `safeStorage`
  (Chromium os_crypt "v10": AES-128-CBC, IV = 16 spaces, key = PBKDF2-HMAC-SHA1(password,
  salt "saltysalt", 1003 iterations, 16 bytes), password = Keychain generic password service
  `vesper-desktop Safe Storage`, account `vesper-desktop Key`). On first launch the shell decrypts
  it once and stores the key in its own Keychain item (service `com.vesper.mac`, account
  `secrets-key:<absolute data dir path>`, so a key made for one data dir never stands in for
  another's migration). If neither exists, generate 32 random bytes (base64). Never log it.
- Never run two Vesper builds at the same time (one Postgres data dir).

## Contracts

### Shell ↔ Go (`server/cmd/vesper/app.go`)

- Command: `<Resources>/bin/vesper app -data-dir <dataDir> -addr 127.0.0.1:<port>` (port 8080).
- Env: inherit, then set `SECRETS_KEY`, `VESPER_APP_DATA_DIR`, `VESPER_APP_ADDR`,
  `VESPER_POSTGRES_BIN_DIR=<Resources>/postgres/bin`, `VESPER_KERNEL_PATH` (if present),
  `VESPER_WEB_DIST_DIR=<Resources>/web` (if `index.html` exists), `VESPER_NODE_BIN=<Resources>/node/bin/node`,
  `VESPER_ROOTFS_URL` (packaged builds, if unset), `RUNNER_MAX_CONCURRENT` (from settings, if
  unset), `VESPER_APP_SIGN_IN_CODE=stdout`; remove `VESPER_NO_SIGNIN`.
- Stdout lines: `VESPER_SIGN_IN_CODE=<code>` then `VESPER_READY_URL=<url>` (30 s timeout). Never
  write the code line to the log file.
- Sign-in: the shell GETs `<url>/api/v1/sign-in?code=<code>` with URLSession, redirects off, takes
  the `vesper_session` cookie from `Set-Cookie`, uses it for its own API calls, and puts it into
  the web views' `WKHTTPCookieStore` (HttpOnly, path `/`, the URL's host) before loading pages.
- Logs: `<dataDir>/logs/vesper-app.log` (append stdout and stderr except the code line).
- Stop: SIGTERM, wait 10 s, SIGKILL. Auto-restart at most 3 times in 10 minutes
  (`stack.autoRestart`).
- The listener refuses non-loopback `Host` headers (421). Agents reach the API in-process.

### Page ↔ shell bridge

Source of truth: `web/lib/native-shell/protocol.ts`; Swift mirror
`macos/Sources/VesperCore/Bridge/Protocol.swift`; fixtures `protocol/native-bridge/*.json`
(both test suites decode every fixture).

- Page → shell: `window.webkit.messageHandlers.vesper.postMessage(msg)`.
- Shell → page: `window.dispatchEvent(new CustomEvent("vesper-native", { detail: cmd }))` via
  `evaluateJavaScript`, with the command JSON-encoded (never string-concatenated).
- Native mode marker: a document-start `WKUserScript` sets
  `window.__VESPER_NATIVE__ = { v: 1, platform: "macos" }` and adds class `native-mac` to `<html>`.
- `NavigatorPortal` takes `native` (a `NavModel`), publishes it to the shell, and renders
  nothing in the page (there is no web left column or fallback column).
- When no screen claims the navigator, the default Chats navigator (chat history and spaces) is
  published as a `NavModel` together with `shell` (areas, apps, current area, badges).
- `nav.activate` carries `newTab: true` when the row was ⌘-clicked: the page opens the row's href
  with `window.open` (a new tab beside this one) and leaves the current tab and its selection alone.
  Rows without an href are activated as by a plain click.
- Request/response messages (`confirmApproval`, `openWorkspaceMenu`, `contextMenu`, `confirm`,
  `prompt`) carry a `requestId`; the shell answers with a `reply` command (returning `selectedId`
  for `contextMenu` and `value` for `prompt`).
- Window-level Liquid Glass toast HUD: pages send `toast.show` / `toast.dismiss` to render bounded
  toast pills (`ToastPresenter` / `ToastQueueLogic`) centered near the bottom of the host window with
  hover-pause countdowns; the shell sends `toast.event` (`action`, `dismissed`, `timeout`) back to
  the originating web view.
- Searchable native Keyboard Shortcuts window (`ShortcutsWindowController`, `?` / `⌘/`): triggered
  either from Help › Keyboard Shortcuts or via the page `showShortcuts` message.
- Native floating Liquid Glass Command Palette (`⌘K`, `⇧⌘K`, `⌥⌘F`): `CommandPaletteController`
  hosts a persistent borderless `NSPanel` backed by `/command-palette` (`WebViewKind.commandPalette`
  with `native-command-palette` and `native-inspector-glass`, clear background). Pages trigger or
  dismiss it via `commandPalette.open` / `commandPalette.close`, and the shell sends `palette.open`
  to initialize scope/query context.
- Native Quick Look (`quickLook`): `QuickLookController` validates same-origin URLs via `BridgeOrigin`,
  downloads authenticated Library, chat attachment, and artifact files into a process-scoped temporary
  cache (cleaned on quit), and presents `QLPreviewPanel` via `MainWindowController` responder-chain
  hooks.
- Native inspector bridge: screens publish an `inspector` message (`InspectorModel | null`) with
  tab kinds `native` (declarative sections/items rendered natively in SwiftUI), `companion`
  (routed to `/companion` via `companion.context`), `panel` (routed to `/inspector-panel` via
  `panel.context` with `keepKeys` persistence across tab switches and `InspectorWidth` sizing),
  and `web` (in-page fallback). Both `/companion` and `/inspector-panel` inject the
  `native-inspector-glass` class and clear `WKWebView` backgrounds (`drawsBackground = false`,
  `underPageBackgroundColor = .clear`) so AppKit's `.sidebar` backdrop shows through. The shell
  dispatches `inspector.visibility`, `inspector.selectTab`, `inspector.action`, `inspector.change`,
  `inspector.toggle`, and `panel.event` back to the page; `/inspector-panel` posts `panel.event`
  (e.g. `openFull`, `close`, `composerDrop`) to the shell, which forwards composer drops across open
  main Vesper tabs; links clicked inside `/companion` or `/inspector-panel` post `openInMain`
  (`{ path, newTab }`) to open in the main pane or a new tab.

### Security rules for the shell

- Accept bridge messages only from the **main frame** whose `securityOrigin` equals the Vesper
  server origin (scheme, host, port). Drop everything else.
- Playground pages (same host, ports 8090–8094) and external pages never get the bridge: they load
  in web views whose configuration has no message handler and no native-mode user script.
- Navigation policy (`VesperCore/Model/Routing.swift`): same origin → in app; playground port → in-app
  window without bridge; other http(s)/mailto → `NSWorkspace.open`; everything else → cancel.
- Workspace folders open only strictly inside the runner's `host_workspaces_dir` (realpath'd).
- The session cookie is `HttpOnly; SameSite=Strict` (as the server sets it), installed in both the
  Vesper and the playground data store. Playground windows need it to sign in to the playground
  gateway, which strips it before proxying to the agent's app; they still get no bridge, user
  scripts or page services.
- **Private WebKit preferences, Vesper web views only.** This macOS exposes no `navigator.mediaDevices`
  (so no `getDisplayMedia`, used by the playground frame capture in `web/lib/frame-capture.ts`) unless
  the private `mediaDevicesEnabled` and `screenCaptureEnabled` `WKPreferences` are on, and caps
  `WKWebView` rendering near 60 fps unless `PreferPageRenderingUpdatesNear60FPS` is off.
  `WebViewFactory.enablePrivateMediaPreferences` sets media flags via KVC when supported;
  `WebViewFactory.disable60FPSCap` checks `_features` and `_setEnabled:forFeature:` on
  `WKPreferences` before `WKWebView` creation to turn off `PreferPageRenderingUpdatesNear60FPS` /
  `PreferPageRenderingUpdatesNear60FPSEnabled` for 120Hz ProMotion pacing on Vesper and companion
  web views. Both skip safely and log if absent, never run on playground or popup web views, and
  `decideMediaCapturePermissionsFor` still prompts only for the Vesper origin's main frame.
  Screen capture goes through the system's own "Share a Window or Entire Screen" picker; verified
  end to end (a MediaStream with one video track arrives). Screenshot to Chat's Screen Recording
  explanation lives in `ScreenRecordingAccess` for any path that needs the permission.
- Popups (`window.open` targets) deny media capture and show the page's host as the window
  subtitle, so an untrusted page can't pose as Vesper.
- `file://` navigations are accepted only as a window drop (browser-initiated, main frame, source
  frame the main frame); every other `file://` navigation is cancelled.
- The clipboard fallback writes only for the key window of the active app.
- Touch ID fails closed. When the gate is on but biometrics can't prompt (no sensor, none enrolled,
  lid closed), the account password is required instead of skipping.
- A Keychain secrets key that exists but is invalid is an error, never replaced by migration or a
  new key (`secrets-key.enc` stays, for a downgrade to the Electron app).

## Feature checklist

What the app does, for regression testing by hand.

**Windows, tabs, navigation**
- [ ] Tab layout setting (`native.tabs.layout`, Settings › General and View › Use Compact Tab Layout): **Separate** (default) = native window tabs; **Compact** = one window whose tabs are drawn in the toolbar (each tab keeps its own web view, history, sidebar model and toolbar items). Switching rebuilds the windows by moving the tab objects, so nothing reloads; order, active tab and frames carry over. Move Tab to New Window / Merge All Windows work in both; Show All Tabs and Show/Hide Tab Bar are separate-only. Unsaved-changes check runs per tab.
- [ ] Native window tabs (`tabbingIdentifier` "vesper"), New Tab ⌘T (and either tab bar's +) opens beside the current tab at the same page (a Knowledge page, a chat, a filtered list; Home only with no window open), New Window ⌘N, Close Tab ⌘W (the app's only tab becomes a new chat with the default persona instead of closing the window), Close Window ⇧⌘W, Reopen Closed Tab ⇧⌘T (stack of 25), tab 1–8 ⌘1–8, ⌘9 last, next/previous tab ⌃Tab/⌃⇧Tab and ⇧⌘]/⇧⌘[, Move Tab to New Window, Merge All Windows, Show All Tabs, Toggle Tab Bar
- [ ] Back ⌘[ / Forward ⌘], trackpad swipe, Reload ⌘R, Force Reload ⇧⌘R, zoom in/out/actual size, full screen, Web Inspector (`isInspectable`)
- [ ] Tab titles from the page title minus a trailing " · Vesper"/" - Vesper"/" — Vesper"
- [ ] Session restore (`session.json`: tabs, active index, bounds; http(s) tabs only; bounds ≥400×300); min size 760×540; default 1280×840
- [ ] Link policy (above); `window.open` to Vesper/playground → new tab; external → default browser
- [ ] ⌘-click a sidebar row with an href (a chat, a run, a Knowledge page) → it opens in a new tab; the current tab doesn't move
- [ ] Knowledge: no Knowledge tab strip (pages are the app's tabs, named after the page); a click on a page replaces the current tab, ⌘-click or the row's Open in New Tab opens one beside it; Home is the explorer's top row; ⌘W closes the tab (⌥W does nothing); the page's Private/Shared menu, persona mode, Copy link and More are toolbar items, and its folder path sits above its title
- [ ] Offline / stack-error state in the window with Retry, Restart Stack, Show Logs
- [ ] Right-click native `NSMenu` context menus across chat messages, board cards, ticket rows, Work/Activity runs & needs-you cards, Library tiles, Knowledge home rows, Custom App cards, and chat attachments (selected text, inputs, and links in messages keep the system menu); right place at every zoom level
- [ ] `confirmAction` (delete a chat, discard edits, cancel a run…) and text-input prompts (`prompt`, e.g. rename dialogs) are native sheets on the window: Return confirms, Esc cancels, custom cancel labels and length caps work; page `alert`/`confirm`/`prompt` are sheets too
- [ ] Floating Liquid Glass Find Bar (`FindBarViewController`): ⌘F opens in the active tab, ⌘G / ⇧⌘G navigate matches when open (preserving Slides ⌘G/⇧⌘G when closed), ⌘E uses the web selection, Esc restores focus to the page
- [ ] Floating Liquid Glass Command Palette (`⌘K`, `⇧⌘K`, `⌥⌘F`, toolbar search): persistent borderless `NSPanel` hosting `/command-palette`; disabled on `/dev` routes so `DevTerminal` keeps `⌘K`
- [ ] Native searchable Keyboard Shortcuts window (`?` / ⌘/) and window-level Liquid Glass Toast HUD (max 3 visible pills, hover pause, Undo action round-trip)
- [ ] Native Quick Look (`Space` in Library / file artifacts, context menu, or Quick Look button) previews same-origin authenticated images, video, audio, PDFs, and files in `QLPreviewPanel`; temp cache cleaned on quit
- [ ] Overscroll past the top/bottom of a page shows the palette's background (dark, Gruvbox), not white
- [ ] Quit confirmation when runs are active (`power.confirmQuitWithActiveRuns`)

**Menus**
- [ ] App: About, Check for Updates…, Settings… ⌘,, Restart Stack, Show Logs…, Services, Hide/Hide Others/Show All, Quit ⌘Q
- [ ] File: New Tab, New Window, Reopen Closed Tab, Quick Capture…, Screenshot to Chat…, Import Backup…, Close Tab, Close Window
- [ ] Edit (standard, incl. Find… ⌘F, Find Next ⌘G, Find Previous ⇧⌘G, Use Selection for Find ⌘E, Command Palette… ⌘K, Search Current View… ⇧⌘K, Search… ⌥⌘F), View (Reload, Force Reload, Developer Tools, zoom, tab bar, full screen, Show/Hide Sidebar ⌃⌘S, Show/Hide Inspector ⌘\), History (Back, Forward), Window (standard + tab commands), Help (Keyboard Shortcuts ⌘/, Show Logs…, Vesper Repository & Docs)
- [ ] "Change Server URL…" and remote/Docker modes are dropped on purpose (local app only)

**Stack**
- [ ] Launch, readiness, sign-in, logs, stop, restart, auto-restart as in Contracts
- [ ] Health phases: starting, downloading (run image %), running, degraded (run image unavailable, low disk < `stack.minFreeDiskGb`, runner offline), error, stopped; platform gate (arm64, macOS ≥ 15)
- [ ] Error titles: Virtualization unavailable, Disk full, Port in use, Keychain key unavailable, Database didn't start, Stack is slow to start, Stack stopped (first match wins, `StackHealthLogic.swift`)
- [ ] First-run run-image download progress (GET `/api/v1/system/vm-image`) in window, menu bar and Dock
- [ ] Logs window: last 256 KB, Copy, Reveal in Finder, Restart Stack
- [ ] Import Backup… (`vesper app-import`, file picker, secrets key prompt/drop secrets)

**Menu bar extra**
- [ ] Status line per phase; error next step; notices (e.g. thermal easing)
- [ ] Needs you (N) with up to 5 items + "Show all N in Inbox…"; Running (N) non-chat runs up to 5 with "(paused)" + "Show all N runs…"
- [ ] Open Vesper, Quick Capture…, Screenshot to Chat… (when enabled), Pause Runs (N) / Resume Runs (N), Restart Stack, Show Logs…, Settings…, Quit Vesper
- [ ] Icon states (running, starting, error); count title ("99+"), `tray.showCount`; closing the last window: Stay in Dock / Menu bar only (hide Dock icon) / Quit

**Notifications**
- [ ] InboxMonitor: GET `/api/v1/inbox` now, SSE `/events` (reconnect 5 s), poll 30 s; refresh on reset/inbox.*/run.*/approval.*/ticket.*/workflow.*; first poll is a baseline; dedupe `id:created_at`
- [ ] 13 kinds with switches (`NativeSettings.swift`); any `needs_you` item alerts; quiet hours; sound; group by ticket/run
- [ ] Approve/Decline actions (POST `/api/v1/approvals/{id}/approve|deny`, `/api/v1/connector-approvals/{id}` `{decision}`, `/api/v1/api-secret-approvals/{id}` `{decision}`), Touch ID first when enabled for the scope
- [ ] Inline Reply on questions (POST `/api/v1/tickets/{KEY}/comments` `{body_md}`, prefix "@handle ")
- [ ] Run finished/blocked/failed once per run (RunMonitor: `/api/v1/runs?state=live` every 20 s, then `state=all`)
- [ ] Click opens the item's href in a window

**Dock**
- [ ] Badge = unresolved unread needs-you count ("99+"); cleared on 401/403
- [ ] Dock menu: Needs you (N) + up to 5 + Show all; New Chat; New Chat with <persona> (up to 6); Quick Capture…; Screenshot to Chat…
- [ ] Run-image download progress on the Dock icon (`dock.progress`)

**Quick Capture, Screenshot, Show/Hide**
- [ ] Global shortcuts (defaults ⌥⇧Space, ⌥⇧S, ⌥⇧V; off by default), validation and system-conflict list
- [ ] Capture panel: Note (POST `/api/v1/knowledge/capture`), Message (POST `/api/v1/chats`), Ticket (POST `/api/v1/tickets`, first line title ≤300); persona/project lists refreshed every 10 min; ≤100k chars; Esc closes, ⌘↩ saves; result link opens
- [ ] Screenshot: `screencapture -i -x -t png`, Screen Recording permission check and pane link, then the send picker
- [ ] Show/Hide toggles the app

**Files in**
- [ ] Drop on Dock icon/window, Open With (file types pdf png jpg jpeg gif webp txt md markdown csv json zip), ≤25 MB, ≤5 files; send picker (new chat with persona / existing chat); upload POST `/api/v1/chat-attachments`; send POST `/api/v1/chats` or `/api/v1/chats/{id}/messages`
- [ ] Quick Actions "Send to Vesper" / "Send Text to Vesper" install/uninstall

**Settings** — sections General, Notifications, Shortcuts, Files & Links, Workspaces, Power & Stack, Backups, Security, Updates; every key and default in `defaultNativeSettings`; persisted to `config.json` `native`; test notification, test Touch ID, open data dir

**Power, backups, updates, workspaces, login**
- [ ] Keep awake while runs are active; on sleep pause (POST `/api/v1/runs/{id}/pause`), resume on wake only runs Vesper paused; battery warning once per battery session
- [ ] Thermal/Low Power easing: PUT `/api/v1/runner/slot-limit` (critical → 1, serious/Low Power → max(1, ⌊max/2⌋)); max from GET `/api/v1/runner`
- [ ] Time Machine exclusion of `<data>/vm` and `<data>/images` (`tmutil`); scheduled export (GET `/api/v1/instance/export` → `vesper-export-YYYY-MM-DD-HHMM.zip`, keep N, 0600)
- [ ] Update check (opt-in, GitHub latest release, semver, https only)
- [ ] Open at login (`SMAppService.mainApp`), start in menu bar
- [ ] Open workspace folder menu (Finder / terminal app / editor app or terminal command), roots from GET `/api/v1/runner` `host_workspaces_dir`
- [ ] Touch ID for approvals (scopes run_approvals, push_requests, connector_approvals, secret_approvals)
- [ ] `vesper://` links: run/<uuid>, ticket/<KEY-n>, epic/<uuid>, page/<uuid>, chat/<uuid>, inbox, capture (strict validation as `DeepLinks.swift`)

## Layout of `macos/`

```
macos/Package.swift                 SwiftPM; macOS 15+
macos/Sources/VesperCore/           logic with no AppKit UI (unit-tested)
  Bridge/       Protocol.swift (Codable mirror), BridgeOrigin.swift
  Stack/        StackController, SecretsKey (+ safeStorage migration), StackHealth, BundledResources
  API/          APIClient (session cookie), InboxMonitor, RunMonitor, EventStream (SSE), APIRuntime,
                QueryStore + LiveUpdates (native screens' cache), Generated/ (from api/openapi.yaml)
  Settings/     NativeSettings (config.json "native"), SessionStore (session.json)
  Model/        DeepLinks, Routing, InspectorLogic, FindLogic, ShortcutsCatalog, ToastQueueLogic, QuickLookLogic, NotificationPolicy, TrayModel, DockModel, Capture, Drop, Power, Thermal, Backups, Updates, WorkspaceOpen
macos/Sources/Vesper/               the app (AppKit + SwiftUI)
  App/          main.swift, AppDelegate, AppModel
  Window/       WindowRootController (3-pane split + stationary rail + toast HUD), MainWindowController (a window and its tabs), TabsModel, TabContainerController, WebContentController (one tab), ShellBridge, WebViewFactory, FindBarViewController, CommandPaletteController, ToastPresenter, OfflineView
  Sidebar/      SidebarView (renders ShellModel + NavModel)
  Inspector/    InspectorViewController (split pane + NSPanel pop-out), InspectorView (SwiftUI renderer), CompanionWebController (persistent /companion WebView), InspectorPanelWebController (persistent /inspector-panel WebView)
  Toolbar/      ToolbarController, TabStripView (compact tabs)
  Menus/        MainMenu
  Windows/      AuxWindows, ShortcutsWindow
  MenuBar/ Notifications/ Dock/ Capture/ Files/ (QuickLookController) Settings/ Logs/ Power/
macos/Tests/VesperCoreTests/        XCTest, incl. bridge fixture decoding
macos/scripts/build-app.sh          assemble + sign Vesper.app
macos/Resources/                    Info.plist template, icons, tray images
macos/scripts/gen-icon.mjs, gen-tray-icons.mjs   regenerate Resources/AppIcon.icns and tray/ from web/public/logo.svg
macos/Makefile                      build, test, app, dmg, run, reinstall
macos/staged/                       staged resources (git-ignored; scripts/stage-mac-resources.sh)
```

## Native screens: API client and data store

Native screens (epic "Native Swift screens") talk to the API through generated Swift, not the bridge:

- `make gen` runs `server/cmd/gen-swift-api`, which writes `API/Generated/API+Schemas.gen.swift`
  (a Codable struct per schema, under the `API` namespace) and `API+Operations.gen.swift` (one
  `API.<operationId>(…)` per operation returning an `APIRequest<Response>`). It's Go on kin-openapi
  rather than swift-openapi-generator because the package fetches no SwiftPM dependency (the macOS
  VM has no network). `make gen-check` and `go test ./cmd/gen-swift-api` fail when it's stale.
- Decoding is strict for required scalars and lenient where Go is loose: a required array or map
  decodes `null` as empty, and string enums are open (`APIStringEnum`), so a newer server's value
  still decodes. A nullable optional member is `APINullable<T>?`: nil omits it, `.null` clears it.
- `QueryStore` (one per app, `AppModel.system.store`) is the React Query counterpart: entries keyed by
  path and query, `load` from `.task`/`onAppear` (never a view body), `observe`/`stopObserving` so
  `/events` hints refetch visible entries at once (`LiveUpdates`, a port of
  `web/lib/live-updates.ts`: keep them in step), and `mutate` with optimistic updates that roll back.

## Native screens: hosting

A tab is still a `WebContentController`; a native screen is drawn over its web view when the tab's
path resolves in `NativeRouteRegistry` (VesperCore `Model/NativeRoutes.swift`). Screens move over
one at a time by adding a `NativeScreen` case and a route.

- **Routing.** Every way into a path ends in `WebContentController.navigate(path:)` or a URL change
  (sidebar, links, `vesper://` deep links, back/forward, ⌘-click into a new tab), and both resolve the
  path, so a registered screen shows wherever a link points. The web view keeps running underneath
  (history, the sidebar's area list, the page's own chrome) and shows again when the path leaves.
- **Chrome.** A screen describes its title, subtitle, title menu, toolbar and inspector as
  `NativeChrome` on its `NativeScreenContext`; `ShellState` shows it instead of the page's
  (`page*` fields) and restores the page's when the screen goes. Toolbar, title-menu and inspector
  commands go to the screen's `onCommand` (`NativeCommandRouting`); the rest still reach the page.
- **Theme.** The page's `appearance` message carries its resolved colours (`tokens`) and text size;
  screens read `@Environment(\.vesperTheme)` (`palette`, `font(_:)`, `vesperText(_:_:)`), so they
  follow the palette, accent, Light/Dark and Settings → Text size live. Fallbacks are system colours.
- **Find.** The find bar searches a `FindTarget`: the web view, or the screen's `NativeFindModel`
  (it lists row texts; the screen marks matches and scrolls to `current`).
- **Debug screen.** `VESPER_NATIVE_DEBUG=1 make -C macos run` (or `defaults write <bundle id>
  VesperNativeDebugScreens -bool YES`) enables `/native-debug` and `/native-debug/:id`.

Manual click-through for the hosting path (with the debug screen enabled):

1. Open `/native-debug` from the address in a new tab (⌘T, then the command palette or a link):
   the native screen shows with title "Native screen", subtitle `/native-debug`, a Refresh toolbar
   button and a Details inspector tab.
2. Change Settings → Appearance (palette, Light/Dark, Text size): swatches and type samples follow
   without reloading.
3. ⌘F, type "milestone": matching rows tint, Return steps through them and scrolls; Esc clears.
4. Right-click a row: Open in New Tab opens `/native-debug/<n>` natively; double-click navigates
   in place, and Back returns to `/native-debug`.
5. Toggle Details → Show query; the title menu's Copy Path copies the path; ⌘\ hides and shows
   the inspector.
6. Navigate to `/inbox` from the sidebar: the web Inbox shows with its own title and toolbar.
7. Resolve an inbox item in another window: the Data section's count updates without Refresh.

## Build and test

- `make -C macos test` → `swift test` (VesperCore).
- `make -C macos app` (or `make mac-app`) → `macos/build/Vesper.app`; `make -C macos run` launches
  it with logs to the terminal; `make -C macos dmg` (`make mac-dmg`) packs the signed app into
  `macos/build/Vesper-arm64.dmg` (app plus an Applications link, volume "Vesper") with a `.sha256`;
  `make -C macos reinstall` replaces `/Applications/Vesper.app`. `SKIP_STAGE=1` reuses `macos/staged`.
- Releases: `.github/workflows/mac-release.yml` on a `vX.Y.Z` tag (see [mac-updates.md](mac-updates.md)).
- Web: `npm --prefix web test`, `npm --prefix web run lint`, `npx --prefix web tsc --noEmit -p web`.
- Server: see AGENTS.md "Running the server tests".
