#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"
repo_root_real="$(cd "${repo_root}" && pwd -P)"
out_dir="${VESPER_IMAGES_DIR:-${HOME}/.cache/vesper/images}"
default_base_image="vesper/agent-base:latest"
base_image="${VESPER_AGENT_BASE_IMAGE:-${default_base_image}}"
kernel_version="${VESPER_KERNEL_VERSION:-6.12.119}"
force=false
auto=false
check_only=false
build_kernel=false
build_rootfs=false

for arg in "$@"; do
  case "$arg" in
    --force) force=true ;;
    --auto) auto=true ;;
    --check) check_only=true ;;
    --kernel) build_kernel=true ;;
    --rootfs) build_rootfs=true ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

if [[ "$build_kernel" = false && "$build_rootfs" = false ]]; then
  build_kernel=true
  build_rootfs=true
fi

sha256_stdin() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    sha256sum | awk '{print $1}'
  fi
}

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

write_file_atomic() {
  local target="$1"
  local content="$2"
  local tmp="${target}.tmp.$$"
  printf '%s\n' "${content}" > "${tmp}"
  mv -f "${tmp}" "${target}"
}

write_sha256_sidecar() {
  local target="$1"
  local digest
  digest="$(sha256_file "${target}")"
  write_file_atomic "${target}.sha256" "${digest}  $(basename "${target}")"
}

read_trimmed_file() {
  local path="$1"
  if [[ -f "${path}" ]]; then
    tr -d '[:space:]' < "${path}"
  fi
}

compute_kernel_inputs_hash() {
  {
    printf 'format=kernel-inputs-v1\n'
    printf 'kernel_version=%s\n' "${kernel_version}"
    for rel in deploy/microvm/kernel.Dockerfile deploy/microvm/kernel.fragment.config; do
      printf '%s  %s\n' "$(sha256_file "${repo_root}/${rel}")" "${rel}"
    done
  } | sha256_stdin
}

compute_base_inputs_hash() {
  local base_files
  base_files="$(
    cd "${repo_root}" && find deploy/agent-base -type f ! -name '.DS_Store' | LC_ALL=C sort
  )"
  {
    printf 'format=agent-base-inputs-v1\n'
    printf 'base_image=%s\n' "${base_image}"
    while IFS= read -r rel; do
      [[ -n "${rel}" ]] || continue
      printf '%s  %s\n' "$(sha256_file "${repo_root}/${rel}")" "${rel}"
    done <<EOF
${base_files}
EOF
  } | sha256_stdin
}

compute_rootfs_inputs_hash() {
  local base_hash="$1"
  local go_files
  go_files="$(
    GOOS=linux GOARCH=arm64 CGO_ENABLED=0 \
      go -C "${repo_root}/server" list -deps \
      -f '{{if and (not .Standard) .Module .Module.Main}}{{$d := .Dir}}{{range .GoFiles}}{{$d}}/{{.}}{{"\n"}}{{end}}{{range .CgoFiles}}{{$d}}/{{.}}{{"\n"}}{{end}}{{range .SFiles}}{{$d}}/{{.}}{{"\n"}}{{end}}{{range .EmbedFiles}}{{$d}}/{{.}}{{"\n"}}{{end}}{{end}}' \
      ./cmd/vesper-guest-agent ./cmd/vesper-mac \
      | LC_ALL=C sort -u
  )"
  {
    printf 'format=rootfs-inputs-v1\n'
    printf 'agent_base_inputs=%s\n' "${base_hash}"
    for rel in deploy/microvm/rootfs.Dockerfile server/go.mod server/go.sum; do
      printf '%s  %s\n' "$(sha256_file "${repo_root}/${rel}")" "${rel}"
    done
    while IFS= read -r abs; do
      [[ -n "${abs}" ]] || continue
      local rel="${abs#"${repo_root_real}/"}"
      printf '%s  %s\n' "$(sha256_file "${abs}")" "${rel}"
    done <<EOF
${go_files}
EOF
  } | sha256_stdin
}

kernel_inputs_hash=""
base_inputs_hash=""
rootfs_inputs_hash=""
need_kernel=false
need_rootfs=false
kernel_reason="up-to-date"
rootfs_reason="up-to-date"

if [[ "${build_kernel}" = true ]]; then
  kernel_inputs_hash="$(compute_kernel_inputs_hash)"
  if [[ "${force}" = true ]]; then
    need_kernel=true
    kernel_reason="forced"
  elif [[ ! -s "${out_dir}/vmlinux" ]]; then
    need_kernel=true
    kernel_reason="vmlinux missing"
  elif [[ "${auto}" = true ]]; then
    if [[ ! -s "${out_dir}/vmlinux.sha256" ]]; then
      need_kernel=true
      kernel_reason="vmlinux.sha256 missing"
    elif [[ "$(read_trimmed_file "${out_dir}/vmlinux.inputs.sha256")" != "${kernel_inputs_hash}" ]]; then
      need_kernel=true
      kernel_reason="kernel inputs changed"
    fi
  fi
fi

if [[ "${build_rootfs}" = true ]]; then
  base_inputs_hash="$(compute_base_inputs_hash)"
  rootfs_inputs_hash="$(compute_rootfs_inputs_hash "${base_inputs_hash}")"
  if [[ "${force}" = true ]]; then
    need_rootfs=true
    rootfs_reason="forced"
  elif [[ "${auto}" = false ]]; then
    need_rootfs=true
    rootfs_reason="requested"
  elif [[ ! -s "${out_dir}/agent-base.erofs" ]]; then
    need_rootfs=true
    rootfs_reason="agent-base.erofs missing"
  elif [[ ! -s "${out_dir}/agent-base.erofs.sha256" ]]; then
    need_rootfs=true
    rootfs_reason="agent-base.erofs.sha256 missing"
  elif [[ "$(read_trimmed_file "${out_dir}/agent-base.erofs.inputs.sha256")" != "${rootfs_inputs_hash}" ]]; then
    need_rootfs=true
    rootfs_reason="rootfs inputs changed"
  fi
fi

if [[ "${check_only}" = true ]]; then
  if [[ "${build_kernel}" = true ]]; then
    if [[ "${need_kernel}" = true ]]; then
      printf 'kernel: rebuild (%s) [inputs=%s]\n' "${kernel_reason}" "${kernel_inputs_hash}"
    else
      printf 'kernel: up-to-date [inputs=%s]\n' "${kernel_inputs_hash}"
    fi
  fi
  if [[ "${build_rootfs}" = true ]]; then
    if [[ "${need_rootfs}" = true ]]; then
      printf 'rootfs: rebuild (%s) [inputs=%s]\n' "${rootfs_reason}" "${rootfs_inputs_hash}"
    else
      printf 'rootfs: up-to-date [inputs=%s]\n' "${rootfs_inputs_hash}"
    fi
    printf 'base_image_inputs=%s\n' "${base_inputs_hash}"
  fi
  exit 0
fi

if [[ "${need_kernel}" = false && "${need_rootfs}" = false ]]; then
  if [[ "${build_kernel}" = true ]]; then
    echo "Kernel up to date at ${out_dir}/vmlinux."
  fi
  if [[ "${build_rootfs}" = true ]]; then
    echo "Rootfs up to date at ${out_dir}/agent-base.erofs."
  fi
  exit 0
fi

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  echo "error: Docker is required to rebuild microVM images (kernel=${need_kernel}, rootfs=${need_rootfs}), but the Docker daemon is not reachable." >&2
  exit 1
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
if [[ "${need_rootfs}" = true ]]; then
  need_base_image=false
  if ! docker image inspect "${base_image}" >/dev/null 2>&1; then
    need_base_image=true
  elif [[ "${base_image}" == "${default_base_image}" ]]; then
    existing_base_hash="$(docker image inspect -f '{{index .Config.Labels "org.vesper.inputs.sha256"}}' "${base_image}" 2>/dev/null || true)"
    if [[ "${existing_base_hash}" != "${base_inputs_hash}" ]]; then
      need_base_image=true
    fi
  fi
  if [[ "${need_base_image}" = true ]]; then
    echo "Building base image ${base_image}..."
    docker build --platform linux/arm64 \
      --label "org.vesper.inputs.sha256=${base_inputs_hash}" \
      -t "${base_image}" "${repo_root}/deploy/agent-base"
  fi
fi

if [[ "${need_kernel}" = true ]]; then
  echo "Building Linux ${kernel_version} arm64 kernel Image (${kernel_reason}) -> ${out_dir}/vmlinux ..."
  docker buildx build \
    --platform linux/arm64 \
    --build-arg "KERNEL_VERSION=${kernel_version}" \
    -f "${script_dir}/kernel.Dockerfile" \
    --output "type=local,dest=${tmpdir}/kernel-out" \
    "${script_dir}"
  install -m 0644 "${tmpdir}/kernel-out/vmlinux" "${out_dir}/vmlinux"
  install -m 0644 "${tmpdir}/kernel-out/kernel.config" "${out_dir}/kernel.config"
  write_sha256_sidecar "${out_dir}/vmlinux"
  write_file_atomic "${out_dir}/vmlinux.inputs.sha256" "${kernel_inputs_hash}"
elif [[ "${build_kernel}" = true ]]; then
  echo "Kernel already up to date at ${out_dir}/vmlinux (pass --force --kernel to rebuild)."
fi

if [[ "${need_rootfs}" = true ]]; then
  echo "Cross-compiling vesper-guest-agent (linux/arm64) (${rootfs_reason})..."
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
  write_sha256_sidecar "${out_dir}/agent-base.erofs"
  write_file_atomic "${out_dir}/agent-base.erofs.inputs.sha256" "${rootfs_inputs_hash}"
elif [[ "${build_rootfs}" = true ]]; then
  echo "Rootfs already up to date at ${out_dir}/agent-base.erofs (pass --force --rootfs to rebuild)."
fi

ls -lh "${out_dir}"
