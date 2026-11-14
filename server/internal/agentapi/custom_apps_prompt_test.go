package agentapi

import (
	"slices"
	"strings"
	"testing"

	"github.com/liamphmurphy/vesper/server/internal/agents"
)

func TestAssistantCustomAppsSectionNamesTools(t *testing.T) {
	for _, tool := range []string{"list_custom_apps", "get_custom_app", "create_custom_app", "update_custom_app", "delete_custom_app", "custom_app_sql"} {
		if !strings.Contains(agents.AssistantCustomAppsSection, tool) {
			t.Errorf("Custom Apps section doesn't mention %s", tool)
		}
		if !slices.Contains(chatTools, tool) {
			t.Errorf("Custom Apps section names %s, which chats don't have", tool)
		}
	}
}
