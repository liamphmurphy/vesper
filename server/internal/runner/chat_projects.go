package runner

import (
	"context"

	"github.com/liamphmurphy/vesper/server/internal/store"
)

// soleProjectNote names the workspace's only active project for a chat with no
// default project, so the agent passes its key instead of spending a
// list_projects round-trip to find the one choice there is.
func soleProjectNote(ctx context.Context, q *store.Queries, chat store.ChatSession, defaultProject string) (string, error) {
	if defaultProject != "" {
		return "", nil
	}
	projects, err := q.ListProjects(ctx, chat.WorkspaceID)
	if err != nil {
		return "", err
	}
	var active []string
	for _, p := range projects {
		if !p.Archived {
			active = append(active, p.Key)
		}
	}
	if len(active) != 1 {
		return "", nil
	}
	return "\n## Projects\nThe workspace has one active project, " + active[0] + ": pass it as the project key when you create tickets or epics, and narrow lookups with it.\n", nil
}
