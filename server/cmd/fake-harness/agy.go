package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// Antigravity (`agy`). The fake speaks it by running the Claude-style script
// and translating each line it would print into agy's stream-json, so every
// FAKE_HARNESS_MODE works for Antigravity too. It answers to the name agy
// (symlink fake-harness to agy) and to `agy models`.
//
// FAKE_IMAGE_STEP for an image step ("Generate exactly one image…" or a
// workflow image step): ok (default) saves a picture under
// $HOME/.gemini/antigravity-cli/artifacts/<conversation>/ and names it in a
// generate_image tool step, like agy's generator; empty, fail, hang and
// moderation as for the Codex step.

var (
	agy      bool
	agyStep  int
	agyTools = map[string]int{} // tool_use id -> step index
)

func agyLine(event string, payload map[string]any) {
	line := map[string]any{"event": event, event: payload}
	if event == "init" {
		line["conversation_id"] = session // agy 1.5.8 puts it beside init
	}
	b, _ := json.Marshal(line)
	fmt.Println(string(b))
}

func agyStepUpdate(state, typ string, extra map[string]any) {
	s := map[string]any{"conversation_id": session, "step_index": agyStep, "state": state, "step_type": typ}
	for k, v := range extra {
		s[k] = v
	}
	agyLine("step_update", s)
}

// agyCall renames a Claude-style tool call to agy's: every MCP tool goes
// through call_mcp_tool.
func agyCall(name string, input any) (string, any) {
	if rest, ok := strings.CutPrefix(name, "mcp__lazyagents__"); ok {
		return "call_mcp_tool", map[string]any{"ServerName": "lazyagents", "ToolName": rest, "Arguments": input}
	}
	return name, input
}

// translateToAgy prints one Claude-style line the way agy would.
func translateToAgy(v map[string]any) {
	switch v["type"] {
	case "system":
		agyLine("init", map[string]any{"cwd": ".", "tools": []string{}, "permission_mode": "request-review", "model": "fake"})
	case "assistant":
		msg, _ := v["message"].(map[string]any)
		blocks, _ := msg["content"].([]any)
		for _, bl := range blocks {
			b, _ := bl.(map[string]any)
			switch b["type"] {
			case "text":
				agyStep++
				agyStepUpdate("DONE", "agent_response", map[string]any{"text_delta": b["text"]})
			case "tool_use":
				agyStep++
				name, _ := b["name"].(string)
				id, _ := b["id"].(string)
				agyTools[id] = agyStep
				name, params := agyCall(name, b["input"])
				agyStepUpdate("ACTIVE", "tool", map[string]any{"tool_name": name, "tool_info": map[string]any{"name": name, "parameters": params}})
			}
		}
	case "user":
		msg, _ := v["message"].(map[string]any)
		blocks, _ := msg["content"].([]any)
		for _, bl := range blocks {
			b, _ := bl.(map[string]any)
			id, _ := b["tool_use_id"].(string)
			idx, ok := agyTools[id]
			if !ok {
				continue
			}
			info, state := map[string]any{"output": b["content"]}, "DONE"
			if isErr, _ := b["is_error"].(bool); isErr {
				info, state = map[string]any{"error": map[string]any{"type": "TOOL_ERROR", "message": b["content"]}}, "ERROR"
			}
			s := map[string]any{"conversation_id": session, "step_index": idx, "state": state, "step_type": "tool", "tool_info": info}
			agyLine("step_update", s)
		}
	case "result":
		env := map[string]any{"conversation_id": session, "status": "SUCCESS", "response": v["result"], "num_turns": 1}
		if isErr, _ := v["is_error"].(bool); isErr {
			env["status"], env["error"] = "ERROR", v["result"]
			delete(env, "response")
		}
		if u, ok := v["usage"].(map[string]any); ok {
			// agy reports usage per request on its agent_response steps (and a
			// conversation total on result); one closing step carries it here.
			usage := map[string]any{"input_tokens": u["input_tokens"], "output_tokens": u["output_tokens"], "cache_read_tokens": u["cache_read_input_tokens"]}
			agyStep++
			agyStepUpdate("DONE", "agent_response", map[string]any{"usage": usage})
			env["usage"] = usage
		}
		agyLine("result", env)
	}
}

// agyModels answers `agy models`.
func agyModels() {
	fmt.Println("Available models:")
	fmt.Println("* gemini-3.8-flash-medium  Gemini Flash (fake)")
	fmt.Println("  gemini-4-hydrogen-high   Gemini Hydrogen (fake)")
}

// agyArgs reads `agy -p <prompt> --model m --conversation id …`.
func agyArgs(args []string) (prompt, model, conversation string) {
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "-p", "--print", "--prompt":
			if i+1 < len(args) {
				prompt = args[i+1]
				i++
			}
		case "--model":
			model = args[i+1]
			i++
		case "--conversation":
			conversation = args[i+1]
			i++
		case "--output-format", "--effort", "--agent", "--print-timeout", "--settings":
			i++
		}
	}
	return
}

// agyMCP reads the lazyagents server from the config the launcher would have
// installed (.lazyagents/agy-config.json). The token comes from the environment.
func agyMCP() (url string, headers map[string]string, err error) {
	raw, err := os.ReadFile(".lazyagents/agy-config.json")
	if err != nil {
		return "", nil, err
	}
	var cfg struct {
		TokenEnv   string `json:"token_env"`
		MCPServers map[string]struct {
			ServerURL string            `json:"serverUrl"`
			Headers   map[string]string `json:"headers"`
		} `json:"mcp_servers"`
	}
	if err = json.Unmarshal(raw, &cfg); err != nil {
		return "", nil, err
	}
	srv := cfg.MCPServers["lazyagents"]
	h := map[string]string{}
	for k, v := range srv.Headers {
		h[k] = strings.ReplaceAll(v, "{{token}}", os.Getenv(cfg.TokenEnv))
	}
	return srv.ServerURL, h, nil
}

// agyImageStep is an image step on Antigravity. It reports whether it handled
// the prompt.
func agyImageStep() {
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
	case "empty":
	default:
		dir := filepath.Join(os.Getenv("HOME"), ".gemini", "antigravity-cli", "artifacts", session)
		name := "image-" + newUUID() + ".png"
		_ = os.MkdirAll(dir, 0o755)
		_ = os.WriteFile(filepath.Join(dir, name), []byte("\x89PNG\r\n\x1a\nfake image"), 0o644)
		if sessionProto == protoAgyACP {
			emitAgyACPImageStep(dir, name)
		} else {
			agyStep++
			agyStepUpdate("ACTIVE", "tool", map[string]any{"tool_name": "generate_image", "tool_info": map[string]any{"name": "generate_image", "parameters": map[string]any{"prompt": "x"}}})
			agyLine("step_update", map[string]any{"conversation_id": session, "step_index": agyStep, "state": "DONE", "step_type": "tool",
				"tool_info": map[string]any{"output": "Saved " + filepath.Join(dir, name)}})
		}
	}
	text("Image step done.")
	result(false, "Image step done.")
}
