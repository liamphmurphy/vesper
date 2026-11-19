package runs

import (
	"reflect"
	"strings"
	"testing"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
	"github.com/liamphmurphy/vesper/server/internal/agents"
)

func TestChatSpecReadOnly(t *testing.T) {
	in := agentdef.Resolved{
		Instructions: "Agent persona", Scopes: []agentdef.ResolvedScope{{Scope: "repo:*", Mode: agentdef.Allowed}, {Scope: "custom:write", Mode: agentdef.Allowed}, {Scope: "wiki:write", Mode: agentdef.Allowed}},
		Setup: []string{"exit 79"}, MCPServers: []agentdef.MCPServer{{Name: "external", URL: "https://example.com"}},
		HarnessOptions: map[string]string{"sandbox": "danger-full-access"}, Fallbacks: []agentdef.Fallback{{Harness: "codex", Model: "other"}},
		Skills: []agentdef.Skill{{Name: "context", Body: "Read sources"}},
	}
	got := ChatSpec(in, ChatCaps{})
	for _, scope := range []string{"repo:read", "repo:write", "tests:run", "db:migrate", "deploy:staging", "custom:write", "future:scope"} {
		if got.Mode(scope) != agentdef.Denied {
			t.Errorf("%s is not denied", scope)
		}
	}
	// A chat never publishes to the shared wiki: what the persona may write
	// becomes a suggestion the person accepts or rejects.
	if got.Mode("wiki:write") != agentdef.RequiresApproval {
		t.Errorf("wiki:write is %q, want requires_approval", got.Mode("wiki:write"))
	}
	if len(got.Setup)+len(got.MCPServers)+len(got.Fallbacks) != 0 || got.HarnessOptions["readonly"] != "true" || got.HarnessOptions["sandbox"] != "read-only" {
		t.Fatalf("unsafe chat spec: %+v", got)
	}
	// Every chat is the Personal Assistant, whatever agent it was started with.
	if got.Instructions != agents.AssistantInstructions || strings.Contains(got.Instructions, "Agent persona") || !reflect.DeepEqual(got.Skills, in.Skills) {
		t.Fatal("chat isn't the Personal Assistant, or lost skills")
	}
	if in.Scopes[0].Mode != agentdef.Allowed || in.HarnessOptions["sandbox"] != "danger-full-access" || len(in.Fallbacks) != 1 {
		t.Fatal("mutated original definition")
	}
}

// The matrix: capabilities widen a chat's spec only as coded, per harness.
func TestChatSpecCapabilities(t *testing.T) {
	base := func(h string) agentdef.Resolved {
		return agentdef.Resolved{Harness: h, Model: "m", Scopes: []agentdef.ResolvedScope{
			{Scope: "repo:*", Mode: agentdef.Allowed}, {Scope: "wiki:write", Mode: agentdef.Allowed}, {Scope: "deploy:staging", Mode: agentdef.Allowed}}}
	}
	code := ChatCaps{Code: true, RepoURL: "https://github.com/a/b", WorkBranches: []string{"feat/add-search"}}
	for _, h := range []string{agentdef.HarnessClaudeCode, agentdef.HarnessCodex} {
		for _, tc := range []struct {
			name    string
			caps    ChatCaps
			coding  bool
			scratch bool // codes in an empty workspace: no repository instructions
			images  bool // image generation option reaches the spec
		}{
			{"none", ChatCaps{}, false, false, false},
			{"code", code, true, false, false},
			{"images", ChatCaps{Images: true}, false, false, h == agentdef.HarnessCodex},
			{"both", ChatCaps{Code: true, RepoURL: code.RepoURL, Images: true}, true, false, h == agentdef.HarnessCodex},
			// Without a repository a coding persona still writes and runs code,
			// in a scratch workspace.
			{"code without repo", ChatCaps{Code: true}, true, false, false},
			{"repo without code", ChatCaps{RepoURL: code.RepoURL}, false, false, false},
		} {
			t.Run(h+"/"+tc.name, func(t *testing.T) {
				got := ChatSpec(base(h), tc.caps)
				for _, scope := range []string{"repo:read", "repo:write", "tests:run"} {
					want := agentdef.Denied
					if tc.coding {
						want = agentdef.Allowed
					}
					if got.Mode(scope) != want {
						t.Errorf("%s is %s, want %s", scope, got.Mode(scope), want)
					}
				}
				for _, scope := range []string{"deploy:staging", "repo:admin", "web:read", "db:migrate"} {
					if got.Mode(scope) != agentdef.Denied {
						t.Errorf("%s widened to %s", scope, got.Mode(scope))
					}
				}
				if got.Mode("wiki:write") != agentdef.RequiresApproval {
					t.Errorf("wiki:write is %s, want requires_approval", got.Mode("wiki:write"))
				}
				opts := got.HarnessOptions
				_, hasImages := opts[agentdef.OptionImageGeneration]
				if hasImages != tc.images {
					t.Errorf("image option %v, want %v (%v)", hasImages, tc.images, opts)
				}
				switch {
				case tc.coding:
					// A coding chat gets the assistant's web option (WebFetch stays
					// on the allowlist), never the web:read scope.
					if opts["sandbox"] != "workspace-write" || opts["readonly"] != "" {
						t.Errorf("coding options %v", opts)
					}
					if opts[agentdef.OptionWebSearch] != "true" || got.Mode("web:read") != agentdef.Denied || strings.Contains(got.Instructions, "no web access") {
						t.Errorf("coding chat web: %v", opts)
					}
				case tc.images:
					// Image-only chats stay read-only; the Codex harness grants the outbox alone.
					if opts["sandbox"] != "read-only" || opts["readonly"] != "true" || opts[agentdef.OptionWebSearch] != "true" {
						t.Errorf("images options %v", opts)
					}
				default:
					if opts["sandbox"] != "read-only" || opts["readonly"] != "true" {
						t.Errorf("plain options %v", opts)
					}
				}
				ins := got.Instructions
				if coder := strings.Contains(ins, "## Working in code"); coder != tc.coding {
					t.Errorf("code instructions present=%v, want %v", coder, tc.coding)
				}
				if branching := strings.Contains(ins, "git checkout -b TYPE/short-description"); branching != (tc.coding && !tc.scratch) {
					t.Errorf("branch and push instructions present=%v, want %v", branching, tc.coding && !tc.scratch)
				}
				if scratch := strings.Contains(ins, "This chat has no repository."); scratch != tc.scratch {
					t.Errorf("scratch workspace instructions present=%v, want %v", scratch, tc.scratch)
				}
				// Branches the chat already pushed are listed for a new segment.
				if listed := strings.Contains(ins, "Branches you already pushed in this chat, oldest first: feat/add-search."); listed {
					t.Errorf("pushed branches listed=%v for %v", listed, tc.caps.WorkBranches)
				}
				if tc.coding == strings.Contains(ins, "Never claim tickets, run or execute project work, change code") {
					t.Errorf("the no-code bullet must go exactly when coding")
				}
				if !strings.Contains(ins, "Never claim tickets or hand work to other personas") && tc.coding {
					t.Errorf("the coder bullet lost the ticket and delegation limits")
				}
				if strings.Contains(ins, "write the shared wiki") {
					t.Errorf("instructions must not forbid writing the shared wiki")
				}
				images := strings.Contains(ins, "## Images")
				if images != tc.caps.Images || strings.Contains(ins, ".lazyagents/outbox/") != (tc.caps.Images && h == agentdef.HarnessCodex) {
					t.Errorf("images instructions: section %v", images)
				}
				if tc.caps.Images && h != agentdef.HarnessCodex && !strings.Contains(ins, "call generate_image") {
					t.Errorf("non-Codex chat should be told to call generate_image")
				}
				if tc.caps.Images && h != agentdef.HarnessCodex && (!strings.Contains(ins, "say you're trying") || !strings.Contains(ins, "follow-up turn")) {
					t.Errorf("non-Codex chat should be told it's only trying, and that a follow-up turn brings the result")
				}
				if strings.Contains(ins, "Codex model") || (h == agentdef.HarnessCodex && strings.Contains(ins, "generate_image")) {
					t.Errorf("image instructions: switch-model guidance or generate_image for a Codex chat")
				}
			})
		}
	}
	// Existing behaviour: no capabilities is exactly the old output.
	if got := ChatSpec(base(agentdef.HarnessCodex), ChatCaps{}); got.Instructions != agents.AssistantInstructions || len(got.HarnessOptions) != 3 {
		t.Fatalf("plain chat changed: %+v", got)
	}
}

func TestSameCapabilities(t *testing.T) {
	base := agentdef.Resolved{Harness: agentdef.HarnessCodex, Scopes: []agentdef.ResolvedScope{{Scope: "repo:read", Mode: agentdef.Allowed}}}
	a := ChatSpec(base, ChatCaps{})
	if !sameCapabilities(a, ChatSpec(base, ChatCaps{})) || sameCapabilities(a, ChatSpec(base, ChatCaps{Images: true})) ||
		sameCapabilities(a, ChatSpec(base, ChatCaps{Code: true, RepoURL: "https://github.com/a/b"})) {
		t.Fatal("capability comparison is wrong")
	}
	// A secret granted mid-chat reaches the next message as its own MCP server.
	withSecrets := ChatSpec(base, ChatCaps{Secrets: true})
	if sameCapabilities(a, withSecrets) || len(withSecrets.MCPServers) != 1 || withSecrets.MCPServers[0].Name != agentdef.SecretsMCPName || !withSecrets.MCPServers[0].Connector {
		t.Fatalf("secrets server: %+v", withSecrets.MCPServers)
	}
	// Unrelated edits to the assistant's definition don't count.
	edited := base
	edited.Instructions = "different"
	edited.Skills = []agentdef.Skill{{Name: "s", Body: "b"}}
	edited.Budget = agentdef.Budget{MaxTurns: 3}
	edited.Scopes = []agentdef.ResolvedScope{{Scope: "wiki:write", Mode: agentdef.Allowed}, {Scope: "repo:read", Mode: agentdef.Denied}}
	if !sameCapabilities(a, ChatSpec(edited, ChatCaps{})) {
		t.Fatal("editing the assistant's instructions, skills or scopes must not change what a chat can do")
	}
	code := ChatCaps{Code: true, RepoURL: "https://github.com/a/b"}
	if !sameCapabilities(ChatSpec(base, code), ChatSpec(edited, code)) {
		t.Fatal("coding chat: unrelated edits changed the capabilities")
	}
}

// wiki:write in a chat is never more than a suggestion, and a persona denied
// it stays denied.
func TestChatSpecWikiWrite(t *testing.T) {
	for _, tc := range []struct {
		name string
		in   []agentdef.ResolvedScope
		want agentdef.Mode
	}{
		{"allowed", []agentdef.ResolvedScope{{Scope: "wiki:write", Mode: agentdef.Allowed}}, agentdef.RequiresApproval},
		{"requires approval", []agentdef.ResolvedScope{{Scope: "wiki:write", Mode: agentdef.RequiresApproval}}, agentdef.RequiresApproval},
		{"wildcard allowed", []agentdef.ResolvedScope{{Scope: "wiki:*", Mode: agentdef.Allowed}}, agentdef.RequiresApproval},
		{"denied", []agentdef.ResolvedScope{{Scope: "wiki:write", Mode: agentdef.Denied}}, agentdef.Denied},
		{"unmentioned", nil, agentdef.RequiresApproval},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got := ChatSpec(agentdef.Resolved{Scopes: tc.in}, ChatCaps{})
			m := map[string]agentdef.Mode{}
			for _, s := range got.Scopes {
				m[s.Scope] = s.Mode
			}
			mode, set := agentdef.ModeFor(m, "wiki:write")
			if tc.want == agentdef.RequiresApproval && !set {
				mode = agentdef.RequiresApproval // unset means suggest (wiki.Decide)
			}
			if mode != tc.want {
				t.Errorf("wiki:write = %q, want %q", mode, tc.want)
			}
		})
	}
}
