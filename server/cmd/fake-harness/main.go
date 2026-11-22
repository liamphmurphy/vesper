// Command fake-harness stands in for the `claude`, `codex` and `agy` CLIs in runner
// tests and demos without API keys (docs/dev/plan.md §10). Invoked as `claude -p …`
// it emits Claude's stream-json and reads the MCP server from --mcp-config;
// invoked as `codex exec [resume] … --json` it emits Codex's JSONL and reads
// the server from -c mcp_servers.lazyagents.* overrides; invoked as agy (and
// `agy models`) it runs the Claude script and prints it as agy's stream-json
// (agy.go), reading the server from .lazyagents/agy-config.json. Whichever
// CLI it plays, it does real work through the Vesper MCP server.
//
// FAKE_HARNESS_MODE picks the first turn's script:
//
//	approval (default)  claim, plan, request db:migrate approval, end turn
//	complete            claim, plan, complete_run
//	chat-read           chat turn; a prompt "read <artifact id> [section]" reads it through MCP,
//	                    saying FAKE_HARNESS_OPENING first when set. A Slides prompt
//	                    "Draft slides from this outline…" (web/lib/slides/outline.ts) adds one
//	                    slide per top-level outline line to the chat's deck with canvas_patch
//	                    (see fakeOutlineDraft). The Welcome Wizard's "(Vesper setup)" prompts
//	                    (web/lib/onboarding.ts) propose a persona (see fakeSetupPersona)
//	design-review       chat turn in a Designs chat (UI e2e, written against this script).
//	                    First turn: design_list, design_outline, then one design_patch of
//	                    exactly 3 ops on the first frame of a design made from the mobile-flow
//	                    starter: add_node (a text "Promo code", why "Add a promo code field"),
//	                    set_node (recolour its shape named "Button", why "Make the button
//	                    stand out") and remove_node (its second text, why "Remove the
//	                    placeholder copy"), summary "Tidy the Start screen"; replies "I
//	                    suggested 3 changes." A turn whose message carries a design selection
//	                    (a canvas ref with a selection: its context file lists "- n_…" nodes)
//	                    replies "You selected <ids>" and design_patches a set_node (opacity) on
//	                    the first selected node, why "Acting on your selection". A turn whose
//	                    prompt carries the person's review feedback ("reviewed your design
//	                    suggestions") replies "Noted: " plus its lines, patching nothing.
//	idle                end the turn without saying what's next
//	crash               exit 3 with an error result
//	chat-image          chat turn on Claude; a prompt "image: <text>" calls generate_image
//	                    with <text>. The Codex step it queues (a codex invocation whose
//	                    prompt starts "Generate exactly one image") does what
//	                    FAKE_IMAGE_STEP says: ok (default; writes exec-<uuid>.png into
//	                    .lazyagents/outbox), empty (succeeds, writes nothing), fail
//	                    (exits 1), hang (waits until killed), moderation (succeeds
//	                    with a content-policy refusal, writes nothing), saved
//	                    (saves into $CODEX_HOME/generated_images/<thread>/ like
//	                    codex-cli, and says its copy was denied), saved-copied
//	                    (saves there and copies it to the outbox as portrait.png).
//	                    FAKE_HARNESS_FAIL_AFTER_IMAGE fails the turn after it
//	                    calls generate_image. The
//	                    image_followup turn after it reads the delivered images, calls
//	                    generate_image once more and echoes its prompt (or fails,
//	                    with FAKE_HARNESS_FAIL_FOLLOWUP set). FAKE_IMAGE_REFERENCES
//	                    (comma-separated) is passed as generate_image references.
//	chat-video          chat turn; a prompt "video: <title>" renders a tiny video
//	                    through the video tools (see fakeVideo; FAKE_VIDEO_STEP)
//	chat-audio          chat turn; a prompt "audio: <title>" renders a tiny WAV
//	                    through the audio tools (see fakeAudio; FAKE_AUDIO_STEP)
//	workflow-image      a workflow step: see the handler below
//	slow                wait for SIGINT (pause), then end the turn
//	delegate            claim, delegate to a copy, end the turn; the delegated run
//	                    writes child.txt in the shared checkout and completes
//	delegate_contract   delegate with a contract (allowed_paths docs/, a passing
//	                    test_command); the resumed parent reports the checks it was given
//	delegate_script     delegate as FAKE_HARNESS_DELEGATIONS (a JSON array of delegate
//	                    arguments) says, optionally writing an uncommitted dirty.txt first
//	                    (FAKE_HARNESS_DIRTY); on resume run FAKE_HARNESS_ROUND2 once (a
//	                    "$1" continue_run_id is the first delegated run's id; with
//	                    FAKE_HARNESS_ROUND2_COMMIT=<path> it first commits that file), then
//	                    complete_run with the whole resume message as the outcome
//	plan_rollover       claim, post a two-step plan, mark step 1 done with a note; end the
//	                    turn when update_step answers rollover: true (after an empty
//	                    commit), else complete_run. The fresh session's turn completes
//
// A delegated run (any delegate* mode) writes the file named by FILE=<path> in its
// task (default child.txt) in its worktree and commits it (FILE=- changes nothing). Test knobs: FAKE_HARNESS_LOG
// appends one JSON line per invocation (cwd, resume session, first prompt line);
// FAKE_HARNESS_SYNC=<dir> makes delegated runs wait until FAKE_HARNESS_SYNC_N (2) of
// them are running at once; FAKE_HARNESS_HOLD=<file> writes <file>.started and waits
// for <file> before working (in chat mode, a reply to the prompt "held" does,
// after saying it's working); FAKE_HARNESS_REJECT_RESUME fails a --resume like a CLI
// that lost the session. The log line also names the harness (claude or codex).
// FAKE_HARNESS_CHILD_REPORT is the report a delegated run that wrote its file
// passes to complete_run.
// FAKE_HARNESS_CONTEXT_TOKENS sets the prompt size each Claude assistant line's
// usage reports (default 2000). FAKE_HARNESS_PLAN="a|b" makes delegate_script's
// first turn post that plan before delegating. FAKE_HARNESS_CHILD_REPRO makes
// a delegated run finish as a reviewer (verdict changes_requested) reporting it
// as repro_command, with repro_covers_all when FAKE_HARNESS_CHILD_COVERS_ALL is
// set. FAKE_HARNESS_RECHECK=<path> makes a resumed delegate_script parent told
// to call recheck_review write "fixed" to <path>, commit it and call it for its
// first delegated run, then on the recheck's result try complete_run
// status=done (falling back to in_review with "DONE REFUSED: <error>");
// FAKE_HARNESS_RECHECK_DIRTY=<path> leaves that file uncommitted first.
// FAKE_HARNESS_CHILD_UNCOMMITTED leaves a delegated run's file uncommitted. A
// delegated run whose checks the server sent back commits whatever is left
// uncommitted and calls complete_run again.
//
// Resumed turns (--resume, or a session rollover's brief) finish the run with
// complete_run, unless FAKE_HARNESS_RESUME=idle.
package main

import (
	"bufio"
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

type bearer struct{ token string }

func (b bearer) RoundTrip(r *http.Request) (*http.Response, error) {
	r = r.Clone(r.Context())
	r.Header.Set("Authorization", b.token)
	return http.DefaultTransport.RoundTrip(r)
}

var (
	session string
	codex   bool // speak Codex's JSONL instead of Claude's stream-json
	items   int
)

func emit(v map[string]any) {
	switch sessionProto {
	case protoCodexServer:
		emitCodexAppServer(v)
		return
	case protoAgyACP:
		emitAgyACP(v)
		return
	}
	if agy {
		translateToAgy(v)
		return
	}
	if !codex {
		v["session_id"] = session
		if m, ok := v["message"].(map[string]any); ok && v["type"] == "assistant" && m["usage"] == nil {
			m["usage"] = contextUsage()
		}
	}
	writeOutJSON(v)
}

// contextUsage is the usage of a Claude assistant line: a request whose
// prompt is FAKE_HARNESS_CONTEXT_TOKENS (default 2000) tokens, mostly cached.
func contextUsage() map[string]any {
	n := contextTokenCount()
	cached := n * 9 / 10
	return map[string]any{"input_tokens": n - cached, "cache_read_input_tokens": cached, "cache_creation_input_tokens": 0, "output_tokens": 1}
}

func item(event string, it map[string]any) {
	emit(map[string]any{"type": event, "item": it})
}

func text(s string) {
	if codex {
		items++
		item("item.completed", map[string]any{"id": fmt.Sprintf("item_%d", items), "type": "agent_message", "text": s})
		return
	}
	emit(map[string]any{"type": "assistant", "message": map[string]any{"role": "assistant", "content": []any{map[string]any{"type": "text", "text": s}}}})
}

func result(isError bool, msg string) {
	if codex {
		if isError {
			emit(map[string]any{"type": "turn.failed", "error": map[string]any{"message": msg}})
			return
		}
		count := 1
		if os.Getenv("LAZYAGENTS_SUBAGENT_JOB_ID") == "" {
			counts := map[string]int{}
			raw, _ := os.ReadFile(".lazyagents/fake-codex-usage.json")
			_ = json.Unmarshal(raw, &counts)
			counts[session]++
			raw, _ = json.Marshal(counts)
			_ = os.WriteFile(".lazyagents/fake-codex-usage.json", raw, 0600)
			count = counts[session]
		}
		emit(map[string]any{"type": "turn.completed", "usage": map[string]any{"input_tokens": 1000 * count, "cached_input_tokens": 500 * count, "output_tokens": 200 * count}})
		return
	}
	// Like the real CLI: tokens are this process's, total_cost_usd is the session's so far.
	count := 1
	if os.Getenv("LAZYAGENTS_SUBAGENT_JOB_ID") == "" {
		counts := map[string]int{}
		raw, _ := os.ReadFile(".lazyagents/fake-claude-usage.json")
		_ = json.Unmarshal(raw, &counts)
		counts[session]++
		raw, _ = json.Marshal(counts)
		_ = os.WriteFile(".lazyagents/fake-claude-usage.json", raw, 0600)
		count = counts[session]
	}
	emit(map[string]any{"type": "result", "subtype": "success", "is_error": isError, "result": msg, "num_turns": 3,
		"total_cost_usd": 0.0125 * float64(count), "usage": map[string]any{"input_tokens": 1000, "output_tokens": 200, "cache_read_input_tokens": 500}})
}

func newUUID() string {
	b := make([]byte, 16)
	_, _ = rand.Read(b)
	b[6] = b[6]&0x0f | 0x40
	b[8] = b[8]&0x3f | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:])
}

func main() {
	var prompt, resume, cfgPath, model string
	var mcpURL, tokenEnv, mcpApproval string
	var images []string // codex --image files (comma-separated)
	args := os.Args[1:]
	agy = filepath.Base(os.Args[0]) == "agy"
	if agy && len(args) > 0 && args[0] == "models" {
		agyModels()
		return
	}
	if agy && slices.Contains(args, "/usage") {
		resets := time.Now().Add(3 * time.Hour).UTC().Format(time.RFC3339)
		cmd := map[string]any{"name": "usage", "data": map[string]any{
			"plan_name": "Antigravity (fake)",
			"groups": []any{
				map[string]any{"display_name": "Gemini", "refresh_window_label": "5h", "remaining_fraction": 0.72, "reset_time": resets},
			},
		}}
		b, _ := json.Marshal(map[string]any{"event": "command_result", "command": cmd})
		fmt.Println(string(b))
		b, _ = json.Marshal(map[string]any{"event": "result", "result": map[string]any{"status": "OK", "num_turns": 0, "command": cmd}})
		fmt.Println(string(b))
		return
	}
	// Chat model discovery for `claude` (chatmodels.DiscoverLocal) and the
	// usage check (usage.Probe): answer control requests, then wait for EOF.
	// Real turns persist their session, control-only checks don't.
	for _, a := range args {
		if a == "--input-format" && (!slices.Contains(args, "--mcp-config") || slices.Contains(args, "--no-session-persistence")) {
			scanner := bufio.NewScanner(os.Stdin)
			for scanner.Scan() {
				var request struct {
					Type      string `json:"type"`
					RequestID string `json:"request_id"`
				}
				if json.Unmarshal(scanner.Bytes(), &request) == nil && request.Type == "control_request" {
					response := any(map[string]any{"models": []any{map[string]any{"value": "sonnet", "displayName": "Claude Sonnet (fake)"}}})
					if request.RequestID == "usage" {
						response = map[string]any{"subscription_type": "max", "rate_limits_available": true, "rate_limits": map[string]any{
							"five_hour": map[string]any{"utilization": 38, "resets_at": time.Now().Add(3 * time.Hour).UTC().Format(time.RFC3339)},
							"seven_day": map[string]any{"utilization": 61, "resets_at": time.Now().Add(80 * time.Hour).UTC().Format(time.RFC3339)}}}
					}
					b, _ := json.Marshal(map[string]any{"type": "control_response", "response": map[string]any{"subtype": "success", "request_id": request.RequestID, "response": response}})
					fmt.Println(string(b))
				}
			}
			return
		}
	}
	var inline []string
	waitSessionEOF := false
	defer func() {
		if waitSessionEOF {
			waitEOFOrTimeout(5 * time.Second)
		}
	}()

	if len(args) > 0 && args[0] == "app-server" {
		var ok bool
		prompt, resume, model, mcpURL, tokenEnv, mcpApproval, images, ok = runCodexAppServer(args[1:])
		if !ok {
			return
		}
		waitSessionEOF = true
	} else if agy && len(args) > 0 && args[0] == "acp" {
		var ok bool
		prompt, resume, model, inline, ok = runAgyACPSession()
		if !ok {
			return
		}
		waitSessionEOF = true
	} else if len(args) > 0 && args[0] == "exec" {
		codex = true
		args = args[1:]
		// exec's own flags (--add-dir <dir>) come before the resume subcommand.
		for len(args) > 1 && args[0] == "--add-dir" {
			args = args[2:]
		}
		isResume := len(args) > 0 && args[0] == "resume"
		if isResume {
			args = args[1:]
		}
		mcpURL, tokenEnv, mcpApproval = parseCodexConfigArgs(args)
		var pos []string
		for i := 0; i < len(args); i++ {
			switch args[i] {
			case "-c":
				i++
			case "-m":
				model = args[i+1]
				i++
			case "--image":
				images = strings.Split(args[i+1], ",")
				i++
			case "-s", "-C", "--add-dir":
				i++
			default:
				if !strings.HasPrefix(args[i], "-") {
					pos = append(pos, args[i])
				}
			}
		}
		if isResume && len(pos) == 2 {
			resume, prompt = pos[0], pos[1]
		} else if len(pos) > 0 {
			prompt = pos[len(pos)-1]
		}
	} else if agy {
		prompt, model, resume = agyArgs(args)
	} else {
		for i := 0; i < len(args); i++ {
			switch args[i] {
			case "-p", "--print":
				if i+1 < len(args) && !strings.HasPrefix(args[i+1], "-") {
					prompt = args[i+1]
					i++
				}
			case "--resume":
				resume = args[i+1]
				i++
			case "--model":
				model = args[i+1]
				i++
			case "--mcp-config":
				cfgPath = args[i+1]
				i++
			}
		}
		if slices.Contains(args, "--input-format") {
			if slices.Contains(args, "--mcp-config") && !slices.Contains(args, "--no-session-persistence") {
				if resume != "" && os.Getenv("FAKE_HARNESS_RESUME") == "gone" {
					fmt.Fprintln(os.Stderr, "No conversation found with session ID: "+resume)
					os.Exit(1)
				}
				prompt, inline = claudeSessionHandshake()
				waitSessionEOF = true
			} else {
				var m struct {
					Message struct {
						Content []struct {
							Text   string `json:"text"`
							Source struct {
								Data string `json:"data"`
							} `json:"source"`
						} `json:"content"`
					} `json:"message"`
				}
				_ = json.NewDecoder(os.Stdin).Decode(&m)
				for _, c := range m.Message.Content {
					if c.Source.Data == "" {
						prompt = c.Text
						continue
					}
					b, _ := base64.StdEncoding.DecodeString(c.Source.Data)
					inline = append(inline, string(b))
				}
			}
		}
	}
	if codex && mcpURL != "" && mcpApproval != "approve" {
		result(true, "MCP tool call requires approval, but approval policy is never")
		os.Exit(1)
	}
	if resume != "" && os.Getenv("FAKE_HARNESS_RESUME") == "gone" {
		fmt.Fprintln(os.Stderr, "No conversation found with session ID: "+resume)
		os.Exit(1)
	}
	prompt = regexp.MustCompile(`(?s)\n\n\(Vesper: this is the first message[^)]*\)`).ReplaceAllString(prompt, "")
	if session == "" {
		session = resume
		if session == "" {
			session = newUUID()
		}
	}
	if path := os.Getenv("FAKE_HARNESS_LOG"); path != "" {
		wd, _ := os.Getwd()
		_, request, _ := strings.Cut(prompt, "Request: ") // an image step's job prompt
		// Each input image as "path=contents", so tests see what was delivered.
		var imageFiles []string
		for _, p := range images {
			b, _ := os.ReadFile(p)
			label := p
			if rel, err := filepath.Rel(wd, p); err == nil && !strings.HasPrefix(rel, "..") {
				label = filepath.ToSlash(rel)
			}
			imageFiles = append(imageFiles, label+"="+string(b))
		}
		for _, b := range inline {
			imageFiles = append(imageFiles, "inline="+b)
		}
		line, _ := json.Marshal(map[string]any{"request": request, "cwd": wd, "resume": resume, "prompt": firstLine(prompt), "full_prompt": prompt, "images": strings.Join(imageFiles, "\n"),
			"mode": os.Getenv("FAKE_HARNESS_MODE"), "model": model, "harness": map[bool]string{true: "codex", false: "claude"}[codex]})
		if agy {
			line, _ = json.Marshal(map[string]any{"request": request, "cwd": wd, "resume": resume, "prompt": firstLine(prompt), "full_prompt": prompt, "images": "",
				"mode": os.Getenv("FAKE_HARNESS_MODE"), "model": model, "harness": "antigravity"})
		}
		if f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644); err == nil {
			_, _ = f.Write(append(line, '\n'))
			f.Close()
		}
	}
	if codex {
		emit(map[string]any{"type": "thread.started", "thread_id": session})
		emit(map[string]any{"type": "turn.started"})
	} else {
		emit(map[string]any{"type": "system", "subtype": "init", "model": "fake", "mcp_servers": []any{map[string]any{"name": "lazyagents", "status": "connected"}}})
	}

	// Conversation starters: a background prompt with no tools or MCP.
	if os.Getenv("FAKE_HARNESS_MODE") == "suggestions" {
		answer := `Here you go: [{"title":"Plan the next session","prompt":"Help me plan my next session.","icon":"dice"},` +
			`{"title":"Tidy the runner","prompt":"What should I tidy in the runner?","icon":"not-an-icon"},` +
			`{"title":"Pick a book","prompt":"Suggest a book for this week.","icon":"wiki"},` +
			`{"title":"Plan a ride","prompt":"Plan a bike ride for Saturday.","icon":"compass"}]`
		text(answer)
		result(false, answer)
		return
	}

	// steer-live: emits an initial chunk, waits for a mid-turn steer (or interrupt), and echoes it.
	if os.Getenv("FAKE_HARNESS_MODE") == "steer-live" {
		if resume != "" && os.Getenv("FAKE_HARNESS_STEER_ON_RESUME") == "" {
			answer := "Resumed after fallback: " + prompt
			text(answer)
			result(false, answer)
			return
		}
		text("Starting live work.")
		select {
		case msg := <-steers:
			answer := "steered:" + msg
			text(answer)
			result(false, answer)
		case <-interrupted:
			text("interrupted")
			result(false, "interrupted")
		case <-time.After(15 * time.Second):
			text("steer timeout")
			result(false, "steer timeout")
		}
		return
	}

	// tool-approval-live: tests in-turn blocking approval on a chat or ticket run without MCP.
	if os.Getenv("FAKE_HARNESS_MODE") == "tool-approval-live" && os.Getenv("LAZYAGENTS_TICKET") == "" {
		allowed, ok := checkSessionPolicy("Bash", map[string]any{"command": "echo approved-live"})
		if !ok {
			result(true, "policy check failed")
			os.Exit(2)
		}
		reply := "tool_denied"
		if allowed {
			reply = "tool_allowed"
		}
		text(reply)
		result(false, reply)
		return
	}

	// A chat can answer successfully without connecting to MCP or calling tools.
	if os.Getenv("FAKE_HARNESS_MODE") == "chat" {
		if prompt == "slow" && resume == "" {
			if sessionProto != protoLegacy {
				select {
				case <-interrupted:
					return
				case <-time.After(60 * time.Second):
				}
			} else {
				time.Sleep(60 * time.Second)
			}
		}
		if prompt == "slow partial" && !codex {
			// Test hook: write a little and call a tool, then hang until stopped,
			// like a reply the person interrupts.
			text("Halfway there: the ledger balances.")
			emit(map[string]any{"type": "assistant", "message": map[string]any{"role": "assistant", "content": []any{
				map[string]any{"type": "tool_use", "id": "toolu_partial", "name": "mcp__lazyagents__read_page", "input": map[string]any{"page": "Ledger"}}}}})
			time.Sleep(60 * time.Second)
		}
		if hold := os.Getenv("FAKE_HARNESS_HOLD"); prompt == "held" && hold != "" {
			// Test hook: a reply that works until <hold> exists, while the
			// person queues follow-ups or asks asides about it.
			text("Working on it.")
			_ = os.WriteFile(hold+".started", nil, 0o644)
			if !waitFor(func() bool { _, err := os.Stat(hold); return err == nil }) {
				result(true, "never released")
				os.Exit(2)
			}
		}
		if prompt == "quota" {
			result(true, "You have hit your usage limit")
			os.Exit(1)
		}
		answer := fmt.Sprintf("Chat reply (resumed=%v, session=%s, model=%s): %s", resume != "", session, model, prompt)
		shellPrompt := prompt
		if _, latest, ok := strings.Cut(prompt, "New message from the user (answer this one):\n"); ok {
			shellPrompt = latest
		}
		if first, ok := strings.CutPrefix(shellPrompt, "sh: "); ok {
			// Test hook: a prompt "sh: <command>" runs the command's first line in
			// the workspace, like an agent using its shell, and reports its output.
			first, _, _ = strings.Cut(first, "\n")
			out, err := exec.Command("sh", "-c", first).CombinedOutput()
			answer = fmt.Sprintf("Shell reply (err=%v): %s", err, strings.TrimSpace(string(out)))
		}
		text(answer)
		result(false, answer)
		return
	}

	if os.Getenv("FAKE_HARNESS_MODE") == "chat-image" && agy && strings.HasPrefix(prompt, "Generate exactly one image") {
		agyImageStep()
		return
	}
	if os.Getenv("FAKE_HARNESS_MODE") == "chat-image" && codex && strings.HasPrefix(prompt, "Generate exactly one image") {
		switch os.Getenv("FAKE_IMAGE_STEP") {
		case "fail":
			result(true, "image step failed")
			os.Exit(1)
		case "hang":
			time.Sleep(time.Hour) // until killed
		case "moderation":
			refusal := "I can't create that image: the request was blocked by the safety system under the content policy."
			text(refusal)
			result(false, refusal)
			return
		case "saved", "saved-copied":
			// Like codex-cli: the image lands in Codex's own folder for the
			// thread. "saved" then has its copy denied by the policy hook (the
			// LAZYAGENTS-97 failure); "saved-copied" copies it under a new name.
			home := os.Getenv("CODEX_HOME")
			if home == "" {
				home = filepath.Join(os.Getenv("HOME"), ".codex")
			}
			dir := filepath.Join(home, "generated_images", session)
			name := "exec-" + newUUID() + ".png"
			_ = os.MkdirAll(dir, 0o755)
			_ = os.WriteFile(filepath.Join(dir, name), []byte("\x89PNG\r\n\x1a\nfake image"), 0o644)
			if os.Getenv("FAKE_IMAGE_STEP") == "saved" {
				denied := "Generated exactly one image. Copying it to `.lazyagents/outbox/` was blocked by this chat's tool permissions."
				text(denied)
				result(false, denied)
				return
			}
			_ = os.MkdirAll(".lazyagents/outbox", 0o755)
			_ = os.WriteFile(".lazyagents/outbox/portrait.png", []byte("\x89PNG\r\n\x1a\nfake image"), 0o644)
		case "empty":
		default:
			_ = os.MkdirAll(".lazyagents/outbox", 0o755)
			_ = os.WriteFile(".lazyagents/outbox/exec-"+newUUID()+".png", []byte("\x89PNG\r\n\x1a\nfake image"), 0o644)
		}
		text("Image step done.")
		result(false, "Image step done.")
		return
	}
	// In-turn Vesper MCP subagents run with OptionNoMCP ("true"), so handle them
	// before opening any lazyagents MCP server config.
	if jobID := os.Getenv("LAZYAGENTS_SUBAGENT_JOB_ID"); jobID != "" {
		if codex {
			items++
			cid := fmt.Sprintf("sub_item_%d", items)
			item("item.started", map[string]any{"id": cid, "type": "command_execution", "command": "echo subagent"})
			item("item.completed", map[string]any{"id": cid, "type": "command_execution", "command": "echo subagent", "aggregated_output": "subagent", "exit_code": 0})
		} else {
			toolName, toolInput := "Read", map[string]any{"file_path": "README.md"}
			if agy {
				toolName, toolInput = "read_file", map[string]any{"Path": "README.md"}
			}
			emit(map[string]any{"type": "assistant", "message": map[string]any{"role": "assistant", "content": []any{
				map[string]any{"type": "tool_use", "id": "sub_read_1", "name": toolName, "input": toolInput}}}})
			emit(map[string]any{"type": "user", "message": map[string]any{"role": "user", "content": []any{
				map[string]any{"type": "tool_result", "tool_use_id": "sub_read_1", "content": "ok", "is_error": false}}}})
		}

		if _, rest, ok := strings.Cut(prompt, "HOLD="); ok {
			holdPath := strings.Fields(rest)[0]
			_ = os.MkdirAll(filepath.Dir(holdPath), 0o755)
			_ = os.WriteFile(holdPath+".started", []byte(jobID), 0o644)
			if sessionProto == protoLegacy {
				watchSignals()
			}
			deadline := time.NewTimer(30 * time.Second)
			tick := time.NewTicker(20 * time.Millisecond)
		holdLoop:
			for {
				if _, err := os.Stat(holdPath); err == nil {
					break holdLoop
				}
				select {
				case <-interrupted:
					deadline.Stop()
					tick.Stop()
					result(false, "Interrupted")
					os.Exit(130)
				case <-deadline.C:
					tick.Stop()
					result(true, "hold timed out")
					os.Exit(2)
				case <-tick.C:
				}
			}
			deadline.Stop()
			tick.Stop()
		}

		reply := "subagent result: " + prompt
		switch {
		case strings.Contains(prompt, "TRY_WRITE"):
			wOK, _ := checkSessionPolicy("Write", map[string]any{"file_path": "blocked-by-explorer.txt"})
			bOK, _ := checkSessionPolicy("Bash", map[string]any{"command": "echo hi"})
			rOK, _ := checkSessionPolicy("Read", map[string]any{"file_path": "README.md"})
			reply = fmt.Sprintf("policy write=%v bash=%v read=%v", wOK, bOK, rOK)
		case strings.Contains(prompt, "DO_WRITE"):
			wOK, _ := checkSessionPolicy("Write", map[string]any{"file_path": "helper.txt"})
			if wOK {
				_ = os.WriteFile("helper.txt", []byte("written by helper\n"), 0o644)
			}
			reply = fmt.Sprintf("wrote=%v", wOK)
		}
		text(reply)
		result(false, reply)
		return
	}

	var cfg struct {
		MCPServers map[string]struct {
			URL     string            `json:"url"`
			Headers map[string]string `json:"headers"`
		} `json:"mcpServers"`
	}
	var err error
	if codex {
		cfg.MCPServers = map[string]struct {
			URL     string            `json:"url"`
			Headers map[string]string `json:"headers"`
		}{"lazyagents": {URL: mcpURL, Headers: map[string]string{"Authorization": "Bearer " + os.Getenv(tokenEnv)}}}
	} else if agy {
		var url string
		var headers map[string]string
		url, headers, err = agyMCP()
		cfg.MCPServers = map[string]struct {
			URL     string            `json:"url"`
			Headers map[string]string `json:"headers"`
		}{"lazyagents": {URL: url, Headers: headers}}
	} else {
		var raw []byte
		raw, err = os.ReadFile(cfgPath)
		if err == nil {
			err = json.Unmarshal(raw, &cfg)
		}
	}
	srv := cfg.MCPServers["lazyagents"]
	if err != nil || srv.URL == "" {
		result(true, "no lazyagents MCP server configured")
		os.Exit(2)
	}
	ctx, cancelTurn := context.WithCancel(context.Background())
	defer cancelTurn()
	if sessionProto != protoLegacy {
		go func() {
			select {
			case <-interrupted:
				cancelTurn()
			case <-ctx.Done():
			}
		}()
	}
	client := mcp.NewClient(&mcp.Implementation{Name: "fake-harness", Version: "1"}, nil)
	sess, err := client.Connect(ctx, &mcp.StreamableClientTransport{
		Endpoint: srv.URL, HTTPClient: &http.Client{Transport: bearer{srv.Headers["Authorization"]}}, DisableStandaloneSSE: true,
	}, nil)
	if err != nil {
		result(true, "connect: "+err.Error())
		os.Exit(2)
	}
	defer sess.Close()

	var callMu sync.Mutex
	n := 0
	var call func(string, map[string]any) map[string]any
	call = func(name string, a map[string]any) map[string]any {
		// Simulate successful verification for main-run lifecycle fixtures.
		// Delegated fixtures report only their assigned task to the parent.
		if name == "complete_run" && a["status"] != "todo" && !strings.Contains(prompt, "delegated part of") {
			tk := call("get_ticket", map[string]any{"ticket": os.Getenv("LAZYAGENTS_TICKET")})
			if criteria, ok := tk["criteria"].([]any); ok {
				for i := range criteria {
					call("check_criterion", map[string]any{"n": i + 1, "done": true})
				}
			}
		}
		callMu.Lock()
		n++
		id := fmt.Sprintf("toolu_%02d", n)
		if codex {
			items++
			id = fmt.Sprintf("item_%d", items)
			item("item.started", map[string]any{"id": id, "type": "mcp_tool_call", "server": "lazyagents", "tool": name, "arguments": a, "status": "in_progress"})
		} else {
			emit(map[string]any{"type": "assistant", "message": map[string]any{"role": "assistant", "content": []any{
				map[string]any{"type": "tool_use", "id": id, "name": "mcp__lazyagents__" + name, "input": a}}}})
		}
		callMu.Unlock()
		res, err := sess.CallTool(ctx, &mcp.CallToolParams{Name: name, Arguments: a})
		out := map[string]any{}
		body, isErr := "", false
		switch {
		case err != nil:
			body, isErr = err.Error(), true
		case res.IsError:
			body, isErr = res.Content[0].(*mcp.TextContent).Text, true
			out["error"] = body
		default:
			b, _ := json.Marshal(res.StructuredContent)
			body = string(b)
			_ = json.Unmarshal(b, &out)
		}
		callMu.Lock()
		if codex {
			status := "completed"
			if isErr {
				status = "failed"
			}
			item("item.completed", map[string]any{"id": id, "type": "mcp_tool_call", "server": "lazyagents", "tool": name, "arguments": a,
				"result": map[string]any{"content": []any{map[string]any{"type": "text", "text": body}}}, "status": status})
		} else {
			emit(map[string]any{"type": "user", "message": map[string]any{"role": "user", "content": []any{
				map[string]any{"type": "tool_result", "tool_use_id": id, "content": body, "is_error": isErr}}}})
		}
		callMu.Unlock()
		return out
	}
	ticket := os.Getenv("LAZYAGENTS_TICKET")
	// workflow-image: an image step does what FAKE_IMAGE_STEP says (ok, empty,
	// moderation), its picture holding FAKE_IMAGE_CONTENT, or "revised" once a
	// reviewer asked for changes. Any other step reports FAIL if an image it
	// was given holds "bad", so what it says comes from the image itself.
	if os.Getenv("FAKE_HARNESS_MODE") == "workflow-image" {
		submit := func(output string) { call("submit_workflow_output", map[string]any{"output": output}) }
		if strings.Contains(prompt, "Generate the image with your image generation tool") {
			switch os.Getenv("FAKE_IMAGE_STEP") {
			case "moderation":
				refusal := "I can't create that image: it was blocked by the safety system under the content policy."
				text(refusal)
				result(false, refusal)
				return
			case "empty":
				submit("Here is a lovely map, in words.")
			default:
				content := os.Getenv("FAKE_IMAGE_CONTENT")
				if strings.Contains(prompt, "asked for changes to the previous attempt") {
					content = "revised"
				}
				if agy {
					// agy's generator saves into its own folder; the runner collects it.
					dir := filepath.Join(os.Getenv("HOME"), ".gemini", "antigravity-cli", "artifacts", session)
					name := "map-" + newUUID() + ".png"
					_ = os.MkdirAll(dir, 0o755)
					_ = os.WriteFile(filepath.Join(dir, name), []byte("\x89PNG\r\n\x1a\n"+content), 0o644)
					if sessionProto == protoAgyACP {
						emitAgyACPImageStep(dir, name)
					} else {
						agyStep++
						agyStepUpdate("ACTIVE", "tool", map[string]any{"tool_name": "generate_image", "tool_info": map[string]any{"name": "generate_image", "parameters": map[string]any{"prompt": "map"}}})
						agyLine("step_update", map[string]any{"conversation_id": session, "step_index": agyStep, "state": "DONE", "step_type": "tool", "tool_info": map[string]any{"output": "Saved " + filepath.Join(dir, name)}})
					}
				} else {
					_ = os.WriteFile(".lazyagents/outbox/map-"+newUUID()+".png", []byte("\x89PNG\r\n\x1a\n"+content), 0o644)
				}
				submit("Made the map. ![map](.lazyagents/outbox/map.png)")
			}
		} else {
			seen := slices.Clone(inline)
			for _, p := range images {
				b, _ := os.ReadFile(p)
				seen = append(seen, string(b))
			}
			verdict := "PASS"
			if len(seen) == 0 || slices.ContainsFunc(seen, func(s string) bool { return strings.Contains(s, "bad") }) {
				verdict = "FAIL"
			}
			// FAKE_CHECK_VERDICT overrides the verdict a check reports; "missing" omits it.
			args := map[string]any{"output": fmt.Sprintf("%s: looked at %d image(s)", verdict, len(seen)), "check": strings.ToLower(verdict)}
			if v := os.Getenv("FAKE_CHECK_VERDICT"); v == "missing" {
				delete(args, "check")
			} else if v != "" {
				args["check"] = v
			}
			call("submit_workflow_output", args)
		}
		text("Step done.")
		result(false, "Step done.")
		return
	}
	// chat-image: "image: <text>" asks for an image through MCP; any other prompt just answers.
	if os.Getenv("FAKE_HARNESS_MODE") == "chat-image" {
		reply := "Chat reply: " + prompt
		if strings.HasPrefix(prompt, "(Vesper: this is an automatic follow-up") {
			// The image follow-up: open the delivered images, try (and fail) to
			// ask for another, and echo what it was told.
			if os.Getenv("FAKE_HARNESS_FAIL_FOLLOWUP") != "" {
				result(true, "follow-up crashed")
				os.Exit(3)
			}
			seen := 0
			for _, p := range regexp.MustCompile("`(\\.lazyagents/attachments/generated/[^`]+)`").FindAllStringSubmatch(prompt, -1) {
				if b, err := os.ReadFile(p[1]); err == nil && len(b) > 0 {
					seen++
				}
			}
			again := call("generate_image", map[string]any{"prompt": "another one"})
			reply = fmt.Sprintf("Follow-up (seen=%d, again=%v):\n%s", seen, again["error"], prompt)
		} else if want, ok := strings.CutPrefix(prompt, "image: "); ok {
			want, _, _ = strings.Cut(want, "\n\n(Vesper:") // notes the runner appended
			args := map[string]any{"prompt": want}
			if refs := os.Getenv("FAKE_IMAGE_REFERENCES"); refs != "" {
				args["references"] = strings.Split(refs, ",")
			}
			out := call("generate_image", args)
			if os.Getenv("FAKE_HARNESS_FAIL_AFTER_IMAGE") != "" {
				result(true, "turn crashed after asking for an image")
				os.Exit(3)
			}
			reply = fmt.Sprintf("Chat reply (session=%s): making it (%v)", session, out["queued"])
		} else if want, ok := strings.CutPrefix(prompt, "persona: "); ok {
			// "persona: <name> | <avatar prompt>" proposes a persona with a picture.
			want, _, _ = strings.Cut(want, "\n\n(Vesper:")
			name, avatar, _ := strings.Cut(want, " | ")
			out := call("propose_persona", map[string]any{"name": name, "avatar_prompt": avatar})
			reply = fmt.Sprintf("Proposed %s (error=%v)", name, out["error"])
		}
		text(reply)
		result(false, reply)
		return
	}
	// chat-video: "video: <title>" renders a tiny video through the video
	// tools, as FAKE_VIDEO_STEP says: ok (default; stills, render, finish),
	// fail (fail_video at encode), unfinished (ends at render) or empty
	// (finishes without writing the file).
	if os.Getenv("FAKE_HARNESS_MODE") == "chat-video" {
		reply := "Chat reply: " + prompt
		if title, ok := strings.CutPrefix(prompt, "video: "); ok {
			title, _, _ = strings.Cut(title, "\n\n(Vesper:")
			reply = fakeVideo(call, title, os.Getenv("FAKE_VIDEO_STEP"))
		}
		text(reply)
		result(false, reply)
		return
	}
	// chat-audio: "audio: <title>" renders a tiny WAV through the audio tools,
	// as FAKE_AUDIO_STEP says: ok (default), ogg (a file the server can't
	// decode), fail (fail_audio), unfinished (ends at check) or empty
	// (finishes without writing the file).
	if os.Getenv("FAKE_HARNESS_MODE") == "chat-audio" {
		reply := "Chat reply: " + prompt
		if title, ok := strings.CutPrefix(prompt, "audio: "); ok {
			title, _, _ = strings.Cut(title, "\n\n(Vesper:")
			reply = fakeAudio(call, title, os.Getenv("FAKE_AUDIO_STEP"))
		}
		text(reply)
		result(false, reply)
		return
	}
	if os.Getenv("FAKE_HARNESS_MODE") == "design-review" {
		answer := fakeDesignReview(call, prompt)
		text(answer)
		result(false, answer)
		return
	}
	// chat-read: a prompt of "read <artifact id> [section]" reads it through MCP; any other prompt reads nothing.
	if os.Getenv("FAKE_HARNESS_MODE") == "chat-read" {
		latest := prompt
		if _, tail, ok := strings.Cut(prompt, "New message from the user (answer this one):\n"); ok {
			latest = tail
		}
		if strings.Contains(latest, "(Vesper setup)") {
			answer := fakeSetupPersona(call, latest)
			text(answer)
			result(false, answer)
			return
		}
		if _, outline, ok := strings.Cut(prompt, "Draft slides from this outline"); ok {
			answer := fakeOutlineDraft(call, outline)
			text(answer)
			result(false, answer)
			return
		}
		if f := strings.Fields(prompt); len(f) >= 2 && f[0] == "read" {
			args := map[string]any{"artifact": f[1]}
			if len(f) > 2 {
				args["section"] = f[2]
			}
			if o := os.Getenv("FAKE_HARNESS_OPENING"); o != "" {
				text(o)
			}
			call("read_artifact", args)
		}
		answer := "Chat reply: " + prompt
		text(answer)
		result(false, answer)
		return
	}
	if os.Getenv("FAKE_HARNESS_MODE") == "planning" {
		who := call("whoami", map[string]any{})
		call("get_ticket", map[string]any{"ticket": "PAY-214"})
		call("propose_tickets", map[string]any{"tickets": []any{map[string]any{"title": "Planned implementation", "description": "An editable draft from the fake harness", "criteria": []string{"Works safely"}, "agent_id": who["id"]}}})
		result(false, "Draft submitted.")
		return
	}
	if os.Getenv("FAKE_HARNESS_MODE") == "subagent" {
		if ticket != "" {
			call("claim_ticket", map[string]any{"ticket": ticket})
		}
		type subCall struct {
			Type   string `json:"type"`
			Role   string `json:"role"`
			Prompt string `json:"prompt"`
		}
		calls := []subCall{{Type: "explorer", Role: "Searcher", Prompt: "inspect"}}
		if rawCalls := os.Getenv("FAKE_SUBAGENT_CALLS"); rawCalls != "" {
			if err := json.Unmarshal([]byte(rawCalls), &calls); err != nil {
				result(true, "bad FAKE_SUBAGENT_CALLS: "+err.Error())
				os.Exit(2)
			}
		}
		results := make([]string, len(calls))
		runOne := func(idx int, c subCall) {
			out := call("run_subagent", map[string]any{"type": c.Type, "role": c.Role, "prompt": c.Prompt})
			if errMsg, ok := out["error"].(string); ok && errMsg != "" {
				results[idx] = fmt.Sprintf("%s:ERR:%s", c.Type, errMsg)
				return
			}
			resStr, _ := out["result"].(string)
			results[idx] = fmt.Sprintf("%s:%s", c.Type, resStr)
		}
		if os.Getenv("FAKE_SUBAGENT_BATCH") != "" {
			tasks := make([]map[string]any, len(calls))
			for i, c := range calls {
				tasks[i] = map[string]any{"type": c.Type, "role": c.Role, "prompt": c.Prompt}
			}
			out := call("run_subagents", map[string]any{"tasks": tasks})
			if errMsg, ok := out["error"].(string); ok && errMsg != "" {
				results = []string{"batch:ERR:" + errMsg}
			} else if rawRes, ok := out["results"].([]any); ok {
				results = make([]string, len(rawRes))
				for i, item := range rawRes {
					m, _ := item.(map[string]any)
					typ, _ := m["type"].(string)
					status, _ := m["status"].(string)
					if status != "completed" {
						errStr, _ := m["error"].(string)
						results[i] = fmt.Sprintf("%d:%s:%s:%s", i, typ, status, errStr)
					} else {
						resStr, _ := m["result"].(string)
						results[i] = fmt.Sprintf("%d:%s:%s", i, typ, resStr)
					}
				}
			}
		} else if os.Getenv("FAKE_SUBAGENT_PARALLEL") != "" {
			var pwg sync.WaitGroup
			for i, c := range calls {
				pwg.Add(1)
				go func(idx int, sc subCall) {
					defer pwg.Done()
					runOne(idx, sc)
				}(i, c)
			}
			pwg.Wait()
		} else {
			for i, c := range calls {
				if ctx.Err() != nil {
					break
				}
				runOne(i, c)
			}
		}
		if ctx.Err() != nil {
			text("Interrupted")
			result(false, "Interrupted")
			os.Exit(130)
		}
		summary := strings.Join(results, " | ")
		if ticket != "" {
			call("complete_run", map[string]any{"outcome": summary})
		}
		text(summary)
		result(false, summary)
		return
	}

	if os.Getenv("FAKE_HARNESS_MODE") == "tool-approval-live" {
		if ticket != "" {
			call("claim_ticket", map[string]any{"ticket": ticket})
		}
		allowed, ok := checkSessionPolicy("Bash", map[string]any{"command": "echo approved-live"})
		if !ok {
			result(true, "policy check failed")
			os.Exit(2)
		}
		reply := "tool_denied"
		if allowed {
			reply = "tool_allowed"
			if ticket != "" {
				call("complete_run", map[string]any{"outcome": "Live approval succeeded"})
			}
		}
		text(reply)
		result(false, reply)
		return
	}

	if os.Getenv("FAKE_HARNESS_MODE") == "policy" {
		call("claim_ticket", map[string]any{"ticket": ticket})
		allowed := false
		if sessionProto != protoLegacy {
			var ok bool
			allowed, ok = checkSessionPolicy("Bash", map[string]any{"command": "go test ./..."})
			if !ok {
				result(true, "policy check failed")
				os.Exit(2)
			}
		} else {
			check := exec.Command("python3", ".lazyagents/tool-policy.py")
			check.Stdin = strings.NewReader(`{"tool_name":"Bash","tool_input":{"command":"go test ./..."}}`)
			body, err := check.CombinedOutput()
			if err != nil {
				result(true, "policy hook failed")
				os.Exit(2)
			}
			allowed = !strings.Contains(string(body), `"deny"`)
		}
		if !allowed {
			text("Tool blocked; waiting for Vesper approval.")
			result(false, "Waiting for tool approval")
			return
		}
		_ = os.WriteFile("approved-action.txt", []byte("ran after approval"), 0o644)
		call("complete_run", map[string]any{"outcome": "Exact tool action approved and completed"})
		result(false, "Done")
		return
	}
	if resume != "" && os.Getenv("FAKE_HARNESS_RESUME") == "idle" {
		text("Still looking around.")
		result(false, "Still looking around.")
		return
	}
	if strings.HasPrefix(os.Getenv("FAKE_HARNESS_MODE"), "delegate") && strings.HasPrefix(prompt, "The server checked your work") {
		// The server sent a delegated run's failed checks back: commit what's
		// left uncommitted and report again.
		_ = exec.Command("git", "add", "-A", "--", ".", ":(exclude).lazyagents").Run()
		if exec.Command("git", "diff", "--cached", "--quiet").Run() != nil {
			if out, err := exec.Command("git", "commit", "-q", "-m", "Fix what the checks found").CombinedOutput(); err != nil {
				result(true, "git commit: "+string(out))
				os.Exit(2)
			}
		}
		call("complete_run", map[string]any{"outcome": "Fixed what the checks found"})
		result(false, "Done.")
		return
	}
	if strings.HasPrefix(os.Getenv("FAKE_HARNESS_MODE"), "delegate") && strings.Contains(prompt, "delegated part of") {
		// A delegated run: no claim; work in its worktree, commit, and report back.
		if resume != "" && os.Getenv("FAKE_HARNESS_REJECT_RESUME") != "" {
			result(true, "No conversation found with session ID: "+resume)
			os.Exit(1)
		}
		if dir := os.Getenv("FAKE_HARNESS_SYNC"); dir != "" {
			_ = os.WriteFile(fmt.Sprintf("%s/%d.start", dir, os.Getpid()), nil, 0o644)
			want := 2
			fmt.Sscan(os.Getenv("FAKE_HARNESS_SYNC_N"), &want)
			if !waitFor(func() bool { m, _ := os.ReadDir(dir); return len(m) >= want }) {
				result(true, "the other delegated runs never started: not running in parallel")
				os.Exit(2)
			}
		}
		if hold := os.Getenv("FAKE_HARNESS_HOLD"); hold != "" {
			_ = os.WriteFile(hold+".started", nil, 0o644)
			if !waitFor(func() bool { _, err := os.Stat(hold); return err == nil }) {
				result(true, "never released")
				os.Exit(2)
			}
		}
		file := "child.txt"
		if _, rest, ok := strings.Cut(prompt, "FILE="); ok && len(strings.Fields(rest)) > 0 {
			file = strings.Fields(rest)[0]
		}
		if file == "-" { // FILE=- : change nothing
			call("complete_run", map[string]any{"outcome": "Nothing to change"})
			result(false, "Done.")
			return
		}
		if err := os.MkdirAll(filepath.Dir(file), 0o755); err != nil {
			result(true, err.Error())
			os.Exit(2)
		}
		if err := os.WriteFile(file, []byte("from the sub agent\n"), 0o644); err != nil {
			result(true, err.Error())
			os.Exit(2)
		}
		for _, args := range [][]string{{"add", file}, {"commit", "-q", "-m", "Add " + file}} {
			if os.Getenv("FAKE_HARNESS_CHILD_UNCOMMITTED") != "" {
				break
			}
			if out, err := exec.Command("git", args...).CombinedOutput(); err != nil {
				result(true, "git "+args[0]+": "+string(out))
				os.Exit(2)
			}
		}
		done := map[string]any{"outcome": "Wrote " + file}
		if rep := os.Getenv("FAKE_HARNESS_CHILD_REPORT"); rep != "" {
			done["report"] = rep
		}
		if repro := os.Getenv("FAKE_HARNESS_CHILD_REPRO"); repro != "" {
			done["verdict"], done["repro_command"] = "changes_requested", repro
			done["repro_covers_all"] = os.Getenv("FAKE_HARNESS_CHILD_COVERS_ALL") != ""
		}
		call("complete_run", done)
		if hold := os.Getenv("FAKE_HARNESS_LINGER"); hold != "" {
			_ = os.WriteFile(hold+".started", nil, 0o644)
			if !waitFor(func() bool { _, err := os.Stat(hold); return err == nil }) {
				os.Exit(2)
			}
		}
		result(false, "Done.")
		return
	}
	if resume != "" && os.Getenv("FAKE_HARNESS_MODE") == "quota" && !codex {
		result(true, "You have hit your usage limit")
		os.Exit(1)
	}
	// A delegation wake that rolled over to a fresh session is a resumed turn too.
	if resume != "" || strings.HasPrefix(prompt, "Your earlier session was closed to keep context small") {
		if os.Getenv("FAKE_HARNESS_MODE") == "delegate_script" && os.Getenv("FAKE_HARNESS_RECHECK") != "" {
			switch {
			case strings.Contains(prompt, "## Review recheck"):
				out := call("complete_run", map[string]any{"outcome": "DONE\n" + prompt, "status": "done"})
				if e, ok := out["error"].(string); ok {
					call("complete_run", map[string]any{"outcome": "DONE REFUSED: " + e + "\n" + prompt, "status": "in_review"})
				}
				result(false, "Done.")
				return
			case strings.Contains(prompt, "call recheck_review"):
				// "Fix" the findings, then have the server rerun the reviewer's tests.
				f := os.Getenv("FAKE_HARNESS_RECHECK")
				_ = os.WriteFile(f, []byte("fixed\n"), 0o644)
				_ = exec.Command("git", "add", f).Run()
				_ = exec.Command("git", "commit", "-q", "-m", "Fix "+f).Run()
				if d := os.Getenv("FAKE_HARNESS_RECHECK_DIRTY"); d != "" {
					_ = os.WriteFile(d, []byte("not committed\n"), 0o644)
				}
				raw, _ := os.ReadFile(".lazyagents/children")
				ids := strings.Fields(string(raw))
				out := call("recheck_review", map[string]any{"run_id": ids[0]})
				if e, ok := out["error"].(string); ok {
					call("complete_run", map[string]any{"outcome": "RECHECK REFUSED: " + e, "status": "todo"})
				}
				result(false, "Waiting for the recheck.")
				return
			}
		}
		if os.Getenv("FAKE_HARNESS_MODE") == "delegate_script" {
			if _, err := os.Stat(".lazyagents/round2"); err != nil && os.Getenv("FAKE_HARNESS_ROUND2") != "" {
				_ = os.WriteFile(".lazyagents/round2", nil, 0o600)
				if f := os.Getenv("FAKE_HARNESS_ROUND2_COMMIT"); f != "" {
					_ = os.MkdirAll(filepath.Dir(f), 0o755)
					_ = os.WriteFile(f, []byte("the main agent's change\n"), 0o644)
					_ = exec.Command("git", "add", f).Run()
					_ = exec.Command("git", "commit", "-q", "-m", "Main agent commits "+f).Run()
				}
				delegateScript(call, "FAKE_HARNESS_ROUND2")
				text("Delegated again. Ending my turn until it reports back.")
				result(false, "Waiting for the sub agent.")
				return
			}
			state := ""
			for _, args := range [][]string{{"log", "--pretty=%s"}, {"branch", "--list"}, {"ls-files"}, {"status", "--porcelain"}, {"rev-parse", "-q", "--verify", "MERGE_HEAD"}} {
				out, _ := exec.Command("git", args...).CombinedOutput()
				state += "\n[git " + args[0] + "]\n" + string(out)
			}
			call("complete_run", map[string]any{"outcome": "RESUMED\n" + prompt + "\n=== checkout" + state})
			result(false, "Done.")
			return
		}
		if os.Getenv("FAKE_HARNESS_MODE") == "delegate_contract" {
			call("complete_run", map[string]any{"outcome": fmt.Sprintf("checks failed=%v outside=%v test_passed=%v criteria=%v",
				strings.Contains(prompt, "**FAILED**"), strings.Contains(prompt, "Changed outside the allowed paths:\n- child.txt"),
				strings.Contains(prompt, "passed."), strings.Contains(prompt, "Automated checks"))})
			result(false, "Done.")
			return
		}
		if os.Getenv("FAKE_HARNESS_MODE") == "delegate" {
			_, statErr := os.Stat("child.txt")
			call("complete_run", map[string]any{"outcome": fmt.Sprintf("Reviewed: child.txt present=%v; %s", statErr == nil, firstLine(prompt))})
			result(false, "Done.")
			return
		}
		text("Resumed: " + firstLine(prompt))
		status := "in_review"
		if strings.HasPrefix(prompt, "Denied") {
			status = "todo"
		}
		call("complete_run", map[string]any{"outcome": "Finished after: " + firstLine(prompt), "status": status})
		result(false, "Done.")
		return
	}

	if os.Getenv("FAKE_HARNESS_MODE") == "quota" {
		// Claude always hits the limit and Codex never does (the existing
		// fixtures). FAKE_HARNESS_CODEX_QUOTA makes Codex hit it too, after FAKE_HARNESS_QUOTA_SLEEP.
		if !codex || os.Getenv("FAKE_HARNESS_CODEX_QUOTA") != "" {
			call("claim_ticket", map[string]any{"ticket": ticket})
			_ = os.WriteFile("before-fallback.txt", []byte("work preserved"), 0o644)
			if d, err := time.ParseDuration(os.Getenv("FAKE_HARNESS_QUOTA_SLEEP")); err == nil {
				time.Sleep(d)
			}
			if msg := os.Getenv("FAKE_HARNESS_QUOTA_MESSAGE"); msg != "" {
				result(true, msg)
				os.Exit(1)
			}
			result(true, "You have hit your usage limit")
			os.Exit(1)
		}
		if _, err := os.Stat("before-fallback.txt"); err != nil {
			result(true, "checkout was lost")
			os.Exit(2)
		}
		if resume != "" || !strings.Contains(prompt, "fresh session") {
			result(true, "missing handoff")
			os.Exit(2)
		}
		call("complete_run", map[string]any{"outcome": "Completed on fallback with preserved checkout"})
		result(false, "Done")
		return
	}
	switch os.Getenv("FAKE_HARNESS_MODE") {
	case "crash":
		text("Something went wrong.")
		result(true, "API Error: overloaded")
		os.Exit(3)
	case "idle":
		text("I looked around and stopped.")
		result(false, "I looked around and stopped.")
		return
	case "slow":
		call("claim_ticket", map[string]any{"ticket": ticket})
		if sessionProto == protoLegacy {
			watchSignals()
		}
		select {
		case <-interrupted:
			text("Interrupted; stopping here.")
			result(false, "Interrupted")
			os.Exit(130)
		case <-time.After(60 * time.Second):
			result(false, "timed out")
			return
		}
	}

	call("claim_ticket", map[string]any{"ticket": ticket})
	if os.Getenv("FAKE_HARNESS_MODE") == "delegate_contract" {
		call("delegate", map[string]any{"task": "Write child.txt", "acceptance_criteria": []string{"child.txt exists"},
			"allowed_paths": []string{"docs/"}, "test_command": "test -f child.txt"})
		text("Delegated it. Ending my turn until it reports back.")
		result(false, "Waiting for the sub agent.")
		return
	}
	if os.Getenv("FAKE_HARNESS_MODE") == "delegate_script" {
		if os.Getenv("FAKE_HARNESS_DIRTY") != "" {
			_ = os.WriteFile("dirty.txt", []byte("uncommitted\n"), 0o644)
		}
		if steps := os.Getenv("FAKE_HARNESS_PLAN"); steps != "" {
			call("post_plan", map[string]any{"steps": strings.Split(steps, "|")})
		}
		delegateScript(call, "FAKE_HARNESS_DELEGATIONS")
		if hold := os.Getenv("FAKE_HARNESS_PARENT_HOLD"); hold != "" {
			_ = os.WriteFile(hold+".started", nil, 0o644)
			if !waitFor(func() bool { _, err := os.Stat(hold); return err == nil }) {
				os.Exit(2)
			}
		}
		text("Delegated. Ending my turn until the sub agents report back.")
		result(false, "Waiting for the sub agents.")
		return
	}
	if os.Getenv("FAKE_HARNESS_MODE") == "delegate" {
		call("delegate", map[string]any{"task": "Write child.txt"})
		text("Delegated it. Ending my turn until it reports back.")
		result(false, "Waiting for the sub agent.")
		return
	}
	if os.Getenv("FAKE_HARNESS_MODE") == "plan_rollover" {
		call("post_plan", map[string]any{"steps": []string{"Write the change", "Ship it"}})
		time.Sleep(200 * time.Millisecond) // let the runner record this turn's context size
		out := call("update_step", map[string]any{"step": 1, "state": "done", "note": "The setting lives in config.go; keep it off by default."})
		if out["rollover"] == true {
			_ = exec.Command("git", "commit", "-q", "--allow-empty", "-m", "Write the change").Run()
			text("Ending my turn for a fresh session.")
			result(false, "Ending my turn.")
			return
		}
		call("complete_run", map[string]any{"outcome": "Done without a rollover"})
		result(false, "Done.")
		return
	}
	call("post_plan", map[string]any{"steps": []string{"Read context", "Make the change", "Apply to staging"}})
	if os.Getenv("FAKE_HARNESS_MODE") == "complete" {
		call("complete_run", map[string]any{"outcome": "Done in one turn"})
		result(false, "Done.")
		return
	}
	ap := call("request_approval", map[string]any{"scope": "db:migrate", "action": "Apply the partition migration to staging",
		"detail": map[string]any{"sql": "SELECT 1"}, "risk": "Locks ledger_entries briefly"})
	text(fmt.Sprintf("Asked for approval (%v). Ending my turn until a person decides.", ap["state"]))
	result(false, "Waiting for approval.")
}

// delegateScript issues the delegate calls in the JSON array named by env. A
// continue_run_id of "$N" means the Nth run_id this parent has been given.
func delegateScript(call func(string, map[string]any) map[string]any, env string) {
	var list []map[string]any
	if err := json.Unmarshal([]byte(os.Getenv(env)), &list); err != nil {
		return
	}
	for _, a := range list {
		raw, _ := os.ReadFile(".lazyagents/children")
		ids := strings.Fields(string(raw))
		if v, ok := a["continue_run_id"].(string); ok && strings.HasPrefix(v, "$") {
			var n int
			fmt.Sscan(v[1:], &n)
			if n >= 1 && n <= len(ids) {
				a["continue_run_id"] = ids[n-1]
			}
		}
		out := call("delegate", a)
		if id, ok := out["run_id"].(string); ok {
			f, _ := os.OpenFile(".lazyagents/children", os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
			fmt.Fprintln(f, id)
			f.Close()
		}
	}
}

// waitFor polls cond for up to 30 seconds.
func waitFor(cond func() bool) bool {
	for i := 0; i < 600; i++ {
		if cond() {
			return true
		}
		time.Sleep(50 * time.Millisecond)
	}
	return false
}

func firstLine(s string) string {
	s, _, _ = strings.Cut(s, "\n")
	if len(s) > 80 {
		s = s[:80]
	}
	return s
}

// fakeOutlineDraft drafts the chat's deck from the outline after the prompt's
// first blank line: one title-body slide per top-level line with its indented
// lines as bullets (a section slide when it has none), added after the deck's
// last slide in one canvas_patch, as a persona would.
func fakeOutlineDraft(call func(string, map[string]any) map[string]any, prompt string) string {
	_, outline, _ := strings.Cut(prompt, "\n\n")
	outline, _, _ = strings.Cut(outline, "\n\n(Vesper:")
	type item struct {
		title  string
		points []string
	}
	var items []item
	for _, l := range strings.Split(outline, "\n") {
		t := strings.TrimSpace(strings.TrimLeft(strings.TrimSpace(l), "-*•"))
		switch {
		case t == "":
		case (strings.HasPrefix(l, " ") || strings.HasPrefix(l, "\t")) && len(items) > 0:
			items[len(items)-1].points = append(items[len(items)-1].points, t)
		default:
			items = append(items, item{title: t})
		}
	}
	var deckID string
	var version float64
	if list, ok := call("canvas_list", map[string]any{})["canvases"].([]any); ok {
		for _, c := range list {
			if m, _ := c.(map[string]any); m["kind"] == "deck" {
				deckID, _ = m["canvas_id"].(string)
			}
		}
	}
	if deckID == "" || len(items) == 0 {
		return "I couldn't find a deck or an outline to draft from."
	}
	read := call("canvas_read", map[string]any{"canvas_id": deckID})
	version, _ = read["version"].(float64)
	var d struct {
		Slides []struct {
			ID string `json:"id"`
		} `json:"slides"`
	}
	body, _ := read["body"].(string)
	if err := json.Unmarshal([]byte(body), &d); err != nil || len(d.Slides) == 0 {
		return "I couldn't read the deck."
	}
	last := d.Slides[len(d.Slides)-1].ID
	frame := func(x, y, w, h int) map[string]any { return map[string]any{"x": x, "y": y, "w": w, "h": h} }
	run := func(t string, size int, font, color string, bold bool) map[string]any {
		return map[string]any{"text": t, "size": size, "font": font, "color": color, "bold": bold}
	}
	// Inserted in reverse after the last slide, so they end up in outline order.
	ops := []any{}
	for i := len(items) - 1; i >= 0; i-- {
		it := items[i]
		var slide map[string]any
		if len(it.points) == 0 {
			slide = map[string]any{"layout": "section", "elements": []any{map[string]any{"type": "text", "placeholder": "title", "frame": frame(160, 380, 1600, 320), "valign": "middle",
				"paragraphs": []any{map[string]any{"align": "center", "runs": []any{run(it.title, 128, "heading", "heading", true)}}}}}}
		} else {
			paras := []any{}
			for _, p := range it.points {
				paras = append(paras, map[string]any{"bullet": "disc", "runs": []any{run(p, 44, "body", "text", false)}})
			}
			slide = map[string]any{"layout": "title-body", "elements": []any{
				map[string]any{"type": "text", "placeholder": "title", "frame": frame(120, 80, 1680, 160), "valign": "middle", "paragraphs": []any{map[string]any{"runs": []any{run(it.title, 80, "heading", "heading", true)}}}},
				map[string]any{"type": "text", "placeholder": "body", "frame": frame(120, 280, 1680, 700), "valign": "top", "paragraphs": paras},
			}}
		}
		ops = append(ops, map[string]any{"op": "insert_slide", "after": last, "value": slide})
	}
	call("canvas_patch", map[string]any{"canvas_id": deckID, "base_version": int(version), "ops": ops, "note": "Drafted from your outline"})
	return fmt.Sprintf("Drafted %d slides from your outline.", len(items))
}

// fakeSetupPersona answers the Welcome Wizard's hidden setup chat: it proposes
// "Hackerman" (FAKE_PERSONA_NAME overrides), concise at first and playful once
// the person asks for a change, so a refined draft is visibly different.
func fakeSetupPersona(call func(string, map[string]any) map[string]any, prompt string) string {
	name := os.Getenv("FAKE_PERSONA_NAME")
	if name == "" {
		name = "Hackerman"
	}
	tone := "concise"
	if strings.Contains(prompt, "Change the draft") {
		tone = "playful"
	}
	call("propose_persona", map[string]any{"name": name, "tone": tone, "color": "#f2a97e",
		"instructions": "You reproduce a bug before fixing it. You lead with the answer. You push back with alternatives.",
		"reason":       "An engineering partner to pair with."})
	return "Here's my draft of " + name + "."
}

// fakeDesignReview plays the persona in the Designs UI e2e (see the header's
// design-review mode).
func fakeDesignReview(call func(string, map[string]any) map[string]any, prompt string) string {
	if _, fb, ok := strings.Cut(prompt, "Review of your design suggestion"); ok {
		var notes []string
		for _, l := range strings.Split(fb, "\n") {
			if t, ok := strings.CutPrefix(strings.TrimSpace(l), "- "); ok && !strings.HasPrefix(t, "`") {
				notes = append(notes, t)
			}
		}
		return "Noted: " + strings.Join(notes, "; ")
	}
	var designID string
	var version float64
	list, _ := call("design_list", map[string]any{})["designs"].([]any)
	if len(list) > 0 {
		m, _ := list[0].(map[string]any)
		designID, _ = m["canvas_id"].(string)
		version, _ = m["version"].(float64)
	}
	if designID == "" {
		return "I can't find a design in this chat."
	}
	patch := func(summary string, ops []any) {
		call("design_patch", map[string]any{"canvas_id": designID, "base_version": int(version), "summary": summary, "ops": ops})
	}
	// A selection: the ref's context file lists the nodes as "- n_…: type name box…".
	var selected []string
	for _, m := range regexp.MustCompile("`(\\.lazyagents/context/[^`]+)`: canvas").FindAllStringSubmatch(prompt, -1) {
		raw, err := os.ReadFile(m[1])
		if err != nil || !strings.Contains(string(raw), "## Selected nodes") {
			continue
		}
		_, nodes, _ := strings.Cut(string(raw), "## Selected nodes")
		for _, id := range regexp.MustCompile(`(?m)^- (n_[a-z0-9_]+):`).FindAllStringSubmatch(nodes, -1) {
			selected = append(selected, id[1])
		}
	}
	if len(selected) > 0 {
		patch("Adjust the selection", []any{map[string]any{"op": "set_node", "id": selected[0], "fields": map[string]any{"opacity": 0.8}, "why": "Acting on your selection"}})
		return "You selected " + strings.Join(selected, ", ")
	}
	outline := call("design_outline", map[string]any{"canvas_id": designID, "depth": 3})
	raw, _ := json.Marshal(outline)
	var o struct {
		Pages []struct {
			Children []struct {
				ID       string `json:"id"`
				Type     string `json:"type"`
				Children []struct {
					ID   string `json:"id"`
					Type string `json:"type"`
					Name string `json:"name"`
				} `json:"children"`
			} `json:"children"`
		} `json:"pages"`
	}
	if err := json.Unmarshal(raw, &o); err != nil || len(o.Pages) == 0 || len(o.Pages[0].Children) == 0 {
		return "The design is empty."
	}
	frame := o.Pages[0].Children[0]
	var button, secondText string
	texts := 0
	for _, c := range frame.Children {
		switch {
		case c.Type == "shape" && c.Name == "Button":
			button = c.ID
		case c.Type == "text":
			if texts++; texts == 2 {
				secondText = c.ID
			}
		}
	}
	if button == "" || secondText == "" {
		return "This isn't the mobile-flow starter."
	}
	patch("Tidy the Start screen", []any{
		map[string]any{"op": "add_node", "parent": frame.ID, "why": "Add a promo code field", "node": map[string]any{
			"type": "text", "name": "Promo code", "x": 0, "y": 0, "w": 345, "h": 19.2, "sizing": map[string]any{"h": "hug"},
			"paragraphs": []any{map[string]any{"runs": []any{map[string]any{"text": "Promo code", "size": 16}}}}}},
		map[string]any{"op": "set_node", "id": button, "fields": map[string]any{"fill": "#2F6BFF"}, "why": "Make the button stand out"},
		map[string]any{"op": "remove_node", "id": secondText, "why": "Remove the placeholder copy"},
	})
	return "I suggested 3 changes."
}
