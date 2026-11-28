package mail

import (
	"context"
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/emersion/go-vcard"
	"github.com/emersion/go-webdav/carddav"
)

const carddavTimeout = 30 * time.Second

// CardDAVFetcher syncs contact email addresses from iCloud CardDAV using the
// user's App-Specific Password, strictly scoping Basic Auth credentials to the
// configured CardDAV host (and *.icloud.com).
type CardDAVFetcher struct{}

func (CardDAVFetcher) FetchContacts(ctx context.Context, creds AccountCredentials) ([]Contact, error) {
	endpoint := strings.TrimSpace(creds.CardDAVURL)
	if endpoint == "" {
		endpoint = DefaultCardDAVURL
	}
	parsed, err := url.Parse(endpoint)
	if err != nil || parsed.Scheme != "https" || parsed.Host == "" {
		return nil, fmt.Errorf("carddav: invalid https URL %q", endpoint)
	}

	httpClient := &http.Client{
		Timeout: carddavTimeout,
		Transport: &scopedBasicAuthTransport{
			base:        http.DefaultTransport,
			allowedHost: strings.ToLower(parsed.Hostname()),
			username:    creds.Email,
			password:    creds.Password,
		},
	}

	client, err := carddav.NewClient(httpClient, endpoint)
	if err != nil {
		return nil, fmt.Errorf("carddav client: %w", err)
	}
	principal, err := client.FindCurrentUserPrincipal(ctx)
	if err != nil {
		return nil, fmt.Errorf("carddav principal discovery: %w", err)
	}
	homeSet, err := client.FindAddressBookHomeSet(ctx, principal)
	if err != nil {
		return nil, fmt.Errorf("carddav addressbook home discovery: %w", err)
	}
	books, err := client.FindAddressBooks(ctx, homeSet)
	if err != nil {
		return nil, fmt.Errorf("carddav find addressbooks: %w", err)
	}

	seen := map[string]Contact{}
	query := &carddav.AddressBookQuery{
		DataRequest: carddav.AddressDataRequest{
			Props: []string{vcard.FieldFormattedName, vcard.FieldEmail},
		},
	}
	for _, book := range books {
		objs, err := client.QueryAddressBook(ctx, book.Path, query)
		if err != nil {
			return nil, fmt.Errorf("carddav query %q: %w", book.Path, err)
		}
		for _, obj := range objs {
			name := strings.TrimSpace(obj.Card.PreferredValue(vcard.FieldFormattedName))
			for _, f := range obj.Card[vcard.FieldEmail] {
				addr := NormalizeEmail(f.Value)
				if addr == "" || !strings.Contains(addr, "@") {
					continue
				}
				if existing, ok := seen[addr]; !ok || (existing.DisplayName == "" && name != "") {
					seen[addr] = Contact{Email: addr, DisplayName: name}
				}
			}
		}
	}

	out := make([]Contact, 0, len(seen))
	for _, c := range seen {
		out = append(out, c)
	}
	return out, nil
}

// scopedBasicAuthTransport attaches Basic Auth only to the configured CardDAV
// host or *.icloud.com subdomains so redirects can never leak credentials.
type scopedBasicAuthTransport struct {
	base        http.RoundTripper
	allowedHost string
	username    string
	password    string
}

func (t *scopedBasicAuthTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	clone := req.Clone(req.Context())
	host := strings.ToLower(clone.URL.Hostname())
	if t.hostAllowed(host) {
		clone.SetBasicAuth(t.username, t.password)
	}
	base := t.base
	if base == nil {
		base = http.DefaultTransport
	}
	return base.RoundTrip(clone)
}

func (t *scopedBasicAuthTransport) hostAllowed(host string) bool {
	if host == "" {
		return false
	}
	if host == t.allowedHost {
		return true
	}
	if strings.HasSuffix(t.allowedHost, ".icloud.com") || t.allowedHost == "icloud.com" {
		return host == "icloud.com" || strings.HasSuffix(host, ".icloud.com")
	}
	return false
}
