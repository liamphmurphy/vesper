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
# Needs: tart and sshpass (brew install openai/tools/tart sshpass),
# Go, and ~60 GB free. VESPER_MACOS_SOURCE picks the Tart image
# (default ghcr.io/cirruslabs/macos-sequoia-xcode:latest, whose account is
# admin/admin; set VESPER_MACOS_SSH_USER/VESPER_MACOS_SSH_PASSWORD for others).
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"
data_dir="${VESPER_USER_DATA_DIR:-${HOME}/Library/Application Support/vesper-desktop}"
out_dir="${1:-${data_dir}/vm/macos-golden}"
source_image="${VESPER_MACOS_SOURCE:-ghcr.io/cirruslabs/macos-sequoia-xcode:latest}"
ssh_user="${VESPER_MACOS_SSH_USER:-admin}"
ssh_password="${VESPER_MACOS_SSH_PASSWORD:-admin}"
vm_name="vesper-macos-golden-$$"

if [[ "$(uname -s)/$(uname -m)" != "Darwin/arm64" ]]; then
  echo "macOS guests need an Apple silicon Mac." >&2
  exit 1
fi
for tool in tart sshpass go; do
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
ip="$(tart ip --wait 180 "${vm_name}")"

# Password only: keys from the host's ssh agent would count against the
# guest's MaxAuthTries before the password is ever tried.
ssh_opts=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5
  -o PubkeyAuthentication=no -o PreferredAuthentications=password,keyboard-interactive)
remote() { SSHPASS="${ssh_password}" sshpass -e ssh "${ssh_opts[@]}" "${ssh_user}@${ip}" "$@"; }
# sshd answers before the guest finishes booting, and rejects the right
# password until it has, so keep trying for a while.
ssh_ready=""
for _ in $(seq 1 100); do
  if ssh_err="$(remote true 2>&1)"; then
    ssh_ready=1
    break
  fi
  sleep 3
done
if [[ -z "${ssh_ready}" ]]; then
  echo "Could not ssh into the VM at ${ip} as ${ssh_user}: ${ssh_err}" >&2
  echo "Check VESPER_MACOS_SSH_USER/VESPER_MACOS_SSH_PASSWORD, and that a VPN isn't routing ${ip} away from the VM." >&2
  exit 1
fi
# ssh joins its arguments into one string the guest's shell parses again, so
# a multi-line script passed inline loses its quoting. Copy it over instead.
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

SSHPASS="${ssh_password}" sshpass -e scp "${ssh_opts[@]}" \
  "${tmpdir}/vesper-guest-agent" "${tmpdir}/dev.vesper.guest-agent.plist" \
  "${tmpdir}/vesper-golden-setup.sh" "${ssh_user}@${ip}:/tmp/"

# sudo -S reads the password from stdin; Tart's images also allow it without.
echo "${ssh_password}" | remote sudo -S sh /tmp/vesper-golden-setup.sh

echo "Shutting it down..."
echo "${ssh_password}" | remote sudo -S shutdown -h now >/dev/null 2>&1 || true
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
