# Desktop: native macOS features

Epic "Native macOS features for the microVM Vesper.app" (LAZYAGENTS-240..249).
Everything here lives in the Electron shell (`desktop/`); the web app and the
Linux/Docker path are unchanged apart from one feature-detected hook for Touch
ID (`web/lib/desktop-bridge.ts`).

## Where things are

| Feature | Ticket | Logic (unit tested) | Electron glue | UI |
| --- | --- | --- | --- | --- |
| Settings model | all | `settings.ts` | `config.ts` (`native` in config.json) | `renderer/preferences.*` |
| Menu bar icon | 240 | `tray-model.ts`, `runs.ts` | `native-tray.ts`, `native.ts` | tray menu |
| Notifications | 241 | `notifications.ts` (policy, actions), `runs.ts` (run finished) | `native-notify.ts` | Settings › Notifications |
| Launch at login | 242 | `login.ts` | `native.ts` (`applyLoginItem`, `startHidden`) | Settings › General |
| Quick capture | 243 | `capture.ts` | `native.ts` (`applyQuickCapture`, `openCapture`) | `renderer/capture.*` |
| vesper:// links | 244 | `deeplink.ts` | `main.ts` (`open-url`, argv), `native.ts` (`handleLink`) | Settings › Files & Links |
| Power | 245 | `power.ts` | `native.ts` (`setupPower`) | Settings › Power & Stack; [desktop-power.md](desktop-power.md) |
| Stack health | 246 | `stack-health.ts` | `native.ts` (`refreshHealth`, `stackCrashed`), `stack.ts` (exit info) | `renderer/offline.*`, `renderer/logs.*` |
| Files in | 247 | `drop.ts`, `services.ts` | `native.ts` (`handleOpenFile`), `main.ts` (`open-file`, file:// drops) | `renderer/send-files.*` |
| Touch ID | 248 | `biometrics.ts` | `native.ts` (`confirmTouchId`) | Settings › Security; web approve hooks |
| Updates | 249 | `updates.ts`, `appstate.ts` | `native.ts` (`checkForUpdates`), `main.ts` (downgrade guard) | Settings › Updates; [desktop-updates.md](desktop-updates.md) |

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

## Security notes

- **vesper:// links** accept only `run/<uuid>`, `ticket/<KEY-n>`,
  `epic/<uuid>`, `page/<uuid>`, `chat/<uuid>`, `inbox` and `capture`. Query
  strings, fragments, credentials, ports, extra segments and encoded
  separators are rejected and logged by reason (never the link). The only
  thing taken from a link is a validated id.
- **Notification actions** call the same endpoints the web app does. Request
  paths are built from validated ids (`decisionRequest`, `replyRequest`), and
  the reply text only goes in the JSON body.
- **Dropped files** never become URLs. Paths are read from disk in the main
  process and uploaded as multipart to `POST /chat-attachments`, where the
  server applies its usual type, size and quota checks. The client check
  (`classifyDroppedFiles`) only saves a doomed upload.
- **Quick Actions** run `open -a <Vesper.app> <files>`, with the app path
  shell-quoted. Selected text goes to a private temp file, not a URL.
- **Touch ID is a local gate.** The desktop asks before the approval request
  is sent; the server never sees or verifies the result. It stops someone at
  an unlocked Mac from approving with a click. It doesn't stop a forged API
  call, another browser, or anything else holding a session. Server-verified
  approvals (passkeys/WebAuthn) are a separate decision. A cancelled or
  failed prompt fails closed; a Mac that can't prompt (no sensor, clamshell,
  nothing enrolled) falls back to the normal click.
- The `vesper:confirm-approval` IPC is only answered for frames on the
  configured server's origin; every other new IPC only for the desktop's own
  `file://` pages.

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
- [ ] **Power**: see [desktop-power.md](desktop-power.md).
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
