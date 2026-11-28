package agentapi

import (
	"context"
	"errors"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/liamphmurphy/vesper/server/internal/agents"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/mail"
)

func requireMailChatScope(ctx context.Context, d Deps, c agents.Caller, toolName string) (*chatScope, error) {
	if d.Mail == nil {
		return nil, apperr.Conflict("Mail Butler is not available on this server")
	}
	s, err := chatScopeFor(ctx, d, c)
	if err != nil {
		return nil, err
	}
	if s == nil {
		return nil, apperr.Conflict("%s only works in a chat with a person", toolName)
	}
	return s, nil
}

func mailListMailboxes(ctx context.Context, d Deps, c agents.Caller, _ Empty) (any, error) {
	s, err := requireMailChatScope(ctx, d, c, "mail_list_mailboxes")
	if err != nil {
		return nil, err
	}
	boxes, err := d.Mail.ListMailboxes(ctx, c.Agent.WorkspaceID, s.UserID)
	if err != nil {
		return nil, err
	}
	type item struct {
		Name      string `json:"name"`
		Delimiter string `json:"delimiter,omitempty"`
		Messages  uint32 `json:"messages"`
		Unseen    uint32 `json:"unseen"`
	}
	out := make([]item, len(boxes))
	for i, b := range boxes {
		out[i] = item{Name: b.Name, Delimiter: b.Delimiter, Messages: b.Messages, Unseen: b.Unseen}
	}
	return map[string]any{"mailboxes": out}, nil
}

type MailCreateMailboxIn struct {
	Name string `json:"name" jsonschema:"Folder name to create (e.g. 'Taxes 2026' or 'Finance/Taxes 2026')"`
}

func mailCreateMailbox(ctx context.Context, d Deps, c agents.Caller, in MailCreateMailboxIn) (any, error) {
	s, err := requireMailChatScope(ctx, d, c, "mail_create_mailbox")
	if err != nil {
		return nil, err
	}
	if err := d.Mail.CreateMailbox(ctx, c.Agent.WorkspaceID, s.UserID, in.Name); err != nil {
		return nil, err
	}
	return map[string]any{"created": in.Name}, nil
}

type MailRenameMailboxIn struct {
	OldName string `json:"old_name" jsonschema:"Existing folder name"`
	NewName string `json:"new_name" jsonschema:"New folder name"`
}

func mailRenameMailbox(ctx context.Context, d Deps, c agents.Caller, in MailRenameMailboxIn) (any, error) {
	s, err := requireMailChatScope(ctx, d, c, "mail_rename_mailbox")
	if err != nil {
		return nil, err
	}
	if err := d.Mail.RenameMailbox(ctx, c.Agent.WorkspaceID, s.UserID, in.OldName, in.NewName); err != nil {
		return nil, err
	}
	return map[string]any{"renamed_from": in.OldName, "renamed_to": in.NewName}, nil
}

type MailSearchIn struct {
	Mailbox string `json:"mailbox,omitempty" jsonschema:"IMAP folder to search; defaults to INBOX"`
	From    string `json:"from,omitempty" jsonschema:"Filter by sender address or name"`
	Subject string `json:"subject,omitempty" jsonschema:"Filter by subject substring"`
	Text    string `json:"text,omitempty" jsonschema:"Filter by body/header text"`
	Unseen  bool   `json:"unseen,omitempty" jsonschema:"Only unread messages"`
	Limit   int    `json:"limit,omitempty" jsonschema:"Max results (default 25, max 100)"`
}

func mailSearch(ctx context.Context, d Deps, c agents.Caller, in MailSearchIn) (any, error) {
	s, err := requireMailChatScope(ctx, d, c, "mail_search")
	if err != nil {
		return nil, err
	}
	msgs, err := d.Mail.SearchMessages(ctx, c.Agent.WorkspaceID, s.UserID, mail.SearchQuery{
		Mailbox: in.Mailbox,
		From:    in.From,
		Subject: in.Subject,
		Text:    in.Text,
		Unseen:  in.Unseen,
		Limit:   in.Limit,
	})
	if err != nil {
		return nil, err
	}
	type msgOut struct {
		UID        uint32 `json:"uid"`
		MessageID  string `json:"message_id,omitempty"`
		FromEmail  string `json:"from_email"`
		FromName   string `json:"from_name,omitempty"`
		Subject    string `json:"subject"`
		ReceivedAt string `json:"received_at,omitempty"`
	}
	out := make([]msgOut, len(msgs))
	for i, m := range msgs {
		ts := ""
		if !m.ReceivedAt.IsZero() {
			ts = m.ReceivedAt.UTC().Format("2006-01-02T15:04:05Z")
		}
		out[i] = msgOut{
			UID:        m.UID,
			MessageID:  m.MessageID,
			FromEmail:  m.FromEmail,
			FromName:   m.FromName,
			Subject:    m.Subject,
			ReceivedAt: ts,
		}
	}
	return map[string]any{"messages": out}, nil
}

type MailMoveMessagesIn struct {
	SourceFolder string   `json:"source_folder,omitempty" jsonschema:"Source IMAP folder; defaults to INBOX"`
	UIDs         []uint32 `json:"uids" jsonschema:"IMAP UIDs from mail_search to move"`
	TargetFolder string   `json:"target_folder" jsonschema:"Destination IMAP folder (created automatically if missing)"`
	Reason       string   `json:"reason,omitempty" jsonschema:"Short reason recorded in the triage audit log"`
}

func mailMoveMessages(ctx context.Context, d Deps, c agents.Caller, in MailMoveMessagesIn) (any, error) {
	s, err := requireMailChatScope(ctx, d, c, "mail_move_messages")
	if err != nil {
		return nil, err
	}
	if err := d.Mail.MoveMessages(ctx, c.Agent.WorkspaceID, s.UserID, in.SourceFolder, in.UIDs, in.TargetFolder, in.Reason); err != nil {
		return nil, err
	}
	return map[string]any{"moved": len(in.UIDs), "target_folder": in.TargetFolder}, nil
}

func mailListRules(ctx context.Context, d Deps, c agents.Caller, _ Empty) (any, error) {
	s, err := requireMailChatScope(ctx, d, c, "mail_list_rules")
	if err != nil {
		return nil, err
	}
	acct, err := d.Mail.GetAccount(ctx, c.Agent.WorkspaceID, s.UserID)
	if errors.Is(err, pgx.ErrNoRows) {
		return map[string]any{"configured": false, "rules": []any{}}, nil
	}
	if err != nil {
		return nil, err
	}
	rules, err := d.Mail.ListRules(ctx, c.Agent.WorkspaceID, s.UserID)
	if err != nil {
		return nil, err
	}
	contactsCount, _ := d.Q.CountMailContacts(ctx, acct.ID)
	type ruleOut struct {
		ID           string `json:"id"`
		Priority     int32  `json:"priority"`
		Name         string `json:"name,omitempty"`
		MatchField   string `json:"match_field"`
		MatchValue   string `json:"match_value"`
		Action       string `json:"action"`
		TargetFolder string `json:"target_folder,omitempty"`
		Enabled      bool   `json:"enabled"`
	}
	out := make([]ruleOut, len(rules))
	for i, r := range rules {
		out[i] = ruleOut{
			ID:           r.ID.String(),
			Priority:     r.Priority,
			Name:         r.Name,
			MatchField:   r.MatchField,
			MatchValue:   r.MatchValue,
			Action:       r.Action,
			TargetFolder: r.TargetFolder,
			Enabled:      r.Enabled,
		}
	}
	return map[string]any{
		"configured":      true,
		"enabled":         acct.Enabled,
		"dry_run":         acct.DryRun,
		"default_folder":  acct.DefaultFolder,
		"allowed_folders": acct.AllowedFolders,
		"contacts_count":  contactsCount,
		"rules":           out,
	}, nil
}

type MailCreateRuleIn struct {
	Name         string `json:"name,omitempty" jsonschema:"Short human label for the rule"`
	MatchField   string `json:"match_field" jsonschema:"One of: from_email, from_domain, subject, list_id"`
	MatchValue   string `json:"match_value" jsonschema:"Exact email/domain or substring to match (case-insensitive)"`
	Action       string `json:"action" jsonschema:"keep (stay in Inbox) or move"`
	TargetFolder string `json:"target_folder,omitempty" jsonschema:"Destination IMAP folder when action is move"`
	Priority     int    `json:"priority,omitempty" jsonschema:"Lower runs first; default 100"`
}

func mailCreateRule(ctx context.Context, d Deps, c agents.Caller, in MailCreateRuleIn) (any, error) {
	s, err := requireMailChatScope(ctx, d, c, "mail_create_rule")
	if err != nil {
		return nil, err
	}
	r, err := d.Mail.CreateRule(ctx, c.Agent.WorkspaceID, s.UserID, mail.RuleInput{
		Priority:     in.Priority,
		Name:         in.Name,
		MatchField:   in.MatchField,
		MatchValue:   in.MatchValue,
		Action:       in.Action,
		TargetFolder: in.TargetFolder,
		Enabled:      true,
	})
	if err != nil {
		return nil, err
	}
	return map[string]any{
		"id":            r.ID.String(),
		"name":          r.Name,
		"match_field":   r.MatchField,
		"match_value":   r.MatchValue,
		"action":        r.Action,
		"target_folder": r.TargetFolder,
		"priority":      r.Priority,
	}, nil
}

type MailDeleteRuleIn struct {
	RuleID string `json:"rule_id" jsonschema:"UUID of the rule from mail_list_rules"`
}

func mailDeleteRule(ctx context.Context, d Deps, c agents.Caller, in MailDeleteRuleIn) (any, error) {
	s, err := requireMailChatScope(ctx, d, c, "mail_delete_rule")
	if err != nil {
		return nil, err
	}
	id, err := uuid.Parse(in.RuleID)
	if err != nil {
		return nil, apperr.Invalid("rule_id", "must be a valid UUID")
	}
	if err := d.Mail.DeleteRule(ctx, c.Agent.WorkspaceID, s.UserID, id); err != nil {
		return nil, err
	}
	return map[string]any{"deleted": in.RuleID}, nil
}

type MailTriageLogIn struct {
	Limit int `json:"limit,omitempty" jsonschema:"Number of recent entries to return (default 25, max 200)"`
}

func mailTriageLog(ctx context.Context, d Deps, c agents.Caller, in MailTriageLogIn) (any, error) {
	s, err := requireMailChatScope(ctx, d, c, "mail_triage_log")
	if err != nil {
		return nil, err
	}
	limit := in.Limit
	if limit <= 0 {
		limit = 25
	}
	rows, err := d.Mail.ListTriageLog(ctx, c.Agent.WorkspaceID, s.UserID, limit)
	if err != nil {
		return nil, err
	}
	type entryOut struct {
		ID           string `json:"id"`
		FromEmail    string `json:"from_email"`
		Subject      string `json:"subject"`
		Action       string `json:"action"`
		TargetFolder string `json:"target_folder,omitempty"`
		Tier         string `json:"tier"`
		Reason       string `json:"reason"`
		DryRun       bool   `json:"dry_run"`
		Undone       bool   `json:"undone"`
		CreatedAt    string `json:"created_at"`
	}
	out := make([]entryOut, len(rows))
	for i, r := range rows {
		out[i] = entryOut{
			ID:           r.ID.String(),
			FromEmail:    r.FromEmail,
			Subject:      r.Subject,
			Action:       r.Action,
			TargetFolder: r.TargetFolder,
			Tier:         r.Tier,
			Reason:       r.Reason,
			DryRun:       r.DryRun,
			Undone:       r.UndoneAt != nil,
			CreatedAt:    r.CreatedAt.UTC().Format("2006-01-02T15:04:05Z"),
		}
	}
	return map[string]any{"entries": out}, nil
}

type MailUndoMoveIn struct {
	LogID     string `json:"log_id" jsonschema:"UUID from mail_triage_log"`
	PinSender bool   `json:"pin_sender,omitempty" jsonschema:"Also add a high-priority rule to always keep this sender in INBOX"`
}

func mailUndoMove(ctx context.Context, d Deps, c agents.Caller, in MailUndoMoveIn) (any, error) {
	s, err := requireMailChatScope(ctx, d, c, "mail_undo_move")
	if err != nil {
		return nil, err
	}
	id, err := uuid.Parse(in.LogID)
	if err != nil {
		return nil, apperr.Invalid("log_id", "must be a valid UUID")
	}
	row, err := d.Mail.UndoTriageLog(ctx, c.Agent.WorkspaceID, s.UserID, id, in.PinSender)
	if err != nil {
		return nil, err
	}
	return map[string]any{
		"undone":      true,
		"from_email":  row.FromEmail,
		"subject":     row.Subject,
		"pinned_rule": in.PinSender,
	}, nil
}
