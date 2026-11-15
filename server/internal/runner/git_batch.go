package runner

import (
	"bufio"
	"context"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"sync"

	"github.com/google/uuid"
)

type gitBatchRecord struct {
	Key  string
	Code int
	Cut  bool
	Data []byte
}

type gitBatchResult struct {
	records []gitBatchRecord
	byKey   map[string]gitBatchRecord
}

func (g *gitBatchResult) get(key string) (gitBatchRecord, bool) {
	r, ok := g.byKey[key]
	return r, ok
}

type gitBatchRequest struct {
	Mode              string              `json:"mode"`
	Base              string              `json:"base,omitempty"`
	CachedHead        string              `json:"cached_head,omitempty"`
	Pathspec          []string            `json:"pathspec,omitempty"`
	DiffLimit         int                 `json:"diff_limit,omitempty"`
	UntrackedLimit    int                 `json:"untracked_limit,omitempty"`
	MaxFiles          int                 `json:"max_files,omitempty"`
	MaxTreeFiles      int                 `json:"max_tree_files,omitempty"`
	MaxFileBytes      int                 `json:"max_file_bytes,omitempty"`
	OversizeFileBytes int                 `json:"oversize_file_bytes,omitempty"`
	MaxTreeTotalBytes int                 `json:"max_tree_total_bytes,omitempty"`
	Repos             []gitSignatureEntry `json:"repos,omitempty"`
}

type gitSignatureEntry struct {
	Dir string `json:"dir"`
}

// gitBatchScript inspects git state safely inside one process per workspace
// call, neutralizing untrusted repository programs (filters, external diff,
// textconv, pager, fsmonitor) identically to gitCmd/repoFilterEnv.
const gitBatchScript = `
import io, json, os, re, struct, subprocess, sys, tarfile

req = json.loads(sys.argv[1])
GIT_BASE = [
    "git",
    "-c", "core.quotepath=off",
    "-c", "diff.external=",
    "-c", "core.pager=cat",
    "-c", "color.ui=false",
    "-c", "diff.noprefix=false",
    "-c", "core.fsmonitor=false",
]
BASE_ENV = dict(os.environ)
BASE_ENV["GIT_TERMINAL_PROMPT"] = "0"
BASE_ENV["GIT_OPTIONAL_LOCKS"] = "0"
COMMIT_RE = re.compile(rb"^[0-9a-f]{40,64}$")

def emit(key, code, cut, data):
    if isinstance(key, str):
        key = key.encode("utf-8")
    sys.stdout.buffer.write(struct.pack(">IiBI", len(key), code, 1 if cut else 0, len(data)))
    sys.stdout.buffer.write(key)
    if data:
        sys.stdout.buffer.write(data)

def run_git(args, cwd, env, limit):
    p = subprocess.Popen(
        GIT_BASE + args,
        cwd=cwd or None,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        close_fds=True,
    )
    chunks = []
    total = 0
    cut = False
    while True:
        chunk = p.stdout.read(65536)
        if not chunk:
            break
        if total < limit:
            take = limit - total
            if len(chunk) > take:
                chunks.append(chunk[:take])
                total = limit
                cut = True
            else:
                chunks.append(chunk)
                total += len(chunk)
        else:
            cut = True
    p.stdout.close()
    code = p.wait()
    return code, cut, b"".join(chunks)

def filter_env(cwd):
    code, _, out = run_git(["config", "--list", "-z"], cwd, BASE_ENV, 1 << 20)
    if code != 0:
        return None, code
    keys = []
    for rec in out.split(b"\x00"):
        key, _, _ = rec.partition(b"\n")
        if key.startswith(b"filter.") and (key.endswith(b".clean") or key.endswith(b".process") or key.endswith(b".smudge")):
            keys.append(key.decode("utf-8", "surrogateescape"))
    env = dict(BASE_ENV)
    env["GIT_CONFIG_COUNT"] = str(len(keys))
    for i, k in enumerate(keys):
        env[f"GIT_CONFIG_KEY_{i}"] = k
        env[f"GIT_CONFIG_VALUE_{i}"] = ""
    return env, 0

def is_excluded(p):
    return p == b"" or p == b"AGENTS.md" or p == b".lazyagents" or p.startswith(b".lazyagents/")

def parse_numstat_meta(b):
    if not b:
        return 0, [], [], {}
    toks = b.rstrip(b"\x00").split(b"\x00")
    entries = 0
    changed_paths = []
    renamed_old = []
    changed_binary = {}
    i = 0
    while i < len(toks):
        parts = toks[i].split(b"\t", 2)
        if len(parts) != 3:
            break
        is_bin = parts[0] == b"-" and parts[1] == b"-"
        path = parts[2]
        if path == b"":
            if i + 2 >= len(toks):
                break
            old_p, path = toks[i + 1], toks[i + 2]
            renamed_old.append(old_p)
            i += 3
        else:
            i += 1
        entries += 1
        changed_paths.append(path)
        changed_binary[path] = is_bin
    return entries, changed_paths, renamed_old, changed_binary

def run_code_changes(cwd, fenv, base, pathspec, diff_limit, untracked_limit, max_files):
    base_bytes = base if isinstance(base, str) else base.decode("utf-8", "surrogateescape")
    args_prefix = ["diff", "--no-ext-diff", "--no-textconv", "-M", "--src-prefix=a/", "--dst-prefix=b/"]
    nc, ncut, numstat = run_git(args_prefix + ["--numstat", "-z", base_bytes] + pathspec, cwd, fenv, 1 << 20)
    emit("numstat", nc, ncut, numstat)
    if nc != 0 or ncut:
        return 0, [], [], {}
    pc, pcut, patch = run_git(args_prefix + ["-p", "--unified=3", base_bytes] + pathspec, cwd, fenv, diff_limit)
    emit("patch", pc, pcut, patch)
    if pc != 0:
        return 0, [], [], {}
    lc, _, ls_others = run_git(["ls-files", "--others", "--exclude-standard", "-z"], cwd, BASE_ENV, 1 << 20)
    emit("ls_others", lc, False, ls_others)
    if lc != 0:
        return 0, [], [], {}
    tracked_count, changed_paths, renamed_old, changed_binary = parse_numstat_meta(numstat)
    seen = 0
    for f in ls_others.split(b"\x00"):
        if f == b"" or f == b"AGENTS.md" or f.startswith(b".lazyagents/"):
            continue
        if tracked_count + seen >= max_files or seen >= max_files:
            break
        seen += 1
        uc, ucut, uout = run_git(
            [b"diff", b"--no-index", b"--no-ext-diff", b"--no-textconv", b"--src-prefix=a/", b"--dst-prefix=b/", b"--unified=3", b"--", b"/dev/null", f],
            cwd,
            BASE_ENV,
            untracked_limit,
        )
        emit(b"untracked\x00" + f, uc, ucut, uout)
    return tracked_count, changed_paths, renamed_old, changed_binary

mode = req["mode"]
if mode == "signature":
    root = os.path.realpath(os.getcwd())
    pathspec = req["pathspec"]
    for idx, r in enumerate(req.get("repos") or []):
        d = r.get("dir") or "."
        target = os.path.realpath(os.path.join(root, d))
        if target != root and not target.startswith(root + os.sep):
            continue
        if not os.path.isdir(target):
            continue
        fenv, fc = filter_env(target)
        if fenv is None:
            continue
        _, _, st = run_git(["status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all"] + pathspec, target, fenv, 1 << 20)
        _, _, ns = run_git(["diff", "--no-ext-diff", "--no-textconv", "--numstat", "-z", "HEAD"] + pathspec, target, fenv, 1 << 20)
        emit(f"sig\x00{idx}\x00status", 0, False, st)
        emit(f"sig\x00{idx}\x00numstat", 0, False, ns)
elif mode == "code_changes":
    fenv, fc = filter_env(None)
    if fenv is None:
        emit("filter_err", fc, False, b"")
    else:
        run_code_changes(None, fenv, req["base"], req["pathspec"], req["diff_limit"], req["untracked_limit"], req["max_files"])
elif mode == "snapshot":
    hc, _, head_raw = run_git(["rev-parse", "--verify", "-q", "HEAD"], None, BASE_ENV, 4 << 10)
    head = head_raw.strip()
    emit("head", hc, False, head)
    if hc == 0 and COMMIT_RE.match(head):
        head_s = head.decode("ascii")
        bc, _, branch_raw = run_git(["symbolic-ref", "--quiet", "--short", "HEAD"], None, BASE_ENV, 4 << 10)
        emit("branch", bc, False, branch_raw.strip())
        mc, _, merge_raw = run_git(["merge-base", head_s, "refs/remotes/origin/HEAD"], None, BASE_ENV, 4 << 10)
        base = merge_raw.strip()
        if mc != 0 or not COMMIT_RE.match(base):
            cc, _, cfg_raw = run_git(["config", "--get", "vesper.base"], None, BASE_ENV, 4 << 10)
            cfg_base = cfg_raw.strip()
            base = cfg_base if (cc == 0 and COMMIT_RE.match(cfg_base)) else head
        emit("base", 0, False, base)
        base_s = base.decode("ascii")
        if base != head:
            lc, _, log_raw = run_git(["log", "--no-color", "--format=%H\x1f%s\x1e", "-n", "100", f"{base_s}..{head_s}"], None, BASE_ENV, 1 << 20)
            emit("commits", lc, False, log_raw)
        fenv, fc = filter_env(None)
        if fenv is None:
            emit("filter_err", fc, False, b"")
        else:
            pathspec = req["pathspec"]
            _, changed_paths, renamed_old, changed_binary = run_code_changes(
                None, fenv, base_s, pathspec, req["diff_limit"], req["untracked_limit"], req["max_files"]
            )
            sc, _, status_raw = run_git(["status", "--porcelain=v1", "-z", "--untracked-files=normal"] + pathspec, None, fenv, 1 << 20)
            emit("status", sc, False, status_raw)
            lsc, _, ls_files = run_git(["ls-files", "--cached", "--others", "--exclude-standard", "-z"] + pathspec, None, fenv, 2 << 20)
            emit("ls_tree_files", lsc, False, ls_files)
            dc, _, ls_del = run_git(["ls-files", "--deleted", "-z"] + pathspec, None, fenv, 1 << 20)
            emit("ls_deleted", dc, False, ls_del)
            cached_head = req.get("cached_head") or ""
            if lsc == 0 and head_s != cached_head:
                tc, _, ls_tree = run_git(["ls-tree", "-r", "-l", "-z", "HEAD"], None, fenv, 2 << 20)
                emit("ls_tree", tc, False, ls_tree)
                if tc == 0:
                    deleted = set(p for p in ls_del.split(b"\x00") if p)
                    deleted.update(renamed_old)
                    path_set = set()
                    for p in ls_files.split(b"\x00"):
                        if not is_excluded(p) and p not in deleted:
                            path_set.add(p)
                    for p in changed_paths:
                        if not is_excluded(p) and p not in deleted:
                            path_set.add(p)
                    paths = sorted(path_set)[: req["max_tree_files"]]
                    head_size = {}
                    head_blob = set()
                    for rec in ls_tree.split(b"\x00"):
                        if not rec or b"\t" not in rec:
                            continue
                        meta, p = rec.split(b"\t", 1)
                        if is_excluded(p):
                            continue
                        fields = meta.split()
                        if len(fields) >= 4 and fields[1] == b"blob":
                            head_blob.add(p)
                            try:
                                head_size[p] = int(fields[3])
                            except ValueError:
                                head_size[p] = 0
                    changed_set = set(changed_paths)
                    unchanged_cand, changed_cand = [], []
                    queued_budget = 0
                    oversize = req["oversize_file_bytes"]
                    max_file = req["max_file_bytes"]
                    total_limit = req["max_tree_total_bytes"] * 2
                    for p in paths:
                        if p not in head_blob or head_size.get(p, 0) > oversize:
                            continue
                        if p in changed_set:
                            if not changed_binary.get(p, False):
                                changed_cand.append(p)
                        else:
                            sz = min(head_size.get(p, 0), max_file)
                            if queued_budget < total_limit:
                                unchanged_cand.append(p)
                                queued_budget += sz
                    candidates = unchanged_cand + changed_cand
                    if candidates:
                        arc_env = dict(fenv)
                        arc_env["GIT_LITERAL_PATHSPECS"] = "1"
                        seen_tar = set()
                        for idx, start in enumerate(range(0, len(candidates), 100)):
                            chunk = candidates[start : start + 100]
                            ac, _, tar_bytes = run_git([b"archive", b"--format=tar", b"HEAD", b"--"] + chunk, None, arc_env, 4 << 20)
                            if ac == 0 and tar_bytes:
                                emit(f"tar\x00{idx}", ac, False, tar_bytes)
                                try:
                                    with tarfile.open(fileobj=io.BytesIO(tar_bytes), mode="r:*") as tf:
                                        for m in tf.getmembers():
                                            if m.isdir() or m.type in (tarfile.XHDTYPE, tarfile.XGLTYPE):
                                                continue
                                            nm = m.name[2:] if m.name.startswith("./") else m.name
                                            seen_tar.add(nm.encode("utf-8", "surrogateescape"))
                                except Exception:
                                    pass
                        fallback_fetched = 0
                        for p in candidates:
                            if p in seen_tar:
                                continue
                            if fallback_fetched >= total_limit:
                                break
                            gc, _, raw = run_git([b"show", b"HEAD:" + p], None, fenv, oversize + 1)
                            if gc == 0:
                                emit(b"show\x00" + p, gc, False, raw)
                                fallback_fetched += min(len(raw), max_file)
`

func (r *Runner) runGitBatch(ctx context.Context, runID string, req gitBatchRequest) (*gitBatchResult, error) {
	reqJSON, err := json.Marshal(req)
	if err != nil {
		return nil, err
	}
	proc, err := r.Backend.Start(ctx, runID, ExecSpec{
		Name: "lazyagents-git-" + runID + "-" + uuid.NewString()[:8],
		Argv: []string{"python3", "-c", gitBatchScript, string(reqJSON)},
		Env:  map[string]string{"GIT_TERMINAL_PROMPT": "0", "GIT_OPTIONAL_LOCKS": "0"},
		Dir:  gitDirectory(ctx),
	})
	if err != nil {
		return nil, err
	}
	res := &gitBatchResult{byKey: map[string]gitBatchRecord{}}
	var readErr error
	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		br := bufio.NewReaderSize(proc.Stdout(), 64<<10)
		var hdr [13]byte
		for {
			_, err := io.ReadFull(br, hdr[:])
			if err == io.EOF {
				return
			}
			if err != nil {
				readErr = err
				_, _ = io.Copy(io.Discard, br)
				return
			}
			keyLen := binary.BigEndian.Uint32(hdr[0:4])
			code := int(int32(binary.BigEndian.Uint32(hdr[4:8])))
			cut := hdr[8] != 0
			dataLen := binary.BigEndian.Uint32(hdr[9:13])
			if keyLen > 1<<20 || dataLen > 32<<20 {
				readErr = fmt.Errorf("git batch frame too large: key=%d data=%d", keyLen, dataLen)
				_, _ = io.Copy(io.Discard, br)
				return
			}
			keyBuf := make([]byte, keyLen)
			if _, err := io.ReadFull(br, keyBuf); err != nil {
				readErr = err
				_, _ = io.Copy(io.Discard, br)
				return
			}
			var dataBuf []byte
			if dataLen > 0 {
				dataBuf = make([]byte, dataLen)
				if _, err := io.ReadFull(br, dataBuf); err != nil {
					readErr = err
					_, _ = io.Copy(io.Discard, br)
					return
				}
			}
			rec := gitBatchRecord{Key: string(keyBuf), Code: code, Cut: cut, Data: dataBuf}
			res.records = append(res.records, rec)
			res.byKey[rec.Key] = rec
		}
	}()
	go func() { defer wg.Done(); _, _ = io.Copy(io.Discard, proc.Stderr()) }()
	wg.Wait()
	code, waitErr := proc.Wait()
	if c, ok := proc.(io.Closer); ok {
		_ = c.Close()
	}
	if readErr != nil {
		return nil, readErr
	}
	if waitErr != nil || code != 0 {
		return nil, fmt.Errorf("git batch: exit %d: %v", code, waitErr)
	}
	return res, nil
}
