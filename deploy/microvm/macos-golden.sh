#!/usr/bin/env bash
# Prepares the macOS golden image that runs' `mac` command boots, from a Tart
# VM image with Xcode installed (https://tart.run). Run it on the Mac that runs
# Vesper; it never redistributes macOS, it pulls and modifies your own copy.
#
#   deploy/microvm/macos-golden.sh [OUTPUT_DIR]
#
# OUTPUT_DIR defaults to the Vesper app's VM directory:
#   ${VESPER_USER_DATA_DIR:-~/Library/Application Support/vesper-desktop}/vm/macos-golden
# Vesper picks the image up on its next start (RUNNER_MACOS_IMAGE_DIR overrides
# where it looks).
#
# Needs: tart (brew install openai/tools/tart), Go, and ~60 GB free.
# VESPER_MACOS_SOURCE picks the Tart image (default
# ghcr.io/cirruslabs/macos-sequoia-xcode:latest). It must run the Tart Guest
# Agent, as every non-vanilla Cirrus Labs image does, and allow passwordless
# sudo: the script works inside the VM with `tart exec`, not SSH.
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"
data_dir="${VESPER_USER_DATA_DIR:-${HOME}/Library/Application Support/vesper-desktop}"
out_dir="${1:-${data_dir}/vm/macos-golden}"
source_image="${VESPER_MACOS_SOURCE:-ghcr.io/cirruslabs/macos-sequoia-xcode:latest}"
vm_name="vesper-macos-golden-$$"

if [[ "$(uname -s)/$(uname -m)" != "Darwin/arm64" ]]; then
  echo "macOS guests need an Apple silicon Mac." >&2
  exit 1
fi
for tool in tart go; do
  if ! command -v "${tool}" >/dev/null 2>&1; then
    echo "Missing ${tool} (see the header of $0)." >&2
    exit 1
  fi
done

tmpdir="$(mktemp -d)"
run_pid=""
cleanup() {
  if [[ -n "${run_pid}" ]] && kill -0 "${run_pid}" 2>/dev/null; then
    tart stop "${vm_name}" >/dev/null 2>&1 || kill "${run_pid}" 2>/dev/null || true
  fi
  tart delete "${vm_name}" >/dev/null 2>&1 || true
  rm -rf "${tmpdir}"
}
trap cleanup EXIT

echo "Building vesper-guest-agent (darwin/arm64)..."
GOOS=darwin GOARCH=arm64 CGO_ENABLED=0 \
  go -C "${repo_root}/server" build -trimpath -ldflags="-s -w" \
  -o "${tmpdir}/vesper-guest-agent" ./cmd/vesper-guest-agent

# launchd starts the agent at boot, as root, before anyone logs in. It
# serves the host only (vsock CID 2) and runs commands as the image's user.
cat > "${tmpdir}/dev.vesper.guest-agent.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>dev.vesper.guest-agent</string>
  <key>ProgramArguments</key>
  <array><string>/usr/local/libexec/vesper-guest-agent</string></array>
  <key>EnvironmentVariables</key>
  <dict><key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string></dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardErrorPath</key><string>/var/log/vesper-guest-agent.log</string>
</dict>
</plist>
PLIST

echo "Pulling ${source_image} (the first pull is tens of GB)..."
tart clone "${source_image}" "${vm_name}"

echo "Booting it to install the agent..."
tart run --no-graphics "${vm_name}" >"${tmpdir}/run.log" 2>&1 &
run_pid=$!
# The image's Tart Guest Agent starts a few seconds into boot; until then
# `tart exec` fails.
exec_ready=""
for _ in $(seq 1 300); do
  if tart exec "${vm_name}" true >/dev/null 2>&1; then
    exec_ready=1
    break
  fi
  if ! kill -0 "${run_pid}" 2>/dev/null; then
    echo "The VM stopped while booting:" >&2
    cat "${tmpdir}/run.log" >&2
    exit 1
  fi
  sleep 1
done
if [[ -z "${exec_ready}" ]]; then
  echo "tart exec never reached ${source_image}; it needs the Tart Guest Agent (vanilla images lack it)." >&2
  exit 1
fi

cat > "${tmpdir}/vesper-golden-setup.sh" <<'SETUP'
set -eu
install -d -o root -g wheel -m 0755 /usr/local/libexec
install -o root -g wheel -m 0755 /tmp/vesper-guest-agent /usr/local/libexec/vesper-guest-agent
install -o root -g wheel -m 0644 /tmp/dev.vesper.guest-agent.plist /Library/LaunchDaemons/dev.vesper.guest-agent.plist
rm -f /tmp/vesper-guest-agent /tmp/dev.vesper.guest-agent.plist /tmp/vesper-golden-setup.sh
# A build VM never sleeps, and Xcode is ready before the first build.
pmset -a sleep 0 displaysleep 0 disksleep 0 >/dev/null 2>&1 || true
if command -v xcodebuild >/dev/null 2>&1; then
  xcodebuild -license accept >/dev/null 2>&1 || true
  xcodebuild -runFirstLaunch >/dev/null 2>&1 || true
fi
mkdir -p /opt/vesper/workspace
SETUP

for f in vesper-guest-agent dev.vesper.guest-agent.plist vesper-golden-setup.sh; do
  tart exec -i "${vm_name}" sh -c "cat > /tmp/${f}" <"${tmpdir}/${f}"
done
tart exec "${vm_name}" sudo -n sh /tmp/vesper-golden-setup.sh

echo "Shutting it down..."
tart exec "${vm_name}" sudo -n shutdown -h now >/dev/null 2>&1 || true
for _ in $(seq 1 120); do
  kill -0 "${run_pid}" 2>/dev/null || break
  sleep 1
done
if kill -0 "${run_pid}" 2>/dev/null; then
  tart stop "${vm_name}"
fi
run_pid=""

vm_dir="${TART_HOME:-${HOME}/.tart}/vms/${vm_name}"
echo "Copying the image to ${out_dir}..."
mkdir -p "$(dirname "${out_dir}")"
rm -rf "${out_dir}.tmp"
mkdir -p "${out_dir}.tmp"
# cp -c clones on APFS, so this costs no extra space on the same volume.
for f in disk.img nvram.bin config.json; do
  cp -c "${vm_dir}/${f}" "${out_dir}.tmp/${f}" 2>/dev/null || cp "${vm_dir}/${f}" "${out_dir}.tmp/${f}"
done
rm -rf "${out_dir}.old"
if [[ -d "${out_dir}" ]]; then
  mv "${out_dir}" "${out_dir}.old"
fi
mv "${out_dir}.tmp" "${out_dir}"
rm -rf "${out_dir}.old"

echo "Done. Restart Vesper; runs can then use \`mac\`."
echo "Runs keep their own copy of the disk, so a new image only reaches new runs."
