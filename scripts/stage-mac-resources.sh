#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
res_dir="${repo_root}/macos/staged"
img_cache="${VESPER_IMAGES_DIR:-${HOME}/.cache/vesper/images}"

mkdir -p "${res_dir}/bin" "${res_dir}/images"

# A bundle staged before bundle-postgres-darwin.sh patched the tzdata path still
# points postgres at the build host's /nix/store, so it runs here but can't load
# any time zone, not even UTC, on a Mac without Nix. Rebuild it instead.
if [[ -x "${res_dir}/postgres/bin/postgres" ]] &&
  grep -rqaE '/nix/store/[0-9a-z]{32}-tzdata-' "${res_dir}/postgres/bin" "${res_dir}/postgres/lib"; then
  echo "Staged PostgreSQL bundle still has a /nix/store tzdata path; rebuilding it..."
  bash "${repo_root}/scripts/bundle-postgres-darwin.sh" "${res_dir}/postgres"
elif [[ ! -x "${res_dir}/postgres/bin/postgres" ]]; then
  echo "Staging relocatable PostgreSQL 17 bundle..."
  bash "${repo_root}/scripts/bundle-postgres-darwin.sh" "${res_dir}/postgres"
else
  echo "Using existing staged PostgreSQL bundle at ${res_dir}/postgres"
fi

echo "Building the headless design worker..."
if [[ ! -d "${repo_root}/design-worker/node_modules" ]]; then
  npm --prefix "${repo_root}/design-worker" ci
fi
npm --prefix "${repo_root}/design-worker" run build

# design-worker/dist contains server.mjs, @resvg/resvg-js, pdfjs runtime, and bundled fonts.
rm -rf "${res_dir}/design-worker" "${res_dir}/web"
mkdir -p "${res_dir}/design-worker"
cp -R "${repo_root}/design-worker/dist/." "${res_dir}/design-worker/"

echo "Building vesper (darwin/arm64) binary..."
CGO_ENABLED=1 GOOS=darwin GOARCH=arm64 \
  go -C "${repo_root}/server" build -trimpath -ldflags="-s -w" \
  -o "${res_dir}/bin/vesper" ./cmd/vesper
chmod 0755 "${res_dir}/bin/vesper"

# Stage the native Apple Silicon Vision matting CLI if Swift is available on macOS
# (or if a prebuilt release binary is already present in macos/.build).
if [[ "$(uname -s)" == "Darwin" ]] && command -v swift >/dev/null 2>&1; then
  echo "Building vesper-matte (darwin/arm64) Vision matting helper..."
  swift build --package-path "${repo_root}/macos" -c release --product vesper-matte
  matte_bin="$(swift build --package-path "${repo_root}/macos" -c release --show-bin-path)/vesper-matte"
  if [[ -x "${matte_bin}" ]]; then
    cp -f "${matte_bin}" "${res_dir}/bin/vesper-matte"
    chmod 0755 "${res_dir}/bin/vesper-matte"
  fi
elif [[ -x "${repo_root}/macos/.build/release/vesper-matte" ]]; then
  cp -f "${repo_root}/macos/.build/release/vesper-matte" "${res_dir}/bin/vesper-matte"
  chmod 0755 "${res_dir}/bin/vesper-matte"
fi

if [[ ! -s "${img_cache}/vmlinux" ]]; then
  echo "Missing ${img_cache}/vmlinux (run make mac-app or deploy/microvm/build-images.sh --auto)" >&2
  exit 1
fi
rm -rf "${res_dir}/images"
mkdir -p "${res_dir}/images"
cp -f "${img_cache}/vmlinux" "${res_dir}/images/vmlinux"
if [[ -f "${img_cache}/vmlinux.sha256" ]]; then
  cp -f "${img_cache}/vmlinux.sha256" "${res_dir}/images/vmlinux.sha256"
fi
if [[ -f "${img_cache}/agent-base.erofs.sha256" ]]; then
  cp -f "${img_cache}/agent-base.erofs.sha256" "${res_dir}/images/agent-base.erofs.sha256"
fi

echo "Staged macOS app resources:"
du -sh "${res_dir}/bin" "${res_dir}/postgres" "${res_dir}/images" "${res_dir}/design-worker"
