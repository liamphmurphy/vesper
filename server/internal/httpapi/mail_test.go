package httpapi

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"net/http"
	"testing"

	"github.com/liamphmurphy/vesper/server/internal/mail"
	"github.com/liamphmurphy/vesper/server/internal/secrets"
)

type testMailIMAP struct {
	mailboxes []mail.Mailbox
}

func (f *testMailIMAP) Close() error                         { return nil }
func (f *testMailIMAP) TestConnection(context.Context) error { return nil }
func (f *testMailIMAP) ListMailboxes(context.Context) ([]mail.Mailbox, error) {
	return f.mailboxes, nil
}
func (f *testMailIMAP) CreateMailbox(_ context.Context, name string) error {
	f.mailboxes = append(f.mailboxes, mail.Mailbox{Name: name})
	return nil
}
func (f *testMailIMAP) RenameMailbox(context.Context, string, string) error { return nil }
func (f *testMailIMAP) Search(context.Context, mail.SearchQuery) ([]mail.MessageSummary, error) {
	return []mail.MessageSummary{}, nil
}
func (f *testMailIMAP) FetchNewInbox(context.Context, uint32, uint32, int) (mail.InboxFetchResult, error) {
	return mail.InboxFetchResult{}, nil
}
func (f *testMailIMAP) MoveByUID(context.Context, string, []uint32, string) error { return nil }
func (f *testMailIMAP) MoveByMessageID(context.Context, string, string, string) (bool, error) {
	return true, nil
}

type testMailCardDAV struct{}

func (testMailCardDAV) FetchContacts(context.Context, mail.AccountCredentials) ([]mail.Contact, error) {
	return []mail.Contact{{Email: "alice@example.com", DisplayName: "Alice"}}, nil
}

func TestMailButlerHTTPAPI(t *testing.T) {
	rawKey := make([]byte, 32)
	_, _ = rand.Read(rawKey)
	box, err := secrets.NewBox(base64.StdEncoding.EncodeToString(rawKey))
	if err != nil {
		t.Fatalf("secrets box: %v", err)
	}
	e := newChatEnvServer(t, nil, func(s *Server) {
		s.Secrets = &secrets.Service{Q: s.Q, Box: box}
		s.Mail = &mail.Service{
			Pool: s.Pool,
			Q:    s.Q,
			Box:  box,
			NewIMAP: func(context.Context, mail.AccountCredentials) (mail.Client, error) {
				return &testMailIMAP{mailboxes: []mail.Mailbox{{Name: "INBOX"}}}, nil
			},
			NewCardDAV: func() mail.ContactsFetcher { return testMailCardDAV{} },
		}
	})

	// Unconfigured by default (opt-in).
	got := e.want("GET", "/mail/account", nil, http.StatusOK)
	if got["configured"] != false {
		t.Fatalf("expected configured=false, got %v", got["configured"])
	}

	// Save opt-in disabled account in dry-run mode.
	acct := e.want("PUT", "/mail/account", map[string]any{
		"enabled":  false,
		"dry_run":  true,
		"email":    "liam@icloud.com",
		"password": "xxxx-xxxx-xxxx-xxxx",
	}, http.StatusOK)
	if acct["enabled"] != false || acct["dry_run"] != true {
		t.Fatalf("unexpected account state: %+v", acct)
	}

	// Test connectivity.
	testRes := e.want("POST", "/mail/account/test", nil, http.StatusOK)
	if testRes["imap_ok"] != true || testRes["carddav_ok"] != true {
		t.Fatalf("expected imap_ok and carddav_ok true, got %+v", testRes)
	}

	// Sync contacts.
	syncRes := e.want("POST", "/mail/contacts/sync", nil, http.StatusOK)
	if syncRes["contacts_count"] != float64(1) {
		t.Fatalf("expected contacts_count=1, got %v", syncRes["contacts_count"])
	}

	// Create, list, and delete a rule.
	rule := e.want("POST", "/mail/rules", map[string]any{
		"name":        "Keep bills",
		"match_field": "subject",
		"match_value": "statement ready",
		"action":      "keep",
		"priority":    10,
	}, http.StatusCreated)
	ruleID, _ := rule["id"].(string)
	if ruleID == "" {
		t.Fatalf("expected rule id, got %+v", rule)
	}

	rules := e.want("GET", "/mail/rules", nil, http.StatusOK)
	if list, _ := rules["rules"].([]any); len(list) != 1 {
		t.Fatalf("expected 1 rule, got %+v", rules)
	}

	e.want("DELETE", "/mail/rules/"+ruleID, nil, http.StatusNoContent)
	e.want("GET", "/mail/triage-log", nil, http.StatusOK)
	e.want("DELETE", "/mail/account", nil, http.StatusNoContent)
}
