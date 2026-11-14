# Running and developing Vesper

[← Back to the project](../README.md)

## Run locally

Requires Docker (Docker Desktop on a laptop).

```sh
cp .env.example .env
docker compose up --build      # → http://localhost:8080
```

The first boot creates an empty workspace with one local user and an Assistant
with all persona permissions enabled. A signed-in browser acts as that user.
The first visit opens the Welcome Wizard in the new-chat welcome, hosted by
your Assistant: your name, what you do and an optional photo; a harness to run
on (Claude Code, Codex or Antigravity, as a subscription login or an API key, verified by
listing its models; Antigravity takes only a Gemini API key; Codex or Antigravity is needed for
image generation); and a first
persona, described in your own words and drafted by the Assistant. It shows
until you finish it; afterwards only its harness step comes back, whenever no
harness is connected. Settings → Run setup again starts it over. Ticket agents use your profile's primary email for
commits and coding chats can choose among its addresses: set them in
Customization → Profile, or with `LOCAL_USER_NAME` and `LOCAL_USER_EMAIL` before
first boot. Settings → Open setup checklist shows what is still missing.
The Northwind Labs demo is opt-in with `SEED=true`; existing databases are left as-is.

### Signing in

The API serves the app only to a signed-in browser. Agent containers can reach
everything the app serves, so arriving at the API proves nothing; a browser
signs in with the owner's password or a one-time link.

**First run.** A fresh install is unclaimed: open it and the sign-in page asks
for a username and password. The first browser to set them claims the install
for good and stays signed in for a year (an HttpOnly, `SameSite=Strict`
cookie). Until then whoever reaches the port could claim it, which is why
compose publishes it on `127.0.0.1` unless you set `LAZYAGENTS_BIND`. Installs
from before passwords existed stay claimed; add a password in Settings → Sign-in.

**Other devices** sign in with the username and password. Ten wrong guesses
in 15 minutes pause password sign-in until the window passes.

**Locked out**, or no password yet:

```sh
make signin    # → http://localhost:8080/api/v1/sign-in?code=…
```

Open it within 15 minutes. It works once and drops you into the app. The API
also logs a link at startup while a claimed install has no password and no
signed-in browser. `make signin` asks the full
stack's API when it's running (`docker compose exec api vesper sign-in-link`)
and otherwise reads the dev database, linking to Next on `WEB_URL`
(`http://localhost:3000`). Agents are unaffected: they use bearer tokens on
`/mcp` and `/api/v1/agent/`.

### Running agents

Assign a ticket to an agent, then **Review & dispatch** it. The `runner`
service runs each turn in a container from `vesper/agent-base` (built by
compose, with Claude Code, Codex and Antigravity installed). Before dispatching:

- set `SECRETS_KEY` in `.env` (`openssl rand -base64 32`);
- add or sign in to the harness credentials in **Settings → Connections & secrets**: `harness:anthropic`
  for Claude Code, `harness:openai` for Codex, and `harness:google` (via Google Antigravity sign-in)
  for Antigravity. Use **Sign in** in Settings or `make start` from a checkout to sign in directly;
- add `git:pat` (a GitHub token) and a repo URL for the project, if agents should
  clone, push and open PRs. Open PRs are polled every 60s: merged → Done.

> **Security:** the runner mounts the Docker socket, which is root-equivalent on
> the host. v1 is meant for a single developer laptop. Works with Docker Desktop
> and OrbStack.

### Personas that do the work

Agents are personas. Open **Customization › All personas** to see who chats and who works. On a
persona's profile, **What it does** picks *Chat only*, *Takes tickets* or *Helps on runs*, and
**Show in chat list** keeps a worker out of the chat switcher. **Work settings** opens its harness,
model, work brief, permissions, helpers and limits. Its tone and style reach its runs too; its
work brief reaches runs only. A run can search your project and work memories and the persona's
own, nothing else you've told your personas. Turning work off waits until it has no open tickets
or runs.

### Runner tools and project libraries

Keep the running dependency list in Git:

- Shared tools: [`deploy/agent-base/Dockerfile`](../deploy/agent-base/Dockerfile)
  installs the toolchains and pinned harness CLIs, Go, sqlc, and Chromium system
  libraries once per image build. Rebuild with `docker compose build agent-base`.
- Project libraries: add `.lazyagents-deps.json` to the repository root. The
  manifest lists tool requirements and directories; exact library versions stay
  in `go.mod`/`go.sum` and `package-lock.json`. This repository includes an example:

```json
{
  "version": 1,
  "required_tools": ["git", "gh", "go", "node", "npm", "python3", "rg", "make", "sqlc"],
  "go_modules": ["server"],
  "npm_projects": ["web"],
  "playwright": ["web"]
}
```

The runner checks tools, downloads Go modules, installs locked npm packages
(including dev dependencies), and installs Chromium before starting model work.
It also prepares delegated worktrees, even for read-only agents. A continued
worktree reuses npm packages when its lockfile, package manifest, and Node/npm
versions match. A missing tool or failed install fails workspace setup with an
`Environment setup failed` message. Repositories without the manifest retain
existing setup behavior. Agent/project setup commands run after dependency setup.
Changes take effect after updating the API/runner binaries; repository manifests
must be on the branch that new runs clone. Existing workspaces are not rewritten.

Docker runs share the named volume `lazyagents-dependency-cache` at `/cache`; workspace
cleanup preserves it. It holds Go modules, npm downloads, Playwright browsers
and the Go build cache (`/cache/go-build`), so a new chat doesn't compile its
dependencies from scratch. Each checkout owns its own `node_modules`. Codex grants cache writes to
execution/repository writers; scoper keeps read-only tool permissions. Shared
caches are intended for projects trusted by the same user, not unrelated tenants.
Playwright browser versions follow the project lockfile; Linux OS library changes
require rebuilding the agent image. Database servers/credentials remain explicit
project configuration, not package dependencies.

The tool policy recognizes read-only shell sequences, pipelines, numeric `sed`
print ranges, and system-shell wrappers such as `/bin/zsh -lc 'rg ...'`. Dynamic
commands, file writes, and unknown programs still require `tests:run`. Ordinary
`git push` requires `repo:write`; combining it with test execution requires both.
Hooks are a best-effort check; the harness/OS sandbox remains the isolation boundary.

### View the runner environment

Open **Settings → Runner environment**, or follow **Environment** from a run log.
The page shows live runner capacity alongside the latest recorded setup per
runner and project: tool versions, direct Go/npm dependencies, Chromium setup,
and shared versus workspace cache availability. Select a project/runner to
inspect its report, or use a run's link for its historical snapshot. Reports are
stored in run events and survive workspace cleanup and runner shutdown.

These are observations from setup, not a live scan of the host. New reports
require the updated runner and a new workspace setup; older runs show a clear
empty state. Failed dependency installs retain their error and any inventory
collected before the failure. Refresh only reloads reports; it does not install
packages or start agent work.

### Open a run's code

By default a run's checkout lives in a Docker volume, which you can't open from
your machine. To work in it alongside the agent (in Neovim, an IDE, a second
terminal), keep checkouts in a folder on your machine instead:

1. Set `VESPER_WORKSPACES_DIR` in `.env` to an absolute path, such as
   `/Users/you/vesper/workspaces`.
2. Restart the runner. `make start` and `make runner` add
   `docker-compose.workspaces.yml` on their own. For the full stack, also set
   `COMPOSE_FILE=docker-compose.yml:docker-compose.workspaces.yml` in `.env`.
3. Turn on **Settings → Runner backends → Host folders**.

New runs then check out into `<folder>/<run id>`. The chat header and the run
page show that folder with a button to copy the path. The agent still sees it at
`/workspace` in its container, nothing else of your machine is mounted, and its
home directory (harness sessions, the SSH key) stays in a volume.

- **Only new runs change.** A run that already has a workspace keeps it, and
  turning the setting off leaves existing folders where they are.
- **The folder goes away with the workspace.** Completed runs and chats idle for
  `RUNNER_CHAT_IDLE_TTL_S` are cleaned up as usual. Unpushed work is pushed to a
  `vesper-checkpoint/...` branch first, so edits of yours that it hasn't pushed
  are saved there.
- **Edit between turns when you can.** While a turn runs, the agent writes to the
  same files, so expect your editor's "file changed" prompts. Running git at
  the same time as the agent can hit `index.lock`.
- **Let the agent push.** The checkout's git config points push credentials at
  paths inside the container, so `git push` from your machine fails. Reading,
  editing and committing locally all work.
- **File ownership.** Turns run as uid 1000. Docker Desktop and OrbStack map
  that to you. On a Linux host, files belong to uid 1000, so give your user
  write access if it's a different uid.
- Don't remove `VESPER_WORKSPACES_DIR` while runs use their folders: the runner
  then can't find those checkouts, and a chat starts over in a fresh one.

### Chat

Select a project, open **Chat** in the sidebar, and choose **New chat**. Select
a harness/model, type a message, and send with Enter (Shift+Enter adds a newline).
Chats appear in the history panel so you can return to the conversation later.
Keep a runner online. It requires `harness:anthropic` for Claude Code,
`harness:openai` for Codex and `harness:google` for Antigravity in **Settings → Connections & secrets**.
Unavailable models are disabled in the picker.

Change the picker before sending to use a different model or harness for the
next reply. Model changes on the same harness resume its session. A harness
change starts a fresh session with a bounded transcript handoff; hidden reasoning,
tool results and older messages outside the budget do not transfer.

Use **Add context** or type `[[` to attach a wiki page, artifact or ticket.
**Start chat** on a context item's page opens a chat with that item attached.
The assistant can read project context through Vesper MCP; pages it reads
appear under **Sources**. Replies arrive when a turn finishes. **Stop** cancels
the current turn; **Save to wiki** and **Save as artifact** preserve a reply.
Chats use a scratch workspace and read-only context tools.

Verification status and known gaps are recorded in
[`docs/dev/verification/LAZYAGENTS-14-report.md`](dev/verification/LAZYAGENTS-14-report.md).
The real Claude Code → Codex smoke is still pending API/runner mode alignment and
a chat-capable runner; automated fake-harness coverage does not establish provider parity.

### Token-efficient execution

Ticket agents work directly in their persistent harness session by default.
Routine scoping, implementation, and shipping do not require separate agents.
Delegation remains available for substantial independent work, missing
capabilities, explicit requests, and independent review of risky or large changes.
Existing review requests for changes still block Done. Enable **Require
independent review before Done** in an agent's Runtime settings to enforce an
approval gate for every ticket that agent runs. Acceptance criteria, scopes, and
human approvals remain required.

A main agent's ticket run on Claude Code (the lead, not a delegated sub agent)
gets one read-only sub agent, `explorer`, that searches and reads code on a
cheap model (`explorer_model`, default `haiku-5.5`) and returns only its
conclusions, keeping file dumps out of the lead's context. It is on by default;
set the harness option `explorer` to `"false"` in an agent's definition to turn
it off. Sub agent runs, chats, `readonly` or `no_tools` agents, and Codex or
Antigravity runs never get it.

Context rollover continues a main agent in a fresh session, briefed from the
ticket, its plan, git and the delegation report, so a long run stops re-reading
its whole history on every call. It fires only when a lead's delegations finish
(the agent is woken with their results) and its last reported context is at
least `ROLLOVER_CONTEXT_TOKENS`; a run that never delegates never rolls over,
and Codex runs, which don't report context, never do. The compose files default
it to `150000`, chosen from measured runs; set it to `0` in `.env` to turn
rollover off (outside compose the default is `0`).

Managed `claim_ticket` responses include the ticket (`ticket_details`, same as `get_ticket`) but no longer repeat instructions and memory already
available in the workspace. Agents are instructed to read only relevant context
and reuse it on resume. New definitions default to **Selective** memory: at most
three relevant previews, with full pages fetched only when needed, within a
1,500-token budget. Existing explicit Index/Linked/Search settings are preserved;
choose Selective on an existing agent's Memory card to use the new selection.
Attached artifacts are still available locally, and duplicate memory/artifact
copies are skipped.

Run logs, usage events, chat replies, and agent run history distinguish cached
input, uncached input, output, and input with an unavailable cache breakdown.
Total tokens include cache reads; cache hits are not added again. Historical
breakdowns are recovered from saved turn usage where available. Unsupported or
self-reported usage stays unknown rather than being labeled uncached. Prices and
provider limits still depend on the harness/provider; cache counts are not a
spend or subscription-limit estimate.

### Skills

An agent definition can carry **skills**: reusable playbooks (a name, a one-line
"use when…" description, and markdown instructions). On Claude Code they're
written into the run workspace as native skills (`.claude/skills/<name>/SKILL.md`,
git-excluded), so the agent loads a skill's body only when a task matches its
description. On Codex they use native discovery under
`.agents/skills/<name>/SKILL.md`. Antigravity has no documented skills folder, so it gets the
same playbooks under `.lazyagents/skills/` with an index in `AGENTS.md`. Edit them in the agent's
**Skills** card.

`examples/skills/` holds a starter library, and
`python3 examples/attach-skills.py` attaches it to the starter agents
(`tech-lead`, `implementer`, `code-reviewer`, `scoper`). It's idempotent.

### Patterns

Reusable team conventions (architecture patterns, coding styles) live in a
curated, workspace-wide wiki area, separate from agents' run notes
(`agents/<handle>/`) and project decisions (`Architecture/ADR - …`).

- Published patterns are atomic notes at `Patterns/<Topic>/<Title>`. Topic is
  one of Go, React, Postgres, Testing, API, Architecture, Process; the title is
  short and imperative ("Wrap errors with context").
- The body starts with `Topic: <topic>` and `Tags: tag1, tag2` (2-5 lowercase
  tags), then the sections When to use, Rule, Example, When not to use, Related.
- Agents look conventions up with `find_pattern({q, topic?, limit?})` before
  implementing. Search tolerates typos and partial words (`eror wrap`, `pgx`);
  an empty `q` lists everything. The web API is `GET /api/v1/wiki/patterns`.
- Agents propose with `propose_pattern({title, topic, tags, body,
  source_ticket?})`, which writes `Patterns/Proposed/<Title>` (always allowed,
  whatever `wiki:write` says). Proposals are not searchable.
- An agent whose `wiki:write` scope is `allowed` (for example a librarian or
  `tech-lead`) reviews them: `list_proposed_patterns`, then `publish_pattern`
  (optionally editing title, topic or body) or `reject_pattern` with a reason.
  Both remove the proposal. If the pattern already exists, merge into it with
  `write_note` (mode replace) and reject the duplicate.
- Run notes under `agents/<handle>/` are only for durable lessons that help a
  future run on this codebase, not a log of what was done. General lessons go
  through `propose_pattern`; project-specific decisions stay in ADRs.

### Planning work

Open **Plans**, choose a project and agent, describe a goal, then **Approve & start planning**.
You can also start from **Plan with an agent** on an epic or **Generate tickets** on a
markdown PRD/SPEC. The planner uses the runner and harness key described above,
with read-only capabilities, no repo cloning/setup, and no write credentials.

Review the draft in Plans or Inbox. Edit, drop or reassign proposals, and select
which proposals or existing tickets must finish first, then
**Accept & create tickets**. Tickets remain in Backlog until you separately
**Review & dispatch** them. Planning can incur model costs; it waits in the queue
if no runner is online.

### Projects and dependencies

Open **Settings → Projects & repos** (or **Manage** beside Projects in the sidebar)
to create a project, edit its GitHub repository/default branch, or archive and restore it.
Project keys stay fixed. Archiving preserves history and requires queued/active runs
to be finished or cancelled first. Approved runs retain their repository settings.

Tickets in an epic ship together. The epic gets one shared branch,
`epic/<project key>-<epic id prefix>`, and one draft pull request from it into
the default branch. Each ticket's branch is cut from the epic branch, its PR is
stacked on the epic branch, and the agent merges it there once its local tests
pass, without waiting for GitHub checks. You review the epic as one GitHub stack and merge the epic's PR once. Tickets outside
an epic still get their own PR into the default branch.

On a ticket, use **Dependencies → Edit** to add blockers. Every blocker must be
**Done** before dispatch; In Review is insufficient. Cycles are rejected. The ticket
list's **Ready to dispatch** filter and an accepted plan's dispatch action show ready
work. Later waves become available as prerequisites finish, with human approval for
every dispatch.

### Kanban board

Open **Board** to see project tickets by status, edit a ticket in its modal,
or filter by epic to manage final acceptance criteria and the done gate.
See [the board guide](board.md) for estimates, statuses and the agent MCP tools.

### Move Vesper to another machine

`vesper export` writes the whole instance to one zip archive: every Postgres
table and every object in the S3 store. `vesper import` loads it into another
instance. Both run inside the `api` container, which holds the credentials.
Export is also a button, **Settings → Backup & move → Export everything**, which
downloads the same archive from the running server. Import is only a command:
it needs an empty instance, stopped, with the same `SECRETS_KEY`.

```sh
# old machine
docker compose exec -T api vesper export -o - > vesper.zip
# new machine: set the same SECRETS_KEY in .env, then
docker compose up -d postgres seaweedfs                    # not api yet
docker compose run --rm -T api import - < vesper.zip
docker compose up -d
```

The image has no shell and runs as a non-root user, so `-` reads or writes the
archive on stdin and stdout; progress goes to stderr. Outside Docker, pass a
file path instead.

- **Same `SECRETS_KEY`.** Stored secrets are sealed with it. The archive carries
  only a fingerprint, and import refuses a different key before changing anything.
- **Import into a fresh instance.** Start only Postgres and the object store, so
  the target has no data. If it does, import refuses; `--replace` discards what
  the exported tables hold. A target that has never been migrated is migrated to
  the archive's schema version, loaded, then upgraded to the running version.
  An archive from a newer Vesper than the target is refused.
- **What moves.** Everything except machine-bound or regenerated state: browser
  sessions and sign-in codes (people sign in again), runner registrations, live
  playgrounds and provider usage caches. Each excluded table and its reason is
  in `server/internal/transfer/schema.go`.
- **Tables and buckets are discovered, not listed.** Export reads the Postgres
  catalog and the bucket listing, so a table or bucket added later is included
  without touching the exporter. The configured `S3_BUCKETS` are always
  included, since some stores (SeaweedFS without credentials) list no buckets.
  Export lists *every* bucket the S3 credential can see, so give Vesper its own
  credential on a shared S3 account.
- **Quiet the instance first.** The database is read in one snapshot, objects a
  moment later. Runs still in flight when you export come back as they were,
  with nobody working on them.
- The archive holds all your data, including sealed secrets. Treat it like a
  database backup; it is written with mode 0600.

## Develop

Requires Go 1.26+, Node 24+ and Docker for Postgres and SeaweedFS.

```sh
make start   # everything: .env, agent image, sign-in, infra, API, web and hardened runner
make dev     # infra in Docker; API on :8000 and Next on :3000 run on the host
make runner  # optional: (re)start the hardened runner, a dev compose container
make gen     # after editing api/openapi.yaml or server/internal/store/queries (needs sqlc)
make test
make help    # everything else
```

Agents only run in Docker (`RUNNER_BACKEND=docker`, the default). Each turn runs in a
container with no capabilities, `no-new-privileges`, memory and process limits
(`RUNNER_MEMORY_MB`, `RUNNER_PIDS_LIMIT`), and no mounts from your machine. The
container is Codex's sandbox there, because Docker blocks the namespaces its own
sandbox needs, so read-only Codex turns rely on the policy hook. A stray write
only reaches that run's disposable volumes.

Agent containers can still reach your API and the internet, but not the
stack's Postgres or SeaweedFS: turns run on an `agents` network that has only
the API on it (`lazyagents_agents` for `make up`). Under `make start` the dev
stack publishes Postgres and SeaweedFS on the host's loopback, which Docker
Desktop and OrbStack may let containers reach through `host.docker.internal`, so
there the separate network keeps them off the compose names only.

The runner itself runs as the `runner` service of `docker-compose.dev.yml`
(`--profile runner`), from your checkout's source. Every `make start` or
`make runner` replaces it, so a runner from an earlier session can't keep
claiming runs with stale code, and stopping `make start` stops it. Its turn
containers join the dev stack's `agents` network and reach the API on the host
as `host.docker.internal`. Each install labels its containers with `RUNNER_STACK`
(`lazyagents-dev` here, `lazyagents` for `make up`), so two installs on one
Docker daemon never clean up each other's turns.

### Test environments

A repository needs no Vesper file for its tests to run in a turn. Three things
make that work, and none of them gives an agent the host's Docker socket.

**Docker, sandboxed per turn.** Each Docker turn gets its own Docker API
(`DOCKER_HOST`), served by the runner on a socket in a directory turns mount
read-only and can't list (`RUNNER_DOCKER_PROXY_DIR`, `RUNNER_DOCKER_PROXY_VOLUME`).
`docker run` and Testcontainers in any language work through it, with any
image. Every container it creates is rebuilt into a sandbox: privileged mode,
added capabilities, devices, host namespaces, host paths, other runs' volumes
and the stack's networks are refused with a message; containers get Docker's
default capabilities, `no-new-privileges` and the turn's memory and process
limits; published ports listen only on the turn network's gateway, which turns
reach as `$TESTCONTAINERS_HOST_OVERRIDE` and your LAN doesn't. A turn sees and
acts on only what it created, and all of it is removed when the turn ends.
`docker compose` works too. Binds under `/workspace` (compose's `./server`)
become mounts of the run's own checkout at that path; any other host path is
refused, and with host-folder workspaces a symlink out of the checkout is too.
Builds use the classic builder (`DOCKER_BUILDKIT=0` in turns): `RUN` steps run
on the turn's network with the daemon's defaults. BuildKit is refused because
its session and gRPC streams can't be inspected. Neither a build tag nor a pull
can replace a locally built image a turn didn't make, such as the agent image.
A turn can remove images its run built (`docker compose down --rmi local`), and
no others. Swarm and plugins aren't available. Ryuk is turned off
(`TESTCONTAINERS_RYUK_DISABLED`), because cleanup is the runner's job. A stack
lasts one turn; one that stays up between messages is still to come.

**Nix, without root.** The agent image ships Nix pointed at the runner's
`nix-daemon`, which owns a store every turn shares (`RUNNER_NIX_VOLUME`). An
agent installs a missing tool with `nix profile install nixpkgs#protobuf`; it's
on `PATH` for the rest of the run and a cache hit for every later run. To move
to a newer Nix, remove the store volume and the
`lazyagents-nix-daemon-<stack>` container; the next runner start recreates
both from the image. At startup the runner checks the daemon with a real
store query, restarting it once if it doesn't answer. If it still doesn't,
turns run without the store, so `nix` fails at once instead of hanging, and
the probe, the daemon's log tail and diagnostics are in
`/run/lazyagents-docker/nix-status.json`, which any turn can read.

**A remembered recipe per repository.** On a repository's first run the runner
reads its CI workflows and compose files: GitHub Actions service containers
become services, and job variables that reach them through `localhost` are
rewritten to the service's name (Vesper's own CI gives `postgres:17-alpine`
and `TEST_DATABASE_URL=postgres://...@postgres:5432/...`). Compose files
contribute well-known backing services (databases, queues, caches, object
stores) only when CI declares none. After each turn the runner adds the Nix
packages the agent installed, and the next run installs them during setup.
Recipes are keyed by repository, so coding chats and ticket runs share them.
Settings → Runner environment lists each one, with where it came from, a JSON
editor and Forget (the next run infers it again); the API is
`/runner/test-environments`.

Services start next to every turn on an internal network of that turn's own,
reachable by `name`, and are removed when it ends. They get the turn's sandbox
with Docker's default capabilities, so official database images work as they
are. A project can still declare services on its agent override
(`services` in the override JSON); those win over the recipe and are frozen
into a run at dispatch, so an agent can't change them:

```json
[{"name": "postgres", "image": "postgres:17-alpine",
  "env": {"POSTGRES_PASSWORD": "test"},
  "healthcheck": ["CMD", "pg_isready", "-U", "postgres"],
  "expose": {"TEST_DATABASE_URL": "postgres://postgres:test@postgres:5432/postgres?sslmode=disable"}}]
```

The turn starts once every healthcheck passes (or, without one, once the
container runs), within two minutes; a service that fails to start fails the
run with its last log lines. The fake backend (below) skips services, the
Docker proxy and Nix, and says so.

Database-backed Go tests skip without `TEST_DATABASE_URL` when you run them,
but fail inside a Vesper run (`LAZYAGENTS_RUN_ID`) or on CI, so "tests pass"
from an agent means they reached a database.

`make start` signs Vesper in to Claude and Codex the first time. `make login`
redoes it. Both store plan logins in the `harness:anthropic` and `harness:openai`
secrets. Vesper keeps its own Codex login, because a copy of `~/.codex/auth.json`
and the original would invalidate each other when one refreshes. If device
sign-in is off for your ChatGPT account, enable it or run
`CODEX_AUTH_FILE=~/.codex/auth.json make codex-login` and sign in again on this
machine afterwards if the CLI complains. Listing models with a plan login uses
the `claude` and `codex` CLIs on the API host.

Both also offer your GitHub CLI token (`gh auth token`) as the `git:pat`
secret, which agents need to push to `https://` repositories and to open pull
requests with `gh`. A `git:ssh` key alone doesn't cover that. `make
github-login` stores or replaces just that token. A token added later takes
effect on the next turn, including in chats that already have a workspace.

You can also sign in from **Settings → Connections & secrets** instead of the
terminal. While a Docker runner is online, Anthropic, OpenAI and the GitHub
token show a **Sign in** button until they're set. The runner starts the
provider's own CLI (`claude setup-token`, `codex login --device-auth` or
`gh auth login --web`) in a throwaway container from the agent image, with no
volumes. Settings shows the link to open and, for Codex and GitHub, the
one-time code to enter there. Claude's page shows a code that you paste back
into Settings. The runner stores the result as the usual secret, so the login
never passes through the browser. A sign-in gives up after 15 minutes, and
starting another for the same provider replaces it. To replace a key that's
already set, use **Replace** or the `make` targets above.

Upgrading from the removed `local` backend keeps your chats. A chat whose
session was there continues on Docker in a new session with its recent messages (the last 40, up to
24,000 characters in total), and says so in the chat. Its old workspace stays
with the backend that made it. Before any chat workspace is removed, unpushed
work goes to a `vesper-checkpoint/chat/<run>` branch. If that push fails the
workspace is kept, and files with nowhere to push stay on disk.

`RUNNER_BACKEND=fake` is for tests and disposable instances only (the e2e
stack, playgrounds): turns run on the host with no isolation, every harness is
a stand-in binary (`server/cmd/fake-harness`), and the runner and API refuse to
start unless `RUNNER_CLAUDE_BIN` and `RUNNER_CODEX_BIN` both name one (`RUNNER_ANTIGRAVITY_BIN`
is optional: without it Antigravity is simply unavailable; name a symlink called `agy`, which
is how the fake knows to speak agy). It needs
no provider keys, and shares download caches under `$RUNNER_DATA_DIR/cache`.
Set the same `RUNNER_BACKEND` on the API and its runners.

See the
[runtime refresh procedure](dev/verification/LAZYAGENTS-14-runtime-evidence.md#coordinated-refresh-procedure)
before replacing existing runners with active work. `make dev` replaces API/web
listeners; use it only during a coordinated maintenance window.

Go integration tests need a Postgres they can create databases on:

```sh
TEST_DATABASE_URL=postgres://lazyagents:lazyagents@localhost:5432/lazyagents?sslmode=disable make test
```

### Playgrounds

A coding chat can hand you the app it's building, running, instead of steps to
run it. The agent calls `start_playground` with the app's processes (command,
directory, port), setup commands (install, migrate, seed), routes when the UI
and API are separate processes, and optionally an OpenAPI document. Services
default to the repository's test environment and always start empty. The chat
shows a card; **Open** puts the playground beside the chat, and it goes full
screen like a canvas.

- **Preview** frames the app. Log in to it as you would anywhere: its cookies
  work in the frame.
- **API** reads the OpenAPI document the agent named (Vesper's own is
  `api/openapi.yaml`), lists its operations by tag, fills a request body from
  the schema, warns where a body doesn't match it (without stopping you sending
  it), and sends from the app's own origin with your Preview session. The log
  lines written while a request ran show under its response.
- **Logs** streams every container's output: setup, each process and each
  service.
- **Reset data** starts every service empty and runs setup again; the code is
  untouched. **Stop** removes it all; **Start again** reruns the last spec in
  the chat's current workspace.

The runner serves each playground on a port of its own on Vesper's host
(`RUNNER_PLAYGROUND_PORTS`, `8090-8094` in both compose files; one playground
per port) and admits only a browser signed in to Vesper there: same host, so
the browser sends the Vesper session, which the runner checks and never passes
on to the app. A playground stops after `RUNNER_PLAYGROUND_IDLE_S` unused (30
minutes by default), when its chat's workspace is cleaned up, and when the
runner restarts. Its processes run in the turn's sandbox from the chat's
workspace, so they reload on the agent's edits if the app watches for changes,
but they don't get the agent's credentials, home directory or tools it
installed with Nix during the chat. The fake backend has no playgrounds.
[docs/dev/playgrounds.md](dev/playgrounds.md) has the design and its
trade-offs.

## Layout

| Path | What |
|---|---|
| `api/openapi.yaml` | REST contract. Go server interfaces and the TS client are generated from it. |
| `server/` | Go module: the `vesper` binary (`serve`, `runner`, `migrate`) |
| `server/internal/harness/` | Claude Code, Codex and Antigravity adapters: invocation and stream parsing |
| `server/internal/runner/` | Queue, workspaces (Docker or local), turns, guards |
| `deploy/agent-base/` | The image managed runs execute in |
| `server/migrations/` | goose SQL, embedded and applied on boot |
| `server/internal/store/queries/` | SQL for sqlc. `internal/store` is generated. |
| `server/internal/tracker/` | Ticket domain service; every change writes its activity event in the same transaction |
| `web/` | Next.js app: a pure UI client of the API |
| `deploy/` | Caddy and SeaweedFS config |

Agents can continue automatically when a provider's usage or rate limit is
reached. Add an ordered list under **Usage fallbacks** in the agent definition
editor, or set `fallbacks` in the definition API:

```json
{
  "harness": "claude-code",
  "model": "your-primary-model",
  "fallbacks": [
    {"harness": "codex", "model": "your-codex-model"}
  ]
}
```

Each target requires a harness and model; optional `harness_options` apply only
to that target. Configure credentials for every harness. Targets are tried once, in order, only for provider quota/rate-limit
errors. Other errors still fail the run. The same checkout, plan and accumulated
usage are retained; the next harness starts a fresh session with the original
task, recent inputs and last assistant message. Full conversation state is not
transferred between harnesses. Existing turn/runtime guards still apply. When
all targets are exhausted the run fails, and each switch appears as a
`harness_fallback` lifecycle event. Definition changes apply to new runs.

Both harness adapters now use the same run-scoped tool policy: native tool hooks
check the frozen scopes before execution. Denied actions are blocked. Actions
requiring approval pause the run and appear in the existing approval UI; a yes
authorizes that exact tool input once, and the resumed turn retries it. Planning
runs permit context reads (including simple read-only shell commands) and block
project command execution and edits. The authenticated
policy endpoint is `POST /api/v1/agent/tool-policy` and accepts `{tool, input}`;
it requires a token bound to the running agent's run and returns `allow` or
`deny`. A policy outage blocks the tool rather than permitting it.

Codex performs an offline hook preflight before each new or resumed turn. It
checks that the generated service hook has an absolute path, can execute from
the workspace, and can reach the authenticated run policy before loading a model.
It also checks that the hook is loaded and refuses to run if another
active hook is unreviewed. Only then does it use Codex's automation hook-trust
flag. It does not disable the sandbox or shell approval policy. Like the CLI's
own tool rules, hooks provide best-effort enforcement, not isolation from a
malicious program; Docker remains the isolation boundary. `python3` is required by both adapters and is
included in the runner image.

Antigravity has no hook-listing command to preflight with. Its turns fail closed a
different way: `agy` only runs what the deny rules, the allow rules for Vesper's own
tools and the policy hook leave it, so a hook that doesn't load leaves a turn able
to do (almost) nothing. Both layers were verified against agy 1.5.8: the deny
rules hold even when the hook approves. See [contracts/antigravity.md](contracts/antigravity.md)
and its decision record [contracts/ADR-antigravity.md](contracts/ADR-antigravity.md),
including what still needs a real Gemini key to settle (image generation).

### Antigravity

Antigravity (`agy`) runs on a **Gemini API key**, stored as `harness:google`. Google's
terms don't let a tool extract or store the OAuth login `agy` keeps, so Vesper never
reads it: there is no plan login and no sign-in button, and the Welcome Wizard shows a
key field only. The agent image installs `agy` at build time from its pinned
release tarball and SHA-512 checksum (`AGY_RELEASE`, `AGY_SHA512_AMD64`,
`AGY_SHA512_ARM64`; set `--build-arg INSTALL_ANTIGRAVITY=false` to leave it out).
It reports tokens but no cost and no plan allowance, so its runs show an unknown cost
and the activity orb shows "Usage unknown". It is an image engine like Codex:
**Settings → Image engine** picks Codex, Antigravity or Auto, a persona can override
it, and a workflow image step can name one.

Repository-authorized Codex turns use a workspace permission profile that also
allows writes to `.git`, so staging and committing work headlessly. Planning
and runs without repository write authorization retain their sandbox settings.
Local macOS runners append Homebrew's binary directories to PATH so installed
tools such as `gh` are available even when launched from a desktop application.

Skills use native discovery on both CLIs: `.claude/skills/<name>/SKILL.md` for
Claude Code and `.agents/skills/<name>/SKILL.md` for Codex. Generated skill files
are excluded from git. Cross-harness fallbacks include a bounded transcript of
recent messages, tool calls and outcomes, and approval decisions; CLI-private
session files and internal reasoning are not portable.

Cost displays distinguish known, unknown and partially priced totals instead of
showing unpriced usage as free. Native reported costs take precedence when
available. Codex prices tokens using the built-in model table or the optional
`RUNNER_MODEL_PRICES` JSON object, keyed by exact model id. Each entry must include
nonnegative `input_per_million`, `cached_input_per_million`, and
`output_per_million` USD rates. Supply your provider's applicable rates; no price
is inferred for an unknown model. Aggregates identify windows containing
unpriced runs. The migration also marks older unpriced turns as unknown/partial.

**Runs → Highlights** summarizes routing across your own persona chats. Filter by
project, UTC date range, replying persona, or Auto effort only. It shows requested
and actual effort, model usage, reasons effort was raised, and average turn time
(including tools, excluding queue time). Each turn counts once on its first reply's
UTC date. Legacy replies without turn metadata count individually as unclassified;
unknown persona, model and effort remain explicit. Model usage does not identify
whether the model was selected automatically. Unlike Costs, Highlights excludes
other people's chats and non-chat runs.

Codex session-total token counters are normalized to per-turn deltas on resume,
so resumed turns do not bill earlier usage twice. The migration repairs older
turns where recorded lifecycle events identify the Codex session; original usage
JSON is retained on those turns for audit.

## Workflows

A workflow is a fixed graph of steps that Vesper runs for you. Build one under **Workflows** by dragging nodes on the canvas, or describe it in the box at the bottom of the canvas: a persona proposes edits, previewed on the canvas until you apply them. Publishing freezes a version; runs in flight keep the version they started with.

Node types are a trigger, **Enrich prompt**, **Agent step** (read-only; a step that reads the web can't read the workspace), **Human gate** and the outputs **Add to wiki**, **Add to library**, **Create ticket** and **Post to chat**. Wiki writes need a gate before them. "Request changes" at a gate re-runs an earlier step as a new attempt, so the graph never loops.

An agent step with **Generate images** on makes pictures. It always runs on Codex, whatever harness the chat uses, as its own persona or else the chat's, which must be allowed to generate images. It can make up to 4 per attempt and fails, with the reason, if it makes none. Later agent steps see the images directly (on Claude Code or Codex), and a step that makes none passes on what it received, so a text-only check can sit between the image and its gate. Gates show them, and every attempt stays in the run view. **Post to chat** shows the image inline and **Add to library** saves it as an image. **Add to wiki** and **Create ticket** are text only and leave images out.

Start one from a chat with `/workflow`, or ask for it in your own words: the persona recognizes a published workflow from its name and description and offers a card to confirm. Nothing runs until you confirm. Open gates appear above the message box and in the Inbox.
