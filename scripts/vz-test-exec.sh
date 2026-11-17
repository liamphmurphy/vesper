#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
entitlements="${repo_root}/deploy/microvm/vz.entitlements"

if [[ $# -eq 0 ]]; then
  echo "usage: $0 <binary> [args...]" >&2
  exit 2
fi

bin="$1"
codesign --sign - --force --entitlements "${entitlements}" "${bin}" >/dev/null
exec "$@"
