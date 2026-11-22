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

## Native screen: Inbox

`/inbox` is native (`macos/Sources/Vesper/Native/Inbox/`, logic in VesperCore `Native/InboxLogic.swift`, a port
of `web/lib/inbox.ts`, which stays for the web tray and dashboard). The web route is gone; in a browser `/inbox`
is a 404. Grouping, Open/Done, sort, project filter, All clear with Still running, the detail pane's actions per
kind, Sent markers and J/K/A/D/R/E/↵/? match the web. Added natively: ⌘/⇧-click multi-select with bulk Mark
done/Reopen, a row context menu, and Undo of Mark done from the toast or ⌘Z (`POST /inbox/unread`). The project
filter is remembered in the app's defaults (`VesperNativeInboxProject`), not shared with the web's page storage.
Not ported yet: the PR feedback strip in PR feedback items and the dispatch banner in dispatch items (they come
with the native Tickets screen); animated persona characters show as their initial (Native 10).

1. Open Inbox from the sidebar: groups in urgency order with counts, title "Inbox", subtitle "N waiting on you".
2. J/K move the selection (wrapping) and the pane follows; ↵ opens the item; ? opens the shortcuts window.
3. On an approval: A approves (the row shows Sent, then leaves on the live update); D denies; R focuses the
   note; ⌘↵ in the note approves; Esc returns to the list.
4. On a question: R, type, ⌘↵: a comment mentioning the agent lands on the ticket.
5. E marks done: the toast offers Undo; Undo (or ⌘Z) puts it back in Open.
6. ⌘-click two rows, right-click: Mark 2 Done; switch to Done, select both, Reopen.
7. Switch Project: the list filters and the choice survives a relaunch.
8. Resolve an item from another window or the web: the row leaves without a refresh.
9. Empty Open view: All clear, Still running lists live runs; "View all runs" opens Runs.

Lessons from the pilot, for the next screens:

- The store's `mutate(optimistic:)` covered every action; `invalidating:` must name the resources the web's
  hook invalidated (inbox, tickets, runs…), or other open screens stay stale until the next hint.
- Window services (toasts with actions, shortcuts, Quick Look, the undo manager, external links) are on
  `NativeScreenContext`; native toasts report their action back through `showToast(_:onEvent:)`.
- Shared views live in `Native/Shared/NativeComponents.swift` (`WorkPersonaAvatarView`, `TonePill`, `KeyCap`,
  `SkeletonBar`, `.buttonStyle(.vesper(.primary))`, `QueryErrorView`); reuse them instead of re-deriving tokens.
- Generated types follow the spec strictly: `InboxItem.ticketKey` is a required string ("" when none), not
  optional. Check `required` in api/openapi.yaml rather than the web's optional chaining.
- Keyboard: `.onKeyPress` on the screen with a `FocusState` for the list, so typing in a text box never
  triggers list shortcuts.
- The web page under a native route now renders its 404; nothing redirects unknown paths, so the native screen
  stays. Don't add a catch-all redirect to the web router.

## Native screen: Work

`/work` and the old bare `/runs` are native (`macos/Sources/Vesper/Native/Work/`); a run's own page
(`/runs/:id`), tickets and epics stay on the web and open with `context.navigate`. Logic is in VesperCore
`Native/WorkLogic.swift` (a port of the Activity parts of `web/lib/work-overview.ts`, with what it reads from
`run-list.ts`, `format.ts` and `costs.ts`), `Native/WorkNav.swift` (the Work header and Runs NavModel of
`native-shell/models/work.ts` and `runs.ts`) and `Native/DispatchLogic.swift` (the dispatch dialog's checks).
The web routes and their dead code are gone; in a browser `/work` and `/runs` are 404s.

- The page is the Overview: telemetry strip (Runner, Needs you, Today, 7d spend), Needs you cards, Running now
  with plan progress, Ready to start with Start ready, Finished today. View "Failed today" leaves only Finished
  today, as on the web.
- The sidebar's list is the screen's own (`NativeChrome.navigator`, see Hosting): Space, Persona and View
  menus with counts, Runs/Tasks switcher, New ticket, filter box, Overview row, Active and day groups, runs
  without a run row under Needs you or Waiting, Load older runs, Retry, and the runner/spend status line.
  `ShellState` keeps the page's list underneath; nav commands carrying `work-activity` go to the screen.
- Filters start from the URL (`?project=`, `?agent=`, `?filter=`, `?q=`, the old `?done=hide`) and then live in
  the screen; they aren't written back to the URL. The Space choice is remembered in the app's defaults
  (`VesperNativeWorkProject`) for a bare `/work`, not shared with the web's page storage; so is the Chat
  companion's open state (`VesperNativeWorkCompanionOpen`).
- Old links redirect: `?run=` opens `/runs/:id`, `?view=tickets`/`?view=epics` (and `?layout=epics`) open
  Tickets, as the web's did. The redirect is a push, so Back from such a run returns to the redirect.
- Live: every query is observed, so `/events` hints refetch it; on top, live runs refresh every 10 s, the
  runner every 15 s (2 s while offline) and spend every 30 s, like the web's intervals.
- Added natively: row context menus (Open, Open in New Tab, Open ticket, Copy Run ID, Copy Link) and ⌘-click
  for a new tab. Start ready shows the bulk dispatch sheet for any count (the web's single-ticket preview with
  the full scope table isn't ported). Persona avatars show photo or initial; animated persona characters come
  with Native 10.

1. Open Work from the sidebar: title "Runs", the Overview, and the Work list in the sidebar with Overview
   selected. Narrow the window: the strip keeps four cells.
2. Space menu → another space: the strip's spend, Needs you, running and ready tickets follow; relaunch and
   open `/work` again: the space is kept. Persona menu narrows the runs list and Needs you.
3. View → Needs you / Running & queued / Failed today: the list and counts follow; Failed today hides Needs you,
   Running now and Ready to start.
4. Type in the sidebar's filter box: runs and waiting items filter; clear it.
5. Start a run from a ticket elsewhere: it shows under Running now and in Active without a refresh; its step
   and progress bar move; when it ends it lands in Finished today and the Today cell counts it.
6. With a waiting approval: the toolbar shows "Needs you · N"; pressing it switches View to Needs you. "Review →"
   on the card opens the run's page; Back returns to Work.
7. Right-click a running row: Open in New Tab opens the run in a tab; Copy Link copies a `vesper://` link.
8. Start ready (N): the sheet lists each ticket with harness, model and its note; Approve & dispatch starts
   them and the rows move to Running now. With no harness key stored, the banner offers Add a key.
9. Scroll to the end of the runs list: Load older runs adds a page. Stop the server: the list shows the
   error row with Retry; start it and Retry.
10. ⌘F "WEB-": matching cards tint, Return steps and scrolls. ⌘\ opens and folds the Chat companion.
11. Open `/work?view=epics` and `/work?run=<id>` from the address: Tickets' Epics and the run's page open.
## Native screen: Library

`/library` is native (`macos/Sources/Vesper/Native/Library/`, logic in VesperCore `Native/LibraryLogic.swift` and
`LibrarySelection.swift`, ports of `web/lib/library-ui.ts` and the helpers the web screen used). The web route,
its navigator model and the Library-only hooks are gone; in a browser `/library` is a 404. Both halves moved:

- **Yours** (keepsakes): a `LazyVGrid` per kind (Images, Videos, Audio, Files, Exports, Diagrams, Documents) with
  the web's tiles, empty states, Show more and item dialogs (image, video and audio players with speed and loop,
  rename, file previews, export source line, reference images), plus Links (To read/Done, Videos/Pages, Undo on
  remove) and the Fridge (persona filter, Add a moment, Undo on delete). `?tab=…&item=…` (a chat's "Open in
  Library") opens the tab and the item. Added natively: click, ⌘-click and ⇧-click selection, arrow keys, ⌘A,
  Esc, Space for Quick Look over the selection (or all tiles from the focused one), Return to open, ⌘⌫ to remove,
  a context menu per tile (bulk Quick Look and Remove for a multi-selection), and dragging a tile out: its
  `NSItemProvider` fetches the file with the session when the drop asks for it. Double-click opens a tile (single
  click selects, as in Finder; the web opened on click).
- **From spaces** (`?source=projects`): a native `Table` with the type filters (counts), search and the space
  picker in the sidebar navigator, the preview pane (outline, readers, tickets, Edit / New version / Export PDF /
  Generate tickets), the drop zone, and native Upload, New mockup and New version sheets. The space comes from
  `?project=` (All spaces otherwise); the web's remembered space isn't read.
- **PDFs** open in PDFKit (`Native/PDF/PDFViewer.swift`): thumbnails, search with match count, zoom, and text
  selection whose menu has Look Up. `/pdf?src=/api/v1/…&title=…` shows one PDF on its own with the window's find
  bar searching it (`NativeFindModel.searcher`); web Knowledge's PDF embed **Open** goes there in the Mac app
  (`nativePdfHref`), while browsers keep the pdf.js dialog. The inline embed on the Knowledge page is still
  pdf.js, so `pdf-viewer.tsx` and `pdfjs-dist` stay (also used by chat PDF cards and `/artifacts/[id]`).
- A screen can now publish the sidebar navigator (`NativeChrome.navigator`, shown over the page's
  `ShellState.pageNavigator`); `nav.*` commands for its id go to the screen (`NativeCommandRouting`).

Not ported: a video tile doesn't play a muted preview on hover; a YouTube link's card opens the video in the
browser instead of embedding the player; dragging several selected tiles drags only the one under the pointer.

1. Open Library from the sidebar: title "Library", the source picker (Yours / From spaces) and the nine tabs in
   the sidebar, Upload in the toolbar, the Images grid with sources under each tile.
2. Click a tile, ⇧-click another, ⌘-click a third: the selection follows; arrows move it, ⇧-arrows extend it.
   Space opens Quick Look on the selection; Esc clears it.
3. Double-click an image: the dialog shows it with Quick Look, Download, Remove and Use as reference; pick "Use as
   my reference": the tile shows "You · reference"; Clear reference removes it.
4. Right-click a tile: Quick Look, Open Details, Open Chat, Rename…, Download…, Copy Link, Remove from Library.
   Rename it; Download saves a copy where you choose; Copy Link copies the content URL.
5. Drag a tile to the Desktop: the real file lands there under its filename.
6. Upload a PNG, then a `.exe`: the PNG appears; the `.exe` is refused with the web's message.
7. Videos and Audio: double-click plays; in audio, scrub the waveform, change speed, toggle loop, rename.
8. Files: open a `.py`, a `.csv`, a `.zip` and a PDF: text, table, file list, and the PDF in PDFKit; search a
   word in the PDF (count, ↑/↓), toggle thumbnails, select text and choose Look Up.
9. From a chat's video card, Open in Library: Videos opens with that video's dialog.
10. Links: Mark done moves a card to Done; remove one, then Undo in the toast: it comes back.
11. Fridge: filter by a persona, Add a moment, delete it, Undo.
12. Switch the source to From spaces: filter by type (counts in the sidebar), search, switch space; select a
    row for the preview; double-click opens the artifact; Upload two files; New mockup opens the editor.
13. Open a Knowledge page with a PDF embed and click Open: the PDF opens natively (title in the toolbar,
    Download); ⌘F searches it; Back returns to the page. In a browser, Open still shows the pdf.js dialog.
## Native screen: Markdown renderer

`MarkdownView` (`macos/Sources/Vesper/Native/Shared/MarkdownView.swift`) is the one markdown renderer for
native screens (ticket descriptions, chat messages, Learn, Knowledge previews); no screen uses it yet
(the Inbox shows its summaries as plain text, as the web does). It reproduces the web's `<Markdown>`
(`web/components/domain/markdown.tsx`): `textStyle`/`textColor` are the container's type and colour,
`anchors` the document headings, `chat` ChatMarkdown (ticket keys and `citations` link, code blocks get
the header, Shiki and the fold of `code-fence.tsx`).

- **Parsing** (VesperCore `Markdown/`): `MarkdownSource` ports the web's rewrites (wiki links,
  ticket keys, citations) and marks `$$` math; `MarkdownParser` parses with cmark-gfm, vendored in
  `macos/Vendor/cmark-gfm` (no SwiftPM dependency); `MarkdownRenderer` builds the attributed text
  with the theme tokens, and `MarkdownDecoration` describes the boxes, rules and quote bars a TextKit 2
  layout fragment draws behind each paragraph.
- **Code colours**: Shiki with the JavaScript regex engine, the web's themes and languages, in
  JavaScriptCore (`CodeHighlighter`, an actor, cached per code and language), re-hued onto the
  palette as `web/lib/code-colors.ts` does. `macos/scripts/build-shiki-bundle.mjs` builds
  `Sources/VesperCore/Resources/shiki/shiki.js` from `web/node_modules` (checked in; re-run after a
  Shiki upgrade or a change to `web/lib/highlight.ts`); `scripts/build-app.sh` copies VesperCore's
  resource bundle into `Contents/Resources`. The bundle uses ES2018 regexes: with ES2024 ones
  JavaScriptCore mis-colours a grammar's first highlight.
- **Fixtures**: `protocol/markdown` (see its README). `web/scripts/markdown-fixtures.mjs` writes the
  web's normalized tree and token colours; `MarkdownSnapshotTests` fails on any difference.
- **Links**: in-app paths navigate (⌘-click opens a new tab), web links open in the browser,
  `[[links]]` resolve through the store (`GET /knowledge/resolve`) and an unresolved one is a ghost
  that creates the page, `#anchors` and footnotes scroll, citations go to the screen's `onLink`.
- **Find**: give the view its row (`findRow`) in `context.find.texts`; it tints the matches and scrolls
  the current row's first match into view.

Not matching the web yet: math shows its TeX source (no KaTeX); the chat's special fences (app,
canvas, pdf, mermaid, charts, choices, recommend, dispatch, workflow runs) show as plain code blocks
until their screens move over; wiki links have no kind mark (status glyph, page icon); hover underlines
on links; wide tables wrap instead of scrolling sideways, and long code lines wrap; inline code has no
border.

Manual click-through (with `VESPER_NATIVE_DEBUG=1`), on `/native-debug/markdown`:

1. The three samples (ticket description, document, chat reply) show headings, lists with numbers and
   bullets, task checkboxes, a quote with its bar (and a nested one), a full-width table with a sunken
   header and aligned columns, a rule, code boxes, display math, raw HTML as text and a footnote list.
2. In the chat sample, code blocks have a language header with Copy; Go, TypeScript and Python are
   coloured like the web's (compare with a chat reply in the browser) and follow Light/Dark and the
   palette; Copy copies the code and says Copied; the 24-line block shows "Show 4 more lines", which
   unfolds and folds.
3. Drag-select across paragraphs, the table and code, ⌘C, and paste: the text comes out in order.
   Force-click (or Control-⌘-D) a word: Look Up opens. Right-click a selection: Copy, Look Up, Services.
4. Links: "web link" opens the browser; "in-app link" opens the Inbox in place, ⌘-click in a new tab;
   [[Roadmap]] links to its page when it exists, otherwise it is grey with a dashed underline; the
   ghost "No such page yet" creates that page and opens it for editing (delete it afterwards);
   PAY-214 (chat sample) opens the ticket.
5. Citations [1] and [2] in the chat sample are chips (a toast names the number); [3] stays text.
6. The footnote mark scrolls to the footnote and its ↩ scrolls back; in the document sample, "link"
   in the footnote jumps to the "Links" heading.
7. ⌘F "quote": matches tint in all three samples; Return moves between samples and scrolls to them.
8. Settings → Appearance: palette, Light/Dark and Text size restyle the text, boxes and code colours live.

## Native screen: Dev terminal

`/dev` is native (`macos/Sources/Vesper/Native/Dev/`, logic in VesperCore `Native/DevTerminalLogic.swift`, a port of
the terminal half of `web/lib/dev-workspace.ts`). The terminal is the page's whole content, so the route moved
whole. The web route, `dev-terminal.tsx` and the `@xterm/xterm` and `@xterm/addon-fit` dependencies are gone; in a
browser `/dev` is a 404. Settings' Dev workspace section and "Open in Dev workspace" buttons stay on the web, and
their link to `/dev` opens the native screen.

- **Emulator.** SwiftTerm, vendored in `macos/Vendor/SwiftTerm` (MIT, tag `v1.18.0`, about 1.5 MB of Swift, no
  modifications; see its README). It builds with SwiftPM alone, so the package still fetches nothing.
  libghostty would have needed Zig and a prebuilt xcframework. `v1.18.0` is the last tag whose library target
  needs no build-tool plugin.
- **Stream.** The same PTY WebSocket the web used: `ws(s)://<host the app reaches Vesper at>:<workspace
  port>/ws?cols=&rows=` with the session cookie and Vesper's `Origin` (the runner refuses other origins).
  Output is binary frames, keystrokes go out as binary frames, and resizes go as `{"type":"resize",…}` text
  frames whenever the view's size changes and once the socket opens. Reconnect makes a new emulator and socket,
  as the web made a new xterm.js.
- **Look.** The web's Gruvbox palette, 13 pt system monospace (`ui-monospace`), no bell. The header, status pill,
  buttons and states use the theme tokens like the web's Tailwind classes.
- **Input.** Native text input and IME, Option as Meta, ⌘C/⌘V and Edit ▸ Copy/Paste, Shift+drag to select past
  tmux's mouse mode. Esc and Ctrl+W/T/N always reach the terminal (there's no browser to take them), so the web's
  keyboard-lock hints are gone. tmux and Neovim copies over OSC 52 go to the pasteboard, with the web's size limit.
  Reads are never answered. Only http(s) links open.
- **Secure Keyboard Entry.** Vesper ▸ Secure Keyboard Entry (enabled while a Dev terminal has the keyboard) or the
  title menu's item toggles it. It's remembered in the app's defaults (`VesperDevSecureKeyboardEntry`). While it's
  on, `EnableSecureEventInput` holds whenever a Dev terminal is first responder in the key window. Each view
  balances its calls (`SecureInputBalance`) and releases them when it goes.
- **Full screen** (Fullscreen, ⌘⇧↵ or ⌃⇧↵ from anywhere in the window). The window enters macOS full screen
  (unless it already is), the sidebar folds and the header gives way to the faint floating bar (status dot,
  Reconnect, Exit). Leaving restores both. The unified toolbar still shows at the top. Leaving macOS full screen
  another way (green button, ⌃⌘F) leaves the terminal's too.
- **Send to chat** writes the snapshot Markdown (selection plus the last 120 lines) to a temporary file and opens
  the app's send picker, as Screenshot to Chat does. The web attached it to the companion chat directly, but the
  companion lives in its own web view now. The companion-drop channel that only this fed is gone from the web.
- While the container starts or an action runs, the workspace is refetched every 2 s, as the web's query was.

1. Settings → Dev workspace off: open `/dev` from the sidebar. "Dev workspace is disabled" shows; Configure in
   Settings opens the Dev workspace section.
2. Turn it on and start: the pill reads "Starting · <step>" and the step updates without a refresh. The terminal
   area says the container isn't ready, with Start container when stopped.
3. When ready, the terminal attaches: the pill reads "Connected · tmux" and the keyboard is in the terminal.
   Gruvbox colours, monospace font and LazyVim's icons draw as on the web.
4. Resize the window and fold the sidebar: tmux and Neovim reflow to the new size (`tmux display -p
   '#{window_width}x#{window_height}'` matches).
5. Type in Japanese with an IME: the composition shows inline and commits. Option+f in zsh moves a word forward.
6. Select text with Shift+drag and press ⌘C, then ⌘V into the terminal. Yank a line in Neovim (`"+yy`) and paste
   in TextEdit: OSC 52 put it on the pasteboard.
7. Vesper ▸ Secure Keyboard Entry with the terminal focused: it's checked, and the title menu's item agrees.
   Click into the sidebar search: secure input is released (`ioreg -l -w 0 | grep kCGSSessionSecureInputPID`
   no longer shows Vesper's pid). Click back into the terminal: it's held again. Turn it off.
8. ⌘⇧↵: the window goes full screen, the sidebar folds, the floating bar fades in on hover. Esc and Ctrl+W reach
   Neovim. ⌘⇧↵ again (or Exit) returns the window and the sidebar. Enter again and leave with ⌃⌘F: the header
   comes back.
9. Shortcuts: the sheet lists LazyVim, tmux with your configured prefix, and the Mac app's keys. Esc closes it
   and the terminal has the keyboard again.
10. Sync repos: the button disables while it runs and the pill follows the workspace state.
11. Send to chat: the send picker offers `dev-terminal-<stamp>.md`. Send it to a chat; it holds the selection and
    the visible output. The button reads "Sent to chat" for a moment.
12. Stop the container from Settings: the socket drops, the pill shows the workspace state, and Reconnect appears.
    Start it and Reconnect: a fresh session attaches.
13. From a chat's ticket card with an open PR, Open in Dev workspace: `/dev` opens natively on that branch.

## Native window: Settings

All web settings routes (`web/app/(app)/settings/*` and the settings sections under `web/app/(app)/customization/*`)
and Mac app preferences live together in the single native Settings window (`⌘,`, `SettingsWindowController`,
`SettingsView`). The web routes for `/settings*` are removed (`setup/page.tsx` and chat approval sheets keep only
their inline helper components), and `SettingsRouteResolver` (`VesperCore/Settings/SettingsRouteResolver.swift`) +
`isNativeSettingsPath` (`web/lib/next-compat/router.ts`) intercept `/settings*`, `/customization*`, `/memory`,
`/personas`, and exact `/agents` links (leaving `/agents/:handle` alone) from any web view, rail item, or tab navigation
to focus the matching pane or redirect `/settings/projects` to `/spaces/<id>`.

Sidebar groups (`SettingsPane` in `SettingsView.swift`):

- **Personal**: `you` (bootstrap profile + personal memory), `appearance` (mode, harness activity toggle, text size,
  18 preset palettes + custom dark/light hex editor with WCAG `< 4.5:1` contrast warnings, 40 KB JSON import/export,
  macOS system accent inheritance), `memory` (all/scoped filters, deep-link highlight, create/edit/delete, import,
  JSON/Markdown export).
- **Personas**: `personas` (`All` / `Chat` / `Tickets` filter, profile/model/work/connectors/memory tabs, create/edit/delete).
- **Integrations**: `secrets` (Provider Credentials + API Secrets with `SECRETS_KEY` guard, scopes, activity, deep-link
  focus), `connectors` (CRUD, status, per-persona permissions), `repositories` (saved GitHub repositories & owners).
- **Workspace**: `workspace` (name/slug, `SECRETS_KEY`, setup checklist, image engine), `runners` (status, host-folder
  workspaces toggle, runner environment snapshots & test environments card with `run_id` deep links), `devWorkspace`
  (enable, start/stop/rebuild/reset, sync repos, tmux prefix, dotfiles repo, "Open Dev Terminal" → `/dev`), `spaces`
  (per-space memory + space agent overrides).
- **Account**: `signIn` (owner password set/change via `OwnerAuthAPI`, sessions, sign-in link).
- **Mac App**: `general`, `notifications`, `shortcuts`, `files`, `workspaces`, `power`, `backups` (folded in web archive
  "Export Everything…" via streaming `BackupExporter.exportToFile` + import info alongside local SQLite snapshots),
  `security`, `updates`.

Pure logic lives in `VesperCore/Settings/` (`SettingsRouteResolver.swift`, `PaletteTokens.swift`, `NativeSettings.swift`,
`OwnerAuthAPI.swift`, `SettingsHelpers.swift`) and `LiveUpdates.swift` includes prefixes for `profile`, `memory`,
`secret`, `api_secret`, `connector`, `repository`, `runner`, `dev_workspace`, `space`/`spaces`, and `image_engine`.
Changing Appearance saves to `config.json` and calls `AppModel.broadcastAppearance()`, pushing `NativeCommand.appearance`
(`themePref` and `settingsJson`) to all open main tabs, companion, inspector, and command-palette web views via
`applyNativeAppearance` while updating `ShellState.theme` and `RailBarView` (filtering harness/usage items when
`showHarnessActivity` is off) without a reload.

Manual click-through checklist:

1. Open Settings (`⌘,`) or click Settings / Memory / Personas / Workspace / Runners / Dev Workspace / Sign-in links inside
   chat, sidebar, or Dev workspace empty state: the unified native window opens directly on the targeted group, pane,
   tab, or deep-linked item (`secret_id`, `memory`, `run_id`, `/personas/<id>`).
2. In **Appearance**, toggle Dark/Light/System, change palette and text size, toggle "Show harness activity", and tweak a
   custom color: open main tabs, Companion, Inspector, Command Palette, and the left rail reflect the change live without
   reloading, including WCAG contrast warnings below 4.5:1 and JSON export/import.
3. Verify **You** and **Memory** edit profile fields and memories, export JSON/Markdown via `NSSavePanel`, and import
   memories.
4. Verify **Personas** filters (`All`, `Chat`, `Tickets`), detail tabs, creating/editing/deleting a persona, and `/agents/:handle`
   still opening normally outside Settings.
5. Verify **Integrations** (`Credentials & API Secrets`, `Connectors`, `Repositories`) create/update/revoke/delete entries
   and show `SECRETS_KEY` status accurately.
6. Verify **Workspace**, **Runners**, **Dev Workspace**, and **Spaces** update workspace settings, show runner snapshots
   and test environments, drive Dev workspace lifecycle actions and "Open Dev Terminal", and edit space overrides/memory.
7. Verify **Sign-in** updates the owner password/session list, and **Mac App → Backups** runs both "Export Everything…"
   (`.tar.gz`) and local DB backup actions cleanly.

## Native scenes and custom persona characters

All 59 `ChatStatusKind` activity scenes (`56` unique definitions plus `3` split aliases: `writing-reply`, `image-view`, `design-view`) and the pooled custom SVG persona character view live natively in `VesperCore` and `Native/Shared/`:

- **Activity scenes (`VesperCore/Native/` + `ActivitySceneView.swift`).** `MotionPrimitives` implements CSS easing (`linear`, `ease`, `ease-in`, `ease-out`, `ease-in-out`, `--motion-ease` `cubic-bezier(0.16, 1, 0.3, 1)`, `steps(N)`), per-property keyframe channel interpolation, and `ActivitySceneTransitioner` (`800 ms` minimum hold skipping transient kinds, `240 ms` crossfade, `600 ms` linear deceleration to `0` on stop). `SVGPathParser` parses `M/m`, `L/l`, `H/h`, `V/v`, `C/c`, `S/s`, `Q/q`, `T/t`, `A/a`, `Z/z` and trims `pathLength=1` paths for `stroke-dashoffset` animations. `ActivitySceneRenderer` draws into CoreGraphics (called by SwiftUI `Canvas` and bitmap snapshot tests), applying the theme's `ActivityScenePalette` and `blur(3px)` focus transitions, and freezing at the resting pose under Reduce Motion.
- **Fixtures (`protocol/activity-scenes/`).** `web/scripts/activity-scene-fixtures.mjs` extracts all 59 kinds, split aliases, transition timings, and 193 scene animations from `web/lib/chat-ui.ts`, `activity-scene.tsx`, and `globals.css` into `fixtures.json`; `ActivitySceneTests` verifies 100% parity and bitmap motion/freeze snapshots for every kind. (`activity-scene.tsx` stays for the web until chat moves over.)
- **Pooled persona characters (`PersonaCharacterSanitizer.swift`, `PersonaCharacterView.swift` + `PersonaCharacterPlatformView.swift`).** `PersonaCharacterSanitizer` ports `web/lib/svg-sanitize.ts` (`character: true`, `XMLParser` whitelist rejecting `<script>`, `<style>`, `<image>`, nested `<svg>`, external `url(...)`, and `javascript:`, prefixing IDs) and `web/lib/persona-character.ts` (`characterStateForStatus`, `characterStateForDock`, `resolveCharacterNodeStyle`), emitting self-contained HTML with CSP `default-src 'none'; style-src 'unsafe-inline'` and the `.persona-character` keyframes. `PersonaCharacterView` stays pure SwiftUI; `PersonaCharacterPlatformView` isolates the macOS `NSViewRepresentable` host and `PersonaCharacterPool`, which owns **one** live pooled `WKWebView` (JS disabled, non-persistent data store, navigation restricted to `about:blank`) for `active: true` cards, plus **one** offscreen snapshotter writing `NSImage` into `NSCache` for `active: false` list/avatar rows (`WorkPersonaAvatarView` uses `active: false` when `characterSvg` is set and `avatarUrl` is absent).

Manual click-through (with `VESPER_NATIVE_DEBUG=1`), on `/native-debug/scenes`:

1. Open `/native-debug/scenes`: all 59 scenes animate smoothly inside the recessed `surface-sunken` stage, matching the web's colours and split-alias notes.
2. Click rapidly between `thinking`, `reading-code`, and `writing-code` inside 800 ms: the intermediate scene is skipped and the outgoing scene crossfades out over 240 ms once the hold ends.
3. Toggle `Stopping (600ms wind-down)` on: the stage coasts to a stop over 600 ms and desaturates to 50% opacity; toggle off to resume.
4. In the Pooled `PersonaCharacterView` card, switch states (`Idle` → `Thinking` → `Reading` → `Coding` → `Creating` → `Needs you`) and colours: the single live character swaps animations immediately (`data-show` sparkles/alerts toggle cleanly) while the four inactive snapshot avatars on the right render without creating additional web views.
5. Enable System Settings → Accessibility → Display → Reduce Motion: every activity scene freezes on its resting frame and the live persona character freezes on `static`.
6. Toggle Light/Dark and accent in Settings → Appearance: scenes re-colour live; ⌘F searches the scene grid by kind name.

## Build and test

- `make -C macos test` → `swift test` (VesperCore).
- `make -C macos app` (or `make mac-app`) → `macos/build/Vesper.app`; `make -C macos run` launches
  it with logs to the terminal; `make -C macos dmg` (`make mac-dmg`) packs the signed app into
  `macos/build/Vesper-arm64.dmg` (app plus an Applications link, volume "Vesper") with a `.sha256`;
  `make -C macos reinstall` replaces `/Applications/Vesper.app`. `SKIP_STAGE=1` reuses `macos/staged`.
- Releases: `.github/workflows/mac-release.yml` on a `vX.Y.Z` tag (see [mac-updates.md](mac-updates.md)).
- Web: `npm --prefix web test`, `npm --prefix web run lint`, `npx --prefix web tsc --noEmit -p web`.
- Server: see AGENTS.md "Running the server tests".
