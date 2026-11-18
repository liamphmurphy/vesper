# Vesper for Safari

Status: built, not yet verified in Safari (2026-11-18). The design came from the
mockup "Share Safari tab with Vesper"; Liam chose real Safari with a bundled extension
over an in-app browser, so Noir, Wipr, logins and passkeys keep working.

## What it does

From a Vesper button in Safari's toolbar:

- **Share this tab** with a persona (new chat) or a recent chat. You choose whether a
  screenshot goes with the text and whether sharing lasts **until you leave the page** or
  **until you press Stop**. While shared, the icon has an amber dot and the popover shows
  the read log, **Send snapshot now** and **Stop**. The chat shows a banner with its own
  **Stop sharing** (`web/app/(app)/chat/_components/browser-share.tsx`).
- **Ask** about the page or the selection: starts a chat whose first message quotes the
  selection as untrusted content. Right-click a selection for **Ask <default persona> about "…"**.
- **Site actions**: on a GitHub pull request, **Review with Code Reviewer** (when that
  persona exists) and **Make a ticket from this**; on a GitHub issue, **Make a ticket**; on a
  YouTube video, **Take notes on this video**. Each is an Ask with a canned prompt
  (`siteActions` in `lib.js`).
- **Save**: the page or selection to Knowledge (`Clippings/`, a literature note with the
  selection quoted), or the link to the Library reading list. Also on the right-click menu.
- **Never-share list**: built-in sites (`browserext.BuiltinNeverShare`: password managers,
  sign-in, payments) plus the person's own, each covering its subdomains. A never-share
  page can't be shared, asked about or clipped, and a shared tab that goes to one stops.

The persona reads a shared tab with the `browser_snapshot` chat tool. It can only read:
clicking or typing in the tab is deliberately not built (it would need approval cards and
a much closer look at prompt injection).

## What never leaves Safari

- Cookies, storage and logins: the extension sends page text, the URL, the title and
  (optionally) a JPEG of the visible tab, nothing else.
- Form fields, editable regions, hidden elements and scripts (`extractPage` in `lib.js`
  walks only visible text nodes and skips `input`, `textarea`, `select`, `contenteditable`).
- Card numbers (13–19 digits passing Luhn) are replaced in text and selections.
- Private windows, non-web pages, addresses with credentials and never-share sites. The
  extension checks first so the button dims; the server checks again
  (`browserext.CheckURL`) and refuses with 409.

A persona sees page text fenced as untrusted (`browserext.Untrusted`: a fence longer
than any backtick run in the page, with a "don't follow instructions in it" notice),
and its steps read "Reading your shared Safari tab · untrusted page".

## How it's put together

```
Safari ── popup.js ──▶ background.js ──sendNativeMessage──▶ VesperSafari.appex (sandboxed)
                         │ executeScript(extractPage)            SafariBridge: op → one API call
                         │ captureVisibleTab                     Bearer token from connection.json
                         ▼                                              │
                       the tab                                          ▼
                                       vesper app  /api/v1/browser-extension/*  (127.0.0.1)
                                              │ browser_shares, never-share, ask, clip
                                              ▼
                                  chat persona ── browser_snapshot ──▶ latest snapshot
```

- `macos/SafariExtension/Resources/`: the web extension (Manifest V3). `lib.js` holds the
  logic with no browser APIs and is tested under Node (`make -C macos safari-test`).
- `macos/SafariExtension/Bridge/`: `SafariBridge` (the allowlist of operations, request
  building, replies) and `SafariConnectionFile`. A SwiftPM target, so `swift test` covers
  it, and the app uses it to write the connection file.
- `macos/SafariExtension/Handler/`: the extension's principal class.
- `macos/scripts/build-app.sh` compiles Bridge and Handler with `swiftc` into
  `Vesper.app/Contents/PlugIns/VesperSafari.appex` (SwiftPM can't build an app
  extension), copies `Resources/` into it, and signs it with
  `SafariExtension/VesperSafari.entitlements` before signing the app.

### Credential

- The extension's token reaches only `/api/v1/browser-extension/*` (`browserExtensionAuth`).
  Those paths are not person-facing for `signedIn`, so the session cookie isn't accepted
  there either.
- `SystemServices` calls `SafariExtensionLink.refresh` on every sign-in. It
  `POST`s `/api/v1/browser-extension-token` (session-authenticated), which replaces the
  previous token, and writes `{base_url, token}` to
  `~/Library/Application Support/Vesper Safari/connection.json` (folder 0700, file 0600).
- The extension's sandbox may read only that folder
  (`temporary-exception.files.home-relative-path.read-only`), and `SafariBridge` sends the
  token only to an `http` loopback address.
- The token is excluded from `vesper export` (`transfer/schema.go`).

### API

All take `Authorization: Bearer vbx_…` and JSON.

| Route | What |
| --- | --- |
| `GET config` | Personas, the 8 most recent chats, never-share lists (`builtin`, `mine`), active shares |
| `POST shares` | Share a tab: `chat_id` or `persona_id` (new chat), `tab_id`, `until` (`page`/`stop`), `include_screenshot`, and the snapshot (`url`, `title`, `text`, `screenshot` base64 JPEG ≤ 1.5 MB, `incognito`). Ends the tab's and the chat's earlier share. |
| `GET shares/{id}` | A share with its read log (latest 20) |
| `POST shares/{id}/snapshot` | A fresh snapshot. 409 when the share has ended, or ends it (leaving the page, never-share) |
| `POST shares/{id}/stop` | `reason`: `stopped`, `tab_closed`, `left_page`, `never_share` |
| `POST ask` | `persona_id`, `prompt`, `url`, `title`, `selection` → `{chat_id}` |
| `POST clip` | `as` (`note`/`link`), `url`, `title`, `selection` |
| `POST never-share`, `DELETE never-share/{host}` | Edit the person's own list; returns the config |

Prefix `/api/v1/browser-extension/`. Chat side (session): `GET /api/v1/chats/{id}/browser-share`
and `POST /api/v1/chats/{id}/browser-share/stop`. Changes publish `browser_share.updated`.

## Installing it without a paid developer account

Vesper.app is signed with a self-signed identity or ad hoc, which Safari treats as an
**unsigned** extension:

1. Open Vesper once (it registers the extension and writes the connection file).
2. Safari → Settings → Advanced → **Show features for web developers**.
3. Safari → Settings → Developer → **Allow unsigned extensions** (asks for your password).
4. Safari → Settings → Extensions → turn on **Vesper**, and allow it on websites when asked.

Safari turns **Allow unsigned extensions** off every time it quits; the extension stays
installed and comes back when you tick it again. Signing with a free Apple ID's "Apple
Development" certificate may keep it enabled across restarts; reports differ, so it's
worth a try (set `VESPER_CODESIGN_IDENTITY`). Only Developer ID signing plus
notarisation (paid) removes the step for certain.

## Limits and follow-ups

- Snapshots are pushed by the extension (on load, on Send snapshot now), not pulled by the
  persona: `browser_snapshot` returns the last one and its time. A persona can't ask
  Safari for a fresh one.
- The screenshot is of the visible tab only, and only when the shared tab is the one
  showing in its window.
- Acting on the tab (click, type, scroll) is not built.
- Not verified yet: the extension loading in Safari, native messaging size limits with a
  screenshot, `captureVisibleTab` and `OffscreenCanvas` in Safari's background page.
