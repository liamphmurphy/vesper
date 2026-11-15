#!/usr/bin/env bash
# Sets up and starts Vesper with hardened agent containers. See `make start`.
set -euo pipefail
cd "$(dirname "$0")/.."

IMAGE=${RUNNER_IMAGE:-vesper/agent-base:latest}
API_PORT=${API_PORT:-8000}
API=http://localhost:$API_PORT/api/v1
# The session cookie this script signs in with (see api_curl).
SESSION_JAR=$(mktemp)
trap 'rm -f "$SESSION_JAR"' EXIT

need() {
  for tool in "$@"; do
    command -v "$tool" >/dev/null || { echo "vesper: $tool is required" >&2; exit 1; }
  done
}

setup() {
  need docker openssl python3 curl
  docker info >/dev/null 2>&1 || { echo "vesper: Docker isn't running" >&2; exit 1; }
  [ -f .env ] || cp .env.example .env
  # Never replace a key: secrets encrypted with it would become unreadable.
  if [ -z "${SECRETS_KEY:-}" ] && ! grep -q '^SECRETS_KEY=.' .env; then
    key=$(openssl rand -base64 32)
    python3 -c 'import sys
s = open(".env").read().replace("\nSECRETS_KEY=\n", "\nSECRETS_KEY=" + sys.argv[1] + "\n", 1)
open(".env", "w").write(s if sys.argv[1] in s else s + "\nSECRETS_KEY=" + sys.argv[1] + "\n")' "$key"
    echo "vesper: generated SECRETS_KEY in .env. Keep it: stored secrets need it."
  fi
  docker build -q -t "$IMAGE" deploy/agent-base >/dev/null
  echo "vesper: agent image $IMAGE is ready"
}

# curl for the person-facing API, which serves only signed-in browsers. The
# script signs in the way a person does: a one-time code from the CLI (it
# reads the dev database directly), spent on a session cookie.
api_curl() {
  if ! grep -q vesper_session "$SESSION_JAR"; then
    code=$(cd server && go run ./cmd/vesper sign-in-link -code)
    curl -fsS -o /dev/null -c "$SESSION_JAR" "$API/sign-in?code=$code"
    grep -q vesper_session "$SESSION_JAR" || { echo "vesper: couldn't sign in to the API" >&2; return 1; }
  fi
  curl -b "$SESSION_JAR" "$@"
}

has_secret() { api_curl -fsS "$API/secrets" | grep -q "\"name\":\"$1\""; }

# Reads the value on stdin so it never appears in a process list.
store_secret() {
  python3 -c 'import json, sys; print(json.dumps({"name": sys.argv[1], "value": sys.stdin.read().strip()}))' "$1" |
    api_curl -fsS -o /dev/null -X PUT -H 'Content-Type: application/json' --data-binary @- "$API/secrets"
  echo "vesper: stored $1"
}

require_api() {
  curl -fsS -o /dev/null "$API/health" || { echo "vesper: the API isn't running on :$API_PORT (start it with make dev)" >&2; exit 1; }
}

valid_claude_auth() {
  python3 -c 'import json, sys
a = json.load(open(sys.argv[1])).get("claudeAiOauth", {})
sys.exit(0 if a.get("accessToken") and a.get("refreshToken") else 1)' "$1" 2>/dev/null
}

login_claude() {
  need docker python3 curl tar
  require_api
  auth=$(mktemp)
  if [ -n "${CLAUDE_AUTH_FILE:-}" ]; then
    cp "${CLAUDE_AUTH_FILE/#\~/$HOME}" "$auth"
  else
    echo "vesper: open the URL below, sign in, and paste the code back here."
    name=vesper-claude-login-$$
    docker run -it --name "$name" "$IMAGE" sh -c 'stty cols 2000; exec claude auth login --claudeai' || true
    docker cp "$name:/home/node/.claude/.credentials.json" - 2>/dev/null | tar -xO > "$auth" || true
    docker rm -f "$name" >/dev/null 2>&1 || true
  fi
  if ! valid_claude_auth "$auth"; then
    rm -f "$auth"
    echo "vesper: no Claude subscription login was captured. Run: CLAUDE_AUTH_FILE=~/.claude/.credentials.json make claude-login" >&2
    return 1
  fi
  store_secret harness:anthropic < "$auth"
  rm -f "$auth"
}

valid_codex_auth() {
  python3 -c 'import json, sys
a = json.load(open(sys.argv[1]))
sys.exit(0 if a.get("auth_mode") == "chatgpt" and a.get("tokens", {}).get("refresh_token") else 1)' "$1" 2>/dev/null
}

login_codex() {
  need docker python3 curl tar
  require_api
  auth=$(mktemp)
  if [ -n "${CODEX_AUTH_FILE:-}" ]; then
    cp "${CODEX_AUTH_FILE/#\~/$HOME}" "$auth"
  else
    echo "vesper: open the URL below and enter the code to sign in to ChatGPT."
    name=vesper-codex-login-$$
    docker run -it --name "$name" "$IMAGE" sh -c "stty cols 2000; exec codex login --device-auth -c 'cli_auth_credentials_store=\"file\"'" || true
    docker cp "$name:/home/node/.codex/auth.json" - 2>/dev/null | tar -xO > "$auth" || true
    docker rm -f "$name" >/dev/null 2>&1 || true
  fi
  if ! valid_codex_auth "$auth"; then
    rm -f "$auth"
    echo "vesper: no ChatGPT login was captured. If device sign-in is off for your account, enable it in ChatGPT's security settings, or run: CODEX_AUTH_FILE=~/.codex/auth.json make codex-login" >&2
    return 1
  fi
  store_secret harness:openai < "$auth"
  rm -f "$auth"
}

warn() {
  printf '\n\033[1;33mvesper: %s\033[0m\n' "$1" >&2
  shift
  for line in "$@"; do printf '  %s\n' "$line" >&2; done
  echo >&2
}

# Stores the GitHub CLI's token as git:pat. An SSH key alone doesn't cover it:
# https repositories and gh (pull requests) need the token. With "ask", an
# existing git:pat is kept; "login" offers to replace it.
offer_github_token() {
  mode=${1:-ask}
  require_api
  if has_secret git:pat; then
    [ "$mode" = login ] || return 0
    read -rp "vesper: replace the stored GitHub token (git:pat) with your GitHub CLI token? [y/N] " answer
    case $answer in [yY]*) ;; *) return 0 ;; esac
  elif ! { command -v gh >/dev/null && gh auth token >/dev/null 2>&1; }; then
    warn "agents have no GitHub token, so they can't push to https repos or open pull requests." \
      "Sign in with: gh auth login   then run: make github-login" \
      "Or add a token in Settings → Connections & secrets → GitHub token."
    return 0
  else
    read -rp "vesper: give agents your GitHub CLI token as git:pat so they can push and open PRs? [y/N] " answer
    case $answer in [yY]*) ;; *)
      warn "skipped the GitHub token: agents can't push to https repos or open PRs." "Add it later with: make github-login"
      return 0 ;;
    esac
  fi
  command -v gh >/dev/null && gh auth token >/dev/null 2>&1 || { echo "vesper: gh isn't signed in (run gh auth login first)" >&2; return 1; }
  gh auth token | store_secret git:pat
}

start() {
  setup
  make --no-print-directory dev-infra stop-dev
  # The runner is a container: stop it with everything else, not just its log tail.
  trap 'docker compose -f docker-compose.dev.yml --profile runner stop runner >/dev/null 2>&1; rm -f "$SESSION_JAR"; kill 0' EXIT
  if [ -n "$(docker ps -q --filter label=com.docker.compose.project=lazyagents --filter label=com.docker.compose.service=runner)" ]; then
    warn "the full stack's runner (docker compose up) is also running." \
      "It serves a different database, so it won't take these runs, but it uses Docker resources." \
      "Stop it with: make down"
  fi
  make --no-print-directory api &
  echo "vesper: waiting for the API on :$API_PORT"
  for _ in $(seq 1 120); do
    curl -fsS -o /dev/null "$API/health" 2>/dev/null && break
    sleep 1
  done
  require_api
  # A failed sign-in leaves that harness unavailable; the rest still starts.
  has_secret harness:anthropic || login_claude || echo "vesper: skipped Claude. Retry with make claude-login."
  has_secret harness:openai || login_codex || echo "vesper: skipped Codex. Retry with make codex-login."
  offer_github_token
  make --no-print-directory web &
  make --no-print-directory runner &
  echo "vesper: running at http://localhost:${WEB_PORT:-3000}. Ctrl-C stops it all."
  echo "vesper: open it and sign in, or choose a username and password on first run. Locked out? make signin prints a one-time link."
  wait
}

case ${1:-} in
  setup) setup ;;
  start) start ;;
  login-claude) login_claude ;;
  login-codex) login_codex ;;
  login-github) offer_github_token login ;;
  *) echo "usage: $0 setup|start|login-claude|login-codex|login-github" >&2; exit 2 ;;
esac
