#!/usr/bin/env bash
# Replace /Applications/Vesper.app with the freshly built DMG and relaunch it.
# Run through `make desktop-reinstall`, which builds the VM image and the DMG
# first. Safe to rerun: it quits Vesper normally (never force-kills), stops a
# Postgres the app left running, keeps the previous app until the copy works,
# then waits for the new app to serve and to install the bundled VM image.
#
#   VESPER_REINSTALL_NO_LAUNCH=1   install only, don't relaunch
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
dmg="${repo_root}/desktop/release/Vesper-arm64.dmg"
app="/Applications/Vesper.app"
bundle_id="com.vesper.desktop"
data_dir="${HOME}/Library/Application Support/vesper-desktop"
backup="${HOME}/.cache/vesper/Vesper.app.previous"
health_url="http://127.0.0.1:8080/api/v1/health"

log() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == Darwin ]] || die "macOS only"
[[ -f "${dmg}" ]] || die "${dmg} not found (run make desktop-dmg)"

# Any Vesper build uses the same data directory, so all of them must stop:
# the installed app and one launched from desktop/release alike.
vesper_running() { pgrep -f "Vesper.app/Contents/(MacOS/Vesper|Resources/bin/vesper)" >/dev/null; }

if vesper_running; then
  log "Quitting Vesper (it saves unpushed chat work on the way out)..."
  osascript -e "tell application id \"${bundle_id}\" to quit" >/dev/null 2>&1 || true
  for _ in $(seq 1 90); do vesper_running || break; sleep 1; done
  vesper_running && die "Vesper is still running after 90s (a quit dialog may be waiting); quit it and rerun"
fi

# A crashed or killed app can leave its Postgres running, and the next launch
# then refuses to start ("postgres is already using ...").
pidfile="${data_dir}/postgres/postmaster.pid"
if [[ -f "${pidfile}" ]]; then
  pg_pid="$(head -n 1 "${pidfile}")"
  if [[ -n "${pg_pid}" ]] && kill -0 "${pg_pid}" 2>/dev/null; then
    log "Stopping Postgres left running by the old app (pid ${pg_pid})..."
    "${repo_root}/desktop/resources/postgres/bin/pg_ctl" -D "${data_dir}/postgres" -m fast -w stop
  fi
fi

log "Installing ${app} from $(basename "${dmg}")..."
mnt="$(mktemp -d /tmp/vesper-dmg.XXXX)"
cleanup() { hdiutil detach "${mnt}" -quiet >/dev/null 2>&1 || true; rmdir "${mnt}" 2>/dev/null || true; }
trap cleanup EXIT
hdiutil attach -nobrowse -readonly -mountpoint "${mnt}" "${dmg}" -quiet
mkdir -p "$(dirname "${backup}")"
if [[ -d "${app}" ]]; then
  rm -rf "${backup}"
  mv "${app}" "${backup}"
fi
if ! ditto "${mnt}/Vesper.app" "${app}"; then
  rm -rf "${app}"
  [[ -d "${backup}" ]] && mv "${backup}" "${app}"
  die "copy failed; the previous app is back in place"
fi
cleanup
trap - EXIT
# Local builds are unsigned: drop the quarantine flag so Gatekeeper lets it open.
xattr -cr "${app}"
[[ -d "${backup}" ]] && log "Previous app kept at ${backup}"

if [[ "${VESPER_REINSTALL_NO_LAUNCH:-}" == 1 ]]; then
  log "Installed (not launched)."
  exit 0
fi

log "Launching Vesper..."
open -a "${app}"
for _ in $(seq 1 120); do
  curl -sf -o /dev/null "${health_url}" && break
  sleep 2
done
curl -sf -o /dev/null "${health_url}" || die "Vesper didn't answer ${health_url} within 4 minutes; see ${data_dir}/logs/vesper-app.log"

# On launch the app copies the VM image that matches the bundled checksum
# into its data directory; check it took the one this build ships.
want="$(awk '{print $1}' "${app}/Contents/Resources/images/agent-base.erofs.sha256")"
got="$(shasum -a 256 "${data_dir}/images/agent-base.erofs" 2>/dev/null | awk '{print $1}')"
[[ "${got}" == "${want}" ]] || die "installed VM image ${got:-missing} doesn't match the bundled ${want}; see ${data_dir}/logs/vesper-app.log"

log "Vesper is running (${health_url}) with VM image ${want:0:12}."
