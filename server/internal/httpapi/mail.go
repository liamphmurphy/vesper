package httpapi

import (
	"context"
	"errors"

	"github.com/jackc/pgx/v5"
	"github.com/oapi-codegen/nullable"

	"github.com/liamphmurphy/vesper/server/internal/api"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/mail"
	"github.com/liamphmurphy/vesper/server/internal/secrets"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

func (s *Server) mailService() *mail.Service {
	if s.Mail != nil {
		return s.Mail
	}
	var box *secrets.Box
	if s.Secrets != nil {
		box = s.Secrets.Box
	}
	return &mail.Service{
		Pool: s.Pool,
		Q:    s.Q,
		Box:  box,
		Log:  s.Log,
	}
}

func (s *Server) toMailAccount(ctx context.Context, row store.MailAccount) api.MailAccount {
	contactsCount, _ := s.Q.CountMailContacts(ctx, row.ID)
	pendingCount, _ := s.Q.CountPendingMailTriage(ctx, row.ID)
	allowed := row.AllowedFolders
	if allowed == nil {
		allowed = []string{}
	}
	out := api.MailAccount{
		Id:                  row.ID,
		Enabled:             row.Enabled,
		DryRun:              row.DryRun,
		Email:               row.Email,
		ImapHost:            row.ImapHost,
		ImapPort:            int(row.ImapPort),
		CarddavUrl:          row.CarddavUrl,
		DefaultFolder:       row.DefaultFolder,
		AllowedFolders:      allowed,
		TriagePolicy:        row.TriagePolicy,
		PinnedModel:         row.PinnedModel,
		PollIntervalSeconds: int(row.PollIntervalSeconds),
		ContactsCount:       int(contactsCount),
		PendingTriageCount:  int(pendingCount),
		LastError:           row.LastError,
		CreatedAt:           row.CreatedAt,
		UpdatedAt:           row.UpdatedAt,
	}
	if row.LastSyncedAt != nil {
		out.LastSyncedAt = nullable.NewNullableWithValue(*row.LastSyncedAt)
	}
	if row.LastContactsSyncedAt != nil {
		out.LastContactsSyncedAt = nullable.NewNullableWithValue(*row.LastContactsSyncedAt)
	}
	return out
}

func toMailRule(row store.MailRule) api.MailRule {
	return api.MailRule{
		Id:           row.ID,
		Priority:     int(row.Priority),
		Name:         row.Name,
		MatchField:   api.MailRuleMatchField(row.MatchField),
		MatchValue:   row.MatchValue,
		Action:       api.MailRuleAction(row.Action),
		TargetFolder: row.TargetFolder,
		Enabled:      row.Enabled,
		CreatedAt:    row.CreatedAt,
		UpdatedAt:    row.UpdatedAt,
	}
}

func toMailTriageLogEntry(row store.MailTriageLog) api.MailTriageLogEntry {
	out := api.MailTriageLogEntry{
		Id:           row.ID,
		ImapUid:      row.ImapUid,
		MessageId:    row.MessageID,
		FromEmail:    row.FromEmail,
		FromName:     row.FromName,
		Subject:      row.Subject,
		SourceFolder: row.SourceFolder,
		Action:       api.MailTriageLogEntryAction(row.Action),
		TargetFolder: row.TargetFolder,
		Tier:         api.MailTriageLogEntryTier(row.Tier),
		Reason:       row.Reason,
		DryRun:       row.DryRun,
		CreatedAt:    row.CreatedAt,
	}
	if row.UndoneAt != nil {
		out.UndoneAt = nullable.NewNullableWithValue(*row.UndoneAt)
	}
	return out
}

func (s *Server) GetMailAccount(ctx context.Context, _ api.GetMailAccountRequestObject) (api.GetMailAccountResponseObject, error) {
	u, _, ws := me(ctx)
	row, err := s.mailService().GetAccount(ctx, ws, u.ID)
	if errors.Is(err, pgx.ErrNoRows) {
		return api.GetMailAccount200JSONResponse{
			Configured:          false,
			DefaultTriagePolicy: mail.DefaultTriagePolicy,
		}, nil
	}
	if err != nil {
		return nil, err
	}
	acct := s.toMailAccount(ctx, row)
	return api.GetMailAccount200JSONResponse{
		Configured:          true,
		Account:             nullable.NewNullableWithValue(acct),
		DefaultTriagePolicy: mail.DefaultTriagePolicy,
	}, nil
}

func (s *Server) UpsertMailAccount(ctx context.Context, req api.UpsertMailAccountRequestObject) (api.UpsertMailAccountResponseObject, error) {
	u, _, ws := me(ctx)
	if req.Body == nil {
		return nil, apperr.Invalid("body", "request body is required")
	}
	b := req.Body
	in := mail.UpsertAccountInput{
		Enabled: b.Enabled,
		DryRun:  b.DryRun,
		Email:   b.Email,
	}
	if b.Password != nil {
		in.Password = *b.Password
	}
	if b.ImapHost != nil {
		in.IMAPHost = *b.ImapHost
	}
	if b.ImapPort != nil {
		in.IMAPPort = *b.ImapPort
	}
	if b.CarddavUrl != nil {
		in.CardDAVURL = *b.CarddavUrl
	}
	if b.DefaultFolder != nil {
		in.DefaultFolder = *b.DefaultFolder
	}
	if b.AllowedFolders != nil {
		in.AllowedFolders = *b.AllowedFolders
	}
	if b.TriagePolicy != nil {
		in.TriagePolicy = *b.TriagePolicy
	}
	if b.PinnedModel != nil {
		in.PinnedModel = *b.PinnedModel
	}
	if b.PollIntervalSeconds != nil {
		in.PollIntervalSeconds = *b.PollIntervalSeconds
	}
	row, err := s.mailService().UpsertAccount(ctx, ws, u.ID, in)
	if err != nil {
		return nil, err
	}
	return api.UpsertMailAccount200JSONResponse(s.toMailAccount(ctx, row)), nil
}

func (s *Server) DeleteMailAccount(ctx context.Context, _ api.DeleteMailAccountRequestObject) (api.DeleteMailAccountResponseObject, error) {
	u, _, ws := me(ctx)
	if err := s.mailService().DeleteAccount(ctx, ws, u.ID); err != nil {
		return nil, err
	}
	return api.DeleteMailAccount204Response{}, nil
}

func (s *Server) TestMailAccount(ctx context.Context, _ api.TestMailAccountRequestObject) (api.TestMailAccountResponseObject, error) {
	u, _, ws := me(ctx)
	res, err := s.mailService().TestAccount(ctx, ws, u.ID)
	if err != nil {
		return nil, err
	}
	return api.TestMailAccount200JSONResponse{
		ImapOk:        res.IMAPOK,
		ImapError:     res.IMAPError,
		CarddavOk:     res.CardDAVOK,
		CarddavError:  res.CardDAVError,
		ContactsCount: res.ContactsCount,
	}, nil
}

func (s *Server) SyncMailContacts(ctx context.Context, _ api.SyncMailContactsRequestObject) (api.SyncMailContactsResponseObject, error) {
	u, _, ws := me(ctx)
	svc := s.mailService()
	acct, err := svc.GetAccount(ctx, ws, u.ID)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, apperr.ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	n, err := svc.SyncContacts(ctx, acct)
	if err != nil {
		return nil, err
	}
	return api.SyncMailContacts200JSONResponse{ContactsCount: n}, nil
}

func (s *Server) ListMailRules(ctx context.Context, _ api.ListMailRulesRequestObject) (api.ListMailRulesResponseObject, error) {
	u, _, ws := me(ctx)
	rows, err := s.mailService().ListRules(ctx, ws, u.ID)
	if err != nil {
		return nil, err
	}
	out := make([]api.MailRule, len(rows))
	for i, r := range rows {
		out[i] = toMailRule(r)
	}
	return api.ListMailRules200JSONResponse{Rules: out}, nil
}

func (s *Server) CreateMailRule(ctx context.Context, req api.CreateMailRuleRequestObject) (api.CreateMailRuleResponseObject, error) {
	u, _, ws := me(ctx)
	if req.Body == nil {
		return nil, apperr.Invalid("body", "request body is required")
	}
	b := req.Body
	in := mail.RuleInput{
		MatchField: string(b.MatchField),
		MatchValue: b.MatchValue,
		Action:     string(b.Action),
		Enabled:    true,
	}
	if b.Priority != nil {
		in.Priority = *b.Priority
	}
	if b.Name != nil {
		in.Name = *b.Name
	}
	if b.TargetFolder != nil {
		in.TargetFolder = *b.TargetFolder
	}
	if b.Enabled != nil {
		in.Enabled = *b.Enabled
	}
	row, err := s.mailService().CreateRule(ctx, ws, u.ID, in)
	if err != nil {
		return nil, err
	}
	return api.CreateMailRule201JSONResponse(toMailRule(row)), nil
}

func (s *Server) DeleteMailRule(ctx context.Context, req api.DeleteMailRuleRequestObject) (api.DeleteMailRuleResponseObject, error) {
	u, _, ws := me(ctx)
	if err := s.mailService().DeleteRule(ctx, ws, u.ID, req.Id); err != nil {
		return nil, err
	}
	return api.DeleteMailRule204Response{}, nil
}

func (s *Server) ListMailTriageLog(ctx context.Context, req api.ListMailTriageLogRequestObject) (api.ListMailTriageLogResponseObject, error) {
	u, _, ws := me(ctx)
	limit := 50
	if req.Params.Limit != nil {
		limit = *req.Params.Limit
	}
	rows, err := s.mailService().ListTriageLog(ctx, ws, u.ID, limit)
	if err != nil {
		return nil, err
	}
	out := make([]api.MailTriageLogEntry, len(rows))
	for i, r := range rows {
		out[i] = toMailTriageLogEntry(r)
	}
	return api.ListMailTriageLog200JSONResponse{Entries: out}, nil
}

func (s *Server) UndoMailTriageLog(ctx context.Context, req api.UndoMailTriageLogRequestObject) (api.UndoMailTriageLogResponseObject, error) {
	u, _, ws := me(ctx)
	pin := false
	if req.Body != nil && req.Body.PinSender != nil {
		pin = *req.Body.PinSender
	}
	row, err := s.mailService().UndoTriageLog(ctx, ws, u.ID, req.Id, pin)
	if err != nil {
		return nil, err
	}
	return api.UndoMailTriageLog200JSONResponse(toMailTriageLogEntry(row)), nil
}
