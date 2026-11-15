package runs

import (
	"testing"

	"github.com/liamphmurphy/vesper/server/internal/store"
)

func TestImageOutboxTool(t *testing.T) {
	sid := "019e-thread"
	run := store.Run{HarnessSessionID: &sid}
	src := "/home/u/.codex/generated_images/" + sid + "/ig_1.png"
	cp := func(s, d string) ToolCheck {
		return ToolCheck{Tool: "Bash", Input: map[string]any{"command": "cp " + s + " " + d}}
	}
	cases := []struct {
		name string
		run  store.Run
		in   ToolCheck
		want bool
	}{
		{"valid", run, cp(src, ".lazyagents/outbox/a.png"), true},
		{"valid upper ext flags", run, cp("-f "+src, ".lazyagents/outbox/a.JPG"), true},
		{"mkdir", run, ToolCheck{Tool: "Bash", Input: map[string]any{"command": "mkdir -p .lazyagents/outbox"}}, true},
		{"glob", run, cp("/home/u/.codex/generated_images/*/*", ".lazyagents/outbox/."), false},
		{"glob in dst name", run, cp(src, ".lazyagents/outbox/*.png"), false},
		{"brace", run, cp("/home/u/.codex/generated_images/"+sid+"/{a,b}.png", ".lazyagents/outbox/a.png"), false},
		{"tilde", run, cp("~/.codex/generated_images/"+sid+"/a.png", ".lazyagents/outbox/a.png"), false},
		{"dot dst", run, cp(src, ".lazyagents/outbox/."), false},
		{"dotfile dst", run, cp(src, ".lazyagents/outbox/.hidden.png"), false},
		{"bad ext", run, cp(src, ".lazyagents/outbox/a.sh"), false},
		{"dotfile src", run, cp("/home/u/.codex/generated_images/"+sid+"/.x.png", ".lazyagents/outbox/a.png"), false},
		{"wrong thread", run, cp("/home/u/.codex/generated_images/other/ig.png", ".lazyagents/outbox/a.png"), false},
		{"wrong home dir", run, cp("/home/u/.ssh/generated_images/"+sid+"/ig.png", ".lazyagents/outbox/a.png"), false},
		{"nil session", store.Run{}, cp(src, ".lazyagents/outbox/a.png"), false},
		{"traversal", run, cp("/home/u/../../etc/.codex/generated_images/"+sid+"/x.png", ".lazyagents/outbox/a.png"), false},
		{"passwd", run, cp("/etc/passwd", ".lazyagents/outbox/a.png"), false},
		{"outside dst", run, cp(src, "/tmp/a.png"), false},
		{"subdir dst", run, cp(src, ".lazyagents/outbox/sub/a.png"), false},
		{"chain", run, cp(src, ".lazyagents/outbox/a.png && id"), false},
		{"redirect", run, cp(src, ".lazyagents/outbox/a.png > /tmp/x"), false},
		{"env var", run, cp(src, "$HOME/.lazyagents/outbox/a.png"), false},
		{"recursive", run, cp("-r "+src, ".lazyagents/outbox/a.png"), false},
		{"rm", run, ToolCheck{Tool: "Bash", Input: map[string]any{"command": "rm -rf .lazyagents/outbox"}}, false},
		{"Write tool", run, ToolCheck{Tool: "Write"}, false},
		{"image-generator subagent", run, ToolCheck{Tool: "Agent", Input: map[string]any{"subagent_type": "image-generator", "description": "Image Generator"}}, true},
		{"other subagent", run, ToolCheck{Tool: "Agent", Input: map[string]any{"subagent_type": "general", "description": "helper"}}, false},
		{"nil session tool", store.Run{}, ToolCheck{Tool: "image_generation"}, true},
		// Codex names its files exec-<uuid>.png when the JavaScript orchestrator makes them.
		{"exec uuid file", run, cp("/Users/u/.codex/generated_images/"+sid+"/exec-0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d.png", ".lazyagents/outbox/exec-0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d.png"), true},
	}
	for _, c := range cases {
		var sessions []string
		if c.run.HarnessSessionID != nil {
			sessions = []string{*c.run.HarnessSessionID}
		}
		if got := imageOutboxTool(c.in, sessions); got != c.want {
			t.Errorf("%s: got %v want %v", c.name, got, c.want)
		}
	}
}

func TestImageToolNames(t *testing.T) {
	for name, want := range map[string]bool{
		"image_gen": true, "image_generation": true, "imagegen": true, "ImageGen": true,
		"image_gen__imagegen": true, "image_gen.imagegen": true, "image_genimagegen": true, "tools.image_gen__imagegen": false,
		"mcp__x__image_gen": false, "image_gen_extra": false, "myimagegen": false, "": false, "mcp__lazyagents__generate_image": false,
		"Bash":           false,
		"generate_image": true, // Antigravity's built-in generator
	} {
		if got := imageToolName(name); got != want {
			t.Errorf("%q: got %v want %v", name, got, want)
		}
		if got := imageOutboxTool(ToolCheck{Tool: name}, nil); got != want {
			t.Errorf("outbox %q: got %v want %v", name, got, want)
		}
	}
}

func TestImageOutboxSessions(t *testing.T) {
	src := func(sid string) ToolCheck {
		return ToolCheck{Tool: "shell", Input: map[string]any{"command": "cp /h/.codex/generated_images/" + sid + "/exec-1.png .lazyagents/outbox/a.png"}}
	}
	if !imageOutboxTool(src("a"), []string{"x", "a"}) || imageOutboxTool(src("b"), []string{"x", "a"}) || imageOutboxTool(src("a"), nil) || imageOutboxTool(src(""), []string{""}) {
		t.Fatal("session membership is wrong")
	}
}
