package runner

import (
	"strings"
	"testing"
)

func str(p *string) string {
	if p == nil {
		return "<nil>"
	}
	return *p
}

func TestParseCodeChanges(t *testing.T) {
	const hunkA = "@@ -1,2 +1,3 @@\n a\n+b\n c\n"
	const hunkB = "@@ -1 +1 @@\n-x\n+y\n@@ -10 +10,2 @@\n z\n+w\n"
	patch := "diff --git a/mod.go b/mod.go\nindex 1..2 100644\n--- a/mod.go\n+++ b/mod.go\n" + hunkB +
		"diff --git a/new.txt b/new.txt\nnew file mode 100644\nindex 0..3\n--- /dev/null\n+++ b/new.txt\n" + hunkA +
		"diff --git a/gone.txt b/gone.txt\ndeleted file mode 100644\nindex 4..0\n--- a/gone.txt\n+++ /dev/null\n@@ -1 +0,0 @@\n-bye\n" +
		"diff --git a/old name.txt b/new name.txt\nsimilarity index 80%\nrename from old name.txt\nrename to new name.txt\nindex 5..6 100644\n--- a/old name.txt\n+++ b/new name.txt\n@@ -1 +1 @@\n-o\n+n\n" +
		"diff --git a/img.png b/img.png\nindex 7..8 100644\nBinary files a/img.png and b/img.png differ\n" +
		"diff --git a/pure.txt b/moved.txt\nsimilarity index 100%\nrename from pure.txt\nrename to moved.txt\n" +
		"diff --git a/mode.sh b/mode.sh\nold mode 100644\nnew mode 100755\n"
	numstat := "2\t2\tmod.go\x00" + "1\t0\tnew.txt\x00" + "0\t1\tgone.txt\x00" + "1\t1\t\x00old name.txt\x00new name.txt\x00" +
		"-\t-\timg.png\x00" + "0\t0\t\x00pure.txt\x00moved.txt\x00" + "0\t0\tmode.sh\x00"
	got, err := ParseCodeChanges([]byte(numstat), patch, false)
	if err != nil {
		t.Fatal(err)
	}
	type want struct {
		path, old, status string
		add, del          int
		binary, hasPatch  bool
	}
	wants := []want{
		{"mod.go", "", "modified", 2, 2, false, true},
		{"new.txt", "", "added", 1, 0, false, true},
		{"gone.txt", "", "deleted", 0, 1, false, true},
		{"new name.txt", "old name.txt", "renamed", 1, 1, false, true},
		{"img.png", "", "modified", 0, 0, true, false},
		{"moved.txt", "pure.txt", "renamed", 0, 0, false, false},
		{"mode.sh", "", "modified", 0, 0, false, false},
	}
	if len(got) != len(wants) {
		t.Fatalf("%d changes, want %d: %+v", len(got), len(wants), got)
	}
	for i, w := range wants {
		g := got[i]
		old := ""
		if g.OldPath != nil {
			old = *g.OldPath
		}
		if g.Path != w.path || old != w.old || g.Status != w.status || g.Additions != w.add || g.Deletions != w.del || g.Binary != w.binary || (g.Patch != nil) != w.hasPatch || g.Truncated {
			t.Errorf("change %d = %+v (patch %q), want %+v", i, g, str(g.Patch), w)
		}
	}
	if str(got[0].Patch) != hunkB || str(got[1].Patch) != hunkA || strings.Contains(str(got[0].Patch), "diff --git") || strings.Contains(str(got[0].Patch), "+++") {
		t.Errorf("patch isn't just the hunks: %q", str(got[0].Patch))
	}
}

func TestParseCodeChangesErrorsAndCut(t *testing.T) {
	if got, err := ParseCodeChanges(nil, "", false); err != nil || len(got) != 0 {
		t.Fatalf("empty: %v %v", got, err)
	}
	if _, err := ParseCodeChanges([]byte("garbage\x00"), "", false); err == nil {
		t.Error("garbage numstat accepted")
	}
	if _, err := ParseCodeChanges([]byte("1\t1\ta\x00"), "diff --git a/zzz b/zzz\n@@ -1 +1 @@\n-a\n+b\n", false); err == nil {
		t.Error("mismatched section accepted")
	}
	if _, err := ParseCodeChanges([]byte("1\t1\ta\x00"), "", false); err == nil {
		t.Error("missing section accepted")
	}
	// A cut patch drops its partial last section; later files keep no patch.
	numstat := "1\t1\ta\x00" + "1\t1\tb\x00" + "1\t1\tc\x00"
	patch := "diff --git a/a b/a\n@@ -1 +1 @@\n-1\n+2\ndiff --git a/b b/b\n@@ -1 +1 @@\n-par"
	got, err := ParseCodeChanges([]byte(numstat), patch, true)
	if err != nil {
		t.Fatal(err)
	}
	if got[0].Patch == nil || got[0].Truncated || got[1].Patch != nil || !got[1].Truncated || got[2].Patch != nil || !got[2].Truncated {
		t.Fatalf("cut handling: %+v", got)
	}
}

func TestUntrackedChange(t *testing.T) {
	text := "diff --git a/n.txt b/n.txt\nnew file mode 100644\nindex 0..1\n--- /dev/null\n+++ b/n.txt\n@@ -0,0 +1,2 @@\n+one\n+two\n"
	ch := UntrackedChange("n.txt", text, false)
	if ch.Status != "added" || ch.Additions != 2 || ch.Deletions != 0 || ch.Binary || ch.Truncated || str(ch.Patch) != "@@ -0,0 +1,2 @@\n+one\n+two\n" {
		t.Errorf("text: %+v", ch)
	}
	bin := UntrackedChange("b.bin", "diff --git a/b.bin b/b.bin\nnew file mode 100644\nBinary files /dev/null and b/b.bin differ\n", false)
	if !bin.Binary || bin.Patch != nil || bin.Status != "added" {
		t.Errorf("binary: %+v", bin)
	}
	if empty := UntrackedChange("e", "diff --git a/e b/e\nnew file mode 100644\nindex 0..0\n", false); empty.Patch != nil || empty.Additions != 0 {
		t.Errorf("empty: %+v", empty)
	}
}

func TestApplyCodeChangeBudget(t *testing.T) {
	mk := func(n int) *string { s := strings.Repeat("x", n); return &s }
	var in []CodeChange
	in = append(in,
		CodeChange{Path: "ok", Patch: mk(100)},
		CodeChange{Path: "big", Patch: mk(CodeChangeMaxPatchBytes + 1)},
		CodeChange{Path: "edge", Patch: mk(CodeChangeMaxPatchBytes)},
	)
	for i := 0; i < 4; i++ { // 40 KB each: the total budget runs out
		in = append(in, CodeChange{Path: "f" + string(rune('0'+i)), Patch: mk(CodeChangeMaxPatchBytes)})
	}
	got := ApplyCodeChangeBudget(in)
	if got[0].Patch == nil || got[0].Truncated {
		t.Errorf("small patch: %+v", got[0])
	}
	if got[1].Patch != nil || !got[1].Truncated {
		t.Errorf("oversized patch kept: %+v", got[1])
	}
	if got[2].Patch == nil {
		t.Error("a patch of exactly the limit is allowed")
	}
	kept := 0
	total := 0
	for _, c := range got {
		if c.Patch != nil {
			kept++
			total += len(*c.Patch)
		} else if !c.Truncated {
			t.Errorf("%s lost its patch without being marked truncated", c.Path)
		}
	}
	if total > CodeChangeMaxTotalBytes || kept == len(got)-1 {
		t.Errorf("total %d bytes in %d patches", total, kept)
	}
	// The file count is bounded.
	many := make([]CodeChange, CodeChangeMaxFiles+5)
	if got := ApplyCodeChangeBudget(many); len(got) != CodeChangeMaxFiles {
		t.Errorf("%d files kept", len(got))
	}
	// Invalid UTF-8 is replaced so the JSON stays valid.
	bad := "a\xffb"
	if got := ApplyCodeChangeBudget([]CodeChange{{Path: "p", Patch: &bad}}); !strings.Contains(*got[0].Patch, "�") {
		t.Error("invalid UTF-8 kept")
	}
}

func TestApplyCodeTreeBudgetWithChanged(t *testing.T) {
	mk := func(s string) *string { return &s }
	files := []CodeReviewFile{
		{Path: "ok.txt", Size: 5, Content: mk("hello")},
		{Path: "bin.dat", Size: 4, Content: mk("a\x00bc")},
		{Path: "huge.bin", Size: CodeReviewOversizeFileBytes + 1, Content: mk("big")},
		{Path: "slice.txt", Size: CodeReviewMaxFileBytes + 10, Content: mk(strings.Repeat("a", CodeReviewMaxFileBytes+10))},
		{Path: "changed.txt", Size: 20 << 10, Content: mk(strings.Repeat("c", 20<<10))},
	}
	// Fill budget with unchanged files to verify changed files yield cleanly.
	for i := 0; i < 6; i++ {
		body := strings.Repeat("b", CodeReviewMaxFileBytes)
		files = append(files, CodeReviewFile{Path: "pad" + string(rune('0'+i)) + ".txt", Size: len(body), Content: &body})
	}
	changed := map[string]bool{"changed.txt": true}
	got, treeTrunc := ApplyCodeTreeBudgetWithChanged(files, changed)
	if treeTrunc {
		t.Error("did not expect treeTrunc for 12 files")
	}
	byPath := map[string]CodeReviewFile{}
	for _, f := range got {
		byPath[f.Path] = f
	}
	if !byPath["bin.dat"].Binary || byPath["bin.dat"].Content != nil || byPath["bin.dat"].Truncated {
		t.Errorf("bin.dat = %+v", byPath["bin.dat"])
	}
	if byPath["huge.bin"].Binary || byPath["huge.bin"].Content != nil || !byPath["huge.bin"].Truncated {
		t.Errorf("huge.bin = %+v", byPath["huge.bin"])
	}
	if byPath["slice.txt"].Content == nil || len(*byPath["slice.txt"].Content) != CodeReviewMaxFileBytes || !byPath["slice.txt"].Truncated {
		t.Errorf("slice.txt = %+v", byPath["slice.txt"])
	}
	if byPath["ok.txt"].Content == nil || *byPath["ok.txt"].Content != "hello" || byPath["ok.txt"].Truncated {
		t.Errorf("ok.txt = %+v", byPath["ok.txt"])
	}
	if byPath["changed.txt"].Content != nil || !byPath["changed.txt"].Truncated {
		t.Errorf("changed.txt should yield to unchanged budget: %+v", byPath["changed.txt"])
	}
	many := make([]CodeReviewFile, CodeReviewMaxTreeFiles+5)
	for i := range many {
		many[i] = CodeReviewFile{Path: "f"}
	}
	trimmed, trunc := ApplyCodeTreeBudget(many)
	if len(trimmed) != CodeReviewMaxTreeFiles || !trunc {
		t.Errorf("trimmed=%d trunc=%v", len(trimmed), trunc)
	}
}
