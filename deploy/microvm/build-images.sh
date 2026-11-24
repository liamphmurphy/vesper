#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"
out_dir="${VESPER_IMAGES_DIR:-${HOME}/.cache/vesper/images}"
base_image="${VESPER_AGENT_BASE_IMAGE:-vesper/agent-base:latest}"
kernel_version="${VESPER_KERNEL_VERSION:-6.12.117}"
force=false
build_kernel=false
build_rootfs=false

for arg in "$@"; do
  case "$arg" in
    --force) force=true ;;
    --kernel) build_kernel=true ;;
    --rootfs) build_rootfs=true ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

if [[ "$build_kernel" = false && "$build_rootfs" = false ]]; then
  build_kernel=true
  build_rootfs=true
fi

mkdir -p "${out_dir}"
tmpdir="$(mktemp -d)"
rootfs_cid=""
erofs_vol="vesper-erofs-work-$$"

cleanup() {
  if [[ -n "${rootfs_cid}" ]]; then
    docker rm -f "${rootfs_cid}" >/dev/null 2>&1 || true
  fi
  docker volume rm -f "${erofs_vol}" >/dev/null 2>&1 || true
  rm -rf "${tmpdir}"
}
trap cleanup EXIT

# Only the rootfs is built from the base image; a kernel-only build skips it.
if [[ "${build_rootfs}" = true ]] && ! docker image inspect "${base_image}" >/dev/null 2>&1; then
  echo "Building base image ${base_image}..."
  docker build --platform linux/arm64 -t "${base_image}" "${repo_root}/deploy/agent-base"
fi

if [[ "${build_kernel}" = true ]] && { [[ "${force}" = true ]] || [[ ! -s "${out_dir}/vmlinux" ]]; }; then
  echo "Building Linux ${kernel_version} arm64 kernel Image -> ${out_dir}/vmlinux ..."
  docker buildx build \
    --platform linux/arm64 \
    --build-arg "KERNEL_VERSION=${kernel_version}" \
    -f "${script_dir}/kernel.Dockerfile" \
    --output "type=local,dest=${tmpdir}/kernel-out" \
    "${script_dir}"
  install -m 0644 "${tmpdir}/kernel-out/vmlinux" "${out_dir}/vmlinux"
  install -m 0644 "${tmpdir}/kernel-out/kernel.config" "${out_dir}/kernel.config"
  (cd "${out_dir}" && shasum -a 256 vmlinux > vmlinux.sha256)
else
  echo "Kernel already present at ${out_dir}/vmlinux (pass --force --kernel to rebuild)."
fi

if [[ "${build_rootfs}" = true ]]; then
  echo "Cross-compiling vesper-guest-agent (linux/arm64)..."
  GOOS=linux GOARCH=arm64 CGO_ENABLED=0 \
    go -C "${repo_root}/server" build -trimpath -ldflags="-s -w" \
    -o "${tmpdir}/vesper-guest-agent" ./cmd/vesper-guest-agent
  echo "Cross-compiling mac (linux/arm64)..."
  GOOS=linux GOARCH=arm64 CGO_ENABLED=0 \
    go -C "${repo_root}/server" build -trimpath -ldflags="-s -w" \
    -o "${tmpdir}/mac" ./cmd/vesper-mac

  echo "Building rootfs stage image..."
  docker build \
    --platform linux/arm64 \
    --build-arg "BASE_IMAGE=${base_image}" \
    -f "${script_dir}/rootfs.Dockerfile" \
    -t vesper/agent-rootfs:dev \
    "${tmpdir}"

  echo "Packing agent-base.erofs -> ${out_dir}/agent-base.erofs ..."
  rootfs_cid="$(docker create --platform linux/arm64 vesper/agent-rootfs:dev)"
  docker volume create "${erofs_vol}" >/dev/null
  docker export "${rootfs_cid}" | docker run --rm -i --platform linux/arm64 \
    -v "${erofs_vol}:/work" \
    -v "${out_dir}:/out" \
    alpine:3.20 sh -euxc '
      apk add --no-cache erofs-utils tar >/dev/null
      rm -rf /work/rootfs
      mkdir -p /work/rootfs
      tar --numeric-owner -xf - -C /work/rootfs
      rm -f /work/rootfs/.dockerenv
      mkdir -p /work/rootfs/dev /work/rootfs/proc /work/rootfs/sys /work/rootfs/tmp /work/rootfs/run /work/rootfs/mnt
      chmod 1777 /work/rootfs/tmp
      mkfs.erofs -zlz4hc /out/agent-base.erofs.tmp /work/rootfs
      mv -f /out/agent-base.erofs.tmp /out/agent-base.erofs
      rm -rf /work/rootfs
    '
  (cd "${out_dir}" && shasum -a 256 agent-base.erofs > agent-base.erofs.sha256)
fi

ls -lh "${out_dir}"
