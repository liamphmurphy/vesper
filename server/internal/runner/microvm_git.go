package runner

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/pushreq"
	"github.com/liamphmurphy/vesper/server/internal/runner/microvm"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

const maxHostBundleBytes = 256 << 20

// HostGitBackend is implemented by backends whose isolation boundary keeps
// git:pat on the host rather than inside run VMs.
type HostGitBackend interface {
	HostGitOnly() bool
}

func (b *MicroVM) HostGitOnly() bool { return true }

// newGitUploadProxy returns an HTTP handler mapped at http://git.vesper.internal
// allowing read-only smart-HTTP git-upload-pack fetches with host-injected PAT
// while rejecting git-receive-pack pushes and unrelated paths.
func newGitUploadProxy(githubBaseURL, token string) http.Handler {
	if githubBaseURL == "" {
		githubBaseURL = "https://github.com"
	}
	target, err := url.Parse(strings.TrimRight(githubBaseURL, "/"))
	if err != nil || target.Host == "" {
		return http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			http.Error(w, "invalid upstream git URL", http.StatusBadGateway)
		})
	}
	authHeader := "Basic " + base64.StdEncoding.EncodeToString([]byte("x-access-token:"+token))
	rp := &httputil.ReverseProxy{
		Rewrite: func(pr *httputil.ProxyRequest) {
			pr.SetURL(target)
			pr.Out.Host = target.Host
			pr.Out.URL.Path = strings.TrimPrefix(pr.In.URL.Path, "/github")
			if token != "" {
				pr.Out.Header.Set("Authorization", authHeader)
			}
		},
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		p := r.URL.Path
		if !strings.HasPrefix(p, "/github/") || strings.Contains(p, "..") {
			http.Error(w, "vesper git proxy: forbidden path", http.StatusForbidden)
			return
		}
		if strings.HasSuffix(p, "/git-receive-pack") || r.URL.Query().Get("service") == "git-receive-pack" {
			http.Error(w, "vesper git proxy: push disabled from microVM (host-side push only)", http.StatusForbidden)
			return
		}
		if strings.HasSuffix(p, "/info/refs") {
			if r.Method != http.MethodGet || r.URL.Query().Get("service") != "git-upload-pack" {
				http.Error(w, "vesper git proxy: only git-upload-pack allowed", http.StatusForbidden)
				return
			}
			rp.ServeHTTP(w, r)
			return
		}
		if strings.HasSuffix(p, "/git-upload-pack") && r.Method == http.MethodPost {
			rp.ServeHTTP(w, r)
			return
		}
		http.Error(w, "vesper git proxy: unsupported git endpoint", http.StatusForbidden)
	})
}

func rewriteGitInsteadOfEnv(env map[string]string, rewriteFrom string) {
	if rewriteFrom == "" {
		rewriteFrom = "https://github.com/"
	}
	if !strings.HasSuffix(rewriteFrom, "/") {
		rewriteFrom += "/"
	}
	idx := 0
	if raw := env["GIT_CONFIG_COUNT"]; raw != "" {
		if n, err := strconv.Atoi(raw); err == nil && n > 0 {
			idx = n
		}
	}
	env[fmt.Sprintf("GIT_CONFIG_KEY_%d", idx)] = "url.http://" + microvm.InternalGitHost + "/github/.insteadOf"
	env[fmt.Sprintf("GIT_CONFIG_VALUE_%d", idx)] = rewriteFrom
	env["GIT_CONFIG_COUNT"] = strconv.Itoa(idx + 1)
}

func (r *Runner) usesHostGitAuth() bool {
	hb, ok := r.Backend.(HostGitBackend)
	return ok && hb.HostGitOnly()
}

func copyGuestFileToHost(ctx context.Context, b Backend, runID, rel, dstPath string, limit int64) error {
	rc, _, err := b.OpenWorkspaceFile(ctx, runID, rel, limit)
	if err != nil {
		return err
	}
	defer rc.Close()
	f, err := os.OpenFile(dstPath, os.O_CREATE|os.O_RDWR|os.O_TRUNC, 0o600)
	if err != nil {
		return err
	}
	defer f.Close()
	if _, err := io.Copy(f, rc); err != nil {
		return err
	}
	return f.Close()
}

func (r *Runner) runHostPushBundle(ctx context.Context, bundleHostPath, bareHostPath, url, destBranch, token string, base bool) (string, error) {
	script := PushBundleScript("push.bundle", filepath.Base(bareHostPath), url, destBranch, base, true)
	hostDir := filepath.Dir(bundleHostPath)
	cmd := exec.CommandContext(ctx, "sh", "-c", script)
	cmd.Dir = hostDir
	cmd.Env = []string{
		"PATH=" + os.Getenv("PATH"),
		"HOME=" + hostDir,
		"TMPDIR=" + hostDir,
		"GH_TOKEN=" + token,
	}
	outBytes, err := cmd.CombinedOutput()
	out := redact(string(outBytes), map[string]string{"GH_TOKEN": token})
	return out, err
}

func (r *Runner) stageOnHost(ctx context.Context, c runCtx, req store.PushRequest, dir, repoURL, token string) (store.PushRequest, error) {
	id := req.ID.String()
	staging := pushreq.StagingBranch(req.ID)
	guestBundle := bundlePath(id)
	defer func() {
		_, _ = r.runScript(context.WithoutCancel(ctx), c.run.ID, "lazyagents-push-cleanup", "rm -rf "+shellQuote(stageDir(id))+" "+shellQuote(guestBundle), nil)
	}()

	out, err := r.runScript(ctx, c.run.ID, "lazyagents-push-bundle", BundleScript(dir, "refs/heads/"+req.Branch, guestBundle), nil)
	if err != nil {
		return req, &pushreq.Refusal{Reason: "Couldn't stage " + req.Branch + ": " + lastLine(out, err)}
	}
	if !strings.Contains(out, bundleMarker) {
		return req, &pushreq.Refusal{Reason: req.Branch + " has no commits GitHub doesn't already have. Commit the work, then ask again."}
	}

	hostTmp, err := os.MkdirTemp("", "vesper-stage-*")
	if err != nil {
		return req, err
	}
	defer os.RemoveAll(hostTmp)
	hostBundle := filepath.Join(hostTmp, "push.bundle")
	if err := copyGuestFileToHost(ctx, r.Backend, c.run.ID.String(), guestBundle, hostBundle, maxHostBundleBytes); err != nil {
		return req, fmt.Errorf("read staged bundle: %w", err)
	}
	hostBare := filepath.Join(hostTmp, "stage.git")
	out, err = r.runHostPushBundle(ctx, hostBundle, hostBare, repoURL, staging, token, true)
	if err != nil {
		return req, &pushreq.Refusal{Reason: "Couldn't stage " + req.Branch + ": " + PushErrorDetail(out, err)}
	}
	baseBranch, base := markerValue(out, stagedMarker), markerValue(out, baseMarker)
	if baseBranch == "" {
		return req, &pushreq.Refusal{Reason: "Couldn't stage " + req.Branch + ": " + PushErrorDetail(out, nil)}
	}
	if baseBranch == req.Branch {
		return req, &pushreq.Refusal{Reason: req.Branch + " is the default branch; push a work branch instead."}
	}

	head := hostGitLine(ctx, hostBare, "rev-parse", "--verify", "-q", "refs/heads/stage")
	if !commitRe.MatchString(head) || !commitRe.MatchString(base) {
		return req, &pushreq.Refusal{Reason: req.Branch + " shares no history with the repository on GitHub."}
	}
	commits := hostCommitList(ctx, hostBare, base, head)
	files, derr := hostCommitChanges(ctx, hostBare, base, head, map[string]string{"GH_TOKEN": token})
	if derr != nil {
		r.Log.Warn("staged diff", "id", id, "err", derr)
		files = []CodeChange{}
	}
	commitsJSON, _ := json.Marshal(commits)
	filesJSON, _ := json.Marshal(files)
	return r.q().SetPushRequestStaged(ctx, store.SetPushRequestStagedParams{
		ID: req.ID, BaseBranch: &baseBranch, BaseSha: &base,
		HeadSha: &head, StagingRef: &staging, Commits: commitsJSON, Files: filesJSON,
	})
}

func hostGitCmd(ctx context.Context, bareDir string, limit int, args ...string) ([]byte, bool, int, error) {
	fullArgs := append([]string{"-C", bareDir, "-c", "core.hooksPath=/dev/null"}, args...)
	cmd := exec.CommandContext(ctx, "git", fullArgs...)
	cmd.Env = []string{
		"PATH=" + os.Getenv("PATH"),
		"GIT_CONFIG_GLOBAL=/dev/null",
		"GIT_CONFIG_NOSYSTEM=1",
	}
	out, err := cmd.Output()
	if err != nil {
		var ee *exec.ExitError
		if errors.As(err, &ee) {
			return out, false, ee.ExitCode(), nil
		}
		return out, false, -1, err
	}
	cut := false
	if limit > 0 && len(out) > limit {
		out = out[:limit]
		cut = true
	}
	return out, cut, 0, nil
}

func hostGitLine(ctx context.Context, bareDir string, args ...string) string {
	out, _, code, err := hostGitCmd(ctx, bareDir, 0, args...)
	if err != nil || code != 0 {
		return ""
	}
	return strings.TrimSpace(string(out))
}

func hostCommitList(ctx context.Context, bareDir, base, head string) []pushreq.Commit {
	if base == head {
		return []pushreq.Commit{}
	}
	out, _, code, err := hostGitCmd(ctx, bareDir, 1<<20, "log", "--no-color", "--format=%H%x1f%s%x1e", "-n", "100", base+".."+head)
	if err != nil || code != 0 {
		return []pushreq.Commit{}
	}
	return parseCommitList(out)
}

func hostCommitChanges(ctx context.Context, bareDir, from, to string, env map[string]string) ([]CodeChange, error) {
	args := func(mode ...string) []string {
		a := append([]string{"diff", "--no-ext-diff", "--no-textconv", "-M", "--src-prefix=a/", "--dst-prefix=b/"}, mode...)
		return append(a, from, to, "--")
	}
	numstat, cut, code, err := hostGitCmd(ctx, bareDir, 1<<20, args("--numstat", "-z")...)
	if err != nil || code != 0 || cut {
		return nil, fmt.Errorf("git diff --numstat: exit %d: %v", code, err)
	}
	patch, patchCut, code, err := hostGitCmd(ctx, bareDir, codeDiffReadLimit, args("-p", "--unified=3")...)
	if err != nil || code != 0 {
		return nil, fmt.Errorf("git diff -p: exit %d: %v", code, err)
	}
	changes, err := ParseCodeChanges(numstat, string(patch), patchCut)
	if err != nil {
		return nil, err
	}
	changes = ApplyCodeChangeBudget(changes)
	for i := range changes {
		if changes[i].Patch != nil {
			p := redact(*changes[i].Patch, env)
			changes[i].Patch = &p
		}
	}
	return changes, nil
}

func pathOrDot(dir, suffix string) string {
	if dir == "" || dir == "." {
		if suffix == "" {
			return "."
		}
		return suffix
	}
	if suffix == "" {
		return dir
	}
	return filepath.ToSlash(filepath.Join(dir, suffix))
}

func (r *Runner) pushCheckpointOnHost(ctx context.Context, runUUID uuid.UUID, dir, branch, repoURL, token string) (string, error) {
	runID := runUUID.String()
	commitScript := "if [ ! -d " + shellQuote(pathOrDot(dir, ".git")) + " ]; then echo vesper-checkpoint-absent; exit 0; fi\n" +
		"(cd " + shellQuote(pathOrDot(dir, "")) + "\n" + ChatCheckpointCommitScript() + ")\n"
	out, err := r.runScript(ctx, runUUID, "lazyagents-checkpoint", commitScript, nil)
	if err != nil || strings.Contains(out, "vesper-checkpoint-absent") {
		return out, err
	}
	guestBundle := pushRoot + "/checkpoint-" + runID + ".bundle"
	defer func() {
		_, _ = r.runScript(context.WithoutCancel(ctx), runUUID, "lazyagents-checkpoint-cleanup", "rm -f "+shellQuote(guestBundle), nil)
	}()
	if out, err = r.runScript(ctx, runUUID, "lazyagents-checkpoint-bundle", BundleScript(pathOrDot(dir, ""), chatCheckpointRef, guestBundle), nil); err != nil {
		return out, err
	}
	if !strings.Contains(out, bundleMarker) {
		return "", nil
	}
	hostTmp, err := os.MkdirTemp("", "vesper-ckpt-*")
	if err != nil {
		return "", err
	}
	defer os.RemoveAll(hostTmp)
	hostBundle := filepath.Join(hostTmp, "push.bundle")
	if err := copyGuestFileToHost(ctx, r.Backend, runID, guestBundle, hostBundle, maxHostBundleBytes); err != nil {
		return "", fmt.Errorf("read checkpoint bundle: %w", err)
	}
	pushURL := repoURL
	pushTok := ""
	if u, ok := pushreq.HTTPSURL(repoURL); ok {
		pushURL = u
		pushTok = token
	}
	hostBare := filepath.Join(hostTmp, "ckpt.git")
	if _, err := r.runHostPushBundle(ctx, hostBundle, hostBare, pushURL, branch, pushTok, false); err != nil {
		return "", err
	}
	return checkpointPushed, nil
}
