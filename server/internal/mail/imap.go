package mail

import (
	"bytes"
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"io"
	"net"
	"slices"
	"strings"
	"time"

	"github.com/emersion/go-imap/v2"
	"github.com/emersion/go-imap/v2/imapclient"
	gomail "github.com/emersion/go-message/mail"
)

const imapDialTimeout = 20 * time.Second

// IMAPClient wraps an authenticated emersion/go-imap/v2 connection.
type IMAPClient struct {
	c *imapclient.Client
}

// DialIMAP connects over TLS and authenticates with the account's credentials.
func DialIMAP(ctx context.Context, creds AccountCredentials) (Client, error) {
	host := strings.TrimSpace(creds.IMAPHost)
	if host == "" {
		host = DefaultIMAPHost
	}
	port := creds.IMAPPort
	if port <= 0 {
		port = DefaultIMAPPort
	}
	addr := net.JoinHostPort(host, fmt.Sprintf("%d", port))
	dialer := &net.Dialer{Timeout: imapDialTimeout}
	rawConn, err := dialer.DialContext(ctx, "tcp", addr)
	if err != nil {
		return nil, fmt.Errorf("imap dial %s: %w", addr, err)
	}
	tlsConn := tls.Client(rawConn, &tls.Config{
		ServerName: host,
		MinVersion: tls.VersionTLS12,
	})
	if err := tlsConn.HandshakeContext(ctx); err != nil {
		_ = rawConn.Close()
		return nil, fmt.Errorf("imap tls handshake: %w", err)
	}
	c := imapclient.New(tlsConn, nil)
	if err := c.Login(creds.Email, creds.Password).Wait(); err != nil {
		_ = c.Close()
		return nil, fmt.Errorf("imap login: %w", err)
	}
	return &IMAPClient{c: c}, nil
}

func (ic *IMAPClient) Close() error {
	if ic == nil || ic.c == nil {
		return nil
	}
	_ = ic.c.Logout().Wait()
	return ic.c.Close()
}

func (ic *IMAPClient) TestConnection(_ context.Context) error {
	if _, err := ic.c.Select("INBOX", &imap.SelectOptions{ReadOnly: true}).Wait(); err != nil {
		return fmt.Errorf("select INBOX: %w", err)
	}
	return nil
}

func (ic *IMAPClient) ListMailboxes(_ context.Context) ([]Mailbox, error) {
	items, err := ic.c.List("", "*", &imap.ListOptions{
		ReturnStatus: &imap.StatusOptions{
			NumMessages: true,
			NumUnseen:   true,
		},
	}).Collect()
	if err != nil {
		return nil, fmt.Errorf("imap list: %w", err)
	}
	out := make([]Mailbox, 0, len(items))
	for _, it := range items {
		m := Mailbox{
			Name: it.Mailbox,
		}
		if it.Delim != 0 {
			m.Delimiter = string(it.Delim)
		}
		if it.Status != nil {
			if it.Status.NumMessages != nil {
				m.Messages = *it.Status.NumMessages
			}
			if it.Status.NumUnseen != nil {
				m.Unseen = *it.Status.NumUnseen
			}
		}
		out = append(out, m)
	}
	return out, nil
}

func (ic *IMAPClient) CreateMailbox(_ context.Context, name string) error {
	name = strings.TrimSpace(name)
	if name == "" {
		return errors.New("mailbox name is required")
	}
	if err := ic.c.Create(name, nil).Wait(); err != nil {
		return fmt.Errorf("imap create %q: %w", name, err)
	}
	return nil
}

func (ic *IMAPClient) RenameMailbox(_ context.Context, oldName, newName string) error {
	oldName, newName = strings.TrimSpace(oldName), strings.TrimSpace(newName)
	if oldName == "" || newName == "" {
		return errors.New("both old and new mailbox names are required")
	}
	if err := ic.c.Rename(oldName, newName, nil).Wait(); err != nil {
		return fmt.Errorf("imap rename %q -> %q: %w", oldName, newName, err)
	}
	return nil
}

func (ic *IMAPClient) Search(_ context.Context, q SearchQuery) ([]MessageSummary, error) {
	mailbox := strings.TrimSpace(q.Mailbox)
	if mailbox == "" {
		mailbox = "INBOX"
	}
	sel, err := ic.c.Select(mailbox, &imap.SelectOptions{ReadOnly: true}).Wait()
	if err != nil {
		return nil, fmt.Errorf("imap select %q: %w", mailbox, err)
	}
	limit := q.Limit
	if limit <= 0 {
		limit = 25
	}
	if limit > 100 {
		limit = 100
	}

	criteria := &imap.SearchCriteria{}
	if s := strings.TrimSpace(q.From); s != "" {
		criteria.Header = append(criteria.Header, imap.SearchCriteriaHeaderField{Key: "From", Value: s})
	}
	if s := strings.TrimSpace(q.Subject); s != "" {
		criteria.Header = append(criteria.Header, imap.SearchCriteriaHeaderField{Key: "Subject", Value: s})
	}
	if s := strings.TrimSpace(q.Text); s != "" {
		criteria.Text = append(criteria.Text, s)
	}
	if q.Unseen {
		criteria.NotFlag = append(criteria.NotFlag, imap.FlagSeen)
	}

	res, err := ic.c.UIDSearch(criteria, nil).Wait()
	if err != nil {
		return nil, fmt.Errorf("imap search: %w", err)
	}
	uids := res.AllUIDs()
	if len(uids) == 0 {
		return []MessageSummary{}, nil
	}
	// Newest first.
	slices.Sort(uids)
	slices.Reverse(uids)
	if len(uids) > limit {
		uids = uids[:limit]
	}
	return ic.fetchSummaries(uids, sel.UIDValidity, false)
}

func (ic *IMAPClient) FetchNewInbox(_ context.Context, lastUIDValidity, lastSeenUID uint32, limit int) (InboxFetchResult, error) {
	sel, err := ic.c.Select("INBOX", &imap.SelectOptions{ReadOnly: true}).Wait()
	if err != nil {
		return InboxFetchResult{}, fmt.Errorf("imap select INBOX: %w", err)
	}
	out := InboxFetchResult{
		UIDValidity: sel.UIDValidity,
		MaxUID:      lastSeenUID,
	}
	if sel.NumMessages == 0 {
		return out, nil
	}
	if limit <= 0 {
		limit = 30
	}

	// First sync or UIDVALIDITY changed: establish high-water mark without
	// retroactively sweeping the entire historical inbox.
	if lastUIDValidity == 0 || lastUIDValidity != sel.UIDValidity {
		if sel.UIDNext > 1 {
			out.MaxUID = uint32(sel.UIDNext - 1)
		}
		return out, nil
	}

	if sel.UIDNext > 0 && uint32(sel.UIDNext) <= lastSeenUID+1 {
		return out, nil
	}

	var uidSet imap.UIDSet
	uidSet.AddRange(imap.UID(lastSeenUID+1), 0) // lastSeenUID+1:*
	res, err := ic.c.UIDSearch(&imap.SearchCriteria{UID: []imap.UIDSet{uidSet}}, nil).Wait()
	if err != nil {
		return out, fmt.Errorf("imap search new uids: %w", err)
	}
	raw := res.AllUIDs()
	uids := make([]imap.UID, 0, len(raw))
	for _, u := range raw {
		if uint32(u) > lastSeenUID {
			uids = append(uids, u)
		}
	}
	if len(uids) == 0 {
		return out, nil
	}
	slices.Sort(uids)
	if len(uids) > limit {
		uids = uids[:limit]
	}
	msgs, err := ic.fetchSummaries(uids, sel.UIDValidity, true)
	if err != nil {
		return out, err
	}
	out.Messages = msgs
	for _, m := range msgs {
		if m.UID > out.MaxUID {
			out.MaxUID = m.UID
		}
	}
	return out, nil
}

func (ic *IMAPClient) MoveByUID(_ context.Context, sourceFolder string, uids []uint32, targetFolder string) error {
	if len(uids) == 0 {
		return nil
	}
	if sourceFolder == "" {
		sourceFolder = "INBOX"
	}
	if _, err := ic.c.Select(sourceFolder, nil).Wait(); err != nil {
		return fmt.Errorf("imap select %q: %w", sourceFolder, err)
	}
	var set imap.UIDSet
	for _, u := range uids {
		set.AddNum(imap.UID(u))
	}
	if _, err := ic.c.Move(set, targetFolder).Wait(); err != nil {
		return fmt.Errorf("imap move to %q: %w", targetFolder, err)
	}
	return nil
}

func (ic *IMAPClient) MoveByMessageID(_ context.Context, sourceFolder, messageID, targetFolder string) (bool, error) {
	messageID = strings.TrimSpace(messageID)
	if messageID == "" {
		return false, nil
	}
	if _, err := ic.c.Select(sourceFolder, nil).Wait(); err != nil {
		return false, fmt.Errorf("imap select %q: %w", sourceFolder, err)
	}
	res, err := ic.c.UIDSearch(&imap.SearchCriteria{
		Header: []imap.SearchCriteriaHeaderField{{Key: "Message-ID", Value: messageID}},
	}, nil).Wait()
	if err != nil {
		return false, fmt.Errorf("imap search message-id: %w", err)
	}
	uids := res.AllUIDs()
	if len(uids) == 0 {
		return false, nil
	}
	var set imap.UIDSet
	for _, u := range uids {
		set.AddNum(u)
	}
	if _, err := ic.c.Move(set, targetFolder).Wait(); err != nil {
		return false, fmt.Errorf("imap move to %q: %w", targetFolder, err)
	}
	return true, nil
}

func (ic *IMAPClient) fetchSummaries(uids []imap.UID, uidValidity uint32, includeSnippet bool) ([]MessageSummary, error) {
	if len(uids) == 0 {
		return []MessageSummary{}, nil
	}
	var set imap.UIDSet
	for _, u := range uids {
		set.AddNum(u)
	}
	headerSection := &imap.FetchItemBodySection{
		Specifier:    imap.PartSpecifierHeader,
		HeaderFields: []string{"List-Id", "List-Unsubscribe"},
		Peek:         true,
	}
	bodySection := &imap.FetchItemBodySection{
		Peek: true,
		Partial: &imap.SectionPartial{
			Offset: 0,
			Size:   16384,
		},
	}
	opts := &imap.FetchOptions{
		UID:          true,
		Envelope:     true,
		InternalDate: true,
		BodySection:  []*imap.FetchItemBodySection{headerSection},
	}
	if includeSnippet {
		opts.BodySection = append(opts.BodySection, bodySection)
	}

	buffers, err := ic.c.Fetch(set, opts).Collect()
	if err != nil {
		return nil, fmt.Errorf("imap fetch: %w", err)
	}
	byUID := make(map[imap.UID]MessageSummary, len(buffers))
	for _, buf := range buffers {
		msg := MessageSummary{
			UID:         uint32(buf.UID),
			UIDValidity: uidValidity,
			ReceivedAt:  buf.InternalDate,
		}
		if buf.Envelope != nil {
			msg.Subject = strings.TrimSpace(buf.Envelope.Subject)
			msg.MessageID = strings.TrimSpace(buf.Envelope.MessageID)
			if msg.ReceivedAt.IsZero() {
				msg.ReceivedAt = buf.Envelope.Date
			}
			if len(buf.Envelope.From) > 0 {
				from := buf.Envelope.From[0]
				msg.FromName = strings.TrimSpace(from.Name)
				msg.FromEmail = NormalizeEmail(from.Addr())
			}
		}
		if hdrBytes := buf.FindBodySection(headerSection); len(hdrBytes) > 0 {
			parseExtraHeaders(hdrBytes, &msg)
		}
		if includeSnippet {
			if rawBody := buf.FindBodySection(bodySection); len(rawBody) > 0 {
				msg.Snippet = extractPlainSnippet(rawBody)
			}
		}
		byUID[buf.UID] = msg
	}
	out := make([]MessageSummary, 0, len(uids))
	for _, u := range uids {
		if m, ok := byUID[u]; ok {
			out = append(out, m)
		}
	}
	return out, nil
}

func parseExtraHeaders(raw []byte, msg *MessageSummary) {
	for _, line := range strings.Split(string(raw), "\n") {
		line = strings.TrimSpace(line)
		lower := strings.ToLower(line)
		if strings.HasPrefix(lower, "list-unsubscribe:") {
			val := strings.TrimSpace(line[len("list-unsubscribe:"):])
			if val != "" {
				msg.ListUnsubscribe = true
			}
		} else if strings.HasPrefix(lower, "list-id:") {
			msg.ListID = strings.TrimSpace(line[len("list-id:"):])
		}
	}
}

func extractPlainSnippet(raw []byte) string {
	mr, err := gomail.CreateReader(bytes.NewReader(raw))
	if err != nil {
		return ""
	}
	for {
		p, err := mr.NextPart()
		if err != nil {
			break
		}
		switch h := p.Header.(type) {
		case *gomail.InlineHeader:
			ct, _, _ := h.ContentType()
			if strings.HasPrefix(strings.ToLower(ct), "text/plain") {
				b, _ := io.ReadAll(io.LimitReader(p.Body, 4096))
				if snip := SanitizeSnippet(string(b), MaxSnippetRunes); snip != "" {
					return snip
				}
			}
		}
	}
	return ""
}
