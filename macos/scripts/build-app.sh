#!/usr/bin/env bash
# Assembles and signs macos/build/Vesper.app (docs/dev/native-mac-app.md, "Processes and files").
#
#   make -C macos app                 stage resources (slow: web build, Postgres, vesper) then assemble
#   make -C macos app SKIP_STAGE=1    reuse macos/staged as it is
#
# Environment:
#   VESPER_CODESIGN_IDENTITY  a code-signing identity (see macos/README.md); default "-" (ad hoc)
#   SKIP_STAGE=1              don't run scripts/stage-mac-resources.sh
#   NODE_VERSION              Node release to bundle (default below); cached in ~/.cache/vesper/node
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
macos_dir="$(cd "${script_dir}/.." && pwd)"
repo_root="$(cd "${macos_dir}/.." && pwd)"
res_src="${macos_dir}/staged"
out_dir="${macos_dir}/build"
app="${out_dir}/Vesper.app"
contents="${app}/Contents"
identity="${VESPER_CODESIGN_IDENTITY:--}"
node_version="${NODE_VERSION:-v24.22.3}"
node_cache="${HOME}/.cache/vesper/node"
entitlements="${repo_root}/deploy/microvm/vz.entitlements"

log() { printf '==> %s\n' "$*"; }

[[ -f "${entitlements}" ]] || { echo "Missing ${entitlements}" >&2; exit 1; }

# 1. Swift executable.
log "swift build -c release"
(cd "${macos_dir}" && swift build -c release --product Vesper)
bin_dir="$(cd "${macos_dir}" && swift build -c release --show-bin-path)"
[[ -x "${bin_dir}/Vesper" ]] || { echo "Missing ${bin_dir}/Vesper" >&2; exit 1; }

# 1b. Vesper for Safari (docs/dev/safari-extension.md): the Safari web extension's handler. SwiftPM
#     can't build an app extension, so compile it here: the shared bridge plus the principal class,
#     with NSExtensionMain as the entry point (what Xcode links an app extension with).
safari_src="${macos_dir}/SafariExtension"
safari_bin="${out_dir}/VesperSafari"
log "building Vesper for Safari"
mkdir -p "${out_dir}"
xcrun swiftc -O -swift-version 5 -module-name VesperSafari \
  -target arm64-apple-macos15.0 -application-extension -parse-as-library \
  -Xlinker -e -Xlinker _NSExtensionMain \
  "${safari_src}"/Bridge/*.swift "${safari_src}"/Handler/*.swift \
  -o "${safari_bin}"

# 2. Resources (bin/vesper, postgres, web, images).
if [[ "${SKIP_STAGE:-}" != "1" ]]; then
  log "staging resources"
  bash "${repo_root}/scripts/stage-mac-resources.sh"
else
  log "SKIP_STAGE=1: reusing ${res_src}"
fi
for sub in bin postgres web images; do
  [[ -d "${res_src}/${sub}" ]] || { echo "Missing ${res_src}/${sub} (run without SKIP_STAGE=1)" >&2; exit 1; }
done
[[ -x "${res_src}/bin/vesper" ]] || { echo "Missing ${res_src}/bin/vesper" >&2; exit 1; }

# 3. Node 24 (the official darwin-arm64 build).
mkdir -p "${node_cache}"
node_tgz="node-${node_version}-darwin-arm64.tar.gz"
node_bin="${node_cache}/${node_version}/node"
if [[ ! -x "${node_bin}" ]]; then
  log "downloading Node ${node_version}"
  dl="$(mktemp -d)"
  trap 'rm -rf "${dl}"' EXIT
  curl -fsSL "https://nodejs.org/dist/${node_version}/${node_tgz}" -o "${dl}/${node_tgz}"
  curl -fsSL "https://nodejs.org/dist/${node_version}/SHASUMS256.txt" -o "${dl}/SHASUMS256.txt"
  expected="$(awk -v f="${node_tgz}" '$2 == f { print $1 }' "${dl}/SHASUMS256.txt")"
  actual="$(shasum -a 256 "${dl}/${node_tgz}" | awk '{ print $1 }')"
  if [[ -z "${expected}" || "${expected}" != "${actual}" ]]; then
    echo "Node checksum mismatch for ${node_tgz} (expected '${expected}', got '${actual}')" >&2
    exit 1
  fi
  tar -xzf "${dl}/${node_tgz}" -C "${dl}" "node-${node_version}-darwin-arm64/bin/node"
  mkdir -p "${node_cache}/${node_version}"
  cp "${dl}/node-${node_version}-darwin-arm64/bin/node" "${node_bin}"
  chmod 0755 "${node_bin}"
fi

# 4. Assemble the bundle.
log "assembling ${app}"
rm -rf "${app}"
mkdir -p "${contents}/MacOS" "${contents}/Resources/node/bin" "${contents}/Resources/tray"
cp "${bin_dir}/Vesper" "${contents}/MacOS/Vesper"
chmod 0755 "${contents}/MacOS/Vesper"
for sub in bin postgres web images; do
  ditto "${res_src}/${sub}" "${contents}/Resources/${sub}"
done
cp "${node_bin}" "${contents}/Resources/node/bin/node"
chmod 0755 "${contents}/Resources/node/bin/node"
cp "${macos_dir}/Resources/AppIcon.icns" "${contents}/Resources/AppIcon.icns"
cp "${macos_dir}/Resources/tray/"*.png "${contents}/Resources/tray/"

version="$(plutil -extract version raw "${repo_root}/web/package.json")"
build="$(git -C "${repo_root}" rev-list --count HEAD 2>/dev/null || echo 1)"
sed -e "s/@VERSION@/${version}/g" -e "s/@BUILD@/${build}/g" "${macos_dir}/Resources/Info.plist" > "${contents}/Info.plist"
plutil -lint "${contents}/Info.plist" >/dev/null
printf 'APPL????' > "${contents}/PkgInfo"

# The extension: its handler, Info.plist and the web extension itself (manifest, scripts, icons).
appex="${contents}/PlugIns/VesperSafari.appex"
mkdir -p "${appex}/Contents/MacOS" "${appex}/Contents/Resources"
cp "${safari_bin}" "${appex}/Contents/MacOS/VesperSafari"
chmod 0755 "${appex}/Contents/MacOS/VesperSafari"
ditto "${safari_src}/Resources" "${appex}/Contents/Resources"
sed -e "s/@VERSION@/${version}/g" -e "s/@BUILD@/${build}/g" "${safari_src}/Info.plist" > "${appex}/Contents/Info.plist"
plutil -lint "${appex}/Contents/Info.plist" >/dev/null

# 5. Sign inside-out, every Mach-O under postgres, web and node, then
#    bin/vesper with the Virtualization entitlement (no hardened runtime), then the Safari extension
#    with its sandbox entitlements, then the app (no --deep, so both keep their entitlements).
sign() { codesign --force --timestamp=none --sign "${identity}" "$@"; }
if [[ "${identity}" == "-" ]]; then
  log "signing ad hoc (set VESPER_CODESIGN_IDENTITY for a stable identity)"
else
  log "signing with '${identity}'"
fi
count=0
for sub in postgres web node; do
  while IFS= read -r f; do
    sign "${f}" >/dev/null 2>&1 || { echo "codesign failed: ${f}" >&2; sign "${f}"; exit 1; }
    count=$((count + 1))
  done < <(find "${contents}/Resources/${sub}" -type f ! -type l -print0 | xargs -0 file --no-pad | grep ': Mach-O' | sed 's/: Mach-O.*$//')
done
log "signed ${count} Mach-O files"
sign --entitlements "${entitlements}" "${contents}/Resources/bin/vesper" 2>&1 | grep -v 'replacing existing signature' || true
# Safari only loads a sandboxed extension; sign it with its entitlements before the app seals it.
sign --entitlements "${safari_src}/VesperSafari.entitlements" "${appex}" 2>&1 | grep -v 'replacing existing signature' || true
sign "${app}" 2>&1 | grep -v 'replacing existing signature' || true

log "built ${app}"
