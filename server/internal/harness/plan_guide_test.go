package harness

import (
	"strings"
	"testing"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
)

// Only a chat on a harness without its own plan tool is told to use set_plan:
// Claude Code and Codex keep their native ones, which TrackPlans reads.
func TestChatAgentsMDPlanGuideOnlyWithoutANativePlanTool(t *testing.T) {
	for _, tc := range []struct {
		harness string
		want    bool
	}{{agentdef.HarnessClaudeCode, false}, {agentdef.HarnessCodex, false}, {agentdef.HarnessAntigravity, true}} {
		chat := explorerSpec("readonly", "true")
		chat.Harness = tc.harness
		md := string(ChatAgentsMD(chat, nil, "", "", nil))
		if got := strings.Contains(md, "set_plan"); got != tc.want {
			t.Errorf("%s chat mentions set_plan = %v, want %v", tc.harness, got, tc.want)
		}
	}
	for _, opt := range []string{agentdef.OptionNoMCP, agentdef.OptionNoTools, agentdef.OptionAside} {
		chat := explorerSpec(opt, "true")
		chat.Harness = agentdef.HarnessAntigravity
		if strings.Contains(string(ChatAgentsMD(chat, nil, "", "", nil)), "set_plan") {
			t.Errorf("%s: chat still told to use set_plan", opt)
		}
	}
	if strings.Contains(string(AgentsMD("", explorerSpec(), nil, "T-1")), "set_plan") {
		t.Error("a ticket run posts its plan with post_plan, not set_plan")
	}
}
