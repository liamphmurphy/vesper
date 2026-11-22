package harness

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
)

// TestAgyProbe drives the real `agy` CLI through Vesper's own launcher, settings
// and policy hook, with nothing reaching Google, as the wiki pattern "Verify
// harness adapters against the real CLI safely" asks: env -i, a temp HOME, a
// fake API key, every proxy pointed at a dead port, and GOOGLE_GEMINI_BASE_URL
// pointed at a local stub that scripts the model's replies. Stubs also stand in
// for Vesper's MCP endpoint and tool policy, so the test sees what agy sends
// them. It is the evidence behind docs/contracts/antigravity.md.
//
// Opt-in: AGY_PROBE=1 AGY_BIN=/path/to/agy (needs python3). AGY_RECORD=<dir>
// also writes what agy printed to <dir>/antigravity-{turn,error}.jsonl, the
// fixtures in testdata.
func TestAgyProbe(t *testing.T) {
	bin := os.Getenv("AGY_BIN")
	if os.Getenv("AGY_PROBE") != "1" || bin == "" {
		t.Skip("set AGY_PROBE=1 and AGY_BIN to probe the real agy")
	}
	if _, err := os.Stat(bin); err != nil {
		t.Skipf("no agy at %s", bin)
	}
	if _, err := exec.LookPath("python3"); err != nil {
		t.Skip("python3 is not installed")
	}
	if out, err := exec.Command(bin, "--version").CombinedOutput(); err != nil {
		t.Fatalf("agy --version: %v\n%s", err, out)
	} else {
		t.Logf("agy --version: %s", strings.TrimSpace(string(out)))
	}

	t.Run("turn", func(t *testing.T) {
		p := newAgyProbe(t, bin)
		file := filepath.Join(p.ws, "notes.txt")
		p.gemini.script(
			agyReply{text: "I'll check the tickets.", call: agyCall("call_mcp_tool", map[string]any{"ServerName": "lazyagents", "ToolName": "list_tickets", "Arguments": map[string]any{"q": "probe"}})},
			agyReply{call: agyCall("read_file", map[string]any{"Path": file})},
			agyReply{call: agyCall("run_command", map[string]any{"CommandLine": "go test ./...", "toolSummary": "Run tests", "WaitMsBeforeAsync": 500})},
			// The policy allows this write: the static deny rule must stop it.
			agyReply{call: agyCall("write_file", map[string]any{"Path": filepath.Join(p.ws, "new.txt"), "Content": "x"})},
			agyReply{call: agyCall("invoke_subagent", map[string]any{"TypeName": "general", "Role": "helper", "Prompt": "run ls"})},
			agyReply{text: "Done."},
		)
		p.policy.deny("Bash", "Agent")
		spec := readOnlyChat()
		spec.Skills = []agentdef.Skill{{Name: "probe-skill", Description: "Zebra-unicorn probe skill.", Body: "Say zebra."}}
		out := p.run(t, spec, "antigravity-turn.jsonl")

		// Vesper's eager tools are declared to the model up front; the rest of
		// the server stays lazy, behind a schema read (LAZYAGENTS-254).
		if first := p.gemini.firstRequest(); !strings.Contains(first, `"name":"mcp_lazyagents_list_tickets"`) || strings.Contains(first, "zebra_ref") {
			t.Error("list_tickets (eager) must be declared to the model and read_page (lazy) must not")
		}
		if !strings.Contains(p.gemini.firstRequest(), "probe-skill (") || !strings.Contains(p.gemini.firstRequest(), "Zebra-unicorn probe skill.") {
			t.Error("agy must list the skill Vesper wrote under .agents/skills to the model")
		}
		if got := p.policy.tools(); strings.Join(got, " ") != "mcp__lazyagents__list_tickets Read Bash Write Agent" {
			t.Errorf("the hook must send Vesper's tool names, got %v", got)
		}
		if p.mcp.calls("tools/call") != 1 || !p.mcp.bearer("probe-token") {
			t.Errorf("Vesper's MCP tool must be called once with the run token")
		}
		if _, err := os.Stat(filepath.Join(p.ws, "new.txt")); err == nil {
			t.Error("a read-only chat wrote a file")
		}
		evs, res := out.events, out.res
		want := "lifecycle message tool_call:list_tickets tool_result:list_tickets tool_call:Read tool_result:Read tool_call:Bash tool_result:Bash tool_call:Write tool_result:Write tool_call:Agent tool_result:Agent message usage"
		if got := types(evs); got != want {
			t.Errorf("events:\n got %s\nwant %s", got, want)
		}
		failed := map[string]string{}
		for _, e := range evs {
			if e.Type == "tool_result" && e.Payload["is_error"] == true {
				failed[e.Payload["tool"].(string)] = e.Payload["output"].(string)
			}
		}
		if !strings.Contains(failed["Bash"], "denied by pre-tool hook: probe policy") || !strings.Contains(failed["Write"], "Matches user-configured deny rule") || failed["Agent"] == "" || len(failed) != 3 {
			t.Errorf("failed tools: %v", failed)
		}
		if res.IsError || res.Final != "Done.\n" || res.SessionID == "" {
			t.Errorf("result = %+v", res)
		}
		// Six requests, each 1200 prompt tokens (1000 cached) and 30 + 7 thinking out.
		if u := res.Usage; u.InputTokens != 7200 || u.CachedTokens != 6000 || u.OutputTokens != 222 || u.ToolCalls != 5 {
			t.Errorf("usage = %+v", u)
		}
	})

	t.Run("quota", func(t *testing.T) {
		p := newAgyProbe(t, bin)
		p.gemini.script(agyReply{status: 429, body: `{"error":{"code":429,"message":"You exceeded your current quota, please check your plan and billing details.","status":"RESOURCE_EXHAUSTED","details":[{"@type":"type.googleapis.com/google.rpc.RetryInfo","retryDelay":"41s"}]}}`})
		out := p.run(t, readOnlyChat(), "antigravity-error.jsonl")
		if !out.res.IsError || !out.res.UsageLimited {
			t.Errorf("a 429 must end the turn as a usage limit: %+v", out.res)
		}
		if _, ok := LimitReset(out.res.Error, time.Now()); !ok {
			t.Errorf("no reset time in %q", out.res.Error)
		}
		if out.exit == 0 {
			t.Errorf("agy exits non-zero on a failed turn")
		}
	})

	// agy caps each rule file at 24,000 bytes and cut the repository's AGENTS.md
	// off behind Vesper's section. Placed by InstructionFiles, a section well
	// past the cap and the repository's file both reach the model whole, with
	// no read_file of AGENTS.md (LAZYAGENTS-253). agy also has a ~20k-token
	// budget for all rules together (about 60 KB in 1.5.9): past it, it shows
	// whole rule files as paths to read instead, starting from vesper-01.
	t.Run("instructions", func(t *testing.T) {
		p := newAgyProbe(t, bin)
		var section strings.Builder
		section.WriteString("# Vesper chat\n\nSECTION_HEAD\n")
		// About a heavy chat's size once its playbooks are skills (~40 KB).
		for i := range 22 {
			fmt.Fprintf(&section, "\n## Part %d\n\n%s\n", i, strings.Repeat("Guidance for this part of the chat. ", 50))
		}
		section.WriteString("\nSECTION_TAIL\n")
		files, _ := InstructionFiles(agentdef.HarnessAntigravity, []byte(section.String()))
		for rel, body := range files {
			if rel == AgentsSectionPath {
				continue
			}
			if err := os.MkdirAll(filepath.Join(p.ws, filepath.Dir(rel)), 0o755); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(p.ws, rel), body, 0o644); err != nil {
				t.Fatal(err)
			}
		}
		repo := "# Repository\n\nREPO_HEAD\n" + strings.Repeat("Repository convention line.\n", 300) + "REPO_TAIL\n"
		if err := os.WriteFile(filepath.Join(p.ws, "AGENTS.md"), []byte("\n"+repo), 0o644); err != nil {
			t.Fatal(err)
		}
		p.gemini.script(agyReply{text: "Done."})
		p.run(t, readOnlyChat(), "")
		first := p.gemini.firstRequest()
		if section.Len() < 2*24000*3/4 {
			t.Fatalf("the section is only %d bytes", section.Len())
		}
		for _, want := range []string{"SECTION_HEAD", "Part 21", "SECTION_TAIL", "REPO_HEAD", "REPO_TAIL"} {
			if !strings.Contains(first, want) {
				t.Errorf("%s didn't reach the model", want)
			}
		}
		if strings.Contains(first, "<truncated") || strings.Contains(first, "\\u003ctruncated") {
			t.Error("agy truncated an instruction file")
		}
		if strings.Contains(first, "read it first") {
			t.Error("the prompt still asks for a read of AGENTS.md")
		}
	})

	// An OAuth account's synced preferences can turn agy's terminal sandbox on
	// whatever settings.json says. Vesper's session settings turn it off again,
	// so commands run unsandboxed without BypassSandbox, whose presence sent each
	// one through agy's safety monitor (LAZYAGENTS-252). agy only offers the
	// model BypassSandbox while the sandbox is on, which is what this observes:
	// the sandbox itself can't start in every probe environment.
	sandboxed := func(t *testing.T, withoutSession bool) (string, agyOutcome, string) {
		p := newAgyProbe(t, bin)
		p.accountSettings = map[string]any{"enableTerminalSandbox": true}
		p.withoutSessionSettings = withoutSession
		outside := filepath.Join(t.TempDir(), "unsandboxed.txt")
		p.gemini.script(
			agyReply{call: agyCall("run_command", map[string]any{"CommandLine": "touch '" + outside + "' && echo RAN", "toolSummary": "Write outside workspace", "WaitMsBeforeAsync": 5000})},
			agyReply{text: "Ran it."},
		)
		s := spec("tests:run", "allowed")
		s.Harness, s.Model = agentdef.HarnessAntigravity, ""
		out := p.runWithSettings(t, s, "", `{"modelProvider":"gemini"}`)
		return p.gemini.firstRequest(), out, outside
	}
	t.Run("sandbox_on_without_session_settings", func(t *testing.T) {
		if first, _, _ := sandboxed(t, true); !strings.Contains(first, "BypassSandbox") {
			t.Fatal("the account setting should turn the sandbox on: the probe no longer shows what --settings changes")
		}
	})
	t.Run("sandbox_off", func(t *testing.T) {
		first, out, outside := sandboxed(t, false)
		if out.exit != 0 || out.res.IsError {
			t.Fatalf("exit=%d res=%+v", out.exit, out.res)
		}
		if strings.Contains(first, "BypassSandbox") {
			t.Error("Vesper's session settings must turn agy's terminal sandbox off")
		}
		if _, err := os.Stat(outside); err != nil {
			t.Errorf("run_command must run unsandboxed and create %s: %v", outside, err)
		}
		for _, e := range out.events {
			if e.Type == "tool_call" && strings.Contains(fmt.Sprint(e.Payload), "BypassSandbox") {
				t.Errorf("a command ran with BypassSandbox: %v", e.Payload)
			}
		}
	})

	runACPTurn := func(t *testing.T, p *agyProbe, spec agentdef.Resolved, turn Turn, check PolicyFunc) (Result, []Event) {
		t.Helper()
		ws := Workspace{Dir: p.ws, MCPURL: p.vesperURL + "/mcp", Token: "probe-token", TokenEnv: "LAZYAGENTS_TOKEN", ContainerSandbox: true}
		inv, err := (Antigravity{}).SessionInvocation(ws, turn)
		if err != nil {
			t.Fatal(err)
		}
		var cfg map[string]any
		cfgRel := agyConfigPathForTag(turn.ConfigTag)
		if err := json.Unmarshal(inv.Files[cfgRel], &cfg); err != nil {
			t.Fatal(err)
		}
		cfg["settings"].(map[string]any)["modelProvider"] = "gemini"
		inv.Files[cfgRel], _ = json.Marshal(cfg)
		for rel, body := range inv.Files {
			dst := filepath.Join(p.ws, rel)
			if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(dst, body, 0o644); err != nil {
				t.Fatal(err)
			}
		}
		binDir := t.TempDir()
		if err := os.Symlink(p.bin, filepath.Join(binDir, "agy")); err != nil {
			t.Fatal(err)
		}
		env := []string{
			"HOME=" + p.home,
			"PATH=" + binDir + ":/usr/bin:/bin",
			"NO_COLOR=1",
			"GEMINI_API_KEY=AIzaProbeNotARealKey",
			"GOOGLE_GEMINI_BASE_URL=" + p.gemini.url,
			"HTTPS_PROXY=http://127.0.0.1:9",
			"HTTP_PROXY=http://127.0.0.1:9",
			"ALL_PROXY=http://127.0.0.1:9",
			"NO_PROXY=127.0.0.1,localhost",
		}
		for k, v := range inv.Env {
			env = append(env, k+"="+v)
		}
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
		defer cancel()
		cmd := exec.CommandContext(ctx, inv.Argv[0], inv.Argv[1:]...)
		cmd.Dir, cmd.Env = p.ws, env
		stdin, err := cmd.StdinPipe()
		if err != nil {
			t.Fatal(err)
		}
		stdout, err := cmd.StdoutPipe()
		if err != nil {
			t.Fatal(err)
		}
		var stderr bytes.Buffer
		cmd.Stderr = &stderr
		if err := cmd.Start(); err != nil {
			t.Fatal(err)
		}
		var mu sync.Mutex
		var evs []Event
		res, runErr := (Antigravity{}).RunSession(ctx, stdin, stdout, ws, turn, SessionCallbacks{
			OnEvent: func(ev Event) {
				mu.Lock()
				evs = append(evs, ev)
				mu.Unlock()
			},
			CheckTool: check,
		})
		waitErr := cmd.Wait()
		if runErr != nil || waitErr != nil {
			t.Fatalf("runErr=%v waitErr=%v res=%+v stderr=%s", runErr, waitErr, res, stderr.String())
		}
		return res, evs
	}

	t.Run("session", func(t *testing.T) {
		p := newAgyProbe(t, bin)
		p.policy.deny("Write")
		p.gemini.route = func(body string) (agyReply, bool) {
			if strings.Contains(body, "conversation title generator") {
				return agyReply{text: "Probe Title"}, true
			}
			return agyReply{}, false
		}
		p.gemini.script(
			agyReply{call: agyCall("write_file", map[string]any{"Path": filepath.Join(p.ws, "nope.txt"), "Content": "x"})},
			agyReply{call: agyCall("run_command", map[string]any{"CommandLine": "echo allowed-acp", "toolSummary": "Allowed", "WaitMsBeforeAsync": 5000})},
			agyReply{text: "ACP done."},
		)
		s := spec("repo:read", "allowed", "repo:write", "allowed", "tests:run", "allowed")
		s.Harness = agentdef.HarnessAntigravity
		var mu sync.Mutex
		var checked []string
		res, evs := runACPTurn(t, p, s, Turn{
			Spec:         s,
			Prompt:       "Run probe commands.",
			SystemAppend: "AGY_SYSTEM_APPEND",
			ConfigTag:    "probe-agy",
		}, func(_ context.Context, tool string, in map[string]any) (bool, string) {
			mu.Lock()
			checked = append(checked, tool)
			mu.Unlock()
			return true, ""
		})
		if res.IsError || res.SessionID == "" || res.Final != "ACP done." {
			t.Fatalf("unexpected res=%+v events=%v", res, evs)
		}
		if res.Usage.InputTokens != 3600 || res.Usage.CachedTokens != 3000 || res.Usage.OutputTokens != 111 {
			t.Fatalf("unexpected usage %+v", res.Usage)
		}
		if _, err := os.Stat(filepath.Join(p.ws, "nope.txt")); !os.IsNotExist(err) {
			t.Fatalf("nope.txt should not exist; err=%v", err)
		}
		if !slices.Contains(checked, "Bash") {
			t.Fatalf("expected CheckTool to run for ACP permission request (Bash), got %v", checked)
		}
		if !strings.Contains(p.gemini.firstRequest(), "AGY_SYSTEM_APPEND") {
			t.Errorf("SystemAppend missing from first request")
		}
	})

	t.Run("session_deny", func(t *testing.T) {
		p := newAgyProbe(t, bin)
		p.gemini.route = func(body string) (agyReply, bool) {
			if strings.Contains(body, "conversation title generator") {
				return agyReply{text: "Probe Title"}, true
			}
			return agyReply{}, false
		}
		p.gemini.script(
			agyReply{call: agyCall("run_command", map[string]any{"CommandLine": "echo bad > blocked.txt", "toolSummary": "Blocked", "WaitMsBeforeAsync": 5000})},
		)
		s := spec("repo:read", "allowed", "repo:write", "allowed", "tests:run", "allowed")
		s.Harness = agentdef.HarnessAntigravity
		var mu sync.Mutex
		var checked []string
		_, _ = runACPTurn(t, p, s, Turn{Spec: s, Prompt: "Try blocked command."}, func(_ context.Context, tool string, in map[string]any) (bool, string) {
			mu.Lock()
			checked = append(checked, tool)
			mu.Unlock()
			return false, "denied by probe policy"
		})
		if !slices.Contains(checked, "Bash") {
			t.Fatalf("expected CheckTool to see Bash, got %v", checked)
		}
		if _, err := os.Stat(filepath.Join(p.ws, "blocked.txt")); !os.IsNotExist(err) {
			t.Fatalf("blocked.txt should not exist after ACP reject_once; err=%v", err)
		}
	})

	t.Run("session_resume", func(t *testing.T) {
		p := newAgyProbe(t, bin)
		p.gemini.route = func(body string) (agyReply, bool) {
			if strings.Contains(body, "conversation title generator") {
				return agyReply{text: "Probe Title"}, true
			}
			return agyReply{}, false
		}
		p.gemini.script(
			agyReply{text: "First ACP turn."},
			agyReply{text: "Resumed ACP turn."},
		)
		s := spec("repo:read", "allowed")
		s.Harness = agentdef.HarnessAntigravity
		allowAll := func(context.Context, string, map[string]any) (bool, string) { return true, "" }
		res1, _ := runACPTurn(t, p, s, Turn{Spec: s, Prompt: "First turn."}, allowAll)
		if res1.IsError || res1.SessionID == "" || res1.Final != "First ACP turn." {
			t.Fatalf("turn 1 unexpected: %+v", res1)
		}
		res2, evs2 := runACPTurn(t, p, s, Turn{Spec: s, Prompt: "Second turn.", SessionID: res1.SessionID}, allowAll)
		if res2.IsError || res2.SessionID != res1.SessionID || res2.Final != "Resumed ACP turn." {
			t.Fatalf("turn 2 unexpected: %+v (evs=%v)", res2, evs2)
		}
		if res2.Usage.InputTokens != 1200 || res2.Usage.CachedTokens != 1000 || res2.Usage.OutputTokens != 37 {
			t.Errorf("resumed turn usage %+v (want single-turn counts)", res2.Usage)
		}
		for _, ev := range evs2 {
			if ev.Type == "message" && strings.Contains(fmt.Sprint(ev.Payload), "First ACP turn.") {
				t.Errorf("replayed turn 1 message leaked into turn 2 events: %v", ev)
			}
		}
	})

	t.Run("session_quota", func(t *testing.T) {
		p := newAgyProbe(t, bin)
		p.gemini.route = func(body string) (agyReply, bool) {
			if strings.Contains(body, "conversation title generator") {
				return agyReply{text: "Probe Title"}, true
			}
			return agyReply{status: 429, body: `{"error":{"code":429,"message":"You exceeded your current quota, please check your plan and billing details.","status":"RESOURCE_EXHAUSTED","details":[{"@type":"type.googleapis.com/google.rpc.RetryInfo","retryDelay":"41s"}]}}`}, true
		}
		s := spec("repo:read", "allowed")
		s.Harness = agentdef.HarnessAntigravity
		res, _ := runACPTurn(t, p, s, Turn{Spec: s, Prompt: "Hello"}, func(context.Context, string, map[string]any) (bool, string) { return true, "" })
		if !res.IsError || !res.UsageLimited {
			t.Fatalf("expected IsError && UsageLimited for 429, got %+v", res)
		}
	})

	t.Run("session_subagent_orchestration", func(t *testing.T) {
		p := newAgyProbe(t, bin)
		p.policy.deny("Agent", "schedule")
		p.gemini.route = func(body string) (agyReply, bool) {
			if strings.Contains(body, "conversation title generator") {
				return agyReply{text: "Probe Title"}, true
			}
			return agyReply{}, false
		}
		p.gemini.script(
			agyReply{call: agyCall("run_workflow", map[string]any{"Description": "Fan out", "Script": "print('hi')"})},
			agyReply{call: agyCall("schedule", map[string]any{"DurationSeconds": 60, "Prompt": "check later"})},
			agyReply{call: agyCall("mcp_lazyagents_run_subagent", map[string]any{"type": "explorer", "role": "Scope Reader", "prompt": "find notes", "toolSummary": "Explore notes"})},
			agyReply{call: agyCall("mcp_lazyagents_run_subagents", map[string]any{"tasks": []any{map[string]any{"type": "explorer", "role": "Reader A", "prompt": "a"}, map[string]any{"type": "explorer", "role": "Reader B", "prompt": "b"}}, "toolSummary": "Explore batch"})},
			agyReply{text: "Delegated cleanly."},
		)
		s := spec("repo:read", "allowed", "repo:write", "allowed", "tests:run", "allowed")
		s.Harness = agentdef.HarnessAntigravity
		res, _ := runACPTurn(t, p, s, Turn{Spec: s, Prompt: "Delegate in parallel."}, func(_ context.Context, tool string, _ map[string]any) (bool, string) {
			if tool == "Agent" || tool == "schedule" {
				return false, "denied by probe policy"
			}
			return true, ""
		})
		if res.IsError || res.Final != "Delegated cleanly." {
			t.Fatalf("unexpected res=%+v", res)
		}
		var modelReq string
		for _, body := range p.gemini.all {
			if !strings.Contains(string(body), "conversation title generator") {
				modelReq = string(body)
				break
			}
		}
		for _, wantTool := range []string{"mcp_lazyagents_run_subagent", "mcp_lazyagents_run_subagents"} {
			if !strings.Contains(modelReq, `"name":"`+wantTool+`"`) {
				t.Errorf("%s must be declared eagerly in ACP mode", wantTool)
			}
		}
		gotTools := p.policy.tools()
		for _, want := range []string{"Agent", "schedule", "mcp__lazyagents_run_subagent", "mcp__lazyagents_run_subagents"} {
			if !slices.Contains(gotTools, want) {
				t.Errorf("policy hook did not receive %q: got %v", want, gotTools)
			}
		}
		if p.mcp.calls("tools/call") != 2 {
			t.Errorf("expected 2 MCP tools/call for run_subagent + run_subagents, got %d (methods=%v, policy=%v)", p.mcp.calls("tools/call"), p.mcp.methods, gotTools)
		}
	})

	t.Run("session_explorer_readonly_shell", func(t *testing.T) {
		p := newAgyProbe(t, bin)
		explorerCheck := func(tool string, input map[string]any) (bool, string) {
			switch tool {
			case "Read":
				return true, ""
			case "Bash":
				if cmd, _ := input["command"].(string); cmd == "ls" {
					return true, ""
				}
				return false, "only read-only shell commands are allowed"
			default:
				return false, "explorer is read-only"
			}
		}
		p.policy.check = explorerCheck
		p.gemini.route = func(body string) (agyReply, bool) {
			if strings.Contains(body, "conversation title generator") {
				return agyReply{text: "Probe Title"}, true
			}
			return agyReply{}, false
		}
		p.gemini.script(
			agyReply{call: agyCall("run_command", map[string]any{"CommandLine": "ls", "toolSummary": "List workspace", "WaitMsBeforeAsync": 5000})},
			agyReply{call: agyCall("run_command", map[string]any{"CommandLine": "echo bad > blocked-shell.txt", "toolSummary": "Mutate", "WaitMsBeforeAsync": 5000})},
			agyReply{call: agyCall("write_file", map[string]any{"Path": filepath.Join(p.ws, "blocked-write.txt"), "Content": "x"})},
			agyReply{text: "Explored."},
		)
		s := spec("repo:read", "allowed")
		s.Harness = agentdef.HarnessAntigravity
		s.HarnessOptions["readonly"] = "true"
		s.HarnessOptions["sandbox"] = "read-only"
		s.HarnessOptions[agentdef.OptionNoMCP] = "true"
		s.HarnessOptions[agentdef.OptionSubagents] = "false"
		var mu sync.Mutex
		var allowedCmds []string
		res, evs := runACPTurn(t, p, s, Turn{
			Spec:         s,
			Prompt:       "Inspect workspace.",
			SystemAppend: "EXPLORER_ISOLATED_PROMPT",
			ConfigTag:    "subagent-explorer-probe",
		}, func(_ context.Context, tool string, input map[string]any) (bool, string) {
			allow, reason := explorerCheck(tool, input)
			if allow && tool == "Bash" {
				mu.Lock()
				allowedCmds = append(allowedCmds, fmt.Sprint(input["command"]))
				mu.Unlock()
			}
			return allow, reason
		})
		if res.IsError || res.Final != "Explored." {
			t.Fatalf("unexpected res=%+v events=%v", res, evs)
		}
		if !slices.Equal(allowedCmds, []string{"ls"}) {
			t.Errorf("expected read-only ls to reach CheckTool and run, got allowed=%v", allowedCmds)
		}
		if got := p.policy.tools(); !slices.Contains(got, "Bash") {
			t.Errorf("expected policy hook to evaluate Bash calls, got %v", got)
		}
		for _, blocked := range []string{"blocked-shell.txt", "blocked-write.txt"} {
			if _, err := os.Stat(filepath.Join(p.ws, blocked)); !os.IsNotExist(err) {
				t.Errorf("%s should not exist; err=%v", blocked, err)
			}
		}
		sawNotes := false
		for _, req := range p.gemini.all {
			if strings.Contains(string(req), "notes.txt") {
				sawNotes = true
				break
			}
		}
		if !sawNotes {
			t.Errorf("expected read-only ls output containing notes.txt to reach the model")
		}
	})

	t.Run("session_image_subagent", func(t *testing.T) {
		p := newAgyProbe(t, bin)
		savedPath := filepath.Join(p.home, ".gemini", "antigravity-cli", "brain", "sub-img-1", "portrait.png")
		var mu sync.Mutex
		subCalls := 0
		p.gemini.route = func(body string) (agyReply, bool) {
			if strings.Contains(body, "conversation title generator") {
				return agyReply{text: "Image Probe Title"}, true
			}
			// Match the image-generator subagent's prompt without matching the parent turn.
			if strings.Contains(body, "Draw a photorealistic portrait") && !strings.Contains(body, "Generate exactly one image") {
				mu.Lock()
				subCalls++
				mu.Unlock()
				return agyReply{text: "Saved " + savedPath}, true
			}
			return agyReply{}, false
		}
		p.gemini.script(
			agyReply{call: agyCall("invoke_subagent", map[string]any{"TypeName": "image-generator", "Role": "Image Generator", "Prompt": "Draw a photorealistic portrait"})},
			agyReply{text: "Generating the image now."},
			agyReply{text: "Done! Saved " + savedPath},
		)
		s := spec()
		s.Harness = agentdef.HarnessAntigravity
		s.Model = ""
		s.HarnessOptions = map[string]string{
			"sandbox":                      "read-only",
			"readonly":                     "true",
			agentdef.OptionImageGeneration: "true",
		}
		res, _ := runACPTurn(t, p, s, Turn{Spec: s, Prompt: "Generate exactly one image: a portrait."}, func(context.Context, string, map[string]any) (bool, string) {
			return true, ""
		})
		mu.Lock()
		gotSubCalls := subCalls
		mu.Unlock()
		if res.IsError || res.SessionID == "" {
			t.Fatalf("unexpected res=%+v", res)
		}
		if gotSubCalls != 1 {
			t.Fatalf("expected image-generator subagent to run once, got %d (final=%q)", gotSubCalls, res.Final)
		}
		if !slices.Contains(res.Images, savedPath) {
			t.Fatalf("expected saved image path %q in res.Images, got %v (final=%q)", savedPath, res.Images, res.Final)
		}
		if got := p.policy.tools(); !slices.Contains(got, "Agent") {
			t.Errorf("expected policy hook to evaluate invoke_subagent as Agent, got %v", got)
		}
	})
}

func readOnlyChat() (s agentdef.Resolved) {
	s.Harness = agentdef.HarnessAntigravity
	s.HarnessOptions = map[string]string{"readonly": "true"}
	return s
}

type agyProbe struct {
	bin, home, ws string
	gemini        *agyGemini
	policy        *agyPolicyStub
	mcp           *agyMCPStub
	vesperURL     string
	// accountSettings stands in for settings Vesper doesn't write, such as an
	// OAuth account's synced preferences: merged over the turn's settings.json.
	accountSettings map[string]any
	// withoutSessionSettings drops Vesper's --settings, to show what they change.
	withoutSessionSettings bool
}

func newAgyProbe(t *testing.T, bin string) *agyProbe {
	p := &agyProbe{bin: bin, home: t.TempDir(), ws: t.TempDir(), gemini: &agyGemini{}, policy: &agyPolicyStub{}, mcp: &agyMCPStub{}}
	if err := os.WriteFile(filepath.Join(p.ws, "notes.txt"), []byte("hello from the workspace\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	g := httptest.NewServer(p.gemini)
	t.Cleanup(g.Close)
	p.gemini.url = g.URL
	mux := http.NewServeMux()
	mux.Handle("/api/v1/agent/tool-policy", p.policy)
	mux.Handle("/mcp", p.mcp)
	v := httptest.NewServer(mux)
	t.Cleanup(v.Close)
	p.vesperURL = v.URL
	return p
}

type agyOutcome struct {
	events []Event
	res    Result
	exit   int
}

func (p *agyProbe) run(t *testing.T, spec agentdef.Resolved, record string) agyOutcome {
	return p.runWithSettings(t, spec, record, `{"modelProvider":"gemini"}`)
}

func (p *agyProbe) runWithSettings(t *testing.T, spec agentdef.Resolved, record, settingsJSON string) agyOutcome {
	t.Helper()
	inv, err := (Antigravity{}).Invocation(Workspace{Dir: p.ws, MCPURL: p.vesperURL + "/mcp", Token: "probe-token", TokenEnv: "LAZYAGENTS_TOKEN", ContainerSandbox: true},
		Turn{Spec: spec, Prompt: "Do the probe task."})
	if err != nil {
		t.Fatal(err)
	}
	if p.accountSettings != nil {
		var cfg map[string]any
		if err := json.Unmarshal(inv.Files[agyConfigPath], &cfg); err != nil {
			t.Fatal(err)
		}
		for k, v := range p.accountSettings {
			cfg["settings"].(map[string]any)[k] = v
		}
		inv.Files[agyConfigPath], _ = json.Marshal(cfg)
	}
	for rel, body := range inv.Files {
		path := filepath.Join(p.ws, rel)
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, body, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	// argv[2] is "agy", found on PATH as it is in the turn container.
	binDir := t.TempDir()
	if err := os.Symlink(p.bin, filepath.Join(binDir, "agy")); err != nil {
		t.Fatal(err)
	}
	env := []string{"HOME=" + p.home, "PATH=" + binDir + ":/usr/bin:/bin", "NO_COLOR=1",
		"GEMINI_API_KEY=AIzaProbeNotARealKey", "GOOGLE_GEMINI_BASE_URL=" + p.gemini.url,
		"HTTPS_PROXY=http://127.0.0.1:9", "HTTP_PROXY=http://127.0.0.1:9", "ALL_PROXY=http://127.0.0.1:9", "NO_PROXY=127.0.0.1,localhost"}
	for k, v := range inv.Env {
		env = append(env, k+"="+v)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	// Production runs keep modelProvider unset so agy uses the container's saved
	// OAuth login; the probe overrides it for this process only so agy routes
	// GEMINI_API_KEY requests to the local stub. agy reads one --settings, so
	// the probe's keys join Vesper's own session settings.
	argv := append([]string(nil), inv.Argv[1:]...)
	i := slices.Index(argv, "--settings")
	if i < 0 {
		t.Fatal("Vesper passes no --settings")
	}
	merged := map[string]any{}
	for _, raw := range []string{argv[i+1], settingsJSON} {
		if err := json.Unmarshal([]byte(raw), &merged); err != nil {
			t.Fatal(err)
		}
	}
	if p.withoutSessionSettings {
		merged = map[string]any{}
		_ = json.Unmarshal([]byte(settingsJSON), &merged)
	}
	body, _ := json.Marshal(merged)
	argv[i+1] = string(body)
	cmd := exec.CommandContext(ctx, inv.Argv[0], argv...)
	cmd.Dir, cmd.Env = p.ws, env
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	runErr := cmd.Run()
	exit := cmd.ProcessState.ExitCode()
	if ctx.Err() != nil {
		t.Fatalf("agy did not finish: %v\nstderr: %s", runErr, stderr.String())
	}
	t.Logf("exit %d, stderr: %s", exit, stderr.String())
	if dir := os.Getenv("AGY_RECORD"); dir != "" && record != "" {
		rec := bytes.ReplaceAll(stdout.Bytes(), []byte(p.ws), []byte("/workspace"))
		if err := os.WriteFile(filepath.Join(dir, record), rec, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	parser := (Antigravity{}).NewParser("")
	var evs []Event
	sc := bufio.NewScanner(&stdout)
	sc.Buffer(make([]byte, 1<<20), 8<<20)
	results := 0
	for sc.Scan() {
		var l struct {
			Event string `json:"event"`
		}
		if err := json.Unmarshal(sc.Bytes(), &l); err != nil || l.Event == "" {
			t.Errorf("stdout line without an event field: %q", sc.Text())
			continue
		}
		if l.Event == "result" {
			results++
		}
		evs = append(evs, parser.Line(sc.Bytes())...)
	}
	if results != 1 {
		t.Errorf("want exactly one result line, got %d", results)
	}
	return agyOutcome{events: evs, res: parser.Result(), exit: exit}
}

// ---------------------------------------------------------------- stubs

type agyReply struct {
	text   string
	call   map[string]any
	status int
	body   string
}

func agyCall(name string, args map[string]any) map[string]any {
	return map[string]any{"name": name, "args": args}
}

// agyGemini answers streamGenerateContent with the scripted replies in order,
// then "done". Usage is fixed so token accounting can be checked exactly.
type agyGemini struct {
	url     string
	mu      sync.Mutex
	replies []agyReply
	// route, when set, answers a request whose body it recognizes (a sub
	// agent's, which agy runs alongside the lead) out of the scripted order.
	route func(body string) (agyReply, bool)
	first []byte
	all   [][]byte
	paths []string
}

func (g *agyGemini) script(r ...agyReply) { g.replies = r }

func (g *agyGemini) firstRequest() string {
	g.mu.Lock()
	defer g.mu.Unlock()
	return string(g.first)
}

func (g *agyGemini) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	body, _ := io.ReadAll(r.Body)
	g.mu.Lock()
	if g.first == nil {
		g.first = body
	}
	g.all = append(g.all, body)
	g.paths = append(g.paths, r.URL.Path)
	var reply agyReply
	var routed bool
	if g.route != nil {
		reply, routed = g.route(string(body))
	}
	switch {
	case routed:
	case len(g.replies) > 0:
		reply, g.replies = g.replies[0], g.replies[1:]
	default:
		reply = agyReply{text: "done"}
	}
	g.mu.Unlock()
	if reply.status != 0 {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(reply.status)
		_, _ = io.WriteString(w, reply.body)
		return
	}
	var parts []map[string]any
	if reply.text != "" {
		parts = append(parts, map[string]any{"text": reply.text})
	}
	if reply.call != nil {
		parts = append(parts, map[string]any{"functionCall": reply.call})
	}
	chunk, _ := json.Marshal(map[string]any{
		"candidates":    []any{map[string]any{"content": map[string]any{"role": "model", "parts": parts}, "finishReason": "STOP", "index": 0}},
		"usageMetadata": map[string]any{"promptTokenCount": 1200, "cachedContentTokenCount": 1000, "candidatesTokenCount": 30, "thoughtsTokenCount": 7, "totalTokenCount": 1237},
	})
	w.Header().Set("Content-Type", "text/event-stream")
	fmt.Fprintf(w, "data: %s\r\n\r\n", chunk)
}

// agyPolicyStub is Vesper's tool-policy endpoint: allow unless the tool is denied.
type agyPolicyStub struct {
	mu     sync.Mutex
	denied []string
	check  func(tool string, input map[string]any) (bool, string)
	seen   []string
	inputs []map[string]any
}

func (s *agyPolicyStub) deny(tools ...string) { s.denied = tools }

func (s *agyPolicyStub) tools() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]string(nil), s.seen...)
}

func (s *agyPolicyStub) input(i int) map[string]any {
	s.mu.Lock()
	defer s.mu.Unlock()
	if i >= len(s.inputs) {
		return nil
	}
	return s.inputs[i]
}

func (s *agyPolicyStub) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	var in struct {
		Tool  string         `json:"tool"`
		Input map[string]any `json:"input"`
	}
	_ = json.NewDecoder(r.Body).Decode(&in)
	s.mu.Lock()
	s.seen = append(s.seen, in.Tool)
	s.inputs = append(s.inputs, in.Input)
	check := s.check
	s.mu.Unlock()
	decision := map[string]string{"decision": "allow"}
	if check != nil {
		if allow, reason := check(in.Tool, in.Input); !allow {
			if reason == "" {
				reason = "probe policy"
			}
			decision = map[string]string{"decision": "deny", "reason": reason}
		}
	} else {
		for _, d := range s.denied {
			if d == in.Tool {
				decision = map[string]string{"decision": "deny", "reason": "probe policy"}
			}
		}
	}
	_ = json.NewEncoder(w).Encode(decision)
}

// agyMCPStub is a Streamable HTTP MCP server with one tool, list_tickets.
type agyMCPStub struct {
	mu      sync.Mutex
	methods []string
	auth    []string
}

func (s *agyMCPStub) calls(method string) (n int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, m := range s.methods {
		if m == method {
			n++
		}
	}
	return n
}

func (s *agyMCPStub) bearer(token string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, a := range s.auth {
		if a != "Bearer "+token {
			return false
		}
	}
	return len(s.auth) > 0
}

func (s *agyMCPStub) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	var msg struct {
		ID     json.RawMessage `json:"id"`
		Method string          `json:"method"`
		Params struct {
			ProtocolVersion string `json:"protocolVersion"`
		} `json:"params"`
	}
	_ = json.NewDecoder(r.Body).Decode(&msg)
	s.mu.Lock()
	s.methods = append(s.methods, msg.Method)
	s.auth = append(s.auth, r.Header.Get("Authorization"))
	s.mu.Unlock()
	if msg.ID == nil {
		w.WriteHeader(http.StatusAccepted)
		return
	}
	var result any = map[string]any{}
	switch msg.Method {
	case "initialize":
		result = map[string]any{"protocolVersion": msg.Params.ProtocolVersion, "capabilities": map[string]any{"tools": map[string]any{}}, "serverInfo": map[string]any{"name": "probe", "version": "1"}}
	case "tools/list":
		result = map[string]any{"tools": []any{
			map[string]any{"name": "list_tickets", "description": "List tickets", "inputSchema": map[string]any{"type": "object", "properties": map[string]any{"q": map[string]any{"type": "string"}}}},
			map[string]any{"name": "read_page", "description": "Read a page", "inputSchema": map[string]any{"type": "object", "properties": map[string]any{"zebra_ref": map[string]any{"type": "string"}}}},
			map[string]any{"name": "run_subagent", "description": "Run a subagent", "inputSchema": map[string]any{"type": "object", "properties": map[string]any{"type": map[string]any{"type": "string"}, "role": map[string]any{"type": "string"}, "prompt": map[string]any{"type": "string"}}}},
			map[string]any{"name": "run_subagents", "description": "Run subagents in parallel", "inputSchema": map[string]any{"type": "object", "properties": map[string]any{"tasks": map[string]any{"type": "array", "items": map[string]any{"type": "object"}}}}},
		}}
	case "tools/call":
		result = map[string]any{"content": []any{map[string]any{"type": "text", "text": "LAZYAGENTS-1 probe ticket"}}}
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{"jsonrpc": "2.0", "id": msg.ID, "result": result})
}
