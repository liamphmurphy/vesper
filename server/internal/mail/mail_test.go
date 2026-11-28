package mail

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"net/http"
	"net/http/httptest"
	"slices"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/liamphmurphy/vesper/server/internal/secrets"
	"github.com/liamphmurphy/vesper/server/internal/seed"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/testdb"
)

type fakeIMAP struct {
	mailboxes  []Mailbox
	fetched    InboxFetchResult
	searchRes  []MessageSummary
	movedUIDs  []movedCall
	movedMsgID []movedMsgIDCall
	created    []string
	renamed    [][2]string
}

type movedCall struct {
	source string
	uids   []uint32
	target string
}

type movedMsgIDCall struct {
	source    string
	messageID string
	target    string
}

func (f *fakeIMAP) Close() error                         { return nil }
func (f *fakeIMAP) TestConnection(context.Context) error { return nil }
func (f *fakeIMAP) ListMailboxes(context.Context) ([]Mailbox, error) {
	return slices.Clone(f.mailboxes), nil
}
func (f *fakeIMAP) CreateMailbox(_ context.Context, name string) error {
	f.created = append(f.created, name)
	f.mailboxes = append(f.mailboxes, Mailbox{Name: name})
	return nil
}
func (f *fakeIMAP) RenameMailbox(_ context.Context, oldName, newName string) error {
	f.renamed = append(f.renamed, [2]string{oldName, newName})
	return nil
}
func (f *fakeIMAP) Search(_ context.Context, _ SearchQuery) ([]MessageSummary, error) {
	return slices.Clone(f.searchRes), nil
}
func (f *fakeIMAP) FetchNewInbox(_ context.Context, _, _ uint32, _ int) (InboxFetchResult, error) {
	return f.fetched, nil
}
func (f *fakeIMAP) MoveByUID(_ context.Context, source string, uids []uint32, target string) error {
	f.movedUIDs = append(f.movedUIDs, movedCall{source: source, uids: slices.Clone(uids), target: target})
	return nil
}
func (f *fakeIMAP) MoveByMessageID(_ context.Context, source, msgID, target string) (bool, error) {
	f.movedMsgID = append(f.movedMsgID, movedMsgIDCall{source: source, messageID: msgID, target: target})
	return true, nil
}

type fakeCardDAV struct {
	contacts []Contact
}

func (f *fakeCardDAV) FetchContacts(context.Context, AccountCredentials) ([]Contact, error) {
	return slices.Clone(f.contacts), nil
}

func setupTestEnv(t *testing.T) (*pgxpool.Pool, *Service, uuid.UUID, uuid.UUID, *fakeIMAP, *fakeCardDAV) {
	t.Helper()
	ctx := context.Background()
	pool := testdb.New(t)
	if _, err := seed.Run(ctx, pool, seed.Options{UserName: "Liam", UserEmail: "liam@example.com"}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	q := store.New(pool)
	u, err := q.GetLocalUser(ctx)
	if err != nil {
		t.Fatalf("local user: %v", err)
	}
	rawKey := make([]byte, 32)
	_, _ = rand.Read(rawKey)
	box, err := secrets.NewBox(base64.StdEncoding.EncodeToString(rawKey))
	if err != nil {
		t.Fatalf("secrets box: %v", err)
	}
	fi := &fakeIMAP{mailboxes: []Mailbox{{Name: "INBOX"}}}
	fc := &fakeCardDAV{contacts: []Contact{{Email: "mom@family.test", DisplayName: "Mom"}}}
	svc := &Service{
		Pool:       pool,
		Q:          q,
		Box:        box,
		NewIMAP:    func(context.Context, AccountCredentials) (Client, error) { return fi, nil },
		NewCardDAV: func() ContactsFetcher { return fc },
	}
	return pool, svc, u.WorkspaceID, u.ID, fi, fc
}

func TestMailButlerPipelineDryRunLiveAndUndo(t *testing.T) {
	ctx := context.Background()
	_, svc, ws, user, fi, _ := setupTestEnv(t)

	// 1. Account is opt-in (enabled=false, dry_run=true).
	acct, err := svc.UpsertAccount(ctx, ws, user, UpsertAccountInput{
		Enabled:  false,
		DryRun:   true,
		Email:    "liam@icloud.com",
		Password: "xxxx-xxxx-xxxx-xxxx",
	})
	if err != nil {
		t.Fatalf("upsert account: %v", err)
	}
	if acct.Enabled || !acct.DryRun {
		t.Fatalf("expected opt-in defaults enabled=false dry_run=true, got enabled=%v dry_run=%v", acct.Enabled, acct.DryRun)
	}

	// Updating settings without re-sending password preserves stored password.
	acct, err = svc.UpsertAccount(ctx, ws, user, UpsertAccountInput{
		Enabled:       true,
		DryRun:        true,
		Email:         "liam@icloud.com",
		DefaultFolder: "Low Priority",
		AllowedFolders: []string{
			"Low Priority", "Newsletters", "Receipts",
		},
	})
	if err != nil {
		t.Fatalf("enable account without password: %v", err)
	}

	// Add an explicit rule for newsletters from a known domain.
	if _, err := svc.CreateRule(ctx, ws, user, RuleInput{
		Priority:     50,
		Name:         "Substack",
		MatchField:   "from_domain",
		MatchValue:   "substack.com",
		Action:       "move",
		TargetFolder: "Newsletters",
		Enabled:      true,
	}); err != nil {
		t.Fatalf("create rule: %v", err)
	}

	// Feed 3 messages: 1 Apple Contact, 1 rule match, 1 unknown sender.
	fi.fetched = InboxFetchResult{
		UIDValidity: 42,
		MaxUID:      103,
		Messages: []MessageSummary{
			{UID: 101, UIDValidity: 42, MessageID: "<m1@family.test>", FromEmail: "mom@family.test", Subject: "Sunday dinner", ReceivedAt: time.Now()},
			{UID: 102, UIDValidity: 42, MessageID: "<m2@substack.com>", FromEmail: "writer@substack.com", Subject: "Weekly issue", ReceivedAt: time.Now()},
			{UID: 103, UIDValidity: 42, MessageID: "<m3@promo.example>", FromEmail: "deals@promo.example", Subject: "50% off today!", ListUnsubscribe: true, Snippet: "Save big on everything", ReceivedAt: time.Now()},
		},
	}

	if err := svc.PollAccount(ctx, acct); err != nil {
		t.Fatalf("poll account (dry-run): %v", err)
	}

	// Dry-run must NOT have executed any IMAP moves.
	if len(fi.movedUIDs) != 0 {
		t.Fatalf("expected 0 IMAP moves in dry-run, got %d", len(fi.movedUIDs))
	}

	// Check triage log has contact keep + rule move (dry-run).
	logs, err := svc.ListTriageLog(ctx, ws, user, 10)
	if err != nil {
		t.Fatalf("list logs: %v", err)
	}
	if len(logs) != 2 {
		t.Fatalf("expected 2 tier-1 log entries, got %d", len(logs))
	}

	// Check unknown sender was queued for idle-VM classification.
	pending, err := svc.Q.CountPendingMailTriage(ctx, acct.ID)
	if err != nil || pending != 1 {
		t.Fatalf("expected 1 pending triage queue item, got %d (err=%v)", pending, err)
	}

	// Simulate runner claiming and deciding the queued item with a disallowed folder
	// (must safely fall back to DefaultFolder = "Low Priority").
	batch, err := svc.Q.ClaimMailTriageBatch(ctx, store.ClaimMailTriageBatchParams{
		AccountID:   acct.ID,
		StaleBefore: time.Now().Add(-5 * time.Minute),
		MaxAttempts: MaxTriageAttempts,
		BatchLimit:  10,
	})
	if err != nil || len(batch) != 1 {
		t.Fatalf("claim batch: len=%d err=%v", len(batch), err)
	}
	if err := svc.Q.SaveMailTriageDecision(ctx, store.SaveMailTriageDecisionParams{
		ID:             batch[0].ID,
		DecisionAction: "move",
		DecisionFolder: "HallucinatedFolder",
		DecisionReason: "Promotional marketing email",
	}); err != nil {
		t.Fatalf("save decision: %v", err)
	}

	// Flip to LIVE mode and poll again to apply the decided item.
	acct, err = svc.UpsertAccount(ctx, ws, user, UpsertAccountInput{
		Enabled:        true,
		DryRun:         false,
		Email:          "liam@icloud.com",
		DefaultFolder:  "Low Priority",
		AllowedFolders: []string{"Low Priority", "Newsletters", "Receipts"},
	})
	if err != nil {
		t.Fatalf("switch to live: %v", err)
	}
	fi.fetched = InboxFetchResult{UIDValidity: 42, MaxUID: 103}
	if err := svc.PollAccount(ctx, acct); err != nil {
		t.Fatalf("poll live: %v", err)
	}

	if len(fi.movedUIDs) != 1 {
		t.Fatalf("expected 1 live IMAP move, got %d", len(fi.movedUIDs))
	}
	if fi.movedUIDs[0].target != "Low Priority" {
		t.Fatalf("expected fallback to Low Priority, got %q", fi.movedUIDs[0].target)
	}
	if !slices.Contains(fi.created, "Low Priority") {
		t.Fatalf("expected Low Priority folder to be auto-created, created=%v", fi.created)
	}

	// Undo the LLM move and pin the sender.
	logs, err = svc.ListTriageLog(ctx, ws, user, 10)
	if err != nil || len(logs) != 3 {
		t.Fatalf("expected 3 logs, got %d (err=%v)", len(logs), err)
	}
	llmLog := logs[0] // newest first
	if llmLog.Tier != "llm" || llmLog.DryRun {
		t.Fatalf("expected newest log to be live llm move, got tier=%s dry_run=%v", llmLog.Tier, llmLog.DryRun)
	}
	undone, err := svc.UndoTriageLog(ctx, ws, user, llmLog.ID, true)
	if err != nil {
		t.Fatalf("undo: %v", err)
	}
	if undone.UndoneAt == nil {
		t.Fatalf("expected undone_at to be set")
	}
	if len(fi.movedMsgID) != 1 || fi.movedMsgID[0].target != "INBOX" {
		t.Fatalf("expected MoveByMessageID back to INBOX, got %+v", fi.movedMsgID)
	}
	rules, err := svc.ListRules(ctx, ws, user)
	if err != nil {
		t.Fatalf("list rules: %v", err)
	}
	foundPin := false
	for _, r := range rules {
		if r.MatchField == "from_email" && r.MatchValue == "deals@promo.example" && r.Action == "keep" {
			foundPin = true
		}
	}
	if !foundPin {
		t.Fatalf("expected undo with pinSender=true to create a keep rule for deals@promo.example")
	}
}

func TestScopedBasicAuthTransportHostLockdown(t *testing.T) {
	var gotAuth string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotAuth = r.Header.Get("Authorization")
		w.WriteHeader(http.StatusOK)
	}))
	defer srv.Close()

	tr := &scopedBasicAuthTransport{
		base:        http.DefaultTransport,
		allowedHost: "contacts.icloud.com",
		username:    "liam@icloud.com",
		password:    "secret-pw",
	}
	if !tr.hostAllowed("contacts.icloud.com") || !tr.hostAllowed("p42-contacts.icloud.com") {
		t.Fatalf("expected icloud.com subdomains to be allowed")
	}
	if tr.hostAllowed("evil.example.com") || tr.hostAllowed("icloud.com.evil.com") {
		t.Fatalf("expected non-icloud hosts to be rejected")
	}

	// Request to httptest (127.0.0.1) must NOT receive Authorization header.
	req, _ := http.NewRequest(http.MethodGet, srv.URL, nil)
	resp, err := (&http.Client{Transport: tr}).Do(req)
	if err != nil {
		t.Fatalf("request: %v", err)
	}
	_ = resp.Body.Close()
	if gotAuth != "" {
		t.Fatalf("credentials leaked to non-allowed host: %q", gotAuth)
	}
}
