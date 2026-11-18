# Native bridge protocol fixtures

Example messages for the protocol between the web UI and the macOS shell
(`web/lib/native-shell/protocol.ts`, mirrored in
`macos/Sources/VesperCore/Bridge/Protocol.swift`).

- `page-messages.json`: page → shell messages. Every entry must decode on the Swift side.
- `native-commands.json`: shell → page commands. Every entry must pass `isNativeCommand` on the
  web side and must round-trip through the Swift encoder.

Both test suites read these files. Change the protocol in both places and add an example here
in the same commit.

## Conventions worth knowing

- **One click, one command.** A click on a nav row sends `nav.activate` only (the page navigates when
  the row has an `href`). Only a disclosure triangle sends `nav.toggle` (`itemId` = the row id,
  `expanded` = the new state). The page owns expansion: when a later model changes an item's
  `expanded`, the shell drops its local override, so a page-driven "Collapse all" wins.
- **Sections.** A `collapsible` section's header folds it; the shell sends `nav.toggle` with `itemId`
  = the **section id** and the new `expanded` state (`collapsed` in the model is the inverse).
  `NavSection.badge` is a count or short label drawn as a capsule beside the title (do not put
  counts into titles). `NavAction.disabled` draws the button greyed and sends nothing.
- **Filters.** `NavModel.filters` are pull-downs with check marks in the header row. Choosing an
  option sends `nav.filter {navigatorId, filterId, value, checked}`. For `multiple` filters
  `checked` is the option's new state; for single-choice filters it is always `true` (the page
  unchecks the others).
- **Appearance.** Shell → page `appearance {accent: "#RRGGBB", mode}` is macOS's accent colour and
  effective appearance, sent when the page reports `ready` and whenever either changes; the page
  applies the accent to its macOS palette. Page → shell `appearance {mode}` is the page's effective
  colour mode, sent whenever it changes; the shell sets the window's appearance to match (and
  leaves the window on the system appearance when they agree).
