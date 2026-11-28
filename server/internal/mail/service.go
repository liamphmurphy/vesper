package mail

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"slices"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/secrets"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

const (
	contactsSyncInterval = 15 * time.Minute
	maxPollBatch         = 30
	maxApplyBatch        = 50
)

// Service manages Mail Butler accounts, contacts, rules, IMAP operations, and
// background polling.
type Service struct {
	Pool       *pgxpool.Pool
	Q          *store.Queries
	Box        *secrets.Box
	Log        *slog.Logger
	NewIMAP    func(ctx context.Context, creds AccountCredentials) (Client, error)
	NewCardDAV func() ContactsFetcher
}

func (s *Service) queries() *store.Queries {
	if s.Q != nil {
		return s.Q
	}
	return store.New(s.Pool)
}

func (s *Service) logger() *slog.Logger {
	if s.Log != nil {
		return s.Log
	}
	return slog.Default()
}

func (s *Service) dialIMAP(ctx context.Context, creds AccountCredentials) (Client, error) {
	if s.NewIMAP != nil {
		return s.NewIMAP(ctx, creds)
	}
	return DialIMAP(ctx, creds)
}

func (s *Service) carddav() ContactsFetcher {
	if s.NewCardDAV != nil {
		return s.NewCardDAV()
	}
	return CardDAVFetcher{}
}

func secretScope(userID uuid.UUID) string {
	return "mail:account:" + userID.String()
}

// UpsertAccountInput configures a user's opt-in Mail Butler account.
type UpsertAccountInput struct {
	Enabled             bool
	DryRun              bool
	Email               string
	Password            string // optional on update if already stored
	IMAPHost            string
	IMAPPort            int
	CardDAVURL          string
	DefaultFolder       string
	AllowedFolders      []string
	TriagePolicy        string
	PinnedModel         string
	PollIntervalSeconds int
}

// UpsertAccount saves or updates the user's Mail Butler configuration.
func (s *Service) UpsertAccount(ctx context.Context, ws, user uuid.UUID, in UpsertAccountInput) (store.MailAccount, error) {
	var zero store.MailAccount
	if s.Box == nil {
		return zero, apperr.Conflict("SECRETS_KEY is not configured; cannot encrypt mail password")
	}
	email := NormalizeEmail(in.Email)
	if email == "" || !strings.Contains(email, "@") {
		return zero, apperr.Invalid("email", "a valid email address is required")
	}
	imapHost := strings.TrimSpace(in.IMAPHost)
	if imapHost == "" {
		imapHost = DefaultIMAPHost
	}
	imapPort := in.IMAPPort
	if imapPort <= 0 {
		imapPort = DefaultIMAPPort
	}
	if imapPort < 1 || imapPort > 65535 {
		return zero, apperr.Invalid("imap_port", "must be between 1 and 65535")
	}
	carddavURL := strings.TrimSpace(in.CardDAVURL)
	if carddavURL == "" {
		carddavURL = DefaultCardDAVURL
	}
	defaultFolder := strings.TrimSpace(in.DefaultFolder)
	if defaultFolder == "" {
		defaultFolder = DefaultFolder
	}
	allowed := CleanFolders(in.AllowedFolders, defaultFolder)
	pollSec := in.PollIntervalSeconds
	if pollSec <= 0 {
		pollSec = DefaultPollInterval
	}
	if pollSec < 15 || pollSec > 3600 {
		return zero, apperr.Invalid("poll_interval_seconds", "must be between 15 and 3600")
	}

	var nonce, ct []byte
	pw := strings.TrimSpace(in.Password)
	if pw != "" {
		var err error
		nonce, ct, err = s.Box.Seal(ws, secretScope(user), []byte(pw))
		if err != nil {
			return zero, fmt.Errorf("seal mail password: %w", err)
		}
	} else {
		// Ensure an account already exists with a stored password.
		if _, err := s.queries().GetMailAccount(ctx, store.GetMailAccountParams{WorkspaceID: ws, UserID: user}); errors.Is(err, pgx.ErrNoRows) {
			return zero, apperr.Invalid("password", "an iCloud App-Specific Password is required")
		} else if err != nil {
			return zero, err
		}
		nonce, ct = []byte{}, []byte{}
	}

	return s.queries().UpsertMailAccount(ctx, store.UpsertMailAccountParams{
		WorkspaceID:         ws,
		UserID:              user,
		Enabled:             in.Enabled,
		DryRun:              in.DryRun,
		Email:               email,
		ImapHost:            imapHost,
		ImapPort:            int32(imapPort),
		CarddavUrl:          carddavURL,
		PasswordNonce:       nonce,
		PasswordCiphertext:  ct,
		DefaultFolder:       defaultFolder,
		AllowedFolders:      allowed,
		TriagePolicy:        strings.TrimSpace(in.TriagePolicy),
		PinnedModel:         strings.TrimSpace(in.PinnedModel),
		PollIntervalSeconds: int32(pollSec),
	})
}

// GetAccount returns the user's Mail Butler account, or pgx.ErrNoRows.
func (s *Service) GetAccount(ctx context.Context, ws, user uuid.UUID) (store.MailAccount, error) {
	return s.queries().GetMailAccount(ctx, store.GetMailAccountParams{WorkspaceID: ws, UserID: user})
}

// DeleteAccount removes the user's Mail Butler account and cached state.
func (s *Service) DeleteAccount(ctx context.Context, ws, user uuid.UUID) error {
	return s.queries().DeleteMailAccount(ctx, store.DeleteMailAccountParams{WorkspaceID: ws, UserID: user})
}

func (s *Service) credentialsFor(acct store.MailAccount) (AccountCredentials, error) {
	if s.Box == nil {
		return AccountCredentials{}, apperr.Conflict("SECRETS_KEY is not configured")
	}
	pw, err := s.Box.Open(acct.WorkspaceID, secretScope(acct.UserID), acct.PasswordNonce, acct.PasswordCiphertext)
	if err != nil {
		return AccountCredentials{}, err
	}
	return AccountCredentials{
		Email:      acct.Email,
		Password:   string(pw),
		IMAPHost:   acct.ImapHost,
		IMAPPort:   int(acct.ImapPort),
		CardDAVURL: acct.CarddavUrl,
	}, nil
}

// TestResult reports IMAP and CardDAV connectivity checks.
type TestResult struct {
	IMAPOK        bool
	IMAPError     string
	CardDAVOK     bool
	CardDAVError  string
	ContactsCount int
}

// TestAccount checks IMAP and CardDAV connectivity for the saved account.
func (s *Service) TestAccount(ctx context.Context, ws, user uuid.UUID) (TestResult, error) {
	acct, err := s.GetAccount(ctx, ws, user)
	if errors.Is(err, pgx.ErrNoRows) {
		return TestResult{}, fmt.Errorf("mail account: %w", apperr.ErrNotFound)
	}
	if err != nil {
		return TestResult{}, err
	}
	creds, err := s.credentialsFor(acct)
	if err != nil {
		return TestResult{}, err
	}
	var out TestResult
	ic, err := s.dialIMAP(ctx, creds)
	if err != nil {
		out.IMAPError = err.Error()
	} else {
		if terr := ic.TestConnection(ctx); terr != nil {
			out.IMAPError = terr.Error()
		} else {
			out.IMAPOK = true
		}
		_ = ic.Close()
	}
	contacts, err := s.carddav().FetchContacts(ctx, creds)
	if err != nil {
		out.CardDAVError = err.Error()
	} else {
		out.CardDAVOK = true
		out.ContactsCount = len(contacts)
	}
	return out, nil
}

// SyncContacts refreshes the account's cached Apple Contacts emails via CardDAV.
func (s *Service) SyncContacts(ctx context.Context, acct store.MailAccount) (int, error) {
	creds, err := s.credentialsFor(acct)
	if err != nil {
		return 0, err
	}
	contacts, err := s.carddav().FetchContacts(ctx, creds)
	if err != nil {
		return 0, err
	}
	tx, err := s.Pool.Begin(ctx)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback(ctx)
	qt := store.New(tx)
	if err := qt.DeleteMailContacts(ctx, acct.ID); err != nil {
		return 0, err
	}
	for _, c := range contacts {
		if err := qt.UpsertMailContact(ctx, store.UpsertMailContactParams{
			AccountID:   acct.ID,
			Email:       c.Email,
			DisplayName: c.DisplayName,
		}); err != nil {
			return 0, err
		}
	}
	if err := qt.TouchMailAccountContactsSynced(ctx, acct.ID); err != nil {
		return 0, err
	}
	if err := tx.Commit(ctx); err != nil {
		return 0, err
	}
	return len(contacts), nil
}

func (s *Service) requireEnabledAccount(ctx context.Context, ws, user uuid.UUID) (store.MailAccount, AccountCredentials, error) {
	acct, err := s.GetAccount(ctx, ws, user)
	if errors.Is(err, pgx.ErrNoRows) {
		return store.MailAccount{}, AccountCredentials{}, apperr.Conflict("mail butler is not configured yet (enable it in Settings -> Mail)")
	}
	if err != nil {
		return store.MailAccount{}, AccountCredentials{}, err
	}
	if !acct.Enabled {
		return store.MailAccount{}, AccountCredentials{}, apperr.Conflict("mail butler is disabled (enable it in Settings -> Mail)")
	}
	creds, err := s.credentialsFor(acct)
	if err != nil {
		return store.MailAccount{}, AccountCredentials{}, err
	}
	return acct, creds, nil
}

// ListMailboxes lists all IMAP folders for the user's account.
func (s *Service) ListMailboxes(ctx context.Context, ws, user uuid.UUID) ([]Mailbox, error) {
	_, creds, err := s.requireEnabledAccount(ctx, ws, user)
	if err != nil {
		return nil, err
	}
	ic, err := s.dialIMAP(ctx, creds)
	if err != nil {
		return nil, err
	}
	defer ic.Close()
	return ic.ListMailboxes(ctx)
}

// CreateMailbox creates an IMAP folder on the mail server.
func (s *Service) CreateMailbox(ctx context.Context, ws, user uuid.UUID, name string) error {
	name = strings.TrimSpace(name)
	if name == "" || strings.EqualFold(name, "INBOX") {
		return apperr.Invalid("name", "invalid mailbox name")
	}
	_, creds, err := s.requireEnabledAccount(ctx, ws, user)
	if err != nil {
		return err
	}
	ic, err := s.dialIMAP(ctx, creds)
	if err != nil {
		return err
	}
	defer ic.Close()
	return ic.CreateMailbox(ctx, name)
}

// RenameMailbox renames an IMAP folder on the mail server.
func (s *Service) RenameMailbox(ctx context.Context, ws, user uuid.UUID, oldName, newName string) error {
	oldName, newName = strings.TrimSpace(oldName), strings.TrimSpace(newName)
	if oldName == "" || newName == "" || strings.EqualFold(oldName, "INBOX") || strings.EqualFold(newName, "INBOX") {
		return apperr.Invalid("name", "invalid mailbox name")
	}
	_, creds, err := s.requireEnabledAccount(ctx, ws, user)
	if err != nil {
		return err
	}
	ic, err := s.dialIMAP(ctx, creds)
	if err != nil {
		return err
	}
	defer ic.Close()
	return ic.RenameMailbox(ctx, oldName, newName)
}

// SearchMessages searches an IMAP mailbox and returns newest-first summaries.
func (s *Service) SearchMessages(ctx context.Context, ws, user uuid.UUID, q SearchQuery) ([]MessageSummary, error) {
	_, creds, err := s.requireEnabledAccount(ctx, ws, user)
	if err != nil {
		return nil, err
	}
	ic, err := s.dialIMAP(ctx, creds)
	if err != nil {
		return nil, err
	}
	defer ic.Close()
	return ic.Search(ctx, q)
}

// MoveMessages moves specific UIDs between IMAP folders and records them in the
// triage log as manual actions.
func (s *Service) MoveMessages(ctx context.Context, ws, user uuid.UUID, sourceFolder string, uids []uint32, targetFolder, reason string) error {
	if len(uids) == 0 {
		return apperr.Invalid("uids", "at least one UID is required")
	}
	if sourceFolder == "" {
		sourceFolder = "INBOX"
	}
	targetFolder = strings.TrimSpace(targetFolder)
	if targetFolder == "" {
		return apperr.Invalid("target_folder", "is required")
	}
	acct, creds, err := s.requireEnabledAccount(ctx, ws, user)
	if err != nil {
		return err
	}
	ic, err := s.dialIMAP(ctx, creds)
	if err != nil {
		return err
	}
	defer ic.Close()
	if err := ensureMailboxExists(ctx, ic, targetFolder); err != nil {
		return err
	}
	if err := ic.MoveByUID(ctx, sourceFolder, uids, targetFolder); err != nil {
		return err
	}
	if reason == "" {
		reason = "Moved via Vesper chat"
	}
	for _, u := range uids {
		_, _ = s.queries().CreateMailTriageLog(ctx, store.CreateMailTriageLogParams{
			AccountID:    acct.ID,
			ImapUid:      int64(u),
			SourceFolder: sourceFolder,
			Action:       "move",
			TargetFolder: targetFolder,
			Tier:         "manual",
			Reason:       reason,
			DryRun:       false,
		})
	}
	return nil
}

// RuleInput validates and creates/updates a deterministic triage rule.
type RuleInput struct {
	Priority     int
	Name         string
	MatchField   string
	MatchValue   string
	Action       string
	TargetFolder string
	Enabled      bool
}

var validMatchFields = []string{"from_email", "from_domain", "subject", "list_id"}

func validateRuleInput(in RuleInput) (RuleInput, error) {
	in.Name = strings.TrimSpace(in.Name)
	in.MatchField = strings.TrimSpace(in.MatchField)
	in.MatchValue = strings.ToLower(strings.TrimSpace(in.MatchValue))
	in.Action = strings.TrimSpace(in.Action)
	in.TargetFolder = strings.TrimSpace(in.TargetFolder)
	if !slices.Contains(validMatchFields, in.MatchField) {
		return in, apperr.Invalid("match_field", "must be one of from_email, from_domain, subject, list_id")
	}
	if in.MatchValue == "" {
		return in, apperr.Invalid("match_value", "is required")
	}
	if in.Action != "keep" && in.Action != "move" {
		return in, apperr.Invalid("action", "must be keep or move")
	}
	if in.Action == "move" && in.TargetFolder == "" {
		return in, apperr.Invalid("target_folder", "is required when action is move")
	}
	if in.Action == "keep" {
		in.TargetFolder = ""
	}
	if in.Priority == 0 {
		in.Priority = 100
	}
	return in, nil
}

// ListRules returns all deterministic rules for the user's account.
func (s *Service) ListRules(ctx context.Context, ws, user uuid.UUID) ([]store.MailRule, error) {
	acct, err := s.GetAccount(ctx, ws, user)
	if errors.Is(err, pgx.ErrNoRows) {
		return []store.MailRule{}, nil
	}
	if err != nil {
		return nil, err
	}
	return s.queries().ListMailRules(ctx, acct.ID)
}

// CreateRule adds a deterministic rule to the user's account.
func (s *Service) CreateRule(ctx context.Context, ws, user uuid.UUID, in RuleInput) (store.MailRule, error) {
	var zero store.MailRule
	acct, err := s.GetAccount(ctx, ws, user)
	if errors.Is(err, pgx.ErrNoRows) {
		return zero, fmt.Errorf("mail account: %w", apperr.ErrNotFound)
	}
	if err != nil {
		return zero, err
	}
	in, err = validateRuleInput(in)
	if err != nil {
		return zero, err
	}
	return s.queries().CreateMailRule(ctx, store.CreateMailRuleParams{
		AccountID:    acct.ID,
		Priority:     int32(in.Priority),
		Name:         in.Name,
		MatchField:   in.MatchField,
		MatchValue:   in.MatchValue,
		Action:       in.Action,
		TargetFolder: in.TargetFolder,
		Enabled:      in.Enabled,
	})
}

// DeleteRule removes a deterministic rule by ID.
func (s *Service) DeleteRule(ctx context.Context, ws, user, ruleID uuid.UUID) error {
	acct, err := s.GetAccount(ctx, ws, user)
	if errors.Is(err, pgx.ErrNoRows) {
		return fmt.Errorf("mail account: %w", apperr.ErrNotFound)
	}
	if err != nil {
		return err
	}
	if _, err := s.queries().DeleteMailRule(ctx, store.DeleteMailRuleParams{ID: ruleID, AccountID: acct.ID}); errors.Is(err, pgx.ErrNoRows) {
		return fmt.Errorf("mail rule: %w", apperr.ErrNotFound)
	} else if err != nil {
		return err
	}
	return nil
}

// ListTriageLog returns recent triage actions for the user's account.
func (s *Service) ListTriageLog(ctx context.Context, ws, user uuid.UUID, limit int) ([]store.MailTriageLog, error) {
	acct, err := s.GetAccount(ctx, ws, user)
	if errors.Is(err, pgx.ErrNoRows) {
		return []store.MailTriageLog{}, nil
	}
	if err != nil {
		return nil, err
	}
	if limit <= 0 {
		limit = 50
	}
	if limit > 200 {
		limit = 200
	}
	return s.queries().ListMailTriageLog(ctx, store.ListMailTriageLogParams{
		AccountID: acct.ID,
		RowLimit:  int32(limit),
	})
}

// UndoTriageLog moves a previously moved message back to its source folder
// (unless it was a dry-run entry), marks the log entry undone, and optionally
// adds a high-priority keep rule for the sender.
func (s *Service) UndoTriageLog(ctx context.Context, ws, user, logID uuid.UUID, pinSender bool) (store.MailTriageLog, error) {
	var zero store.MailTriageLog
	acct, err := s.GetAccount(ctx, ws, user)
	if errors.Is(err, pgx.ErrNoRows) {
		return zero, fmt.Errorf("mail account: %w", apperr.ErrNotFound)
	}
	if err != nil {
		return zero, err
	}
	entry, err := s.queries().GetMailTriageLog(ctx, store.GetMailTriageLogParams{ID: logID, AccountID: acct.ID})
	if errors.Is(err, pgx.ErrNoRows) {
		return zero, fmt.Errorf("triage log entry: %w", apperr.ErrNotFound)
	}
	if err != nil {
		return zero, err
	}
	if entry.UndoneAt != nil {
		return entry, nil
	}
	if entry.Action == "move" && !entry.DryRun && entry.TargetFolder != "" {
		creds, err := s.credentialsFor(acct)
		if err != nil {
			return zero, err
		}
		ic, err := s.dialIMAP(ctx, creds)
		if err != nil {
			return zero, err
		}
		defer ic.Close()
		moved := false
		if entry.MessageID != "" {
			moved, err = ic.MoveByMessageID(ctx, entry.TargetFolder, entry.MessageID, entry.SourceFolder)
			if err != nil {
				return zero, err
			}
		}
		if !moved && entry.ImapUid > 0 {
			_ = ic.MoveByUID(ctx, entry.TargetFolder, []uint32{uint32(entry.ImapUid)}, entry.SourceFolder)
		}
	}
	updated, err := s.queries().MarkMailTriageLogUndone(ctx, store.MarkMailTriageLogUndoneParams{ID: logID, AccountID: acct.ID})
	if err != nil {
		return zero, err
	}
	if pinSender && entry.FromEmail != "" {
		_, _ = s.queries().CreateMailRule(ctx, store.CreateMailRuleParams{
			AccountID:  acct.ID,
			Priority:   10,
			Name:       "Keep " + entry.FromEmail,
			MatchField: "from_email",
			MatchValue: NormalizeEmail(entry.FromEmail),
			Action:     "keep",
			Enabled:    true,
		})
	}
	return updated, nil
}

// DeterministicDecision is the outcome of Tier-1 (Contacts + explicit rules)
// evaluation. Matched == false means the message should go to Tier-2 LLM triage.
type DeterministicDecision struct {
	Matched      bool
	Action       string // "keep" or "move"
	TargetFolder string
	Tier         string // "contact" or "rule"
	Reason       string
}

// EvaluateDeterministic checks Apple Contacts first, then explicit rules in
// priority order.
func EvaluateDeterministic(msg MessageSummary, isContact bool, rules []store.MailRule) DeterministicDecision {
	if isContact {
		return DeterministicDecision{
			Matched: true,
			Action:  "keep",
			Tier:    "contact",
			Reason:  "Sender is in Apple Contacts",
		}
	}
	fromEmail := NormalizeEmail(msg.FromEmail)
	fromDomain := EmailDomain(fromEmail)
	subjectLower := strings.ToLower(msg.Subject)
	listIDLower := strings.ToLower(msg.ListID)

	for _, r := range rules {
		if !r.Enabled {
			continue
		}
		val := strings.ToLower(strings.TrimSpace(r.MatchValue))
		if val == "" {
			continue
		}
		matched := false
		switch r.MatchField {
		case "from_email":
			matched = fromEmail == val
		case "from_domain":
			matched = fromDomain == val || strings.HasSuffix(fromDomain, "."+val)
		case "subject":
			matched = strings.Contains(subjectLower, val)
		case "list_id":
			matched = listIDLower != "" && strings.Contains(listIDLower, val)
		}
		if matched {
			label := r.Name
			if label == "" {
				label = fmt.Sprintf("%s=%s", r.MatchField, r.MatchValue)
			}
			return DeterministicDecision{
				Matched:      true,
				Action:       r.Action,
				TargetFolder: r.TargetFolder,
				Tier:         "rule",
				Reason:       "Matched rule: " + label,
			}
		}
	}
	return DeterministicDecision{}
}

// PollAccount syncs contacts if stale, polls new INBOX messages, runs Tier-1
// triage, queues unknown senders for the runner, and applies decided Tier-2
// items from the runner.
func (s *Service) PollAccount(ctx context.Context, acct store.MailAccount) error {
	if !acct.Enabled {
		return nil
	}
	q := s.queries()
	if acct.LastContactsSyncedAt == nil || time.Since(*acct.LastContactsSyncedAt) >= contactsSyncInterval {
		if n, err := s.SyncContacts(ctx, acct); err != nil {
			s.logger().Warn("mail contacts sync failed", "account", acct.ID, "err", err)
		} else {
			s.logger().Info("mail contacts synced", "account", acct.ID, "count", n)
		}
	}

	creds, err := s.credentialsFor(acct)
	if err != nil {
		_ = q.UpdateMailAccountError(ctx, store.UpdateMailAccountErrorParams{ID: acct.ID, LastError: err.Error()})
		return err
	}
	ic, err := s.dialIMAP(ctx, creds)
	if err != nil {
		_ = q.UpdateMailAccountError(ctx, store.UpdateMailAccountErrorParams{ID: acct.ID, LastError: err.Error()})
		return err
	}
	defer ic.Close()

	// 1. Apply any Tier-2 decisions already produced by the runner.
	if err := s.applyDecided(ctx, ic, acct); err != nil {
		s.logger().Warn("mail apply decided failed", "account", acct.ID, "err", err)
	}

	// 2. Fetch new INBOX messages.
	fetched, err := ic.FetchNewInbox(ctx, uint32(acct.InboxUidValidity), uint32(acct.LastSeenUid), maxPollBatch)
	if err != nil {
		_ = q.UpdateMailAccountError(ctx, store.UpdateMailAccountErrorParams{ID: acct.ID, LastError: err.Error()})
		return err
	}

	rules, err := q.ListMailRules(ctx, acct.ID)
	if err != nil {
		return err
	}

	for _, msg := range fetched.Messages {
		isContact, err := q.IsMailContact(ctx, store.IsMailContactParams{AccountID: acct.ID, Email: msg.FromEmail})
		if err != nil {
			return err
		}
		dec := EvaluateDeterministic(msg, isContact, rules)
		if dec.Matched {
			if err := s.executeDecision(ctx, ic, acct, msg, dec.Action, dec.TargetFolder, dec.Tier, dec.Reason); err != nil {
				s.logger().Warn("mail tier1 execute failed", "account", acct.ID, "uid", msg.UID, "err", err)
			}
			continue
		}
		var recv *time.Time
		if !msg.ReceivedAt.IsZero() {
			t := msg.ReceivedAt
			recv = &t
		}
		_, err = q.EnqueueMailTriage(ctx, store.EnqueueMailTriageParams{
			AccountID:       acct.ID,
			WorkspaceID:     acct.WorkspaceID,
			UserID:          acct.UserID,
			ImapUid:         int64(msg.UID),
			UidValidity:     int64(msg.UIDValidity),
			MessageID:       msg.MessageID,
			FromEmail:       msg.FromEmail,
			FromName:        msg.FromName,
			Subject:         msg.Subject,
			ListUnsubscribe: msg.ListUnsubscribe,
			Snippet:         msg.Snippet,
			ReceivedAt:      recv,
		})
		if err != nil && !errors.Is(err, pgx.ErrNoRows) {
			s.logger().Warn("mail enqueue triage failed", "account", acct.ID, "uid", msg.UID, "err", err)
		}
	}

	return q.UpdateMailAccountSyncState(ctx, store.UpdateMailAccountSyncStateParams{
		ID:               acct.ID,
		InboxUidValidity: int64(fetched.UIDValidity),
		LastSeenUid:      int64(fetched.MaxUID),
		LastError:        "",
	})
}

func (s *Service) applyDecided(ctx context.Context, ic Client, acct store.MailAccount) error {
	q := s.queries()
	items, err := q.ListDecidedMailTriageItems(ctx, store.ListDecidedMailTriageItemsParams{
		AccountID: acct.ID,
		RowLimit:  maxApplyBatch,
	})
	if err != nil {
		return err
	}
	for _, it := range items {
		action := it.DecisionAction
		folder := it.DecisionFolder
		if action == "move" {
			folder = resolveAllowedFolder(folder, acct.AllowedFolders, acct.DefaultFolder)
		} else {
			action = "keep"
			folder = ""
		}
		msg := MessageSummary{
			UID:         uint32(it.ImapUid),
			UIDValidity: uint32(it.UidValidity),
			MessageID:   it.MessageID,
			FromEmail:   it.FromEmail,
			FromName:    it.FromName,
			Subject:     it.Subject,
		}
		if err := s.executeDecision(ctx, ic, acct, msg, action, folder, "llm", it.DecisionReason); err != nil {
			return err
		}
		if err := q.MarkMailTriageApplied(ctx, it.ID); err != nil {
			return err
		}
	}
	return nil
}

func (s *Service) executeDecision(ctx context.Context, ic Client, acct store.MailAccount, msg MessageSummary, action, targetFolder, tier, reason string) error {
	if action == "move" && !acct.DryRun {
		if err := ensureMailboxExists(ctx, ic, targetFolder); err != nil {
			return err
		}
		if err := ic.MoveByUID(ctx, "INBOX", []uint32{msg.UID}, targetFolder); err != nil {
			return err
		}
	}
	_, err := s.queries().CreateMailTriageLog(ctx, store.CreateMailTriageLogParams{
		AccountID:    acct.ID,
		ImapUid:      int64(msg.UID),
		UidValidity:  int64(msg.UIDValidity),
		MessageID:    msg.MessageID,
		FromEmail:    msg.FromEmail,
		FromName:     msg.FromName,
		Subject:      msg.Subject,
		SourceFolder: "INBOX",
		Action:       action,
		TargetFolder: targetFolder,
		Tier:         tier,
		Reason:       reason,
		DryRun:       acct.DryRun,
	})
	return err
}

func resolveAllowedFolder(requested string, allowed []string, fallback string) string {
	req := strings.TrimSpace(requested)
	for _, f := range allowed {
		if strings.EqualFold(f, req) {
			return f
		}
	}
	if strings.TrimSpace(fallback) != "" {
		return strings.TrimSpace(fallback)
	}
	return DefaultFolder
}

func ensureMailboxExists(ctx context.Context, ic Client, name string) error {
	boxes, err := ic.ListMailboxes(ctx)
	if err != nil {
		return err
	}
	for _, b := range boxes {
		if strings.EqualFold(b.Name, name) {
			return nil
		}
	}
	return ic.CreateMailbox(ctx, name)
}

// Run polls all enabled Mail Butler accounts on a ticker until ctx is cancelled.
func (s *Service) Run(ctx context.Context, tick time.Duration) {
	if tick <= 0 {
		tick = 15 * time.Second
	}
	t := time.NewTicker(tick)
	defer t.Stop()
	for {
		s.pollDue(ctx)
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}

func (s *Service) pollDue(ctx context.Context) {
	accts, err := s.queries().ListEnabledMailAccounts(ctx)
	if err != nil {
		if ctx.Err() == nil {
			s.logger().Warn("mail poller list accounts", "err", err)
		}
		return
	}
	now := time.Now()
	for _, acct := range accts {
		if ctx.Err() != nil {
			return
		}
		interval := time.Duration(acct.PollIntervalSeconds) * time.Second
		if interval < 15*time.Second {
			interval = 15 * time.Second
		}
		// Poll immediately if decided items are waiting, or when the account's poll interval elapsed.
		due := acct.LastSyncedAt == nil || now.Sub(*acct.LastSyncedAt) >= interval
		if !due {
			decided, err := s.queries().ListDecidedMailTriageItems(ctx, store.ListDecidedMailTriageItemsParams{
				AccountID: acct.ID,
				RowLimit:  1,
			})
			due = err == nil && len(decided) > 0
		}
		if !due {
			continue
		}
		if err := s.PollAccount(ctx, acct); err != nil && ctx.Err() == nil {
			s.logger().Warn("mail poll failed", "account", acct.ID, "err", err)
		}
	}
}
