# Vesper: notes for agents

## Trying Vesper in a playground

To let the person click through a change (UI or API), start a playground with
`start_playground` instead of describing how to run it. Run Vesper in
**no sign-in mode** (`VESPER_NO_SIGNIN=1`). A playground can't do the normal
sign-in: `make signin` needs a shell the person doesn't have, and the
playground gateway keeps the `vesper_session` cookie for the outer Vesper.

```json
{
  "services": [
    { "name": "postgres", "image": "postgres:17-alpine",
      "env": { "POSTGRES_USER": "lazyagents", "POSTGRES_PASSWORD": "lazyagents", "POSTGRES_DB": "lazyagents" },
      "healthcheck": ["CMD-SHELL", "pg_isready -U lazyagents -d lazyagents"] },
    { "name": "s3", "image": "chrislusf/seaweedfs:4.48",
      "command": ["server", "-s3", "-dir=/data", "-ip.bind=0.0.0.0", "-master.volumeSizeLimitMB=64"],
      "tmpfs": ["/data"], "healthcheck": ["CMD-SHELL", "nc -z 127.0.0.1 8333"] }
  ],
  "setup": [
    "(cd web && { [ -d node_modules ] || npm ci; })",
    "(mkdir -p .lazyagents/pgbin && cd server && go build -o ../.lazyagents/pgbin/vesper ./cmd/vesper && go build -o ../.lazyagents/pgbin/fake-harness ./cmd/fake-harness)",
    "(cd .lazyagents/pgbin && ln -sf fake-harness claude && ln -sf fake-harness codex && ln -sf fake-harness agy)"
  ],
  "processes": [
    { "name": "api", "dir": "server", "port": 8000,
      "command": "(until curl -sf http://localhost:8000/api/v1/health >/dev/null; do sleep 1; done; exec /workspace/.lazyagents/pgbin/vesper runner) & exec /workspace/.lazyagents/pgbin/vesper serve",
      "env": { "DATABASE_URL": "postgres://lazyagents:lazyagents@postgres:5432/lazyagents?sslmode=disable",
               "S3_ENDPOINT": "http://s3:8333", "API_ADDR": "0.0.0.0:8000", "VESPER_NO_SIGNIN": "1",
               "RUNNER_BACKEND": "fake", "RUNNER_MCP_URL": "http://localhost:8000/mcp", "RUNNER_DATA_DIR": "/tmp/runs",
               "RUNNER_CLAUDE_BIN": "/workspace/.lazyagents/pgbin/claude", "RUNNER_CODEX_BIN": "/workspace/.lazyagents/pgbin/codex",
               "RUNNER_ANTIGRAVITY_BIN": "/workspace/.lazyagents/pgbin/agy",
               "FAKE_HARNESS_MODE": "chat-read" } },
    { "name": "web", "dir": "web", "port": 3000, "command": "npm run dev -- -H 0.0.0.0 -p 3000",
      "env": { "API_INTERNAL_URL": "http://api:8000" } }
  ],
  "routes": [
    { "path": "/api", "process": "api" },
    { "path": "/events", "process": "api" },
    { "path": "/mcp", "process": "api" },
    { "path": "/", "process": "web" }
  ],
  "openapi": "api/openapi.yaml"
}
```

- Keep the `/` route: a path no route matches goes to the first process,
  which is `api`, so without it the pages come from the Go API.
- `VESPER_NO_SIGNIN=1` serves the API as the seeded local user with no
  session. The API refuses to start with it unless `PUBLIC_URL` is a
  loopback address, which the default (`http://localhost:8080`) is. Never set
  it anywhere but a disposable local instance.
- Leave `SECRETS_KEY` unset: secrets are then off, which a throwaway instance
  doesn't need.
- The inner Vesper has a runner (`vesper runner`, fake backend), started in
  the api container once the API is healthy: a process needs a port, and the
  runner listens on none. Its `claude`, `codex` and `agy` are the repository's
  `fake-harness` (it speaks agy only when its name is `agy`), so chats get canned replies through the real MCP path and
  no credentials enter the playground. Change `FAKE_HARNESS_MODE` for other
  scripts (see `server/cmd/fake-harness/main.go`).
- Wrap each setup command in `( … )` so a `cd` stays inside it, and keep each
  process's `dir` one that already exists: Docker creates a missing one as
  root, and nothing can write there afterwards.
- The first start compiles the API and starts `next dev`, which takes a few
  minutes. Call `playground_status` until it's running, and read `log` if it
  failed.

## Export and import (adding tables and buckets)

`vesper export` / `vesper import` (`server/internal/transfer`) move a whole
instance. They read the Postgres catalog and the S3 bucket listing, so **a new
table or bucket is exported with no code change**. Don't add it to a list.

- To keep a table out (a cache, a session, anything tied to this machine), add
  it to `excluded` in `server/internal/transfer/schema.go` **with the reason**.
  `TestEveryTableIsExportedOrExcluded` fails for a table that is neither.
- Foreign-key cycles are handled by deferring one key; a new cycle needs nothing.
- A migration that rewrites existing rows works on imported data too: import
  loads rows at the archive's schema version, then runs the newer migrations.
- A new bucket needs nothing, but add it to the `S3_BUCKETS` default so export
  finds it on stores that won't list buckets.
- The real-store test runs when `TEST_S3_ENDPOINT` is set (dev compose
  SeaweedFS); the rest run on `TEST_DATABASE_URL` alone.

## Running the server tests

Database tests need `TEST_DATABASE_URL` (a Postgres server they may create
databases on); inside a Vesper run or on CI they fail without it rather than
skip.

- The whole server suite (`go test ./...` in `server`) takes about 4–5
  minutes on a laptop, almost all of it in `internal/runner` and
  `internal/httpapi`. While iterating, run only the package you changed,
  narrowed with `-run` in those two:
  `go test ./internal/runner -run 'TestChatAside'`. Run the full suite once,
  at the end.
- `testdb.New` clones a database migrated once per test binary, so a new
  migration needs no test changes. Use `testdb.NewUnmigrated` for a test that
  runs migrations itself.
- Runner tests get the fake harness from `setup`, built once per test binary.
  Don't `go build` it in a test.
- A runner test that leaves a turn running (e.g. a held chat) must release it:
  `setup`'s cleanup waits up to 30s for in-flight turns, then fails the test.
