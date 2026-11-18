#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
res_dir="${repo_root}/macos/staged"
img_cache="${VESPER_IMAGES_DIR:-${HOME}/.cache/vesper/images}"

mkdir -p "${res_dir}/bin" "${res_dir}/images"

if [[ ! -x "${res_dir}/postgres/bin/postgres" ]]; then
  echo "Staging relocatable PostgreSQL 17 bundle..."
  bash "${repo_root}/scripts/bundle-postgres-darwin.sh" "${res_dir}/postgres"
else
  echo "Using existing staged PostgreSQL bundle at ${res_dir}/postgres"
fi

echo "Building the static web UI and the design worker..."
if [[ ! -d "${repo_root}/web/node_modules" ]]; then
  npm --prefix "${repo_root}/web" ci
fi
npm --prefix "${repo_root}/web" run build

# web/dist is the whole UI: index.html and assets/ (served by `vesper app` itself), fonts/, and
# design-worker/ (server.mjs plus the resvg native addon; run with the bundled node).
rm -rf "${res_dir}/web"
mkdir -p "${res_dir}/web"
cp -R "${repo_root}/web/dist/." "${res_dir}/web/"

echo "Building vesper (darwin/arm64) binary..."
CGO_ENABLED=1 GOOS=darwin GOARCH=arm64 \
  go -C "${repo_root}/server" build -trimpath -ldflags="-s -w" \
  -o "${res_dir}/bin/vesper" ./cmd/vesper
chmod 0755 "${res_dir}/bin/vesper"

if [[ ! -s "${img_cache}/vmlinux" ]]; then
  echo "Missing ${img_cache}/vmlinux (run deploy/microvm/build-images.sh --kernel)" >&2
  exit 1
fi
cp -f "${img_cache}/vmlinux" "${res_dir}/images/vmlinux"
if [[ -f "${img_cache}/vmlinux.sha256" ]]; then
  cp -f "${img_cache}/vmlinux.sha256" "${res_dir}/images/vmlinux.sha256"
fi
if [[ -f "${img_cache}/agent-base.erofs.sha256" ]]; then
  cp -f "${img_cache}/agent-base.erofs.sha256" "${res_dir}/images/agent-base.erofs.sha256"
fi

echo "Staged macOS app resources:"
du -sh "${res_dir}/bin" "${res_dir}/postgres" "${res_dir}/images" "${res_dir}/web"
