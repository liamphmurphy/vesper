// Package mail implements Vesper's opt-in IMAP/CardDAV Mail Butler:
// syncing Apple Contacts over CardDAV, polling iCloud Mail over IMAP,
// evaluating deterministic rules, queueing unknown senders for idle-VM
// classification, and executing safe folder moves with full audit and undo.
package mail

import (
	"context"
	"strings"
	"time"
)

const (
	DefaultIMAPHost     = "imap.mail.me.com"
	DefaultIMAPPort     = 993
	DefaultCardDAVURL   = "https://contacts.icloud.com/"
	DefaultFolder       = "Low Priority"
	DefaultPollInterval = 60
	MaxSnippetRunes     = 600
	MaxTriageAttempts   = 3
)

// DefaultAllowedFolders is the starter set of non-inbox folders the classifier
// may move mail into.
var DefaultAllowedFolders = []string{"Low Priority", "Newsletters", "Receipts"}

// DefaultTriagePolicy is used when the user hasn't customized their plain-English
// triage instructions in Settings.
const DefaultTriagePolicy = `Keep in INBOX:
- Personal emails from real humans, friends, family, or colleagues
- Important notices: bills, invoices, statements, payment due notices, banking/financial alerts, tax documents, medical/dental/insurance notices, government mail, travel/flight confirmations, account security alerts, and direct order/delivery problems

Move out of INBOX:
- Newsletters, digests, blogs, and mailing lists -> Newsletters
- Routine purchase receipts and shipping confirmations -> Receipts
- Marketing, promotions, sales, cold outreach, and low-priority automated notifications -> Low Priority`

// Mailbox is one IMAP folder on the mail server.
type Mailbox struct {
	Name      string
	Delimiter string
	Messages  uint32
	Unseen    uint32
}

// MessageSummary is the metadata and short plain-text snippet fetched for
// search results or incoming triage.
type MessageSummary struct {
	UID             uint32
	UIDValidity     uint32
	MessageID       string
	FromEmail       string
	FromName        string
	Subject         string
	ListID          string
	ListUnsubscribe bool
	Snippet         string
	ReceivedAt      time.Time
}

// InboxFetchResult holds newly arrived INBOX messages since the last poll.
type InboxFetchResult struct {
	UIDValidity uint32
	MaxUID      uint32
	Messages    []MessageSummary
}

// Contact is one email address synced from CardDAV (Apple Contacts).
type Contact struct {
	Email       string
	DisplayName string
}

// SearchQuery filters IMAP search.
type SearchQuery struct {
	Mailbox string // defaults to "INBOX"
	From    string
	Subject string
	Text    string
	Unseen  bool
	Limit   int // defaults to 25, max 100
}

// AccountCredentials are the decrypted connection parameters for one account.
type AccountCredentials struct {
	Email      string
	Password   string
	IMAPHost   string
	IMAPPort   int
	CardDAVURL string
}

// Client abstracts IMAP operations so Service and Poller are testable without a
// live mail server.
type Client interface {
	Close() error
	TestConnection(ctx context.Context) error
	ListMailboxes(ctx context.Context) ([]Mailbox, error)
	CreateMailbox(ctx context.Context, name string) error
	RenameMailbox(ctx context.Context, oldName, newName string) error
	Search(ctx context.Context, q SearchQuery) ([]MessageSummary, error)
	FetchNewInbox(ctx context.Context, lastUIDValidity, lastSeenUID uint32, limit int) (InboxFetchResult, error)
	MoveByUID(ctx context.Context, sourceFolder string, uids []uint32, targetFolder string) error
	MoveByMessageID(ctx context.Context, sourceFolder, messageID, targetFolder string) (bool, error)
}

// ContactsFetcher abstracts CardDAV contact syncing.
type ContactsFetcher interface {
	FetchContacts(ctx context.Context, creds AccountCredentials) ([]Contact, error)
}

// NormalizeEmail lowercases and trims an email address.
func NormalizeEmail(raw string) string {
	return strings.ToLower(strings.TrimSpace(raw))
}

// EmailDomain extracts the lowercased domain part after '@', or "".
func EmailDomain(addr string) string {
	addr = NormalizeEmail(addr)
	at := strings.LastIndexByte(addr, '@')
	if at < 0 || at+1 >= len(addr) {
		return ""
	}
	return addr[at+1:]
}

// SanitizeSnippet collapses whitespace and truncates a plain-text body preview.
func SanitizeSnippet(s string, maxRunes int) string {
	s = strings.Join(strings.Fields(s), " ")
	if maxRunes <= 0 {
		maxRunes = MaxSnippetRunes
	}
	if r := []rune(s); len(r) > maxRunes {
		return string(r[:maxRunes])
	}
	return s
}

// CleanFolders trims, deduplicates, and removes INBOX from allowed folder lists.
func CleanFolders(in []string, fallback string) []string {
	seen := map[string]struct{}{}
	out := make([]string, 0, len(in)+1)
	add := func(f string) {
		f = strings.TrimSpace(f)
		if f == "" || strings.EqualFold(f, "INBOX") {
			return
		}
		key := strings.ToLower(f)
		if _, ok := seen[key]; ok {
			return
		}
		seen[key] = struct{}{}
		out = append(out, f)
	}
	for _, f := range in {
		add(f)
	}
	add(fallback)
	if len(out) == 0 {
		out = append(out, DefaultFolder)
	}
	return out
}
