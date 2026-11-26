#!/usr/bin/env bash
# Auto-rebuilds stale microVM images (kernel and/or rootfs), builds and signs
# macos/build/Vesper.app, and installs it into /Applications/Vesper.app.
#
# Environment:
#   VESPER_CODESIGN_IDENTITY  Signing identity passed to build-app.sh (default: "-" ad hoc)
#   VESPER_IMAGES_DIR         Image cache directory (default: ~/.cache/vesper/images)
#   VESPER_INSTALL_DIR        Destination folder (default: /Applications)
#   FORCE_IMAGES=1            Force rebuilding both kernel and rootfs
#   SKIP_IMAGES=1             Skip checking/rebuilding microVM images
#   SKIP_STAGE=1              Reuse macos/staged as-is during build-app.sh
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
install_dir="${VESPER_INSTALL_DIR:-/Applications}"
src="${repo_root}/macos/build/Vesper.app"
dst="${install_dir}/Vesper.app"
stage_dst="${install_dir}/.Vesper.app.installing.$$"

log() { printf '==> %s\n' "$*"; }

cleanup() {
  if [[ -e "${stage_dst}" ]]; then
    rm -rf "${stage_dst}"
  fi
}
trap cleanup EXIT

if [[ "$(uname -s)/$(uname -m)" != "Darwin/arm64" ]]; then
  echo "error: building and installing Vesper.app requires an Apple Silicon Mac (Darwin/arm64)." >&2
  exit 1
fi

if [[ "${SKIP_IMAGES:-}" != "1" ]]; then
  img_args=(--auto)
  if [[ "${FORCE_IMAGES:-}" == "1" ]]; then
    img_args+=(--force)
  fi
  log "checking microVM kernel and rootfs images"
  bash "${repo_root}/deploy/microvm/build-images.sh" "${img_args[@]}"
else
  log "SKIP_IMAGES=1: skipping microVM image freshness check"
fi

log "building Vesper.app"
bash "${repo_root}/macos/scripts/build-app.sh"

[[ -d "${src}" ]] || { echo "error: expected built app at ${src}" >&2; exit 1; }

if pgrep -x Vesper >/dev/null 2>&1; then
  log "quitting running Vesper"
  osascript -e 'tell application "Vesper" to quit' >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -x Vesper >/dev/null 2>&1 || break
    sleep 1
  done
  if pgrep -x Vesper >/dev/null 2>&1; then
    echo "warning: Vesper did not exit within 10s; quit and relaunch it after install" >&2
  fi
fi

log "installing ${dst}"
mkdir -p "${install_dir}"
rm -rf "${stage_dst}"
ditto "${src}" "${stage_dst}"
rm -rf "${dst}"
mv "${stage_dst}" "${dst}"

log "installed ${dst}"
