#!/usr/bin/env bash
# Real-stack e2e: Go API + runner (RUNNER_BACKEND=fake) +
# Postgres + a local blob directory + Next, with the deterministic fake-harness binary
# standing in for `claude`, `codex` and `agy`. See README.md.
#
# Usage: web/e2e-stack/run.sh [playwright args...]
# Env:   E2E_DATABASE_URL  use this (disposable!) Postgres instead of starting one
#                          (default: a local Postgres 17 from the app's bundle, scripts/dev-postgres.sh)
#        E2E_STACK_SETUP_ONLY=1  start the stack, print URLs, wait (no Playwright)
#        E2E_FAKE_HARNESS_MODE   the fake CLIs' mode for the whole run (default chat-read). A run
#                          with no mode and no playwright args also restarts the runner in
#                          design-review and runs the @design-review specs (designs-review.spec.ts)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WEB="$(cd "$HERE/.." && pwd)"
REPO="$(cd "$WEB/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/vesper-e2e-stack.XXXXXX")"
PIDS=()
PG_STARTED=

cleanup() {
  local code=$?
  set +e
  for pid in "${PIDS[@]:-}"; do [ -n "$pid" ] && kill "$pid" 2>/dev/null; done
  sleep 1
  for pid in "${PIDS[@]:-}"; do [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null; done
  [ -n "$PG_STARTED" ] && DEV_PG_DIR="$TMP/pg" DEV_PG_PORT="$PG_PORT" "$REPO/scripts/dev-postgres.sh" stop >/dev/null 2>&1
  if [ $code -ne 0 ] && [ -d "$TMP/logs" ]; then
    echo "--- stack failed (exit $code); log tails from $TMP/logs ---" >&2
    for f in "$TMP"/logs/*.log; do echo "== $f" >&2; tail -n 25 "$f" >&2; done
  fi
  [ -n "${E2E_KEEP_TMP:-}" ] || rm -rf "$TMP"
  exit $code
}
trap cleanup EXIT INT TERM
mkdir -p "$TMP/logs" "$TMP/bin" "$TMP/runs"

free_port() { node -e 'const s=require("net").createServer().listen(0,"127.0.0.1",()=>{console.log(s.address().port);s.close()})'; }
wait_for() { # url, label, seconds
  local i
  for ((i = 0; i < $3; i++)); do curl -s -o /dev/null "$1" && return 0; sleep 1; done
  echo "timed out waiting for $2 ($1)" >&2
  return 1
}

API_PORT="$(free_port)"; WEB_PORT="$(free_port)"
# The design worker (renders and layouts for the Go API) is the web app's /internal/designs, behind a shared token.
DESIGN_WORKER_TOKEN="$(head -c 24 /dev/urandom | base64 | tr -d '/+=')"
API_URL="http://127.0.0.1:$API_PORT"
WEB_URL="http://127.0.0.1:$WEB_PORT"

# --- Fake CLIs and the PATH guard ------------------------------------------
echo ">> building fake-harness and vesper"
(cd "$REPO/server" && go build -o "$TMP/fake-harness" ./cmd/fake-harness && go build -o "$TMP/vesper" ./cmd/vesper)
for cli in claude codex agy; do ln -s "$TMP/fake-harness" "$TMP/bin/$cli"; done
GIT_BIN="$(command -v git)" || { echo "git is required" >&2; exit 1; }
ln -s "$GIT_BIN" "$TMP/bin/git"
# The API and runner see ONLY this PATH: the fake CLIs, git, and system dirs.
# Real CLIs live in ~/.local/bin, ~/.nix-profile/bin, /opt/homebrew/bin: refuse
# to start if any of them could be found from here.
SAFE_PATH="$TMP/bin:/usr/bin:/bin"
for cli in claude codex agy; do
  found="$(PATH="$SAFE_PATH" command -v "$cli" || true)"
  if [ "$found" != "$TMP/bin/$cli" ]; then
    echo "PATH GUARD: '$cli' resolves to '${found:-nothing}' instead of $TMP/bin/$cli; refusing to start (a real CLI could run)" >&2
    exit 1
  fi
done

# --- Postgres ----------------------------------------------------------------
if [ -n "${E2E_DATABASE_URL:-}" ]; then
  DATABASE_URL="$E2E_DATABASE_URL"
else
  PG_PORT="$(free_port)"
  echo ">> starting disposable postgres on :$PG_PORT"
  export DEV_PG_DIR="$TMP/pg" DEV_PG_PORT="$PG_PORT"
  PG_STARTED=1
  "$REPO/scripts/dev-postgres.sh" start >/dev/null
  DATABASE_URL="$("$REPO/scripts/dev-postgres.sh" url)"
fi

# --- API and runner -------------------------------------------------------------
# Same env for both. Every harness binary is the fake.
mkdir -p "$TMP/home"
# One key for both processes (secrets are encrypted with it).
SECRETS_KEY="$(head -c 32 /dev/urandom | base64)"
stack_env() {
  exec env -i HOME="$TMP/home" PATH="$SAFE_PATH" TMPDIR="$TMP" \
    API_ADDR="127.0.0.1:$API_PORT" DATABASE_URL="$DATABASE_URL" \
    BLOB_DIR="$TMP/blobs" SEED=false PR_SYNC_INTERVAL_S=0 \
    SECRETS_KEY="$SECRETS_KEY" PUBLIC_URL="$WEB_URL" \
    RUNNER_BACKEND=fake RUNNER_DATA_DIR="$TMP/runs" RUNNER_MCP_URL="$API_URL/mcp" \
    RUNNER_CLAUDE_BIN="$TMP/bin/claude" RUNNER_CODEX_BIN="$TMP/bin/codex" RUNNER_ANTIGRAVITY_BIN="$TMP/bin/agy" \
    DESIGN_WORKER_URL="$WEB_URL/internal/designs" DESIGN_WORKER_TOKEN="$DESIGN_WORKER_TOKEN" \
    FAKE_HARNESS_MODE="${HARNESS_MODE:-chat-read}" "$@"
}

echo ">> starting api on :$API_PORT (runs migrations and first-boot seed)"
stack_env "$TMP/vesper" serve >"$TMP/logs/api.log" 2>&1 &
PIDS+=($!)
wait_for "$API_URL/api/v1/health" api 120
echo ">> starting runner"
HARNESS_MODE="${E2E_FAKE_HARNESS_MODE:-chat-read}"
stack_env "$TMP/vesper" runner >"$TMP/logs/runner.log" 2>&1 &
RUNNER_PID=$!
PIDS+=($!)

# The API serves only signed-in browsers. Sign in the way a person does (a
# one-time code from the CLI, spent on a session cookie) and hand the cookie
# to curl here and to Playwright's browser and request contexts.
CODE="$(stack_env "$TMP/vesper" sign-in-link -code)"
curl -fsS -o /dev/null -c "$TMP/session.jar" "$API_URL/api/v1/sign-in?code=$CODE"
SESSION="$(awk '$6 == "vesper_session" { print $7 }' "$TMP/session.jar")"
[ -n "$SESSION" ] || { echo "sign-in set no session cookie" >&2; exit 1; }
SIGNED_IN=(-b "vesper_session=$SESSION")
# Cookies ignore the port, so one cookie on 127.0.0.1 covers web and API.
printf '{"cookies":[{"name":"vesper_session","value":"%s","domain":"127.0.0.1","path":"/","expires":-1,"httpOnly":true,"secure":false,"sameSite":"Strict"}],"origins":[]}\n' \
  "$SESSION" >"$TMP/storage-state.json"

# Chats are project-scoped and a fresh workspace has none.
curl -fsS "${SIGNED_IN[@]}" -X POST "$API_URL/api/v1/projects" -H 'content-type: application/json' \
  -d '{"key":"E2E","name":"E2E stack","color":"#6366f1","repo_url":"git@github.com:example/e2e-stack.git","default_branch":"main"}' >/dev/null
# ...and a main agent to chat with (SEED=false creates no agents).
curl -fsS "${SIGNED_IN[@]}" -X POST "$API_URL/api/v1/agents" -H 'content-type: application/json' \
  -d '{"handle":"e2e-main","name":"E2E main","kind":"main"}' >/dev/null
CATALOG="$(curl -fsS "${SIGNED_IN[@]}" "$API_URL/api/v1/chat-models")"
for want in 'Claude Sonnet (fake)' 'GPT-5 Codex (fake)' 'gemini-3.8-flash'; do
  grep -q "$want" <<<"$CATALOG" || { echo "chat-models catalog lacks '$want': $CATALOG" >&2; exit 1; }
done

# --- Web ---------------------------------------------------------------------------
echo ">> building and starting web on :$WEB_PORT"
(cd "$WEB" && API_INTERNAL_URL="$API_URL" DESIGN_WORKER_TOKEN="$DESIGN_WORKER_TOKEN" npm run build >"$TMP/logs/web-build.log" 2>&1)
(cd "$WEB" && exec env API_INTERNAL_URL="$API_URL" DESIGN_WORKER_TOKEN="$DESIGN_WORKER_TOKEN" STATIC_DIR=dist PORT="$WEB_PORT" HOSTNAME=127.0.0.1 node dist/design-worker/server.mjs) >"$TMP/logs/web.log" 2>&1 &
PIDS+=($!)
wait_for "$WEB_URL/chat" web 60

echo ">> stack up: web $WEB_URL api $API_URL"
if [ -n "${E2E_STACK_SETUP_ONLY:-}" ]; then
  echo "setup only: Ctrl-C to tear down"; wait; exit 0
fi
cd "$WEB"
pw() {
  E2E_FAKE_HARNESS_MODE="$HARNESS_MODE" E2E_STACK_BASE_URL="$WEB_URL" E2E_STACK_API_URL="$API_URL" E2E_STACK_STORAGE_STATE="$TMP/storage-state.json" npx playwright test -c playwright.stack.config.ts "$@"
}
if [ -n "${E2E_FAKE_HARNESS_MODE:-}" ] || [ $# -gt 0 ]; then
  pw "$@"
else
  # Specs that need another script run after the rest, once the runner is restarted in that mode.
  code=0
  pw --grep-invert @design-review || code=$?
  kill "$RUNNER_PID" 2>/dev/null || true
  wait "$RUNNER_PID" 2>/dev/null || true
  HARNESS_MODE=design-review
  stack_env "$TMP/vesper" runner >"$TMP/logs/runner-design-review.log" 2>&1 &
  PIDS+=($!)
  sleep 2
  pw --grep @design-review || code=$?
  exit $code
fi
