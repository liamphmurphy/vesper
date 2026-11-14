# Vesper — Design Handoff

Vesper is a lightweight issue tracker for autonomous LLM coding agents: projects, epics, tickets, agent assignments and the context documents (PRDs, specs, ADRs, reports) agents read and write.

This folder is the visual source of truth for the first build. Implement the UI to match it. All names, numbers and people in the mockups are fictional sample data.

```
helm-design/
├── DESIGN.md          ← this spec
├── tokens.css         ← design tokens as CSS custom properties (dark + light)
├── screens/           ← static HTML mockups; open in any browser, they link to each other
│   ├── dashboard.html
│   ├── tickets.html
│   ├── ticket-detail.html
│   ├── epics.html
│   ├── agents.html
│   ├── artifacts.html
│   ├── tickets-light.html   ← light-theme reference
│   ├── inbox.html           ← v0.2 additions start here
│   ├── command-menu.html
│   ├── new-ticket.html
│   ├── dispatch.html
│   ├── agent-config.html
│   ├── run-log.html
│   ├── settings.html
│   ├── states.html          ← empty, loading, error and system states
│   └── foundations.html     ← tokens, type, states, components on one sheet
└── shots/             ← full-page PNGs of each screen at 1440px
```

**How to use the mockups.** The HTML in `screens/` is reference markup with inline styles and hard-coded hex values. Do not copy it into the app verbatim. Rebuild it with real components that read from `tokens.css`. Every hex in the mockups maps to a token below. When the markup and this document disagree, this document wins.

---

## 1. Principles

1. **Color means state, never decoration.** Amber always means a person needs to act (an approval or a review). Red always means blocked. The accent (the mark's violet) is reserved for primary actions, focus and the current selection. Everything else is greyscale.
2. **Agents are rounded squares, people are circles.** Every agent has a fixed identity hue. People are neutral grey circles with initials. Anyone looking at the screen should be able to tell who did the work without reading a name.
3. **Mono for machine values.** Ticket IDs, branch names, model names, counts, durations, spend and permission scopes are set in JetBrains Mono. Prose and labels are set in Inter.
4. **Borders over shadows.** Surfaces are separated by 1px borders a few percent brighter than the ground. Shadows appear only on floating UI (popovers, the bulk-action bar, the command menu).
5. **Calm density.** 13px base type, 44px list rows and 30px controls. Show the minimum by default and reveal more on hover or selection.

---

## 2. Tokens

Everything lives in `tokens.css`. Dark is the default. Set `data-theme="light"` on `<html>` for light, or leave it unset to follow the OS.

### Surfaces and text (dark → light)

| Token | Dark | Light | Use |
|---|---|---|---|
| `--bg` | `#0C0B12` | `#FCFBFE` | App ground |
| `--bg-sidebar` | `#100F18` | `#F4F2F9` | Sidebar |
| `--bg-panel` | `#0E0D15` | `#F9F8FC` | Right-hand detail panels |
| `--surface` | `#15141F` | `#FFFFFF` | Cards |
| `--surface-raised` | `#1B1A27` | `#FFFFFF` | Popovers, floating bars |
| `--surface-sunken` | `#110F19` | `#F6F5FA` | List group headers, nested blocks |
| `--hover` / `--selected` | `#1A1925` / `#201E2C` | `#F0EEF6` / `#ECE8F7` | Interactive states |
| `--border` | `#24222F` | `#E5E2EE` | Card outlines |
| `--border-subtle` | `#1E1C29` | `#ECE9F3` | Dividers inside cards, header rules |
| `--border-row` | `#181722` | `#F1EFF6` | Between list rows |
| `--border-strong` | `#2E2B3B` | `#DEDAEA` | Buttons, chips, inputs |
| `--text` | `#EEEDF3` | `#17151F` | Primary text |
| `--text-2` | `#CBC9D6` | `#3A3747` | Body copy inside content |
| `--text-secondary` | `#A4A1B3` | `#55526A` | Labels, inactive nav |
| `--text-tertiary` | `#8C899C` | `#66637A` | Meta, timestamps. This is the dimmest text allowed (passes 4.5:1 on every surface, `--selected` included). |
| `--accent` | `#9B8CFF` | `#5B4BD6` | Primary buttons, focus, selection |

The light accent is darker than the dark-theme accent so white text on it still passes contrast.

### Color palettes

Mode and palette are independent. See [PALETTES.md](PALETTES.md) for the ten additional presets, custom radial controls, visualization colors, persistence, and export behavior.

### Dusk (v0.4)

The palette is taken from the Vesper mark: a dusk gradient from `--brand-deep` `#2B2366` through `--brand-violet` `#7864D9` to the evening star `--brand-star` `#F2A97E`. Neutrals carry a slight violet tint instead of pure grey, and the accent is the mark's violet lightened for contrast (`#9B8CFF` on `--bg` is about 7:1; `--text-on-accent` `#120F24` on it is about 6.8:1). The brand gradient is for the logo, the welcome glow and persona portraits only. It never fills a control and never stands for a state, so the peach star can't be mistaken for amber.

### Dusk brand layer

The mark's gradient (`--brand-deep` → `--brand-violet` → `--brand-star`) appears only on portraits and decoration, never on a control or as a state's colour, and always beside words that say what's happening (`globals.css`, "The Dusk brand layer"):

* `dusk-aura`: a persona's portrait on the live chat status card while it works. A 2px dusk ring circles it and a violet glow breathes behind it. Off while it waits on you, is quiet or is stopping.
* `dusk-shimmer`: the status line ("Gwen is thinking…") while it works. A band of starlight crosses the words.
* `dusk-tile`: `EmptyState`'s icon tile, lit violet from the top-left with the mark's four-point star on its corner.
* `live-sheen`: a neutral white sheen across a progress bar that's still moving (a ticket run, a run's plan, research). The bar keeps its state colour.

Under reduced motion they hold still: the ring and tile stay, the shimmer becomes plain text, and the sheen goes.

### Workflow states

| State | Token | Dark | Glyph |
|---|---|---|---|
| Backlog | `--state-backlog` | `#6B6B73` | 14px circle, 1.5px **dashed** ring |
| Todo | `--state-todo` | `#A1A1AA` | 14px circle, 1.5px solid ring |
| In progress | `--state-progress` | `#F0BF4C` | Ring and inner pie filled **50%** |
| In review | `--state-review` | `#4EA7FC` | Ring and inner pie filled **75%** |
| Done | `--state-done` | `#4CB782` | Solid filled circle |
| Needs human | `--state-human` | `#F59E5B` | Solid filled circle (used for flags and timeline events) |
| Blocked | `--state-blocked` | `#EF6461` | Solid filled circle |

Status glyph recipe (pie with a gap between ring and fill):

```css
.status { width: 14px; height: 14px; border-radius: 50%; }
.status--progress {
  border: 1.5px solid var(--state-progress);
  background: conic-gradient(var(--state-progress) 0 50%, transparent 0);
  box-shadow: inset 0 0 0 2px var(--bg); /* use the parent surface color */
}
```

### Priority

| Priority | Glyph |
|---|---|
| Urgent | 16px square, radius 4, `--priority-urgent` fill, black "!" at 11px/700 |
| High / Medium / Low | Three vertical bars 3px wide, 6/9/12px tall, 2px gap. Lit bars use `--text-2`; unlit bars use `#34343C` (dark) / `#D4D4DA` (light). High lights 3 bars, Medium 2, Low 1. |
| None | All three bars unlit |

### Pills (tinted status labels)

A pill is the state color at about 12% alpha with a lighter foreground of the same hue. It is used for flags like **Needs approval**, **Blocked**, **PR #482**, **On track**, **Running**.

| Pill | Background | Foreground |
|---|---|---|
| Human / approval / at risk | `--pill-human-bg` | `--pill-human-fg` |
| Blocked / off track | `--pill-blocked-bg` | `--pill-blocked-fg` |
| Review / PR | `--pill-review-bg` | `--pill-review-fg` |
| Done / running / on track | `--pill-done-bg` | `--pill-done-fg` |
| Neutral / queued / idle | `--pill-neutral-bg` | `--pill-neutral-fg` |

Flag shape: radius 5px, padding 1px 7px, 11.5px/500. Status pill shape: full pill, height 24px, with a 6px leading dot.

### Agent identity

Each agent gets one fixed hue. The avatar's foreground is that hue and its background is a ~15% tint of it. Tokens are `--agent-<name>` and `--agent-<name>-bg`. The current roster is Atlas (indigo), Quill (teal), Sentry (rose), Juno (blue), Nova (amber), Relay (green), Pike (orange) and Echo (violet). New agents should pick from the same palette in order.

| Avatar | Size | Radius | Content |
|---|---|---|---|
| Agent, inline / table | 20px | 6px | Initial, 10px/600 |
| Agent, list | 24px | 7px | Initial, 11px/600 |
| Agent, card header | 38px | 10px | Initial, 15px/600 |
| Agent, stacked | 22px | 6px | 2px ring in the surface color, −5px overlap |
| Human | 20–26px | 50% | Two initials, 9–11px/600, `--human-avatar-bg` |
| Unassigned | 20px | 6px | 1.5px dashed `#44444C` border, empty |

### Artifact type tags

These are small uppercase tags: 10px/600, letter-spacing 0.06em, padding 2–3px 6–7px, radius 4px, colored with `--doc-*` / `--doc-*-bg`.

`PRD` indigo · `SPEC` blue · `ADR` amber · `REPORT` green (always agent-generated) · `DESIGN` rose.

### Component tokens (v0.2)

The v0.1 mockups hard-coded a few component colors. They're now tokens with light values, so the app can theme them: `--row-hover`, `--border-hover`, `--border-float`, `--kbd-border`, `--btn-secondary-bg` / `--btn-secondary-border`, `--btn-outline-bg`, `--approve-fg`, `--segment-on`, `--command-on`, `--search-bg`, `--priority-unlit`, `--unassigned` and `--scrim`. The mockups keep their literal hex values, which match the dark tokens.

### Typography

| Style | Spec | Use |
|---|---|---|
| Display | Inter 26/1.2, 600, −0.022em | Page titles ("Good morning, Maya", "Epics") |
| Title | Inter 19/1.3, 600, −0.015em | Featured epic name |
| Card heading | Inter 14, 600 | Section and card headings |
| Body | Inter 13/1.45, 400–500 | Default UI text; row titles are 500 |
| Reading | Inter 14/1.65 | Ticket descriptions and comments |
| Chat | Inter 15/1.6 | Chat messages: replies are read like a page |
| Small | Inter 12–12.5 | Meta, column headers, secondary lines. Chat surfaces and the menu set nothing smaller than 12px. |
| Mono | JetBrains Mono 11–12.5 | IDs, branches, models, numbers |
| Metric | Inter 28, 600, −0.02em | KPI tiles |

**Scale.** Every font size in the web app is one of 13 steps, as Tailwind utilities named by their px at the default Text size: `text-10` (glyph badges, micro tags), `text-11`, `text-12` (small, meta), `text-13` (body), `text-14` (reading), `text-15` (chat), `text-16`, `text-18`, `text-20`, `text-22`, `text-26` (display), `text-28` (metric), `text-32`. Tailwind's own sizes (`text-xs`…) and arbitrary sizes (`text-[12.5px]`) are not allowed; `lib/ui-conventions.test.mjs` fails on them. The steps set no line-height. In CSS, write `calc(Npx * var(--type-scale))`.

**Text size.** Settings → Appearance → Text size (Small 0.92×, Default, Large 1.12×, Larger 1.25×) sets `data-text-size` on `<html>` before first paint, which sets `--type-scale`. The scale steps and the `type-*` shorthands (restated in `globals.css`) multiply by it; spacing and control heights don't, so check new fixed-height UI at Larger.

Apply `font-feature-settings: "cv11","ss01","ss03"` to Inter globally. Inline code: mono 12px, padding 1px 5px, radius 4px, `--selected` background, `--border-strong` border.

### Spacing, radius, sizing

* 4px base grid. Common gaps are 6, 8, 10, 12, 14, 16, 20, 24 and 28.
* Radii: tags 4px, nav/small buttons 6px, buttons and inputs 7px, inner cards 10px, cards 12px, featured cards 14px.
* Controls: buttons 30px tall, filter chips and segmented items 26px, list rows 44px, group headers 38px, top bar 52px, sidebar 232px.
* Content max width is 1180px (dashboard, epics, agents). Ticket descriptions max out at 780px.
* Safe areas: the viewport uses `viewport-fit=cover`, so on phones the page draws under the notch and home indicator. Anything fixed to a screen edge (tab bar, sheets, pinned action bars) pads itself with the safe-area utilities in `globals.css`: `pt-safe`, `pb-safe`, `pl-safe`, `pr-safe`, `px-safe`, `py-safe` and `p-safe`, each set to `env(safe-area-inset-*)`. Add them alongside the bar's own padding, e.g. a wrapper with `pb-safe` around a 52px bar, rather than folding them into its height. The insets are 0 on desktop, so nothing moves there.
* Theme color: `<meta name="theme-color">` is the `--bg` token per scheme (`#0C0B12` dark, `#FCFBFE` light), set from the `viewport` export in `app/layout.tsx`.

---

## 3. App shell

```
┌──────────────────┬────────────────────────────────────┬──────────────┐
│ Column (248px)   │ Pane bar (44px): ‹ › crumb ·· acts │ Companion    │
│ fixed top        ├────────────────────────────────────┤ (dock, 360px │
│ the area's list  │ [optional view/filter bar]         │ or 44px rail)│
│ fixed foot       │ Content (max 1180, padding 32/28)  │ facts · Chat │
└──────────────────┴────────────────────────────────────┴──────────────┘
```

The shell is one left column, the same on every screen, then the main pane with the open item, then
the companion: one right-hand panel beside every page, with the page's facts and a chat with your
persona.

**Column** (`components/shell/sidebar.tsx`, 248px, `NAVIGATOR_WIDTH` in `lib/navigator.ts`,
`--bg-sidebar`, shown at `COMPACT` and wider). Its top never changes: the mark and "Vesper", the
Search field (⌘K), the Needs you pill (`--pill-human` while anything waits, with its count), and the
areas as an icon row spread across the full width (Chat, Runs with a live dot, Tickets, Knowledge with a suggestions dot)
ending in the Apps flyout, which holds the other apps and the tools (Reports among them) and reads as
current on any of them. Its foot never changes either: the harness characters in a row, each opening
its usage bubble above it, then Customization and Settings.

**The area's list.** Between top and foot sits one list. By default it is Chats (title, an accent +
for New chat, the persona filter chip, the history, spaces, setup progress); personas and spaces
appear here and nowhere else in navigation. A screen with a list of its own puts it there instead with
`NavigatorPortal` (`components/shell/navigator-slot.tsx`): Runs its run list, Knowledge its explorer,
an app editor its structure (the way back to Knowledge, the item's name, then pages and
layers), Learn its lessons, the wiki its tree. Each list's title row ends with its own +. Two lists
never stack, and nothing draws a second column.

**Collapsed strip.** Clicking the mark folds the column to a 52px strip of the same fixed items
(mark, Search, Needs you, the areas stacked, the harness characters stacked with bubbles to the
right, Customization, Settings) and no list. It is one preference for the whole app
(`lazyagents.column-collapsed`), not per screen; the column starts expanded. ⌘\ stays the dock's
toggle. Reading focus (⌘.) hides the column without touching the preference.

**Back and forward** (`HistoryNav`, Go back and Go forward, disabled at either end where the browser
has the Navigation API) lead the page content: they are the first thing in the content's top bar,
whatever that bar is (a `TopBar` breadcrumb, the chat header, an editor header, Knowledge's tabs, the
welcome screen's bar). Never in the column, and exactly once per screen
(`e2e/history-everywhere.spec.ts` sweeps every route for it).

**The companion.** The shell's right-hand column (`components/shell/companion.tsx`, `lib/companion.ts`)
holds one panel beside every page on wide screens, filled like the left column's middle: a page with a
panel of its own renders its `Dock` into the column through `CompanionPortal` (an editor's tabs,
Knowledge's, a run's Context and Chat, a ticket's Properties and Chat, an epic's Context and Chat);
any other page gets the default companion, the work chat, folded to its 44px rail until opened. It is
always 360px wide (wider for a document or a review), sticky to the viewport, and below `xl` floats
over the page from the right edge. One open state is shared by every dock
(`lazyagents.companion-open`) and changes only when you open or fold one (`actOnDock`), so the panel
stays as you left it from page to page; each dock keeps its own tab. Knowledge is the exception that
starts each new browser tab folded. The chat page claims the column (`useClaimCompanion`): the
conversation is the page, and its own dock beside it holds its canvases, activity and linked items.
A document's chat is its own (a design's, a deck's, a doc's): canvases belong to the chat that made
them, so the companion shows the item's chat where the item has one, and the work chat elsewhere.

**Who you're talking to.** The main pane's composer talks to what the pane shows (a run's composer
to its agent: "To Builder · WEB-9"); the companion's Chat always talks to your persona. The work chat
(`components/domain/work-chat.tsx`) is one list shared by every page, so the conversation follows
you; each message carries the run or ticket in view after `<!-- vesper:work-context -->`, as
Knowledge's carries the page after its own marker; beside a page with neither, only what's pinned.
A Pin on the Viewing chip keeps an item attached as you move between runs and tickets: messages
then name both ("Pinned …", "Viewing …"), until it is unpinned. Dock composers lead with a
"To <persona>" chip, then what the message carries (`DockContext`). The person's bubble shows only
what they typed. On phones the run's header and the ticket's action bar open the same work chat in
a full-height sheet.

**Personas** are who you're talking to, never where you are. A persona shows in a conversation (the
header's persona control and the composer's "To" chip) and as attribution (who wrote, suggested or
asked for something: a reply's identity, a suggestion's author, a Needs you item), and filters lists
of conversations or their output with one chip (`PersonaFilter` on Chats: All personas by default,
a menu with each persona's chat count and what it is doing, ✕ to clear, and "New chat with …" while
filtered). Never on the area row, the column's fixed top, an app's list or the collapsed strip. A
dock's new chat (the work chat, Knowledge's) starts with the persona last used there
(`useDockPersona`), and its empty state names that persona.

**Linked items.** Under the main chat's header, a Linked row lists what the conversation links to:
the tickets and pages its messages carried, then its runs. Each opens read-only in the chat page's
dock (`?item=ticket:KEY|run:ID|page:ID`, like a thread), with an Open link to the full page; the sent
chips under messages open the same way.

**Chat headers.** The chat header names the persona as a control ("Persona: Atlas ▾"): before the
first message it switches the persona, afterwards it starts a new chat with another. While the live
status card is on screen the header's live line is only its dot. A docked chat (an app's dock, a run
or ticket side panel) has one header row: the persona as avatar ▾, the title, an Activity toggle and
the host's actions (Designs' "Suggests ▾"); its repository picker moves to the composer's + menu.

**Docks continue the top bar.** An app's dock (`Dock` in `components/shell/editor-layout.tsx`:
Designs, Docs, Slides, Finance, Knowledge) is a full-height column beside the page's 44px top bar,
and its own first row, the same height, continues it. That row is the active tab's header: for Chat,
the chat's header itself (`useDockHeaderSlot`, so the conversation renders it there rather than
under another row); for other tabs, the tab's name. The tabs show as icons in that row only when
there is more than one (Designs: Chat, Design, Review), then ⇥. Nothing stacks between the row and
the messages: the docked header doesn't name the app around it, what waits on the document sits
on the editor's bar (Designs' "Review N" pill beside the save state), and a deck in chat is a
one-line card that opens the deck, never a second copy of it beside it.

**Decks and designs are Knowledge pages.** Knowledge is the one document store (LAZYAGENTS-212):
every deck and design has a private page (`Slides/<title>`, `Designs/<title>` until moved), made with
it, in the explorer with its own icon and in Knowledge's tabs. The page links to the canvas, which
stays the body, so versions, review and the persona's canvas and design tools are unchanged. Opening
one shows its editor inside Knowledge: its controls join Knowledge's one bar beside the tabs
(`EditorEmbedContext`), its structure replaces the explorer in the left column under "‹ Knowledge",
and its dock is the companion. Knowledge's New page (+) offers a Document, a Deck (blank or a
starter) or a Design (by starter); there is no Slides or Designs index. Old `/apps/slides/<id>` and
`/apps/designs/<id>` links find the page and open it there, keeping their query. Renaming either side
renames the other; deleting the page deletes the deck or design.

**Recent.** ⌘K's Recent list holds what you opened as well as what you picked there: chats with
messages, runs, tickets, Knowledge pages and designs (`useRecordVisit`), six at most.

**Harness characters on phones.** A row of them sits at the foot of the chat history drawer and in a
Harnesses section on More; each opens its usage bubble above it.

**Live activity in a dock.** A conversation marked `docked` starts its live card folded: the scene,
status, progress segments and the step under way ("Fix the snapshot · 2 of 3"); Show steps opens the
full list. The main chat starts it open.

**Pane bar** (`TopBar`, 44px): back and forward, then the breadcrumb (or a pane's tabs, as
Knowledge's open pages, sitting on the bar's bottom rule) (tertiary separators, current item in `--text` 500), with actions on the right, secondary buttons first and the primary button last. A screen with a `PageHeader` keeps its `TopBar` above it, so its back and forward come from there.

**Responsive:** at `COMPACT` (768px, `lib/viewport.ts`) and wider, the shell is a wrapping flex row with the column beside the content.

*Compact shell (below 768px).* The content runs full width, with no sidebar or icon rail. A bottom tab bar (`components/shell/tab-bar.tsx`, rules in `lib/tab-bar.ts`) is fixed to the bottom edge on `--sidebar`, above a `--border-subtle` top rule. Its tabs are Chat, Inbox, Runs, Tickets and More. Each tab is at least 44px tall: an 18px icon in a 48×28 pill, with an 11px label under it. The current tab's pill fills with `--selected` and its label turns `--text`. Inactive tabs are `--text-tertiary`. Inbox shows the unread count as an amber (`--state-human`) badge, and Runs shows a green (`--state-done`) dot while runs are live. Both read `useNavCounts()`, as the sidebar does, and the counts reach screen readers through the link name ("Inbox 3 unread"). The bar is 56px tall plus the bottom safe-area inset (`pb-safe`), and it publishes that height as `--tab-bar-h`, which is 0 when there is no bar. The shell pads its content by `--tab-bar-h`. Screens sized to the viewport use `h-app` (100dvh less the bar) instead of `h-dvh`, and the activity orb stays above the bar. Detail screens (a run, a ticket, the ticket composer) hide the bar and take the whole screen. Pages the bar has no tab for (apps, tools, Customization, Settings) are listed under More (`/more`), and More stays current while one of them is open. More is built from `NAV_GROUPS` (`moreSections()` in `lib/tab-bar.ts`) and `useNavCounts()`, so it can't drift from the sidebar. From the top it has a search field, your profile row with Customization and Settings buttons (Settings gets an amber dot when a setting runs need is missing), the Apps as a three-column grid of tiles, the Tools as a list that keeps the sidebar's badges, and Spaces. Every row is at least 44px tall. The search field opens the command menu, which fills the screen below `COMPACT`: it has no radius or border and is padded for the safe areas. Its input is 16px, its results are at least 44px tall, the close button is 44px, and the keyboard hints are hidden.

*Compact Inbox.* Below `COMPACT` the Inbox (`app/(app)/inbox/compact-inbox.tsx`) is a list of cards: agent square and name, ticket key, age, a kind pill, title and a two-line summary, under sideways-scrolling filter chips (All, Approvals, Questions, Blocked, Mockups). Approval cards carry Deny and Approve (amber), question cards an inline reply field (16px text), blocked cards Open run. Tapping an approval card opens a bottom sheet with the action, risk summary and a monospace preview that scrolls sideways and opens full screen when long, with Deny and Approve pinned to its bottom edge. Touch targets are 44px, written in px (`h-[44px]`): the root font is 13px, so `h-11` is only 35.75px. There is no swipe-to-approve: approvals are consequential and a swipe is easy to make by accident.

*Compact chat.* The chat header (`compact-chat-header.tsx`) has four parts, each control a 44px square: ≡ (history), the title in 15px semibold over a 12px tertiary line naming the persona and the repository, a panels button (an accent dot while a design, canvas or playground is open), and ··· (Chat menu). The menu holds what the desktop header and tabs hold: Activity, Repository, Default project, Rename, and Archive (Restore if the chat is archived). Its rows are at least 44px tall. ≡ opens the history drawer (`history-drawer.tsx`), a modal panel on `--sidebar` that slides in from the left, up to 320px wide (85vw at most), over a scrim. It holds New chat, Search chats, the persona row, spaces and recent chats, all from the sidebar's components. Row actions show without hover. Opening a chat or link closes the drawer, and so do a scrim tap, Escape and a swipe to the left. Focus returns to ≡.

*Tickets header.* On wide screens every Tickets layout (List, Board, Epics) has one bar, `TicketsTopBar`: back and forward, the project as a pill in the breadcrumb (the project switcher itself), then "Tickets" and any saved view; New ticket and the List / Board / Epics switch on the right. The same bar on all three, so switching layouts doesn't move the header. The board's filters sit at the end of its Board / Map row.

*Compact Tickets.* The Tickets layouts drop their top bar. The layout bar becomes the header: a "Tickets" title, the project picker and a + button, then a full-width List / Board / Epics switch. Filters sit on one line that scrolls sideways (`ChipScroller`, never wrapping), with chips 32px tall. The list is grouped (by status by default: In Progress, Todo, Backlog…) under sticky group headers. Its 64px rows open the ticket from anywhere in the row and show the status glyph, the title over key · priority · points, and the agent's square. There's no row checkbox or bulk bar. The board shows one status column per screen: columns snap sideways, and a status pager above them (pills with counts) follows the swipe and jumps to a column. Ticket detail is one column under a back bar: key, title, then a meta strip of 36px chips (status, agent, priority, epic). Each chip opens its picker as a bottom sheet (`components/ui/sheet.tsx`: slides up over the scrim, 48px options, current one checked). Then come criteria, description, activity, and the wide layout's side panel. Comment (which opens the composer in a sheet) and Start run (dispatch) are pinned to the bottom edge above the safe area. Touch sizes are in px, because the root font is 13px and rem-based sizes come out smaller than they look.

*Compact composer.* Below `COMPACT` the composer is the message field over one row: +, the model chip, Stop and Send. + opens a bottom sheet (`composer-sheet.tsx`) with one 56px row per `composerOptions` entry, in the same order, showing the label over its current value. The desktop control's trigger is stretched over the row, so a tap anywhere opens the same picker. The sheet has a grabber (swipe down to close), closes on Escape and a scrim tap, and pads for the bottom safe area. On touch screens (`pointer: coarse`) the message field is 16px, so iOS doesn't zoom in on focus, and the keyboard-hint line under the composer is hidden. Hover-revealed row actions (`lib/reveal.ts`) are always shown when the screen can't hover.

*Live-run strip.* The compact shell has no activity orb. Instead a 44px strip above the chat composer (`components/shell/live-run-strip.tsx`) names the newest live run: a green dot (amber while it waits on a person), the agent, the ticket key and "step N of M". It opens that run, and "+N more" opens Runs. With no live run, nothing is shown.

*Compact chat panels.* The chat's side panels (design, canvas, playground) open as one full-height sheet over the chat (`chat-panel-host.tsx`). Its top has a grabber, a switch between the open panels, and a 44px close button. Panels stay mounted, so switching doesn't reload a playground. A bottom bar holds Comments for a canvas and an amber "Review N suggestions" for a design. A drag down, close or Escape returns to the chat, and the header's panels button brings the sheet back.

*Compact Runs.* `/runs` shows live runs as cards: agent, title, ticket key, elapsed time, Running or an amber Needs you, the current step and a progress bar. Below them is a card of the runs finished today. Run detail hides the tab bar. It has a header with back, the title and a ··· menu, then a strip of plan steps and the log at full screen, with any approval inline in the log. A reply composer (16px) is pinned to the bottom edge and posts a ticket comment.

Tables and the ticket list sit in `overflow-x: auto` containers with a min-width (620–920px). Multi-column grids use `repeat(auto-fit/auto-fill, minmax(…))`.

---

**Index screen header.** Every index screen (Learn, Library, Reports, Scheduled, Workflows, Settings and its sub-screens, Setup, Wiki) opens with `PageHeader` from `components/ui/page-header.tsx`: `type-display` title, a 14px secondary description at most 720px wide, primary actions on the right, and an optional row of tabs, switches and pickers under it. Detail screens (a ticket, run, epic, agent or page) and the dense work toolbars (Runs, Tickets) keep their own headers.

**Empty states.** A screen or section with nothing in it uses `EmptyState` (`compact` in trays, cards and panel sections): icon, heading, one line on how things get here, and the action that adds the first one. A one-line hint inside a side panel ("No headings yet.") stays plain tertiary text.

**Visual regression.** `web/e2e/visual.spec.ts` snapshots the shell's key screens (chat, a chat with personas, runs and a run, the Tickets layouts and a ticket, Settings, Library, Knowledge, a deck open in Knowledge) in Dusk light and Gruvbox dark, with a fixed clock, reduced motion, relative times masked and at most 100 pixels of difference. A layout change updates them on purpose (`--update-snapshots`), and the diff in review shows what moved.

## 4. Components

**Buttons (30px, radius 7, 13px)**
* Primary: `--accent` background, `--text-on-accent`, 600 weight, optional 13px "+" icon. Keyboard hint (e.g. `C`) in mono at 60% opacity.
* Secondary: `--surface-raised`-ish fill (`#1E1E24`), `#3A3A44` border, `--text`, 500 weight.
* Outline: transparent background, `--border-strong` border, `--text-2`.
* Ghost / icon: no border, 28–30px square, hover fills with `--hover`. Icon-only buttons need an `aria-label`.
* Approve (human action): `--state-human` fill with near-black text. Use it only on approval surfaces.

**Segmented control:** a 2px-padded container with a `--border` outline on `--surface`. The selected segment fills with `#1F1F25`, text 500.

**Filter chip:** 26px, a 1px `--border-strong` outline split into two cells, a tertiary label on the left ("Status") and a value on the right ("is not Done"). "+ Filter" uses a dashed outline.

**Label chip:** 22px full pill, `--border-strong` outline, 6px colored dot, 11.5px secondary text.

**Card:** `--surface`, 1px `--border`, radius 12. The header row (padding 14/18) holds a 14px/600 title and a secondary link on the right, divided from the body by `--border-subtle`. On hover, list rows inside cards fill with `#131317`.

**KPI tile:** label 12.5 secondary, value at Metric style with a context line beside or under it, and an optional micro-visual (dot row, stacked bar, 7-day mini bars where the last bar is accent).

**Progress bar:** 3–4px track (`--track`), radius 2, fill in the owning project or state color. The stacked variant is 6–8px tall with 2px gaps and segments ordered done → review → progress → todo/backlog.

**Ticket list row (44px):** `[checkbox, appears on hover/selected] [priority 16] [ID mono 64px] [status 14] [title 500, ellipsis] [inline flag pill] … [labels] [epic 120px] [agent 108px] [date 52px right-aligned]`. Group headers are 38px on `--surface-sunken` with the status glyph, name, mono count and a "+" button. Selected rows get an accent tint of about 8% and a filled accent checkbox.

**Bulk-action bar (floating):** centered at the bottom, max 640px, `--surface-raised`, radius 12, `--shadow-float`. It holds "N selected", then ghost actions (Status, Priority, Attach artifact), a secondary **Assign agent** button and a close button.

**Agent picker popover:** 300px, `--surface-raised`, radius 12, shadow. A search row at the top, then options at 40px each: agent avatar, name, a "model · specialty" second line, and availability on the right (Available green / Busy amber / "N queued" grey).

**Approval banner:** border `--state-human` at 25% alpha, fill at 6%, radius 12. It contains the agent avatar, a title in `--pill-human-fg` ("Atlas is waiting for your approval") and a one-line description of the exact action, with mono code for identifiers. Actions are Deny, View plan, then **Approve & continue**.

**Activity timeline:** a 1px vertical rule at x=11. Events are an avatar (circle for people, square for agents) plus a single sentence with bold actor and object names and a tertiary timestamp. Rich events (plan, test result, comment thread) render a nested card under the sentence. The plan card lists numbered steps with state glyphs, done, current (human-amber half pie) or pending. Comment threads show replies in a `--surface-sunken` footer.

**Property list (detail panels):** rows of at least 34px with an 88px tertiary key and a value with a leading glyph. The whole row is the hit target (hover `--hover`, radius 7).

**Doc card:** `--surface`, radius 10, padding 12. Type tag and version in the first row, title 500, then a provenance line ("Read by Atlas" tertiary, or "Generated by Atlas" in report green).

### Added in v0.2

**Dialog:** a `--surface-raised` panel, 1px `#2A2A31` border, radius 14, `--shadow-float`, over a `rgba(5,5,7,0.62)` scrim that covers the whole shell. Top-aligned at about 8–12vh. Widths are 640 (command menu) or 720 (composer, dispatch). A dialog footer sits on `--surface-sunken` behind a `--track` rule, with a tertiary note on the left and actions on the right (ghost → outline/secondary → primary or approve).

**Form controls:** the field label is 12.5/500 `--text-2` above the control, with an optional 12px tertiary hint below. Text inputs and selects are 30px, radius 7, `--border-strong` on `--surface`. Mono inputs (handles, durations, keys) use JetBrains Mono 12.5. A prefix such as `@` sits inside the input in tertiary. Textareas follow the same rules. Instructions and config use mono on `--surface-sunken`.

**Toggle:** 28×16 track, radius 8, accent when on and `#2A2A31` when off. The 12px knob is near-black when on and `--text-secondary` when off. Label sits on the right, 12.5 secondary. Use `role="switch"`.

**Segmented control (small):** the existing segmented control at 24px, used inline in tables (for example, permission mode: Allowed / Approval / Denied).

**Property chip:** 26px, radius 6, `--border-strong` outline, glyph plus value, 12px `--text-2`. This is the compact form of a property row, used in composers.

**Enforcement chip:** a mono chip that says how a scope is enforced. `credential` and `brokered` use the filled chip (`--selected` fill). `harness` uses the outlined chip because it's weaker. Always show these next to the scope mode, never instead of it.

**Scope mode:** a 8px state dot plus a label. Allowed uses the done dot and `--text-2`. Requires approval uses the human dot and `--pill-human-fg`. Denied uses the blocked dot and `--pill-blocked-fg`.

**Human-action banner:** the approval banner pattern, reused for anything waiting on a person: dispatch ("Pike is assigned and waiting for dispatch"), approvals, and the "Managed runs are off" system banner. Amber means a person can act. The red variant (`--state-blocked` at 25% border and 6% fill) means something is broken (runner offline, load error).

**Inbox row (60px):** unread dot (7px accent) → 24px avatar → a first line with kind flag, mono ID and title (600 when unread, 500 when read) → a second line, 12.5 tertiary sentence → time on the right. Grouped under 34px sunken headers: Needs you, Waiting on others, Earlier.

**Command item (38px):** a 44px lead column (status glyph, doc tag or icon), title with the query match underlined in accent, tertiary meta, and trailing flags, avatars or keycaps. The selected item fills `#1F1F26`.

**Run event row:** a grid of 64px mono time | 72px mono type | content. Types are `lifecycle`, `message`, `tool` and `usage`. Tool calls render as a nested card: a mono tool name and args header with duration and result glyph, and optional output in a sunken mono block. A 2px left rail marks events that matter: `--state-human` for approval and wait, `--state-blocked` for denied or failed.

**Turn item:** a state glyph, "Turn n", time, the trigger sentence ("Resumed: Maya Chen asked for a benchmark") and a mono stats line. The current turn gets the accent selection tint. A dashed amber block under the list explains what the run is waiting for.

**Skeleton:** `--track` bars, radius 4, a 1.6s opacity pulse that is turned off under `prefers-reduced-motion`. Skeletons keep the real layout: 44px rows, the same card grid. Containers get `aria-busy="true"`.

**Empty state:** centered in its container. A 40px icon tile (radius 10, `--selected`, `--border-strong`), a 14/600 heading, a 13px secondary body at most 360px wide, then up to two buttons. The copy says what will appear here and the next step.

**Toast:** a floating `--surface-raised` pill with radius 10 and `--shadow-float`, centered at the bottom. Use it only for transient system status ("Live updates paused. Reconnecting…").

---

## 5. Screens

### Dashboard (`dashboard.html`)
The answer to "what needs me, and is everything moving?"
* Greeting and summary line, with a 24h / 7d / 30d range control.
* Four KPI tiles: active agents (dot per seat, colored by state), in progress (with a progress/review split bar), awaiting review (count of items older than a day in amber), and completed this week (mini bars plus median cycle time).
* Left column, 2/3 width:
  * **Needs your attention:** approvals, blocked tickets, PRs ready, spec conflicts. Each row has an agent avatar, ID, a kind pill, the title, "agent · time", and two inline actions.
  * **Projects** table: progress bar plus percentage, open count, stacked agent avatars, updated time.
* Right column, 1/3 width:
  * **Live agents:** status, current ticket and task, step progress.
  * **Ticket flow:** a stacked bar with a legend.
  * **Recent artifacts.**

### Tickets (`tickets.html`, light: `tickets-light.html`)
A list in the style of Linear, grouped by status: In Progress → In Review → Todo → Backlog.
* View tabs: All, Active, Backlog, Agent-owned, Needs human. Filter chips sit on the right.
* Rows follow the ticket-row spec above. Inline flags: *Needs approval* (amber), *PR #482* (blue), *Queued* (neutral).
* The mockup shows two rows selected, the floating bulk bar, and the **Assign to agent** popover open.

### Ticket detail (`ticket-detail.html`)
* The main column (max 780) holds, in order:
  * the approval banner, when one is pending;
  * the title (Display) and description (Reading style);
  * acceptance criteria as real checkboxes, with completed items struck through in tertiary;
  * **Context artifacts**, a grid of doc cards with an Attach button;
  * **Activity**, the timeline;
  * a comment composer: a textarea, attach/mention icons, the hint "Comments mentioning @atlas resume the run", and a Comment button.
* The right panel (~300px, `--bg-panel`) holds:
  * the property list: Status, Priority, Agent, Reviewer, Epic with percentage, Project, Estimate, Due, Labels;
  * an agent run card: run time, tool calls, tokens, spend, permission scopes (scopes that need approval are amber), and View run log / Pause agent;
  * a Code section with the branch and the PR with a +/− diff count.
* The top bar has the breadcrumb Project / Epic / ID, a "1 / 15" pager with up/down arrows, a copy-link button and a more menu.

### Epics (`epics.html`)
* **Featured epic** card: icon tile, name (Title style), health pill, project and target date, one-line objective, stacked progress bar with "12 of 19 tickets done". On the right is a meta grid (agents, owner, source PRD link, agent hours). Below it is a compact ticket list with a "View all" link.
* **Q4 timeline:** month columns with epic bars positioned by start and end dates, tinted by project color, and a 1px accent "today" line.
* **All active epics:** a card grid. Each card shows the project, health pill, name, description, progress with percentage, stacked agent avatars and the due date.
* Health values: On track (green), At risk (amber), Off track (red).

### Agents (`agents.html`)
* Status filter pills with counts: All, Running, Waiting, Blocked, Idle.
* Agent cards (auto-fill, min 320px) contain:
  * a 38px avatar, the name, the role line, and a status pill;
  * when active, the current assignment block: ticket ID, "step n/m", task sentence, progress in the status color;
  * when idle, a dashed block with a status sentence and an accent **Assign** link;
  * stats: Done 7d, Merged %, Cycle time, Spend;
  * a footer with the model chip, tool and permission chips (mono, outlined) and the queue length.

### Artifacts (`artifacts.html`)
* Search input, type tabs with counts (All, PRDs, Specs, ADRs, Agent reports, Designs) and a dashed drop zone ("Drop PRDs, specs or ADRs here").
* Table columns: type tag plus name with a meta line, author (person circle or agent square), project, linked ticket count, updated. The selected row gets an accent tint.
* The preview panel (~340px) shows:
  * an abstract page thumbnail, the title, a summary and a meta grid;
  * an **Outline** with how often agents cited each section;
  * **Read by** agent chips;
  * New version / **Generate tickets** buttons.

### Foundations (`foundations.html`)
A one-page reference for every token and component above. Use it when checking a token or component visually.

### Inbox (`inbox.html`)
Everything waiting on a person, newest first.
* Tabs with counts: All, Approvals, Dispatch, Mentions, Reviews, Blocked. A Project filter chip sits on the right.
* Groups: **Needs you** (approvals, tickets ready to dispatch, mentions, blocked runs), **Waiting on others** (PRs you review), **Earlier** (read or resolved).
* The right panel (~380px) shows the selected item. For an approval that means:
  * the agent and the request as a sentence ("Atlas wants to run `db:migrate`");
  * the exact action as a mono key/value block;
  * the agent's risk summary with the evidence artifact;
  * enforcement, plan step and run cost so far;
  * an optional note that is added to the resumed turn;
  * Deny / Open ticket / **Approve & continue**.
* Keyboard: `A` approve, `D` deny, `J`/`K` move between items.

### Command menu (`command-menu.html`)
* `⌘K` opens a 640px dialog over the current page.
* The query input has a scope chip (the current project; `tab` toggles it) and `esc`.
* Results are grouped Tickets → Artifacts → Epics → Actions, with matches underlined.
* Actions include create with the query as title, dispatch ready tickets, and full-text search of artifacts.
* The footer shows keyboard hints. `>` limits results to commands.

### New ticket (`new-ticket.html`)
* `C` or the sidebar "+" opens a 720px composer.
* The header holds the project picker. Then:
  * the title (Title style) and description (Reading style, inline code allowed);
  * an editable acceptance-criteria list (drag handle, disabled checkbox because agents tick these, remove);
  * attached artifacts as compact doc chips;
  * a row of property chips: status, priority, epic, agent, reviewer, labels, estimate, due.
* The footer has a "Create more" toggle and a lock note: assigning doesn't start the agent.
* Actions: **Create & dispatch…** (secondary, opens the dispatch dialog) and **Create ticket** (primary, `⌘↵`).

### Dispatch (`dispatch.html`)
A person must dispatch every ticket before its agent runs.
* **On the ticket:** a human-action banner ("Pike is assigned and waiting for dispatch") with Reassign and **Review & dispatch…**. The Agent property shows a *Not dispatched* pill.
* **The dispatch dialog** shows exactly what the run will get:
  * definition and override versions;
  * harness and model chips;
  * repo, base branch and the branch to be created;
  * setup commands;
  * context artifacts and where they'll be delivered;
  * a scope table (scope, mode, enforced by, plain-language meaning);
  * the secrets injected or withheld;
  * run guards;
  * when it starts (runner slots).
* Values that come from a project override carry a small outlined `project` marker.
* Footer: Cancel, Edit agent, **Approve & dispatch** (the approve button, because this is an approval surface). The same dialog handles bulk dispatch, with the ticket list summarized at the top.

### Agent configuration (`agent-config.html`)
* A hero with the agent's 38px avatar, name, status pill, role and current definition version.
* Tabs: Overview, **Definition**, Project overrides, Runs, Tokens.
* The main column is a stack of cards:
  * **Identity:** name, handle, role, color from the fixed palette.
  * **Runtime:**
    * harness segmented control (Claude Code / Codex), with a sunken capability list showing what Vesper can enforce on that harness;
    * model, concurrent runs, optional run guards.
  * **Instructions:** mono markdown, written to `AGENTS.md`.
  * **Permissions:** for each scope, a small segmented mode, an enforcement chip and a "how" line, with a legend footer.
  * **MCP servers:** `lazyagents` is locked and always on.
  * **Harness options:** key/values for a single harness.
* The right panel (~340px) has three sections:
  * **Project overrides:** a list showing each override's changes.
  * **Resolved for [project]:** the merged definition, with override-sourced values marked `project`.
  * **Versions:** the change history.
* The top bar shows an amber "Unsaved changes" note, Discard, and **Save as v8** (`⌘S`). Saving creates a new immutable version.

### Run log (`run-log.html`)
Opened from "View run log" on the ticket's agent run card.
* **Summary strip:** run number, state pill, mode, start time, then harness, model, session, run time, tool calls, tokens and spend as mono stats.
* **Left rail:** the run's turns (each one a resume of the same harness session) with their triggers. When the run is waiting, a dashed amber block says what it's waiting for and links to the request.
* **Event stream:**
  * tabs (All, Messages, Tool calls, Errors), a filter input and a Follow toggle;
  * normalized events as run event rows;
  * calls blocked by the harness appear as a red-railed tool card with a *denied by harness* flag.
* Top bar: Raw log (download), Pause, Cancel run (outline with red text).

### Settings (`settings.html`)
* A secondary 220px settings nav: Workspace (General, Members), Work (Projects & repos, Runner, **Connections & secrets**).
* **Connections & secrets** has three cards:
  * **Harnesses:** API keys by harness, with masked values and usage counts.
  * **GitHub:**
    * the personal access token row, with identity and expiry;
    * PR sync stats;
    * a sunken note about the shared-identity limitation.
  * **Secrets:** a table of name, scope granted with its enforcement chip, what it applies to (project or workspace), agents using it, and when it was updated. Values are never shown after saving.

### States (`states.html`)
A reference sheet for:
* empty project, inbox zero, no results, no agents;
* list and card skeletons;
* inline load error;
* system banners ("Managed runs are off", "Runner offline");
* the reconnecting toast.

Every screen uses these patterns rather than a blank page or a spinner. In code (`components/ui/loading.tsx`): a section or value that's loading is a skeleton shaped like it (`Skeleton`, `LoadingLines`, `LoadingText`), and `Spinner` is only for a button or an inline step that's working. Skeletons stay hidden for their first 150ms so a fast load shows nothing but the content. "Loading…" never appears on screen; it's the screen-reader label. `lib/ui-conventions.test.mjs` enforces both.

---

### Wiki (built in Phase 4.5, no mockup; extends the system above)
* **Layout:** top bar (Wiki / folder / page), a page tree (~240px, `--bg-sidebar`), the page at reading width, and the usual right panel (~340px, `--bg-panel`).
* **Tree:** "Pages" by folder, then "Agent memory" with one folder per agent (`agents/<handle>/`). Pages with pending suggestions show an amber mono count; so does the Wiki nav item.
* **Page:** folder line (tertiary), title (`type-display`), "author · vN · time" meta. A leading `# Title` that repeats the title is hidden. `E` edits.
* **Editor:** a path field (moving a page keeps its links; the old path still resolves) and a mono textarea. Typing `[[` opens a listbox (float panel) of pages, documents, tickets, epics and agents; ↑↓ moves, ↵/Tab inserts. ⌘S saves silently as a new version; Esc cancels. A 409 shows a red banner.
* **Links:** accent text with a 12px leading mark for what they point at: a page icon in the doc-type color (new token `--doc-note` for wiki pages, a neutral grey), a status glyph for tickets, a 12px agent square, the epics icon. `[[X#Section]]` reads "X › Section". **Ghost links** (unresolved) are tertiary text with a dashed underline; clicking creates the page and opens the editor.
* **Suggestions:** an amber card per agent suggestion: avatar, "Sentry suggested an edit", note and time, a line diff (green additions, red struck deletions, unchanged runs folded to "⋯ n unchanged lines"), then Reject (approve-outline) and Accept (approve). A stale suggestion says so.
* **Right panel:** Local graph (radial SVG: centre, direct links on an inner ring, second hops outside; node color = doc type, ticket state or agent hue; nodes are links), Backlinks (linked mentions with snippets and cited sections, then unlinked mentions with "Link it"), Outline with citations, Read by, History.
* **Home:** search (matches highlighted with the amber pill tint), suggestions, recently updated, agent memory shortcuts, vault import/export.
* **Elsewhere:** a Backlinks section on artifact detail and in the ticket panel; a "Wiki pages" tab on Artifacts; a Memory card (on/off, inject Index/Linked/Search, token budget) on the agent definition.

---

## 6. Interaction and accessibility notes

* Use real elements: `<a href>` for navigation and rows that open something, `<button>` for actions, `<input>`/`<textarea>` with labels. Never put click handlers on divs.
* Every icon-only button has an `aria-label`. Decorative SVGs get `aria-hidden="true"`. Meaningful charts get `role="img"` plus an `aria-label` that states the numbers.
* Hover states: rows fill with `--hover`-ish `#131317`, card borders brighten to `#2C2C34`, nav items fill with `--hover`.
* Keyboard shortcuts:
  * `⌘K` command menu, `C` new ticket, `⌘↵` submit a composer, `⌘S` save a definition.
  * In the Inbox: `A` approve, `D` deny, `J`/`K` next and previous.
  * Bulk selection is checkbox on hover, then shift-click.
* Never the browser's `confirm()` or `alert()`. Something cheap to keep (a saved link, a moment) is removed at once with an **Undo** toast (`undoable()` in `lib/toast.ts`): it hides now and the delete runs when the toast goes. Something that can't be taken back (cancelling a run, deleting a secret, discarding unsaved edits, approving many requests) asks first with `await confirmAction({ title, body, confirmLabel })` from `components/ui/confirm.tsx`: a verb on the confirm button, red for destructive, focus on Cancel.
* Feedback for an action is a toast: `toast()` from `components/ui/toast.tsx` (store in `lib/toast.ts`) from any handler or hook. They stack bottom-centre (at most three, newest last), pause while hovered or focused, and errors stay longer. Inline errors next to a form field stay inline; a toast is for what just happened elsewhere or out of sight.
* Dialogs trap focus, close on `esc`, and return focus to whatever opened them. The command menu uses `role="combobox"` with a `listbox` of `option`s.
* Status must never rely on color alone. Glyph shapes differ (dashed, ring, half, three-quarter, filled) and pills always carry text.
* Small text never goes dimmer than `--text-tertiary`.
* Motion explains a change; it isn't decoration:
  * Use the `--motion-*` tokens in `globals.css` and the shared classes (`motion-scrim`, `motion-dialog`, `motion-float`, `motion-toast`) or the helpers in `components/ui/motion.tsx`. Every Radix overlay animates. Durations: `--motion-fast` 120ms (hover, colour; the default for any `transition-*`), `--motion-base` 200ms, `--motion-slow` 320ms, `--motion-exit` 140ms, `--motion-progress` 600ms (a bar filling). Curves: `--motion-ease` (default for `transition-*` and `ease-out`), `--motion-travel` (something moving between places), `--motion-spring`. In Tailwind, `duration-(--motion-base)`; a raw `duration-300` or `cubic-bezier()` fails `lib/ui-conventions.test.mjs`. `el.animate()` can't read a `var()`, which is why `motion.tsx` restates the curve.
  * Live lists mark rows with `data-enter-key` and call `useEntrances(root)`: a row that arrives later (a new chat in history, something new in Needs you, a chat message) rises in; what's there on first paint or after the whole list is replaced stays still. Status pills and glyphs recolour over `--motion-base` instead of snapping. Every `<details>` opens by height.
  * Frequent actions stay under 150ms, entrances under 320ms, and exits are shorter than entrances. Move only `transform` and `opacity` unless the height or width is the point (`Collapse`, the sidebar).
  * Nothing replays on first paint or polling. Don't animate run logs, tables, keyboard row movement or streaming text.
  * Under `prefers-reduced-motion`, animations that something waits on run for 1ms; the rest are off.

---

## 7. Domain model implied by the UI

The UI implies these entities. They're a starting point, not a schema decision.

* **Project**: name, color, epics.
* **Epic**: project, name, objective, owner (person), source PRD, target date, health, tickets.
* **Ticket**: project-prefixed ID (`PAY-214`), title, description (markdown), acceptance criteria (checklist), status, priority, labels, epic, assigned agent, human reviewer, estimate, due date, attached artifacts, branch, PR, activity.
* **Agent**: name, handle, identity color, role/specialty, status (running / waiting / blocked / idle), current ticket plus plan step, queue, stats, and a versioned **definition**: harness, model, instructions, scopes (each `allowed`, `requires approval` or `denied`), run guards, MCP servers and harness options.
* **Project override**: a partial definition for one agent in one project. It can switch harness, append instructions, add MCP servers, and only tighten scopes.
* **Run**: ticket, agent, a snapshot of the resolved definition, harness session, state, and a sequence of **turns**, each with a trigger and normalized events.
* **Secret**: name, the scope it grants, project or workspace, and the agents using it. The value is write-only.
* **Artifact**: type (PRD / spec / ADR / report / design), title, version history, author (person or agent), project, epic, linked tickets, outline sections with citation counts, readers.
* **Activity event**: actor (person or agent), verb, objects, timestamp, optional rich payload (plan, test run, comment thread, generated artifact).
* **Approval request**: agent, ticket, exact action plus parameters, risk summary, state (pending / approved / denied).

---

## 8. Not designed yet

* Light-theme versions of every screen except Tickets. The tokens already cover them.
* Settings pages other than Connections & secrets (General, Members, Projects & repos, Runner). Build them from the same cards, form controls and tables.
* The Overview, Runs and Tokens tabs of an agent, and the project-override editor. Reuse the Definition cards and show only overridable fields.
* The logo. The sidebar and Foundations still use the placeholder mark.
* The workspace-wide wiki graph view (only the local graph exists).

Extend the system above for these rather than inventing new patterns.
