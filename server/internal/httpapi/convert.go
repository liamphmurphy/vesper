package httpapi

import (
	"context"
	"encoding/json"
	"slices"
	"time"

	"github.com/google/uuid"
	openapi_types "github.com/oapi-codegen/runtime/types"

	"github.com/liamphmurphy/vesper/server/internal/api"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

func toUser(u store.User) api.User {
	return api.User{Id: u.ID, Name: u.Name, Email: u.Email, Initials: u.Initials, RoleTitle: u.RoleTitle, AvatarColor: u.AvatarColor, AvatarUrl: userAvatarURL(u)}
}

func toUserRef(u store.User) *api.UserRef {
	return &api.UserRef{Id: u.ID, Name: u.Name, Initials: u.Initials, AvatarColor: u.AvatarColor, AvatarUrl: userAvatarURL(u)}
}

func toAgent(a store.Agent) api.Agent {
	return api.Agent{
		Id: a.ID, Name: a.Name, Handle: a.Handle, Kind: api.AgentKind(a.Kind), ColorIndex: int(a.ColorIndex),
		Role: a.Role, Specialty: a.Specialty, Model: a.Model, Status: api.AgentStatus(a.Status),
	}
}

func toAgentRef(a store.Agent) *api.AgentRef {
	return &api.AgentRef{Id: a.ID, Name: a.Name, Handle: a.Handle, ColorIndex: int(a.ColorIndex)}
}

func toProject(p store.Project) api.Project {
	return api.Project{Id: p.ID, Key: p.Key, Name: p.Name, Color: p.Color, RepoUrl: p.RepoUrl, DefaultBranch: p.DefaultBranch, Archived: p.Archived, Revision: int(p.Revision), SpaceId: p.SpaceID}
}

func toLabel(l store.Label) api.Label {
	return api.Label{Id: l.ID, Name: l.Name, Color: l.Color}
}

func toCriterion(c store.Criterion) api.Criterion {
	return api.Criterion{Id: c.ID, Position: int(c.Position), Text: c.Text, Done: c.Done}
}

func toDate(t *time.Time) *openapi_types.Date {
	if t == nil {
		return nil
	}
	return &openapi_types.Date{Time: *t}
}

func toPR(number *int32, state, url *string, add, del *int32) *api.PullRequest {
	if number == nil {
		return nil
	}
	pr := api.PullRequest{Number: int(*number), State: api.PullRequestStateOpen, Url: url}
	if state != nil {
		pr.State = api.PullRequestState(*state)
	}
	if add != nil {
		v := int(*add)
		pr.Additions = &v
	}
	if del != nil {
		v := int(*del)
		pr.Deletions = &v
	}
	return &pr
}

// withSync adds what the PR sync job learned (§6.7).
func withSync(pr *api.PullRequest, t store.Ticket) *api.PullRequest {
	if pr == nil {
		return nil
	}
	if t.PrClosedUnmerged {
		v := true
		pr.ClosedUnmerged = &v
	}
	pr.SyncedAt = t.PrSyncedAt
	return pr
}

func (s *Server) prFeedbackByURLs(ctx context.Context, ws uuid.UUID, urls []string) (map[string]store.PrFeedback, error) {
	out := map[string]store.PrFeedback{}
	var clean []string
	for _, u := range urls {
		if u != "" && !slices.Contains(clean, u) {
			clean = append(clean, u)
		}
	}
	if len(clean) == 0 {
		return out, nil
	}
	rows, err := s.Q.ListPRFeedbackByURLs(ctx, store.ListPRFeedbackByURLsParams{WorkspaceID: ws, PrUrls: clean})
	if err != nil {
		return nil, err
	}
	for _, r := range rows {
		out[r.PrUrl] = r
	}
	return out, nil
}

func toPRFeedback(row store.PrFeedback) *api.PRFeedback {
	data := runs.DecodePRFeedback(row)
	checks := make([]api.PRCheckFailure, 0, len(data.FailedChecks))
	for _, c := range data.FailedChecks {
		checks = append(checks, api.PRCheckFailure{
			Name:       c.Name,
			Conclusion: c.Conclusion,
			DetailsUrl: nonEmpty(c.DetailsURL),
			Title:      nonEmpty(c.Title),
			Summary:    nonEmpty(c.Summary),
		})
	}
	threads := make([]api.PRReviewThread, 0, len(data.ReviewThreads))
	for _, th := range data.ReviewThreads {
		comments := make([]api.PRReviewComment, 0, len(th.Comments))
		for _, c := range th.Comments {
			comments = append(comments, api.PRReviewComment{
				Author:    c.Author,
				Body:      c.Body,
				Url:       nonEmpty(c.URL),
				CreatedAt: c.CreatedAt,
			})
		}
		item := api.PRReviewThread{
			Id:        th.ID,
			Path:      th.Path,
			Url:       nonEmpty(th.URL),
			DiffHunk:  nonEmpty(th.DiffHunk),
			UpdatedAt: th.UpdatedAt,
			Comments:  comments,
		}
		if th.Line > 0 {
			l := th.Line
			item.Line = &l
		}
		if th.Outdated {
			o := true
			item.Outdated = &o
		}
		threads = append(threads, item)
	}
	return &api.PRFeedback{
		CiState:           api.PRCIState(data.CIState),
		FailedChecksCount: data.FailedChecksCount,
		FailedChecks:      checks,
		UnresolvedThreads: data.UnresolvedThreads,
		ReviewThreads:     threads,
		CiFailedAt:        row.CiFailedAt,
		ReviewUpdatedAt:   row.ReviewUpdatedAt,
		UpdatedAt:         row.UpdatedAt,
	}
}

// actorDirectory resolves activity actors to display data.
type actorDirectory struct {
	users  map[[16]byte]store.User
	agents map[[16]byte]store.Agent
}

func (d actorDirectory) actor(typ string, id *openapi_types.UUID) api.Actor {
	a := api.Actor{Type: api.ActorType(typ), Id: id, Name: "System"}
	if id == nil {
		return a
	}
	switch typ {
	case "user":
		if u, ok := d.users[*id]; ok {
			a.Name, a.Initials, a.AvatarColor = u.Name, &u.Initials, u.AvatarColor
		} else {
			a.Name = "Deleted user"
		}
	case "agent":
		if ag, ok := d.agents[*id]; ok {
			ci := int(ag.ColorIndex)
			a.Name, a.ColorIndex = ag.Name, &ci
		} else {
			a.Name = "Deleted agent"
		}
	}
	return a
}

func (d actorDirectory) event(e store.ActivityEvent) api.ActivityEvent {
	payload := map[string]any{}
	_ = json.Unmarshal(e.Payload, &payload)
	return api.ActivityEvent{Id: e.ID, Actor: d.actor(e.ActorType, e.ActorID), Verb: e.Verb, Payload: payload, CreatedAt: e.CreatedAt}
}

func toEpic(e store.Epic, r store.EpicRollupsRow) api.Epic {
	return api.Epic{Id: e.ID, ProjectId: e.ProjectID, Name: e.Name, Health: api.EpicHealth(e.Health), RequiresMockup: e.RequiresMockup, Status: api.EpicStatus(e.Status), CriteriaTotal: int(r.CriteriaTotal), CriteriaDone: int(r.CriteriaDone), PointsTotal: int(r.PointsTotal), PointsDone: int(r.PointsDone), TicketsTotal: int(r.TicketsTotal), TicketsOpen: int(r.TicketsOpen)}
}

func toEpicCriterion(c store.EpicCriterion, d actorDirectory) api.EpicCriterion {
	out := api.EpicCriterion{Id: c.ID, EpicId: c.EpicID, Position: int(c.Position), Text: c.Text, Done: c.Done, CheckedAt: c.CheckedAt}
	if c.CheckedByType != nil {
		a := d.actor(*c.CheckedByType, c.CheckedByID)
		out.CheckedBy = &a
	}
	return out
}
