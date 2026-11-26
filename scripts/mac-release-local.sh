#!/usr/bin/env bash
# Builds Vesper-arm64.dmg on an Apple Silicon Mac and publishes it (with
# agent-base.erofs) to a GitHub release — a local fallback when CI's macos-26
# runner is queued or slow. Mirrors .github/workflows/mac-release.yml.
#
# Examples:
#   scripts/mac-release-local.sh v0.3.0 --from-run
#   scripts/mac-release-local.sh v0.3.0 --from-run 45224199657
#   scripts/mac-release-local.sh v0.3.0 --build-images
#   scripts/mac-release-local.sh v0.3.0 --dmg-only
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"

usage() {
  cat <<'EOF'
Usage: scripts/mac-release-local.sh <tag> [options]

Build Vesper-arm64.dmg locally on an Apple Silicon Mac and publish it to a
GitHub release, matching .github/workflows/mac-release.yml.

Arguments:
  <tag>                 Release tag, e.g. v0.3.0 or v0.3.0-rc.1 (must match
                        vMAJOR.MINOR.PATCH[-suffix] and exist as a git tag).

Options:
  --from-run [RUN_ID]   Download kernel + rootfs artifacts from a mac-release
                        workflow run (omit RUN_ID or pass 'auto' to pick the
                        latest mac-release run for <tag>). Avoids Docker on
                        macOS and guarantees the bundled checksum matches CI.
  --build-images        Run deploy/microvm/build-images.sh --kernel --rootfs
                        locally before building the DMG.
  --dmg-only            Upload only Vesper-arm64.dmg (+ .sha256) to an
                        existing release; skips agent-base.erofs.
  --skip-build          Skip `make -C macos dmg` and upload the existing
                        macos/build/Vesper-arm64.dmg (+ .sha256).
  --no-upload           Build locally without creating or updating the release.
  --allow-head-mismatch Allow building even if HEAD is not at <tag>.
  --repo OWNER/REPO     Override the GitHub repository (default: GH_REPO or
                        the repo detected by `gh`).
  -h, --help            Show this help.

Environment:
  VESPER_IMAGES_DIR         Directory with vmlinux / agent-base.erofs (default: ~/.cache/vesper/images)
  VESPER_CODESIGN_IDENTITY  Signing identity passed through to build-app.sh (default: "-")
  SKIP_STAGE                Set to 1 to reuse macos/staged as-is
EOF
}

log() { printf '==> %s\n' "$*"; }
die() { echo "error: $*" >&2; exit 1; }

tag=""
from_run=""
build_images=0
dmg_only=0
skip_build=0
no_upload=0
allow_head_mismatch=0
repo="${GH_REPO:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --from-run)
      if [[ $# -ge 2 && "$2" != -* ]]; then
        from_run="$2"
        shift 2
      else
        from_run="auto"
        shift
      fi
      ;;
    --from-run=*)
      from_run="${1#*=}"
      [[ -n "$from_run" ]] || from_run="auto"
      shift
      ;;
    --build-images)
      build_images=1
      shift
      ;;
    --dmg-only)
      dmg_only=1
      shift
      ;;
    --skip-build)
      skip_build=1
      shift
      ;;
    --no-upload)
      no_upload=1
      shift
      ;;
    --allow-head-mismatch)
      allow_head_mismatch=1
      shift
      ;;
    --repo)
      [[ $# -ge 2 ]] || die "--repo requires OWNER/REPO"
      repo="$2"
      shift 2
      ;;
    --repo=*)
      repo="${1#*=}"
      shift
      ;;
    -*)
      die "unknown option: $1 (see --help)"
      ;;
    *)
      if [[ -z "$tag" ]]; then
        tag="$1"
        shift
      else
        die "unexpected argument: $1 (see --help)"
      fi
      ;;
  esac
done

[[ -n "$tag" ]] || { usage >&2; exit 1; }

# Semver only, matching mac-release.yml and Updates.swift.
if ! [[ "$tag" =~ ^v[0-9]{1,6}\.[0-9]{1,6}\.[0-9]{1,6}(-[0-9A-Za-z.-]{1,64})?$ ]]; then
  die "tag '$tag' isn't vMAJOR.MINOR.PATCH (optionally -suffix)"
fi

if [[ -n "$from_run" && "$build_images" == "1" ]]; then
  die "--from-run and --build-images cannot be used together"
fi

version="${tag#v}"
prerelease=false
if [[ "$version" == *-* ]]; then
  prerelease=true
fi

if [[ "$skip_build" == "0" ]]; then
  if [[ "$(uname -s)/$(uname -m)" != "Darwin/arm64" ]]; then
    die "local DMG builds require an Apple Silicon Mac (Darwin/arm64)"
  fi
fi

if [[ "$no_upload" == "0" || -n "$from_run" ]]; then
  command -v gh >/dev/null 2>&1 || die "gh CLI is required (install via Homebrew: brew install gh)"
  gh auth status >/dev/null 2>&1 || die "gh is not authenticated (run: gh auth login)"
fi

gh_repo_args=()
if [[ -n "$repo" ]]; then
  gh_repo_args=(-R "$repo")
fi

# Verify tag exists locally and (when building) HEAD matches it.
git -C "$repo_root" rev-parse -q --verify "refs/tags/${tag}" >/dev/null \
  || die "git tag '${tag}' not found locally (create it or run: git fetch --tags)"

if [[ "$skip_build" == "0" && "$allow_head_mismatch" == "0" ]]; then
  head_sha="$(git -C "$repo_root" rev-parse HEAD)"
  tag_sha="$(git -C "$repo_root" rev-parse "${tag}^{commit}")"
  if [[ "$head_sha" != "$tag_sha" ]]; then
    die "HEAD (${head_sha:0:8}) does not match tag ${tag} (${tag_sha:0:8}); run 'git checkout ${tag}' or pass --allow-head-mismatch"
  fi
fi

tmp_dir=""
version_bumped=0
cleanup() {
  if [[ "$version_bumped" == "1" ]]; then
    git -C "$repo_root" checkout -- VERSION 2>/dev/null || true
  fi
  if [[ -n "$tmp_dir" && -d "$tmp_dir" ]]; then
    rm -rf "$tmp_dir"
  fi
}
trap cleanup EXIT

# Resolve kernel + rootfs images directory.
img_dir="${VESPER_IMAGES_DIR:-${HOME}/.cache/vesper/images}"

if [[ -n "$from_run" ]]; then
  run_id="$from_run"
  if [[ "$run_id" == "auto" ]]; then
    log "looking up latest mac-release workflow run for ${tag}"
    run_id="$(gh run list "${gh_repo_args[@]}" \
      --workflow mac-release.yml \
      --branch "$tag" \
      --limit 5 \
      --json databaseId \
      --jq '.[0].databaseId // empty')"
    [[ -n "$run_id" ]] || die "no mac-release.yml run found for tag ${tag}; pass --from-run <run-id> explicitly"
  fi

  tmp_dir="$(mktemp -d)"
  img_dir="${tmp_dir}/images"
  mkdir -p "$img_dir"

  log "downloading kernel artifact from run ${run_id}"
  gh run download "${gh_repo_args[@]}" "$run_id" -n kernel -D "$img_dir"
  if [[ "$dmg_only" == "0" ]]; then
    log "downloading rootfs artifact from run ${run_id}"
    gh run download "${gh_repo_args[@]}" "$run_id" -n rootfs -D "$img_dir"
  fi
elif [[ "$build_images" == "1" ]]; then
  log "building kernel and rootfs locally into ${img_dir}"
  VESPER_IMAGES_DIR="$img_dir" bash "${repo_root}/deploy/microvm/build-images.sh" --kernel --rootfs
fi

# Validate required image artifacts before spending time on the DMG build.
if [[ "$skip_build" == "0" && "${SKIP_STAGE:-}" != "1" ]]; then
  [[ -s "${img_dir}/vmlinux" ]] || die "missing ${img_dir}/vmlinux (use --from-run, --build-images, or set VESPER_IMAGES_DIR)"
fi

if [[ "$dmg_only" == "0" ]]; then
  [[ -s "${img_dir}/agent-base.erofs" ]] || die "missing ${img_dir}/agent-base.erofs (use --from-run, --build-images, or --dmg-only)"
  [[ -s "${img_dir}/agent-base.erofs.sha256" ]] || die "missing ${img_dir}/agent-base.erofs.sha256"
  # GitHub release assets are limited to 2 GiB each (matches mac-release.yml).
  erofs_size="$(stat -c %s "${img_dir}/agent-base.erofs" 2>/dev/null || stat -f %z "${img_dir}/agent-base.erofs")"
  if [[ "$erofs_size" -ge 2147483648 ]]; then
    die "agent-base.erofs is ${erofs_size} bytes, over GitHub's 2 GiB release asset limit"
  fi
fi

# Build the DMG with the tag's version stamped into VERSION (restored on EXIT).
if [[ "$skip_build" == "0" ]]; then
  if ! git -C "$repo_root" diff --quiet -- VERSION; then
    die "VERSION has uncommitted changes; commit or stash it first"
  fi

  log "stamping version ${version} into VERSION (temporary)"
  version_bumped=1
  printf '%s\n' "$version" > "${repo_root}/VERSION"

  log "building macos/build/Vesper-arm64.dmg (VESPER_IMAGES_DIR=${img_dir})"
  VESPER_IMAGES_DIR="$img_dir" make -C "${repo_root}/macos" dmg
fi

dmg_file="${repo_root}/macos/build/Vesper-arm64.dmg"
dmg_sha="${repo_root}/macos/build/Vesper-arm64.dmg.sha256"
[[ -s "$dmg_file" ]] || die "missing ${dmg_file}"
[[ -s "$dmg_sha" ]] || die "missing ${dmg_sha}"

upload_files=("$dmg_file" "$dmg_sha")
if [[ "$dmg_only" == "0" ]]; then
  upload_files+=("${img_dir}/agent-base.erofs" "${img_dir}/agent-base.erofs.sha256")
fi

log "release assets ready:"
ls -lh "${upload_files[@]}"

if [[ "$no_upload" == "1" ]]; then
  log "--no-upload set; skipping GitHub release upload"
  exit 0
fi

if gh release view "${gh_repo_args[@]}" "$tag" >/dev/null 2>&1; then
  log "updating existing GitHub release ${tag}"
  gh release upload "${gh_repo_args[@]}" "$tag" "${upload_files[@]}" --clobber
else
  if [[ "$dmg_only" == "1" ]]; then
    die "release ${tag} does not exist yet; cannot use --dmg-only without agent-base.erofs"
  fi
  flags=()
  if [[ "$prerelease" == "true" ]]; then
    flags+=(--prerelease)
  fi
  log "creating GitHub release ${tag} (prerelease=${prerelease})"
  gh release create "${gh_repo_args[@]}" "$tag" "${upload_files[@]}" \
    --verify-tag --title "Vesper ${version}" --generate-notes "${flags[@]}"
fi

log "published ${tag}"
