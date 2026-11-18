#!/usr/bin/env bash
# A local Postgres 17 for development and the real-stack e2e, run from the
# relocatable bundle the macOS app embeds (scripts/bundle-postgres-darwin.sh).
#
# Usage: scripts/dev-postgres.sh start|stop|status|psql [psql args...]|url
#   start   initialise the data directory on first use, start the server, and
#           create the lazyagents database. Safe to repeat.
#   stop    stop the server (data is kept).
#   url     print the DATABASE_URL for it.
# Env:
#   DEV_PG_DIR     where pgdata/ and postgres.log live (default <repo>/.dev)
#   DEV_PG_PORT    TCP port on 127.0.0.1 (default 5432)
#   DEV_PG_BUNDLE  the bundle to run (default desktop/resources/postgres if
#                  it's staged, else <repo>/.dev/postgres, built on first use)
# Trust auth on a loopback port: for disposable local data only.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIR="${DEV_PG_DIR:-$ROOT/.dev}"
PORT="${DEV_PG_PORT:-5432}"
PGDATA="$DIR/pgdata"
PGUSER_NAME=lazyagents
PGDB=lazyagents

bundle() {
  if [[ -n "${DEV_PG_BUNDLE:-}" ]]; then
    echo "$DEV_PG_BUNDLE"
  elif [[ -x "$ROOT/desktop/resources/postgres/bin/postgres" ]]; then
    echo "$ROOT/desktop/resources/postgres"
  else
    echo "$ROOT/.dev/postgres"
  fi
}

ensure_bundle() {
  local b
  b="$(bundle)"
  if [[ ! -x "$b/bin/postgres" ]]; then
    echo "building the Postgres bundle into $b (needs nix; macOS only)..." >&2
    "$ROOT/scripts/bundle-postgres-darwin.sh" "$b" >&2
  fi
  echo "$b"
}

# The bundle's binaries find their libraries relative to themselves.
pg() { local tool="$1"; shift; env -i PATH=/usr/bin:/bin HOME="$HOME" "$B/bin/$tool" "$@"; }

cmd="${1:-}"
[[ $# -gt 0 ]] && shift
case "$cmd" in
  url)
    echo "postgres://$PGUSER_NAME:$PGUSER_NAME@127.0.0.1:$PORT/$PGDB?sslmode=disable"
    ;;
  start)
    B="$(ensure_bundle)"
    mkdir -p "$DIR"
    if [[ ! -f "$PGDATA/PG_VERSION" ]]; then
      pg initdb -D "$PGDATA" --username="$PGUSER_NAME" --auth=trust --encoding=UTF8 --locale=C --no-instructions >/dev/null
    fi
    if ! pg pg_isready -h 127.0.0.1 -p "$PORT" >/dev/null 2>&1; then
      pg pg_ctl -D "$PGDATA" -l "$DIR/postgres.log" -w \
        -o "-c listen_addresses=127.0.0.1 -c port=$PORT -c unix_socket_directories=" start >/dev/null
    fi
    if [[ "$(pg psql -h 127.0.0.1 -p "$PORT" -U "$PGUSER_NAME" -d postgres -qtAc "SELECT 1 FROM pg_database WHERE datname = '$PGDB'")" != 1 ]]; then
      pg psql -h 127.0.0.1 -p "$PORT" -U "$PGUSER_NAME" -d postgres -qc "CREATE DATABASE $PGDB" >/dev/null
    fi
    echo "postgres ready: $("$0" url)"
    ;;
  stop)
    B="$(ensure_bundle)"
    if [[ -f "$PGDATA/postmaster.pid" ]]; then
      pg pg_ctl -D "$PGDATA" -m fast -w stop >/dev/null
    fi
    ;;
  status)
    B="$(ensure_bundle)"
    pg pg_isready -h 127.0.0.1 -p "$PORT"
    ;;
  psql)
    B="$(ensure_bundle)"
    pg psql -h 127.0.0.1 -p "$PORT" -U "$PGUSER_NAME" -d "$PGDB" "$@"
    ;;
  *)
    echo "usage: $0 start|stop|status|psql [args]|url" >&2
    exit 2
    ;;
esac
