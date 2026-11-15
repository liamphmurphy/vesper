package runner

import (
	"bytes"
	"fmt"
	"strconv"
	"strings"
	"unicode/utf8"
)

// Limits on what a coding chat turn reports about its changes (the contract's
// ChatCodeChange). Over budget, a file's patch is left out and marked truncated.
const (
	CodeChangeMaxFiles      = 50
	CodeChangeMaxPatchBytes = 40 << 10
	CodeChangeMaxTotalBytes = 200 << 10
)

// Limits on the reviewed branch file tree snapshot (CodeReviewFile).
const (
	CodeReviewMaxTreeFiles      = 1000
	CodeReviewMaxFileBytes      = 40 << 10
	CodeReviewOversizeFileBytes = 128 << 10
	CodeReviewMaxTreeTotalBytes = 256 << 10
)

// CodeReviewFile is one file in the reviewed branch tree snapshot.
type CodeReviewFile struct {
	Path      string  `json:"path"`
	Size      int     `json:"size"`
	Binary    bool    `json:"binary"`
	Content   *string `json:"content,omitempty"`
	Truncated bool    `json:"truncated"`
}

// CodeChange is one file a coding chat turn changed. Its JSON is the
// contract's ChatCodeChange, stored on the assistant message as is.
type CodeChange struct {
	Repository string  `json:"repository,omitempty"`
	Path       string  `json:"path"`
	OldPath    *string `json:"old_path,omitempty"`
	Status     string  `json:"status"` // added | modified | deleted | renamed
	Additions  int     `json:"additions"`
	Deletions  int     `json:"deletions"`
	Binary     bool    `json:"binary"`
	Patch      *string `json:"patch,omitempty"`
	Truncated  bool    `json:"truncated"`
}

// numstatEntry is one record of `git diff --numstat -z`.
type numstatEntry struct {
	path, oldPath        string
	additions, deletions int
	binary               bool
}

// parseNumstat reads `git diff --numstat -z` output: "add<TAB>del<TAB>path NUL",
// and for a rename "add<TAB>del<TAB> NUL old NUL new NUL". Binary files count "-".
func parseNumstat(b []byte) ([]numstatEntry, error) {
	if len(b) == 0 {
		return nil, nil
	}
	toks := bytes.Split(bytes.TrimSuffix(b, []byte{0}), []byte{0})
	var out []numstatEntry
	for i := 0; i < len(toks); i++ {
		f := strings.SplitN(string(toks[i]), "\t", 3)
		if len(f) != 3 {
			return nil, fmt.Errorf("unexpected numstat record %q", toks[i])
		}
		e := numstatEntry{path: f[2]}
		if f[0] == "-" && f[1] == "-" {
			e.binary = true
		} else {
			var err1, err2 error
			e.additions, err1 = strconv.Atoi(f[0])
			e.deletions, err2 = strconv.Atoi(f[1])
			if err1 != nil || err2 != nil {
				return nil, fmt.Errorf("unexpected numstat counts in %q", toks[i])
			}
		}
		if f[2] == "" { // rename: the next two records are the old and new path
			if i+2 > len(toks)-1 {
				return nil, fmt.Errorf("truncated numstat rename record")
			}
			e.oldPath, e.path = string(toks[i+1]), string(toks[i+2])
			i += 2
		}
		out = append(out, e)
	}
	return out, nil
}

// patchSection is one file of `git diff -p`: its metadata flags and hunks.
type patchSection struct {
	header                  string // the "diff --git a/x b/y" line
	added, deleted, renamed bool
	binary                  bool
	hunks                   string // from the first @@ line
}

// splitPatch cuts `git diff -p` output into its per-file sections. A hunk line
// always starts with a space, +, - or \, so "diff --git " only starts a section.
func splitPatch(patch string) []patchSection {
	var out []patchSection
	var cur *patchSection
	var hunks strings.Builder
	flush := func() {
		if cur != nil {
			cur.hunks = hunks.String()
			out = append(out, *cur)
		}
		hunks.Reset()
	}
	inHunks := false
	for _, line := range strings.SplitAfter(patch, "\n") {
		if line == "" {
			continue
		}
		if strings.HasPrefix(line, "diff --git ") {
			flush()
			cur, inHunks = &patchSection{header: strings.TrimRight(line, "\n")}, false
			continue
		}
		if cur == nil {
			continue
		}
		if inHunks {
			hunks.WriteString(line)
			continue
		}
		switch {
		case strings.HasPrefix(line, "@@"):
			inHunks = true
			hunks.WriteString(line)
		case strings.HasPrefix(line, "new file mode"):
			cur.added = true
		case strings.HasPrefix(line, "deleted file mode"):
			cur.deleted = true
		case strings.HasPrefix(line, "rename from "), strings.HasPrefix(line, "rename to "):
			cur.renamed = true
		case strings.HasPrefix(line, "Binary files "), strings.HasPrefix(line, "GIT binary patch"):
			cur.binary = true
		}
	}
	flush()
	return out
}

// countHunkLines counts the added and removed lines of a section's hunks.
func countHunkLines(hunks string) (add, del int) {
	for _, line := range strings.Split(hunks, "\n") {
		switch {
		case strings.HasPrefix(line, "+"):
			add++
		case strings.HasPrefix(line, "-"):
			del++
		}
	}
	return add, del
}

// plainPath reports a path git writes in a diff header unquoted, so the
// header can be checked against the numstat's path.
func plainPath(p string) bool {
	return !strings.ContainsAny(p, "\"\\") && !strings.ContainsFunc(p, func(r rune) bool { return r < 0x20 || r == 0x7f })
}

// ParseCodeChanges combines `git diff --numstat -z` and `git diff -p` of the
// same comparison (same flags and pathspecs, so the files line up in order).
// patchCut means the patch output was cut by a read limit: its last section is
// dropped as incomplete and files without a section keep no patch.
func ParseCodeChanges(numstat []byte, patch string, patchCut bool) ([]CodeChange, error) {
	entries, err := parseNumstat(numstat)
	if err != nil {
		return nil, err
	}
	secs := splitPatch(patch)
	if patchCut && len(secs) > 0 {
		secs = secs[:len(secs)-1]
	}
	if len(secs) > len(entries) || (!patchCut && len(secs) != len(entries)) {
		return nil, fmt.Errorf("diff has %d files but numstat has %d", len(secs), len(entries))
	}
	out := make([]CodeChange, 0, len(entries))
	for i, e := range entries {
		ch := CodeChange{Path: e.path, Additions: e.additions, Deletions: e.deletions, Binary: e.binary, Status: "modified"}
		if e.oldPath != "" {
			old := e.oldPath
			ch.OldPath, ch.Status = &old, "renamed"
		}
		if i < len(secs) {
			s := secs[i]
			if plainPath(e.path) && s.header != "" && !strings.HasSuffix(s.header, " b/"+e.path) {
				return nil, fmt.Errorf("diff section %q doesn't match %q", s.header, e.path)
			}
			switch {
			case s.added:
				ch.Status = "added"
			case s.deleted:
				ch.Status = "deleted"
			}
			ch.Binary = ch.Binary || s.binary
			if !ch.Binary && s.hunks != "" {
				h := s.hunks
				ch.Patch = &h
			}
		} else if !ch.Binary {
			ch.Truncated = true // the patch output ran out before this file
		}
		out = append(out, ch)
	}
	return out, nil
}

// UntrackedChange renders a new, untracked file from `git diff --no-index`
// against /dev/null. cut means the output hit a read limit.
func UntrackedChange(path, patch string, cut bool) CodeChange {
	ch := CodeChange{Path: path, Status: "added"}
	secs := splitPatch(patch)
	if len(secs) == 0 {
		return ch // an empty file has no hunks
	}
	s := secs[0]
	if s.binary {
		ch.Binary = true
		return ch
	}
	ch.Additions, ch.Deletions = countHunkLines(s.hunks)
	if s.hunks != "" {
		h := s.hunks
		ch.Patch = &h
	}
	ch.Truncated = cut
	return ch
}

// ApplyCodeChangeBudget enforces the contract's limits: at most
// CodeChangeMaxFiles files, and a patch over CodeChangeMaxPatchBytes, or one
// that would take the turn past CodeChangeMaxTotalBytes, is left out and the
// file marked truncated. Patch text is made valid UTF-8.
func ApplyCodeChangeBudget(in []CodeChange) []CodeChange {
	if len(in) > CodeChangeMaxFiles {
		in = in[:CodeChangeMaxFiles]
	}
	total := 0
	for i := range in {
		in[i].Path = strings.ToValidUTF8(in[i].Path, "�")
		if in[i].Patch == nil {
			continue
		}
		p := strings.ToValidUTF8(*in[i].Patch, "�")
		if len(p) > CodeChangeMaxPatchBytes || total+len(p) > CodeChangeMaxTotalBytes || in[i].Truncated {
			in[i].Patch, in[i].Truncated = nil, true
			continue
		}
		total += len(p)
		in[i].Patch = &p
	}
	return in
}

// ApplyCodeTreeBudget bounds a branch tree snapshot without changed-file prioritization.
func ApplyCodeTreeBudget(in []CodeReviewFile) ([]CodeReviewFile, bool) {
	return ApplyCodeTreeBudgetWithChanged(in, nil)
}

// ApplyCodeTreeBudgetWithChanged enforces tree count, per-file, oversize, binary
// and total text-content limits, prioritizing unchanged files in the budget since
// changed files already carry their diffs.
func ApplyCodeTreeBudgetWithChanged(in []CodeReviewFile, changedPaths map[string]bool) ([]CodeReviewFile, bool) {
	treeTruncated := false
	if len(in) > CodeReviewMaxTreeFiles {
		in = in[:CodeReviewMaxTreeFiles]
		treeTruncated = true
	}
	out := make([]CodeReviewFile, len(in))
	copy(out, in)
	total := 0
	applyOne := func(i int) {
		out[i].Path = strings.ToValidUTF8(out[i].Path, "")
		if out[i].Binary || (out[i].Content != nil && strings.IndexByte(*out[i].Content, 0) >= 0) {
			out[i].Binary = true
			out[i].Content = nil
			out[i].Truncated = false
			return
		}
		if out[i].Size > CodeReviewOversizeFileBytes {
			out[i].Binary = false
			out[i].Content = nil
			out[i].Truncated = true
			return
		}
		if out[i].Content == nil {
			return
		}
		s := strings.ToValidUTF8(*out[i].Content, "")
		if out[i].Size == 0 && len(s) > 0 {
			out[i].Size = len(s)
		}
		if len(s) > CodeReviewMaxFileBytes {
			s = s[:CodeReviewMaxFileBytes]
			for len(s) > 0 && !utf8.ValidString(s) {
				s = s[:len(s)-1]
			}
			out[i].Truncated = true
		}
		if total+len(s) > CodeReviewMaxTreeTotalBytes {
			out[i].Content = nil
			out[i].Truncated = true
			return
		}
		total += len(s)
		out[i].Content = &s
	}
	for i := range out {
		if !changedPaths[out[i].Path] {
			applyOne(i)
		}
	}
	for i := range out {
		if changedPaths[out[i].Path] {
			applyOne(i)
		}
	}
	return out, treeTruncated
}
