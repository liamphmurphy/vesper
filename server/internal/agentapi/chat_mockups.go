package agentapi

import (
	"context"
	"encoding/json"
	"strings"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/agents"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/artifacts"
	"github.com/liamphmurphy/vesper/server/internal/runs"
)

// MockupCard is the body of a ```mockup fence: the chat draws that version
// natively with Approve and Request changes (macos ChatEmbeds/MockupCardView).
type MockupCard struct {
	ArtifactID uuid.UUID `json:"artifact_id"`
	VersionID  uuid.UUID `json:"version_id"`
	Title      string    `json:"title"`
}

// mockupCardFence is the card exactly as the persona pastes it into its reply.
func mockupCardFence(card MockupCard) (string, error) {
	raw, err := json.Marshal(card)
	if err != nil {
		return "", err
	}
	return "```mockup\n" + string(raw) + "\n```", nil
}

// createChatMockup is create_mockup in a chat: the mockup lands in the chat's
// project if it has one (or standalone when it doesn't), and the reply carries
// it as a card instead of the run waiting for a review.
func createChatMockup(ctx context.Context, d Deps, c agents.Caller, scope *chatScope, in MockupIn, id *uuid.UUID) (any, error) {
	project := strings.TrimSpace(in.Project)
	if id == nil && strings.TrimSpace(in.Ticket) == "" {
		if project == "" {
			project = scope.ProjectKey
		}
		if project != "" {
			p, err := scope.targetProject(ctx, d, c.Agent.WorkspaceID, project)
			if err != nil {
				return nil, err
			}
			project = p.Key
		}
	}
	out, err := d.Runs.CreateChatMockup(ctx, c, runs.ChatMockup{
		ChatID: scope.ChatID, ProjectKey: project, TicketKey: strings.TrimSpace(in.Ticket),
		Title: strings.TrimSpace(in.Title), SVG: in.SVG, Note: strings.TrimSpace(in.Note), MockupID: id,
	})
	if err != nil {
		return nil, err
	}
	card, err := mockupCardFence(MockupCard{ArtifactID: out.Artifact.ID, VersionID: out.Version.ID, Title: out.Artifact.Title})
	if err != nil {
		return nil, err
	}
	return map[string]any{
		"artifact_id": out.Artifact.ID, "version_id": out.Version.ID, "version": out.Version.Label,
		"review_state": artifacts.ReviewPending, "state": "created", "card": card,
		"tell_the_person": "Put card in your reply exactly as given (a ```mockup fence): the chat shows this version there for the person to approve or request changes on. " +
			"Their decision reaches you with their next message. To revise, call create_mockup with this mockup_id and post the new card.",
	}, nil
}

// chatOnlyMockupArgs refuses the chat's arguments in a run, whose mockups
// stay in its ticket's project.
func chatOnlyMockupArgs(in MockupIn) error {
	if strings.TrimSpace(in.Project) != "" {
		return apperr.Invalid("project", "a run's mockups stay in its ticket's project; project is for chats")
	}
	return nil
}
