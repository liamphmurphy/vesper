package httpapi

import (
	"context"
	"fmt"
	"regexp"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/api"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

var githubPRRepoRe = regexp.MustCompile(`^https://github\.com/([^/]+/[^/]+)/pull/\d+`)

func (s *Server) ListChatTicketRuns(ctx context.Context, req api.ListChatTicketRunsRequestObject) (api.ListChatTicketRunsResponseObject, error) {
	c, err := s.ownChat(ctx, req.Id)
	if err != nil {
		return nil, err
	}
	rows, err := s.Q.ListChatTicketRuns(ctx, c.ID)
	if err != nil {
		return nil, err
	}
	out := api.ChatTicketRuns{Runs: make([]api.ChatTicketRun, len(rows))}
	for i, r := range rows {
		out.Runs[i] = toChatTicketRun(r)
	}
	return api.ListChatTicketRuns200JSONResponse(out), nil
}

func (s *Server) StartChatTicketRun(ctx context.Context, req api.StartChatTicketRunRequestObject) (api.StartChatTicketRunResponseObject, error) {
	u, _, ws := me(ctx)
	run, err := s.Runs.StartChatTicketRun(ctx, ws, u.ID, req.Id, runs.ChatDispatch{Ticket: req.Body.Ticket, MessageID: req.Body.MessageId})
	if err != nil {
		return nil, err
	}
	// Read it back the way the tray lists it, so the card can show it at once.
	rows, err := s.Q.ListChatTicketRuns(ctx, req.Id)
	if err != nil {
		return nil, err
	}
	for _, r := range rows {
		if r.RunID == run.ID {
			return api.StartChatTicketRun201JSONResponse(toChatTicketRun(r)), nil
		}
	}
	// The row was written in the same transaction, so this is a bug, not a race.
	return nil, fmt.Errorf("started run %s isn't listed in chat %s", run.ID, req.Id)
}

func toChatTicketRun(r store.ListChatTicketRunsRow) api.ChatTicketRun {
	out := api.ChatTicketRun{
		RunId: r.RunID, MessageId: r.MessageID, Ticket: r.TicketKey, TicketTitle: r.TicketTitle, Agent: r.AgentHandle,
		State: r.State, WaitReason: r.WaitReason, StartedAt: r.StartedAt, EndedAt: r.EndedAt,
		CostUsd: float32(r.CostUsdMicros) / 1e6, StepsTotal: int(r.StepsTotal), StepsDone: int(r.StepsDone),
		Repository: r.Repository, Branch: r.Branch, PrUrl: r.PrUrl,
	}
	if out.Repository == nil && r.PrUrl != nil {
		if m := githubPRRepoRe.FindStringSubmatch(*r.PrUrl); m != nil {
			repo := "https://github.com/" + m[1] + ".git"
			out.Repository = &repo
		}
	}
	if r.PrState != nil {
		st := api.PullRequestState(*r.PrState)
		out.PrState = &st
	}
	if r.CurrentStep != "" {
		out.CurrentStep = &r.CurrentStep
	}
	if r.ActivityTool != "" {
		out.Activity = &api.ChatTicketRunActivity{Tool: r.ActivityTool}
		if r.ActivityCommand != "" {
			out.Activity.Command = &r.ActivityCommand
		}
	}
	if id, err := uuid.Parse(r.ApprovalID); err == nil {
		out.Approval = &api.ChatTicketRunApproval{Id: id, Scope: r.ApprovalScope, Action: r.ApprovalAction, Detail: r.ApprovalDetail, Risk: r.ApprovalRisk}
	}
	return out
}
