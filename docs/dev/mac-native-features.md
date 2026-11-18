# Mac app: native features

Epic "Native macOS features for the microVM Vesper.app" (LAZYAGENTS-240..249).
Everything here lives in the Swift shell (`macos/`, see
[native-mac-app.md](native-mac-app.md)); the web app and the Linux/Docker path
are unchanged apart from the page-to-shell bridge (`web/lib/desktop-bridge.ts`,
`web/lib/native-shell`).

## Where things are

Logic is in `macos/Sources/VesperCore` (unit tested in
`macos/Tests/VesperCoreTests`), AppKit glue in `macos/Sources/Vesper`.

| Feature | Ticket | Logic (VesperCore) | Glue (Vesper) | UI |
| --- | --- | --- | --- | --- |
| Settings model | all | `Settings/NativeSettings.swift`, `SettingsStore.swift` (`native` in config.json) | `Settings/` | Settings window |
| Menu bar icon | 240 | `Model/TrayModel.swift`, `API/RunMonitor.swift` | `MenuBar/MenuBarController.swift`, `System/MenuBuilder.swift` | menu bar menu |
| Notifications | 241 | `Model/NotificationPolicy.swift`, `API/InboxMonitor.swift`, `API/RunMonitor.swift` | `Notifications/NotificationPresenter.swift` | Settings › Notifications |
| Launch at login | 242 | `Model/Login.swift` | `App/AppDelegate.swift` (`SMAppService`) | Settings › General |
| Quick capture | 243 | `Model/Capture.swift`, `CaptureOptions.swift`, `GlobalShortcut.swift` | `Capture/` | `Capture/QuickCapturePanel.swift` |
| vesper:// links | 244 | `Model/DeepLinks.swift` | `App/AppDelegate.swift` | Settings › Files & Links |
| Power | 245 | `Model/Power.swift` | `Power/PowerController.swift` | Settings › Power & Stack; [mac-power.md](mac-power.md) |
| Stack health | 246 | `Stack/StackHealthLogic.swift`, `StackController.swift` | `Window/OfflineView.swift`, `Logs/` | offline view, logs window |
| Files in | 247 | `Model/Drop.swift`, `Services.swift` | `Files/FilesIn.swift`, `Files/SendPicker.swift` | send picker |
| Touch ID | 248 | `Model/Biometrics.swift` | `System/TouchID.swift` | Settings › Security; web approve hooks |
| Updates | 249 | `Model/Updates.swift`, `UpdateCheck.swift`, `BackupExport.swift` (app state) | `App/AppDelegate.swift` | Settings › Updates; [mac-updates.md](mac-updates.md) |
| Screenshot to Chat | follow-up | `Model/Screenshot.swift` | `Capture/ScreenshotToChat.swift`, `ScreenRecordingAccess.swift` | Settings › Shortcuts; menu bar; File menu |
| Backups | follow-up | `Model/Backups.swift`, `BackupExport.swift`, `BackupImport.swift` | `Windows/ImportBackupFlow.swift` | Settings › Backups |
| Ease off when hot | follow-up | `Model/Thermal.swift`; server `PUT /runner/slot-limit` | `Power/PowerController.swift` | Settings › Power & Stack; menu bar notice |
| Open workspace folder | follow-up | `Model/WorkspaceOpen.swift` | `System/WorkspaceMenu.swift` | Settings › Workspaces; web folder chip and chat title menu |
| Dock menu and progress | follow-up | `Model/DockModel.swift` | `Dock/DockController.swift` | Settings › General |
| Show/Hide shortcut | follow-up | `Model/DockModel.swift` (`showHideAction`) | `Capture/GlobalShortcuts.swift` | Settings › Shortcuts |

## Settings and defaults

Defaults keep the app's earlier behaviour; anything that reaches outside the
app (a login item, a global shortcut, a network update check, Touch ID) is
opt-in.

| Setting | Default |
| --- | --- |
| Menu bar icon / count | on / on |
| When the last window closes | Stay in Dock (also: Menu bar only, Quit) |
| Open at login / start in menu bar | off / on |
| Notifications, per kind | on, every kind |
| Run finished, actions, grouping, sound | on |
| Quiet hours | off, 22:00–08:00 |
| Quick capture | off, ⌥⇧Space |
| Dropped files / vesper:// links | on / on |
| Keep awake while runs work | on |
| When the Mac sleeps | Leave runs |
| Battery warning / ask before quit | on / on |
| Restart stack after a crash | on (3 per 10 min) |
| Low disk warning | 10 GB |
| Touch ID for approvals | off; all four scopes once on |
| Daily update check | off |
| Screenshot to Chat | off, ⌥⇧S |
| Show/Hide Vesper shortcut | off, ⌥⇧V |
| Dock menu / Dock download progress | on / on |
| Keep VM disks and caches out of Time Machine | on |
| Scheduled export to a folder | off; daily, keep 7 |
| Take fewer runs when hot / Low Power Mode | on |
| Terminal app / editor | Terminal / `nvim` in Terminal |

## Security notes

- **vesper:// links** accept only `run/<uuid>`, `ticket/<KEY-n>`,
  `epic/<uuid>`, `page/<uuid>`, `chat/<uuid>`, `inbox` and `capture`. Query
  strings, fragments, credentials, ports, extra segments and encoded
  separators are rejected and logged by reason (never the link). The only
  thing taken from a link is a validated id.
- **Notification actions** call the same endpoints the web app does. Request
  paths are built from validated ids (`decisionRequest`, `replyRequest`), and
  the reply text only goes in the JSON body.
- **Dropped files** never become URLs. Paths are read from disk by the shell and uploaded as multipart to `POST /chat-attachments`, where the
  server applies its usual type, size and quota checks. The client check
  (`classifyDroppedFiles`) only saves a doomed upload.
- **Quick Actions** run `open -a <Vesper.app> <files>`, with the app path
  shell-quoted. Selected text goes to a private temp file, not a URL.
- **Touch ID is a local gate.** The app asks before the approval request
  is sent; the server never sees or verifies the result. It stops someone at
  an unlocked Mac from approving with a click. It doesn't stop a forged API
  call, another browser, or anything else holding a session. Server-verified
  approvals (passkeys/WebAuthn) are a separate decision. A cancelled or
  failed prompt fails closed; a Mac that can't prompt (no sensor, clamshell,
  nothing enrolled) falls back to the normal click.
- The bridge messages `confirmApproval` and `openWorkspaceMenu` are only
  answered for the main frame on the local server's origin
  (`Bridge/BridgeOrigin.swift`).
- **Opening workspace folders**: the path comes from the page, so the app
  resolves it (following symlinks) and opens it only if it's a folder strictly
  inside a live runner's `host_workspaces_dir` from `GET /runner`. The
  terminal-editor command is limited to plain words; the folder is
  shell-quoted and the whole line is an AppleScript string literal.
- **Exports** contain everything, with secrets sealed by this Mac's
  `SECRETS_KEY`. They're written 0600, and only files named
  `vesper-export-YYYY-MM-DD-HHMM.zip` are ever pruned from the folder.
- **The slot limit** sits on runner registrations, which runners delete when
  they stop, so a cap can't outlive the app that set it. The app only sets
  it for its own local stack.

## Manual checklist on a Mac

These can't run on Linux CI. Tick them off on a real Mac session and note
anything that differs.

- [ ] **Tray**: icon appears; template icon tints in light and dark menu bars;
      the count shows and updates when an approval arrives; Needs-you and
      Running items open their pages; Pause Runs / Resume Runs; Restart Stack;
      Show Logs; Quit stops the stack (asks first with runs working).
- [ ] **Last window**: each of Stay in Dock, Menu bar only (Dock icon hides,
      reappears when a window opens) and Quit.
- [ ] **Notifications**: with Vesper's style set to Alerts, Approve and Decline
      resolve an approval; inline Reply on a question posts a ticket comment
      and resumes the run; alerts for one ticket group together; a disabled
      kind stays silent; quiet hours; a run-finished alert fires once.
- [ ] **Login item**: toggling registers/removes it in System Settings › Login
      Items; a login launch starts with no window; stopping the stack's start
      (e.g. a bad kernel path) produces the "Vesper couldn't start"
      notification and the tray error icon.
- [ ] **Quick capture**: the shortcut works from another app; ⌘Space is
      refused as Spotlight's; a shortcut held by another app shows an error;
      Esc closes without sending; note, message and ticket each land.
- [ ] **vesper://**: `open vesper://inbox`, `open vesper://ticket/LAZYAGENTS-244`
      with the app running and quit (cold start); `open 'vesper://run/x?y'`
      does nothing.
- [ ] **Power**: see [mac-power.md](mac-power.md).
- [ ] **Stack health**: first launch shows the run image download with
      progress; kill `vesper` from Activity Monitor and watch it restart;
      fill the threshold above free space to see the disk warning.
- [ ] **Files**: drop a PDF on the Dock icon; drop two images on a page
      outside the composer; Open With › Vesper from Finder; Install the Quick
      Actions and use Send to Vesper on a file and Send Text to Vesper on a
      selection.
- [ ] **Touch ID**: in both a locally built (ad-hoc) and a downloaded app; on a
      Mac without a sensor (or lid closed) approvals fall back to a click.
- [ ] **Updates**: Check Now with no releases says up to date; a downgrade
      warning appears when an older build opens newer data.
- [ ] **Screenshot to Chat**: first use prompts for Screen Recording; a region
      lands in the Send picker; Esc in the picker sends nothing; the temp file
      is gone after the picker closes; ⌥⇧S can't also be Quick Capture's.
- [ ] **Time Machine**: `tmutil isexcluded ~/Library/Application\ Support/vesper-desktop/vm`
      says Excluded; turning the setting off removes it.
- [ ] **Exports**: Export Now writes a zip that File › Import Backup can
      inspect; with keep 2, a third export deletes the oldest; a stopped
      server records a failure and notifies once.
- [ ] **Ease off**: under sustained load until macOS reports serious thermal pressure, or with Low Power Mode on
      (System Settings › Battery), `GET /api/v1/runner` shows `slot_limit`
      within ~15 s and the tray says so; it lifts when back to normal.
- [ ] **Dock**: right-click the Dock icon shows Needs-you items (opening their
      pages), New Chat and New Chat with each persona (opening the new-chat
      page with that persona picked), Quick Capture and Screenshot to Chat; on
      first launch the icon shows the run image download's progress.
- [ ] **Show/Hide**: the shortcut brings Vesper forward from another app and
      hides it when pressed again; with no window open it opens one; it can't
      reuse Quick Capture's or Screenshot's keys.
- [ ] **Open folder**: with host-folder workspaces on, the run chip's Open
      menu opens Finder, the terminal app, and `nvim` in Terminal; a path
      outside the workspace root is refused.
