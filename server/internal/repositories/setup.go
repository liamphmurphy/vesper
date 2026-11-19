package repositories

import (
	"strings"

	"github.com/liamphmurphy/vesper/server/internal/personas"
)

const BranchConfig = "vesper.branch"

func quote(s string) string { return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'" }

func PrePushHook(known []string) string {
	refs := make([]string, len(known))
	for i, k := range known {
		refs[i] = "refs/heads/" + k
	}
	hook := []string{
		"#!/bin/sh",
		"# Vesper: this chat may push only branches it made (not a hard boundary).",
		"known=" + quote(strings.Join(refs, " ")),
		"pattern=" + quote(personas.WorkBranchPattern),
		`made=$(git config --get-all ` + BranchConfig + ` 2>/dev/null | sed 's|^|refs/heads/|' | tr '\n' ' ')`,
		`while read -r local_ref local_sha remote_ref remote_sha; do`,
		`  case "$local_sha" in *[!0]*) ;; *) echo "vesper: this chat may not delete $remote_ref" >&2; exit 1 ;; esac`,
		`  case " $known $made " in *" $remote_ref "*) continue ;; esac`,
		`  name=${remote_ref#refs/heads/}`,
		`  if [ "$name" = "$remote_ref" ] || ! printf '%s\n' "$name" | grep -Eq "$pattern"; then`,
		`    echo "vesper: name a new branch TYPE/short-description (feat/..., fix/..., chore/...); $remote_ref isn't one" >&2; exit 1`,
		`  fi`,
		`  case "$remote_sha" in *[!0]*) echo "vesper: $remote_ref already exists and wasn't made in this chat; pick another name" >&2; exit 1 ;; esac`,
		`  git config --add ` + BranchConfig + ` "$name"`,
		`  made="$made $remote_ref"`,
		"done",
		"exit 0",
	}
	quoted := make([]string, len(hook))
	for i, l := range hook {
		quoted[i] = quote(l)
	}
	return strings.Join(quoted, " ")
}

// SetupScript is also returned by use_repository: a newly attached checkout
// is prepared during the same agent turn, including the branch guard.
// Inputs are validated identities or server-owned paths, still shell quoted.
func SetupScript(url, dir string, branches []string, checkpoint *string, name, email string) string {
	var b strings.Builder
	b.WriteString("(set -eu\nmkdir -p " + quote(dir) + "\ncd " + quote(dir) + "\n")
	b.WriteString(`helper='!f() { echo username=x-access-token; echo "password=$GH_TOKEN"; }; f'` + "\n")
	b.WriteString("if [ ! -d .git ]; then\nmkdir -p .lazyagents\nrm -rf .lazyagents/clone\n")
	b.WriteString(`git -c credential.helper= -c "credential.https://github.com.helper=$helper" clone --quiet --no-checkout -- ` + quote(url) + " .lazyagents/clone\n")
	b.WriteString("mv .lazyagents/clone/.git .git\nrm -rf .lazyagents/clone\nif git rev-parse -q --verify HEAD >/dev/null; then git reset -q --hard; fi\n")
	// Recovery restores the exact unsaved snapshot before accepting new work.
	if checkpoint != nil && *checkpoint != "" {
		b.WriteString("if git fetch --quiet origin " + quote(*checkpoint) + " 2>/dev/null; then git checkout --quiet --detach FETCH_HEAD; echo '→ recovered checkpoint " + strings.ReplaceAll(*checkpoint, "'", "") + "'; else echo '→ checkpoint " + strings.ReplaceAll(*checkpoint, "'", "") + " is no longer on origin: starting without it'; fi\n")
	}
	b.WriteString("git config vesper.base \"$(git rev-parse HEAD 2>/dev/null || true)\"\nfi\n")
	b.WriteString("git config user.name " + quote(name) + "\ngit config user.email " + quote(email) + "\n")
	b.WriteString(`git config credential.https://github.com.helper "$helper"` + "\n")
	b.WriteString(`if [ -n "${GIT_SSH_COMMAND:-}" ]; then git config core.sshCommand "$GIT_SSH_COMMAND"; fi` + "\n")
	b.WriteString("mkdir -p .git/hooks\nprintf '%s\\n' " + PrePushHook(branches) + " > .git/hooks/pre-push\nchmod +x .git/hooks/pre-push\n")
	b.WriteString("mkdir -p .git/info\nprintf '%s\\n' '/.lazyagents/' >> .git/info/exclude\n)\n")
	return b.String()
}
