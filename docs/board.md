# Kanban board, estimates and epic criteria

The board (`/board`) shows one project's tickets as columns. Agents are its
primary users: they estimate tickets and check epic criteria through MCP.
People watch the board, edit tickets in a modal and close epics. Design and
open questions: wiki `Architecture/ADR - Kanban board, estimates and epic criteria`.
API contract: `getProjectBoard`, `updateTicket`, `updateEpic` and the
`*EpicCriteri*` operations in `api/openapi.yaml`.

## Statuses

Columns, in order: **Backlog → To do → In progress → In review → Done**.
**Canceled** is a sixth status, hidden unless you tick *Show canceled*.

| Who | What they can set |
| --- | --- |
| The system | Claim or dispatch moves `backlog`/`todo` to `in_progress`. `complete_run` moves to `in_review` (default), `done` (subject to the run's review policy) or back to `todo`. A merged PR moves to `done`. |
| People | Any status: drag a card, use its **⋯ Move to…** menu (keyboard: focus the card, Space), or edit the status in the modal. |
| Agents | No direct status tool. Ticket status only changes through `complete_run`. |

- **Canceled is human-only.** It's refused (409) while the ticket has a live
  run: cancel the run first. Canceled tickets leave dispatch, the attention
  list, the active, backlog and agent views, and epic point totals.
- **Blocked is a badge, not a column.** A card with open blockers shows
  ⛔ Blocked in its real status column. A canceled blocker still blocks.
- Board moves and modal saves send the ticket's `revision`. If someone else changed the
  ticket first, the move or save is rejected (409) and the board shows the
  newer state. Changes from agents and other tabs arrive live over SSE.

## Estimates

- Scale: **1, 2, 3, 5, 8, 13** story points (Fibonacci), enforced by the API
  (422, field `estimate_points`) and by a DB check. A ticket can also be
  unestimated (shown as a dashed *unestimated* pill).
- Each estimate records who set it, when, and a rationale. The modal shows
  "Set by @agent" or the person's name.
- **People win.** A person can always change or clear an agent's estimate. An
  agent can't overwrite a person's estimate (409: comment instead), and no
  agent can re-estimate a done or canceled ticket.
- Rollups: a column header shows its card count and points. An epic's points
  total is the sum over its non-canceled tickets, and "done" points are the
  sum over its done tickets. Unestimated tickets count as 0.

## Epic final acceptance criteria and the done gate

Each epic has an ordered list of final acceptance criteria and a status,
**Open** or **Done**. Filter the board by an epic (the *Epic* picker) to see
its header: points and criteria progress bars, the criteria editor and the
**Mark epic done** button. The epic page (`/epics`) has the same editor and gate.

- People add, edit, reorder, tick and delete criteria in the header.
- **Gate:** an epic can be set to Done only when every criterion is checked
  and every ticket in it is done or canceled. The header says what blocks it
  in the **Can’t mark done yet** panel, and disables the button. If a stale request reaches the
  server refuses (409) and the header lists the unchecked criteria and open
  tickets. Once nothing blocks it, the header reads "Ready to mark done".
- The board and epics page require at least one criterion before offering Done.
- While an epic is done, its criteria are locked and no ticket can be added
  to it. Setting it back to Open is always allowed.
- Only people move an epic to Done in v1.

## Editing a ticket

Click a card (or focus it and press Enter) to open the edit modal; the URL
gains `?ticket=KEY`, so the modal can be linked. Cmd/Ctrl-click opens the
full ticket page instead. The modal edits title, description, status,
priority, point estimate, assignee, epic and the ticket's acceptance criteria
(add, edit, reorder, tick, delete). **Save changes** sends one revision-checked
`PATCH /tickets/{key}` with only the changed fields; criteria changes are
saved in the same request, atomically. If the ticket changed meanwhile, a
banner keeps your draft and offers **Reapply mine** against the latest version
or a reload that replaces the draft. Description supports Write/Preview;
Cmd/Ctrl+Enter saves. Esc or Cancel closes without saving, asking before
discarding unsaved edits.

## How agents use it (MCP)

Agents reach all of this through the Vesper MCP server (`/mcp`, or the
REST mirror `POST /api/v1/agent/tools/{name}`). Managed runs get a run token;
an unmanaged session uses an agent token from the agent's page.

| Tool | What it does | Who can call it |
| --- | --- | --- |
| `get_ticket` | Returns `status`, `revision`, `estimate_points` and `estimate {points, rationale, by, at}`. When the ticket is in an epic, also `epic {id, name, status, points_total, points_done, tickets_open, criteria [{n, text, done}]}` | Every profile that has it |
| `estimate_ticket` | `{ticket, points, rationale}`. Points must be on the scale; a rationale (up to 2000 characters) is required. Works on the run's own ticket or any other ticket in the same project | The main agent of a live ticket run (not chat, planning or delegated runs) |
| `check_epic_criterion` | `{epic, n, done=true}`. `epic` is the id or exact name from `get_ticket`, `n` the criterion number. `done: false` unticks it | The main agent of a live ticket run whose `tracker:epics` scope is **allowed** (default denied; `requires_approval` counts as denied) |
| `create_ticket` | Optional `points` and `estimate_rationale` on the new ticket. Chats also take `project` (default: the chat's default project) and `agent`, a main agent's handle to assign it to; a run's follow-ups stay in its project, unassigned | Lead and chat runs |
| `propose_tickets` | Each draft can carry `points` and `estimate_rationale`. On acceptance the estimate is credited to the planning agent, unless the reviewer changed it first | Planning runs |
| `create_epic` | Creates an epic in `project`, or the chat's default project | Chat runs |
| `update_ticket` | `{ticket, revision, title?, description?, status?, priority?, points?, estimate_rationale?, epic_id?, agent?, requires_mockup?, pr_url?, pr_draft?}`. A stale `revision` is refused. `canceled` is refused (only people cancel), and so are status and `pr_url` changes while the ticket has a live run. `pr_url` links a PR for work done in the chat, so PR sync moves the ticket to Done on merge. Each event's payload carries `via {chat_id, persona_id}` | Chat runs |
| `comment_ticket` | `{ticket, body}`. Comments as the assistant; the event carries `via {chat_id, persona_id}` | Chat runs |
| `reply_to_run` | `{ticket, answer}`. Posts the person's answer as a comment (written by the assistant, naming whose answer it is) and resumes the run. Only for a run the chat started, while it waits for a reply, after the person has answered in the chat | Chat runs |

Apart from a chat's `update_ticket`, no MCP tool sets ticket or epic status directly. A typical lead run: call
`claim_ticket` (which returns the ticket, including the epic's criteria), and
`estimate_ticket` on tickets it has sized. Once the work is verified it calls
`check_epic_criterion` for the criteria it has met, then `complete_run`. A
person reviews it on the board and closes the epic once the gate opens.

## Verification

The board is native in the Mac app now, so the web real-stack board spec is
gone. The agent side is covered by `TestMCPEstimateTicket`,
`TestMCPEpicCriteria` and `TestPlanningProposalPoints` in
`server/internal/httpapi/mcp_estimates_test.go`, and the board's columns and
card reordering by `macos/Tests/VesperCoreTests/TicketsLogicTests.swift`.
