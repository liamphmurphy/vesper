#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
out_dir="${1:-${repo_root}/macos/staged/postgres}"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "bundle-postgres-darwin.sh only runs on macOS" >&2
  exit 1
fi

echo "Resolving nixpkgs#postgresql_17 via nix..."
# A read loop rather than mapfile: macOS ships bash 3.2, which has no mapfile,
# and CI's macOS runners use it.
store_paths=()
while IFS= read -r p; do
  [[ -n "${p}" ]] && store_paths+=("${p}")
done < <(
  nix build --no-link --print-out-paths nixpkgs#postgresql_17 nixpkgs#postgresql_17.lib 2>/dev/null \
    || nix build --no-link --print-out-paths nixpkgs#postgresql_17
)
# A failed nix build inside the process substitution doesn't trip set -e.
if [[ ${#store_paths[@]} -eq 0 ]]; then
  echo "nix build nixpkgs#postgresql_17 printed no store paths" >&2
  exit 1
fi

tmp_stage="${out_dir}.stage.$$"
rm -rf "${tmp_stage}"
mkdir -p "${tmp_stage}/bin" "${tmp_stage}/lib/postgresql" "${tmp_stage}/share"

find_file_in_stores() {
  local rel="$1"
  for sp in "${store_paths[@]}"; do
    if [[ -e "${sp}/${rel}" ]]; then
      printf '%s\n' "${sp}/${rel}"
      return 0
    fi
  done
  return 1
}

pg_bins=(postgres initdb pg_isready pg_ctl psql pg_dump pg_restore)
for b in "${pg_bins[@]}"; do
  src="$(find_file_in_stores "bin/${b}")"
  cp -L "${src}" "${tmp_stage}/bin/${b}"
  chmod 0755 "${tmp_stage}/bin/${b}"
done

# Copy top-level PostgreSQL shared libraries (libpq, etc.)
for sp in "${store_paths[@]}"; do
  if [[ -d "${sp}/lib" ]]; then
    while IFS= read -r -d '' f; do
      cp -L "${f}" "${tmp_stage}/lib/$(basename "${f}")"
      chmod 0755 "${tmp_stage}/lib/$(basename "${f}")"
    done < <(find "${sp}/lib" -maxdepth 1 \( -name '*.dylib' -o -name '*.so' \) -print0)
  fi
  # Copy loadable plugins & extensions (including pg_trgm, plpgsql, charset conversions).
  if [[ -d "${sp}/lib/postgresql" ]]; then
    while IFS= read -r -d '' f; do
      cp -L "${f}" "${tmp_stage}/lib/postgresql/$(basename "${f}")"
      chmod 0755 "${tmp_stage}/lib/postgresql/$(basename "${f}")"
    done < <(find "${sp}/lib/postgresql" -maxdepth 1 \( -name '*.dylib' -o -name '*.so' \) -print0)
  fi
  if [[ -d "${sp}/share/postgresql" ]] && [[ ! -d "${tmp_stage}/share/postgresql" ]]; then
    cp -R -L "${sp}/share/postgresql" "${tmp_stage}/share/postgresql"
    chmod -R u+rwX,go+rX "${tmp_stage}/share/postgresql"
  fi
done

echo "Relocating Mach-O dylib dependencies -> @loader_path ..."
/usr/bin/python3 - "${tmp_stage}" <<'PY'
import os
import re
import shutil
import subprocess
import sys

stage = os.path.abspath(sys.argv[1])
lib_dir = os.path.join(stage, "lib")

def is_macho(path):
    if not os.path.isfile(path) or os.path.islink(path):
        return False
    out = subprocess.check_output(["file", "-b", path], text=True)
    return "Mach-O" in out

def otool_deps(path):
    out = subprocess.check_output(["otool", "-L", path], text=True)
    deps = []
    for line in out.splitlines()[1:]:
        line = line.strip()
        if not line:
            continue
        dep = line.split(" (", 1)[0]
        deps.append(dep)
    return deps

def collect_files():
    res = []
    for sub in ("bin", "lib"):
        root = os.path.join(stage, sub)
        for dp, _, fns in os.walk(root):
            for fn in sorted(fns):
                p = os.path.join(dp, fn)
                if is_macho(p):
                    res.append(p)
    return res

# 1. Recursively bundle all /nix/store/*.dylib dependencies into lib/.
seen_targets = set()
changed = True
while changed:
    changed = False
    for p in collect_files():
        if p in seen_targets:
            continue
        seen_targets.add(p)
        for dep in otool_deps(p):
            if dep.startswith("/nix/store/"):
                base = os.path.basename(dep)
                dst = os.path.join(lib_dir, base)
                if not os.path.exists(dst):
                    shutil.copy2(os.path.realpath(dep), dst)
                    os.chmod(dst, 0o755)
                    changed = True

# Map every bundled library basename (under lib/ and lib/postgresql/) to its staged path.
bundled = {}
for dp, _, fns in os.walk(lib_dir):
    for fn in fns:
        p = os.path.join(dp, fn)
        if is_macho(p):
            bundled.setdefault(fn, p)

# 2. Rewrite install names and load paths relative to @loader_path.
for p in collect_files():
    os.chmod(p, 0o755)
    pdir = os.path.dirname(p)
    if p.startswith(lib_dir + os.sep):
        subprocess.check_call(["install_name_tool", "-id", f"@loader_path/{os.path.basename(p)}", p])
    for dep in otool_deps(p):
        if dep.startswith("/nix/store/"):
            base = os.path.basename(dep)
            target = bundled.get(base)
            if not target:
                raise RuntimeError(f"missing bundled dependency {dep} for {p}")
            rel = os.path.relpath(target, pdir).replace(os.sep, "/")
            new_ref = f"@loader_path/{rel}"
            subprocess.check_call(["install_name_tool", "-change", dep, new_ref, p])
    # Drop any /nix/store rpaths if present.
    lout = subprocess.check_output(["otool", "-l", p], text=True)
    lines = lout.splitlines()
    for i, ln in enumerate(lines):
        if "cmd LC_RPATH" in ln:
            for j in range(i + 1, min(i + 6, len(lines))):
                if lines[j].strip().startswith("path /nix/store/"):
                    rpath = lines[j].strip().split()[1]
                    subprocess.call(["install_name_tool", "-delete_rpath", rpath, p],
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

# 2b. nixpkgs builds Postgres --with-system-tzdata, which compiles the tzdata
# store path into postgres and initdb as an absolute string; there is no env
# var to override it. On a Mac without that store path, every time zone,
# even 'UTC', fails to load and postgres refuses to start. Point it at macOS's
# own zoneinfo, overwriting the C string in place (shorter, NUL-padded).
TZ_RE = re.compile(rb"/nix/store/[0-9a-z]{32}-tzdata-[^/\x00]+/share/zoneinfo")
SYSTEM_TZDIR = b"/usr/share/zoneinfo"
for p in collect_files():
    with open(p, "rb") as fh:
        data = fh.read()
    out = bytearray(data)
    for m in TZ_RE.finditer(data):
        s, e = m.span()
        if (s > 0 and data[s - 1] != 0) or data[e] != 0:
            raise RuntimeError(f"tzdata path in {p} is not a standalone C string")
        out[s:e] = SYSTEM_TZDIR + b"\0" * ((e - s) - len(SYSTEM_TZDIR))
    if out != data:
        with open(p, "wb") as fh:
            fh.write(out)

# 3. Verify zero /nix/store references remain and ad-hoc sign every Mach-O binary/dylib.
for p in collect_files():
    for dep in otool_deps(p):
        if "/nix/store/" in dep:
            raise RuntimeError(f"unrelocated /nix/store ref in {p}: {dep}")
    with open(p, "rb") as fh:
        if re.search(rb"/nix/store/[^\x00]*tzdata", fh.read()):
            raise RuntimeError(f"unpatched /nix/store tzdata path in {p}")
    subprocess.check_call(["codesign", "--force", "--sign", "-", p],
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

print(f"Verified {len(collect_files())} relocatable Mach-O binaries/libraries with zero /nix/store refs.")
PY

echo "Smoke-testing relocated PostgreSQL 17 initdb + Unix-socket startup + pg_trgm..."
smoke_dir="$(mktemp -d /tmp/vesper-pg-smoke.XXXXXX)"
cleanup_smoke() {
  if [[ -f "${smoke_dir}/data/postmaster.pid" ]]; then
    "${tmp_stage}/bin/pg_ctl" -D "${smoke_dir}/data" -m immediate stop >/dev/null 2>&1 || true
  fi
  rm -rf "${smoke_dir}"
}
trap cleanup_smoke EXIT

mkdir -p "${smoke_dir}/sock"
chmod 0700 "${smoke_dir}/sock"
env -i PATH=/usr/bin:/bin \
  "${tmp_stage}/bin/initdb" -D "${smoke_dir}/data" --username=vesper --auth=trust --encoding=UTF8 --locale=C --no-instructions >/dev/null
env -i PATH=/usr/bin:/bin \
  "${tmp_stage}/bin/pg_ctl" -D "${smoke_dir}/data" -l "${smoke_dir}/pg.log" \
  -o "-k ${smoke_dir}/sock -h '' -c timezone=UTC -c log_timezone=UTC" start >/dev/null
env -i PATH=/usr/bin:/bin \
  "${tmp_stage}/bin/pg_isready" -h "${smoke_dir}/sock" -U vesper >/dev/null
env -i PATH=/usr/bin:/bin \
  "${tmp_stage}/bin/psql" -h "${smoke_dir}/sock" -U vesper -d postgres \
  -c "CREATE EXTENSION IF NOT EXISTS pg_trgm; SELECT array_length(show_trgm('vesper'), 1);" >/dev/null
# Named zones load from /usr/share/zoneinfo (step 2b), not the build host's nix store.
env -i PATH=/usr/bin:/bin \
  "${tmp_stage}/bin/psql" -h "${smoke_dir}/sock" -U vesper -d postgres -v ON_ERROR_STOP=1 \
  -c "SELECT now() AT TIME ZONE 'America/Los_Angeles';" >/dev/null
env -i PATH=/usr/bin:/bin \
  "${tmp_stage}/bin/pg_ctl" -D "${smoke_dir}/data" -m fast stop >/dev/null
rm -rf "${smoke_dir}"
trap - EXIT

mkdir -p "$(dirname "${out_dir}")"
rm -rf "${out_dir}"
mv "${tmp_stage}" "${out_dir}"
du -sh "${out_dir}"
