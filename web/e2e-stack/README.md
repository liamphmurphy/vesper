# Real-stack browser e2e

Browser → Next → **real Go API** → **real runner** (`RUNNER_BACKEND=fake`) →
**real Postgres**. Unlike `web/e2e/*.spec.ts`, nothing is mocked: the specs
contain no `page.route` and the chat REST/SSE traffic is the real thing.

> **Fake CLIs, not real providers.** `claude` and `codex` are both
> the deterministic `server/cmd/fake-harness` binary. A pass proves the
> product plumbing (catalog, model/harness selection, runner dispatch, segment
> switching, cancel, persistence, history reload) with the fake's scripted
> output. It is **not** evidence that a real CLI, its output format, or any
> provider works. That needs a separate, credentialed
> verification.

## What it covers

`board-flow.spec.ts` covers an agent claiming a ticket and estimating a sibling
through the real MCP endpoint, live SSE updates on the open board, a person's
modal edit to Done, and the epic gate refusing closure until all final criteria
are checked. It then verifies the saved ticket and epic through REST. This flow
does not invoke a model.

`needs-you.spec.ts` covers the sidebar's Needs you tray (LAZYAGENTS-162): an
agent's run on the real `/mcp` endpoint (an unmanaged session) asks for a
`deploy:staging` approval twice and then asks a question with `await_human`.
The open page's badge goes up live; the person denies (with a reason) and
approves from the tray, and answers with its inline reply. Each time the run is
back to `running` and the agent reads the decision or the reply through
`wait_for_approval` / `await_signal`.

`run-composer.spec.ts` covers the run thread (LAZYAGENTS-163) the same way: the
person approves the agent's request with A in `/runs/{id}` and answers its
`await_human` question from the composer; the agent reads the approval and the
reply. An unmanaged session's question comes from its Needs you item, since
`await_human` logs no run event.

`slides-outline.spec.ts` covers the Slides New deck chooser: a deck started
from a starter deck in a chosen theme, and Draft from outline, where the fake
(`FAKE_HARNESS_MODE=chat-read`, set for the whole stack) reads the deck and
adds one slide per outline line with `canvas_patch`. The spec checks the
slides arrive as per-slide suggestions, the first version is untouched, and
only the accepted slide is kept. The fixture inserts one epic directly into the disposable
database because epic creation has no standalone REST endpoint; criteria,
tickets, estimates and status changes use the real API/MCP. The script provides
both `E2E_STACK_BASE_URL` (web) and `E2E_STACK_API_URL` (API) to Playwright.

`designs-review.spec.ts` (tagged `@design-review`, the spec itself is
`e2e/designs-review.spec.ts`) covers reviewing a persona's design suggestions,
direct edit with Undo, and a selection reaching the persona. It needs the fake in
`design-review` mode, so a run with no arguments restarts the runner in that mode
after the other specs; to run just it: `E2E_FAKE_HARNESS_MODE=design-review npm run e2e:stack -- designs-review`.
The design worker token (`DESIGN_WORKER_TOKEN`) is set for the API and web.

## The disposable fixture (`run.sh`)

Everything lives under a fresh temp dir and is torn down on exit (success,
failure or Ctrl-C):

- **Postgres** a local Postgres 17 from the macOS app's bundle
  (`scripts/dev-postgres.sh`, macOS) on a free port, or `E2E_DATABASE_URL` (CI
  service container; must be disposable, it is migrated and written to).
  `vesper serve` runs migrations and first-boot seed (`SEED=false`).
- **Blobs** a local directory (`BLOB_DIR`) under the temp dir.
- **Fixtures**: a project and a main agent, created through the real API.
- **API + runner**: built binaries, `RUNNER_MCP_URL` and `PUBLIC_URL` on the
  free ports.
- **Web**: `npm run build`, then `design-worker/server.mjs` serving `dist/` with `API_INTERNAL_URL` set (it proxies `/api`, `/mcp` and `/events`).

### Fake harness and the PATH guard

`RUNNER_CLAUDE_BIN`, `RUNNER_CODEX_BIN` and `RUNNER_ANTIGRAVITY_BIN` point at
symlinks to the built fake in `$TMP/bin`. The API and runner run under
`env -i` with `PATH=$TMP/bin:/usr/bin:/bin` (`git` is symlinked in). Before
anything starts, the script requires `command -v claude|codex` to
resolve inside `$TMP/bin` under that PATH (`agy` too) and refuses to start otherwise, so a
real, logged-in CLI (`~/.local/bin`, `~/.nix-profile/bin`, `/opt/homebrew/bin`)
cannot be reached. Claude/Codex model lists come from the fake answering the
same discovery protocol the local catalog uses, and Antigravity's from the fake
answering `agy models`.

## Run locally

Needs Go, Node 24, Chromium (`npx playwright install chromium`), and either macOS (for the bundled Postgres) or `E2E_DATABASE_URL`.

```sh
cd web
npm ci
npm run e2e:stack                       # whole suite
npm run e2e:stack -- --headed           # extra args go to playwright
E2E_STACK_SETUP_ONLY=1 npm run e2e:stack  # just start the stack and print URLs
E2E_KEEP_TMP=1 npm run e2e:stack        # keep $TMP (logs/) for debugging
```

On failure the script prints the tail of each process log. CI runs the same
command in the `e2e-stack` job and uploads `playwright-report/` and
`test-results/` (traces) on failure.
