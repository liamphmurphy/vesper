package harness

import (
	"strings"
	"testing"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
)

func TestChatAgentsMDOmitsProjectAndWorkInstructions(t *testing.T) {
	with := string(ChatAgentsMD(agentdef.Resolved{}, nil, "PAY", "", nil))
	without := string(ChatAgentsMD(agentdef.Resolved{}, nil, "", "", nil))
	if with != without {
		t.Fatalf("project key leaked into ChatAgentsMD:\nwith:\n%s\nwithout:\n%s", with, without)
	}
	if !strings.Contains(with, "# Vesper chat\n\n") {
		t.Fatalf("missing chat heading:\n%s", with)
	}
	for _, bad := range []string{"PAY", "default project", "ticket", "epic", "list_projects", "claim_ticket"} {
		if strings.Contains(strings.ToLower(with), strings.ToLower(bad)) {
			t.Errorf("ChatAgentsMD still mentions %q:\n%s", bad, with)
		}
	}
}
