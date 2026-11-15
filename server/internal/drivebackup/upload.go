package drivebackup

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/transfer"
	"github.com/liamphmurphy/vesper/server/internal/usersecrets"
)

const (
	// DefaultBaseURL is Google's API host; tests point Uploader at httptest.
	DefaultBaseURL = "https://www.googleapis.com"
	// chunkUnit is the granularity Drive requires of every chunk but the last.
	chunkUnit = 256 << 10
	// DefaultChunkSize is what one chunk holds in memory: the whole upload
	// needs this much, however big the archive is.
	DefaultChunkSize = 32 * chunkUnit // 8 MiB
	defaultRetries   = 5
	// requestTimeout bounds one request (a chunk takes the longest).
	requestTimeout = 10 * time.Minute
	filePrefix     = "vesper-export-"
	zipType        = "application/zip"
)

// backupName matches exactly the names FileName makes, so pruning never
// touches anything else a person keeps in the folder, such as a download
// from Settings (vesper-export-2026-11-14.zip).
var backupName = regexp.MustCompile(`^vesper-export-\d{8}T\d{6}Z\.zip$`)

// validFolderID is config's check; Upload repeats it because the ID goes
// into a Drive search query.
var validFolderID = folderID

// ErrPrune means the new backup uploaded but removing older ones failed. The
// backup itself is safe; Result still names it.
var ErrPrune = errors.New("the backup uploaded, but removing older backups failed")

// Exporter writes a full-instance archive; *transfer.Exporter is one.
type Exporter interface {
	Export(ctx context.Context, w io.Writer) (*transfer.Manifest, error)
}

// Uploader streams archives into a Google Drive folder with Drive v3's
// resumable upload protocol, one chunk in memory at a time.
type Uploader struct {
	// Token returns a current OAuth access token. It is called before every
	// request, so a long upload picks up a refreshed one.
	Token func(ctx context.Context) (string, error)
	// HTTP defaults to a client that won't dial private addresses or follow
	// redirects (they would take the token with them).
	HTTP *http.Client
	// BaseURL defaults to DefaultBaseURL.
	BaseURL string
	// ChunkSize defaults to DefaultChunkSize; it is rounded down to a
	// multiple of 256 KiB, as Drive requires.
	ChunkSize int
	// Retries is how many times a failing request is retried (5xx, 429,
	// network errors) before the upload gives up. Defaults to 5.
	Retries int
	// Sleep waits between retries; tests replace it.
	Sleep func(ctx context.Context, d time.Duration) error
	Now   func() time.Time
}

// SecretToken is an Uploader.Token that reads an OAuth secret's access token
// through usersecrets, which refreshes it when it is about to expire.
func SecretToken(s *usersecrets.Service, sec store.UserSecret) func(context.Context) (string, error) {
	return func(ctx context.Context) (string, error) { return s.Value(ctx, sec) }
}

// Result describes an upload.
type Result struct {
	FileID   string
	Name     string
	Bytes    int64
	Manifest *transfer.Manifest
	// Pruned are the IDs of older backups deleted afterwards.
	Pruned []string
}

// DriveError is a refusal from the Drive API.
type DriveError struct {
	Status  int
	Reason  string
	Message string
}

func (e *DriveError) Error() string {
	switch {
	case e.Status == http.StatusUnauthorized:
		return "Google Drive refused the sign-in; sign in to the secret again from Customization › Secrets"
	case e.Status == http.StatusForbidden && e.Message != "":
		return "Google Drive refused the request: " + e.Message
	case e.Status == http.StatusNotFound:
		return "Google Drive couldn't find the folder or upload (it may have been deleted, or the secret can't see it)"
	case e.Message != "":
		return fmt.Sprintf("Google Drive returned %d: %s", e.Status, e.Message)
	}
	return fmt.Sprintf("Google Drive returned %d", e.Status)
}

// exportError is the archive failing, as opposed to Drive.
type exportError struct{ err error }

func (e *exportError) Error() string { return "export failed: " + e.err.Error() }
func (e *exportError) Unwrap() error { return e.err }

// FileName is the name of a backup made at t.
func FileName(t time.Time) string {
	return filePrefix + t.UTC().Format("20060102T150405Z") + ".zip"
}

// defaultClient is shared, so every chunk reuses one kept-alive connection.
var defaultClient = sync.OnceValue(func() *http.Client {
	tr := usersecrets.SafeTransport(false, nil)
	// Drive answers the last chunk once it has assembled the file.
	tr.ResponseHeaderTimeout = 2 * time.Minute
	tr.IdleConnTimeout = 90 * time.Second
	return &http.Client{Transport: tr, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
})

func (u *Uploader) client() *http.Client {
	if u.HTTP != nil {
		return u.HTTP
	}
	return defaultClient()
}

// tokenError is Token failing. Retrying won't help: usersecrets already
// retried the provider, or the grant lapsed and needs a person.
type tokenError struct{ err error }

func (e *tokenError) Error() string { return e.err.Error() }
func (e *tokenError) Unwrap() error { return e.err }

// permanent reports an error that retrying won't fix.
func permanent(ctx context.Context, err error) bool {
	return ctx.Err() != nil || errors.As(err, new(*usersecrets.Blocked)) || errors.As(err, new(*tokenError))
}

func (u *Uploader) base() string {
	if u.BaseURL != "" {
		return strings.TrimRight(u.BaseURL, "/")
	}
	return DefaultBaseURL
}

func (u *Uploader) chunkSize() int {
	n := u.ChunkSize
	if n <= 0 {
		n = DefaultChunkSize
	}
	return max(chunkUnit, n/chunkUnit*chunkUnit)
}

func (u *Uploader) now() time.Time {
	if u.Now != nil {
		return u.Now()
	}
	return time.Now()
}

func (u *Uploader) sleep(ctx context.Context, attempt int) error {
	d := time.Duration(1<<min(attempt, 6)) * time.Second
	if u.Sleep != nil {
		return u.Sleep(ctx, d)
	}
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-t.C:
		return nil
	}
}

func (u *Uploader) retries() int {
	if u.Retries > 0 {
		return u.Retries
	}
	return defaultRetries
}

// do sends one authenticated request. body may be nil.
func (u *Uploader) do(ctx context.Context, method, target string, body []byte, hdr http.Header) (*http.Response, error) {
	tok, err := u.Token(ctx)
	if err != nil {
		return nil, &tokenError{err}
	}
	var r io.Reader = http.NoBody
	if body != nil {
		r = bytes.NewReader(body)
	}
	req, err := http.NewRequestWithContext(ctx, method, target, r)
	if err != nil {
		return nil, err
	}
	for k, v := range hdr {
		req.Header[k] = v
	}
	req.Header.Set("Authorization", "Bearer "+tok)
	req.ContentLength = int64(len(body))
	return u.client().Do(req)
}

// driveError reads Drive's JSON error body.
func driveError(res *http.Response) *DriveError {
	var body struct {
		Error struct {
			Message string `json:"message"`
			Errors  []struct {
				Reason string `json:"reason"`
			} `json:"errors"`
		} `json:"error"`
	}
	_ = json.NewDecoder(io.LimitReader(res.Body, 64<<10)).Decode(&body)
	e := &DriveError{Status: res.StatusCode, Message: body.Error.Message}
	if len(body.Error.Errors) > 0 {
		e.Reason = body.Error.Errors[0].Reason
	}
	return e
}

// retryable is a response worth sending again: Drive asks for exponential
// backoff on 5xx and on rate limits (429, or 403 with a rate-limit reason).
func retryable(e *DriveError) bool {
	return e.Status >= 500 || e.Status == http.StatusTooManyRequests ||
		(e.Status == http.StatusForbidden && (e.Reason == "rateLimitExceeded" || e.Reason == "userRateLimitExceeded"))
}

func drain(res *http.Response) {
	_, _ = io.Copy(io.Discard, io.LimitReader(res.Body, 64<<10))
	_ = res.Body.Close()
}

// Upload writes exp's archive to a new timestamped vesper-export-*.zip in
// folderID, then, if retention > 0, deletes older vesper-export-*.zip files
// in the folder so retention remain (the new one included). The archive is
// streamed through a pipe: memory holds one chunk, not the archive. If the
// upload fails nothing is pruned. If only pruning fails, Result names the new
// backup and the error wraps ErrPrune.
func (u *Uploader) Upload(ctx context.Context, exp Exporter, folderID string, retention int) (Result, error) {
	if !validFolderID.MatchString(folderID) {
		return Result{}, errors.New("isn't a Google Drive folder ID")
	}
	res := Result{Name: FileName(u.now())}
	session, err := u.startSession(ctx, res.Name, folderID)
	if err != nil {
		return res, err
	}

	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	pr, pw := io.Pipe()
	type exported struct {
		m   *transfer.Manifest
		err error
	}
	done := make(chan exported, 1)
	go func() {
		m, err := exp.Export(ctx, pw)
		pw.CloseWithError(err) // nil closes with EOF
		done <- exported{m, err}
	}()
	id, n, upErr := u.stream(ctx, session, pr)
	if upErr != nil {
		// Unblock and stop the exporter before waiting for it.
		pr.CloseWithError(upErr)
		cancel()
	}
	ex := <-done
	if upErr != nil {
		u.cancelSession(context.WithoutCancel(ctx), session)
		return res, upErr
	}
	res.FileID, res.Bytes, res.Manifest = id, n, ex.m

	if retention > 0 {
		res.Pruned, err = u.Prune(ctx, folderID, res.FileID, retention)
		if err != nil {
			return res, fmt.Errorf("%w: %w", ErrPrune, err)
		}
	}
	return res, nil
}

// startSession opens a resumable upload session and returns its URI.
func (u *Uploader) startSession(ctx context.Context, name, folderID string) (string, error) {
	meta, _ := json.Marshal(map[string]any{"name": name, "parents": []string{folderID}, "mimeType": zipType})
	target := u.base() + "/upload/drive/v3/files?uploadType=resumable&supportsAllDrives=true&fields=id"
	hdr := http.Header{"Content-Type": {"application/json; charset=UTF-8"}, "X-Upload-Content-Type": {zipType}}
	for attempt := 0; ; attempt++ {
		res, err := u.do(ctx, http.MethodPost, target, meta, hdr)
		var de *DriveError
		if err == nil {
			if res.StatusCode == http.StatusOK {
				loc := res.Header.Get("Location")
				drain(res)
				return u.checkSession(loc)
			}
			de = driveError(res)
			_ = res.Body.Close()
			if !retryable(de) {
				return "", de
			}
			err = de
		} else if permanent(ctx, err) {
			return "", err
		}
		if attempt >= u.retries() {
			return "", fmt.Errorf("couldn't start the Google Drive upload: %w", err)
		}
		if err := u.sleep(ctx, attempt); err != nil {
			return "", err
		}
	}
}

// checkSession accepts a session URI only on the API's own host: every
// chunk carries the access token there.
func (u *Uploader) checkSession(loc string) (string, error) {
	s, err := url.Parse(loc)
	b, _ := url.Parse(u.base())
	if loc == "" || err != nil || s.Scheme != b.Scheme || s.Host != b.Host {
		return "", errors.New("google Drive didn't return a usable upload session")
	}
	return loc, nil
}

// stream reads chunks from r and sends them until r ends, returning the new
// file's ID and size.
func (u *Uploader) stream(ctx context.Context, session string, r io.Reader) (string, int64, error) {
	buf := make([]byte, u.chunkSize())
	var offset int64
	for {
		n, err := io.ReadFull(r, buf)
		final := false
		switch {
		case err == nil:
		case errors.Is(err, io.EOF), errors.Is(err, io.ErrUnexpectedEOF):
			final = true
		default:
			return "", offset, &exportError{err}
		}
		id, err := u.sendChunk(ctx, session, buf[:n], offset, final)
		if err != nil {
			return "", offset, err
		}
		offset += int64(n)
		if final {
			if id == "" {
				return "", offset, errors.New("google Drive didn't confirm the upload")
			}
			return id, offset, nil
		}
	}
}

// sendChunk sends data, which starts at byte start of the archive, resending
// whatever Drive says it didn't keep. It returns the file ID once Drive has
// the whole file (only after the final chunk).
func (u *Uploader) sendChunk(ctx context.Context, session string, data []byte, start int64, final bool) (string, error) {
	end := start + int64(len(data))
	total := "*"
	if final {
		total = strconv.FormatInt(end, 10)
	}
	committed := start
	failures := 0
	query := false // ask where the upload stands before sending again
	for {
		var hdr http.Header
		var body []byte
		if query {
			hdr = http.Header{"Content-Range": {"bytes */" + total}}
		} else {
			body = data[committed-start:]
			if len(body) == 0 {
				// Only a final, empty remainder: say the size and finish.
				hdr = http.Header{"Content-Range": {"bytes */" + total}}
			} else {
				hdr = http.Header{"Content-Range": {fmt.Sprintf("bytes %d-%d/%s", committed, end-1, total)}}
			}
		}
		rctx, cancel := context.WithTimeout(ctx, requestTimeout)
		res, err := u.do(rctx, http.MethodPut, session, body, hdr)
		var retry error
		switch {
		case err != nil:
			cancel()
			if permanent(ctx, err) {
				return "", err
			}
			retry = err
		case res.StatusCode == http.StatusOK || res.StatusCode == http.StatusCreated:
			var f struct {
				ID string `json:"id"`
			}
			err := json.NewDecoder(io.LimitReader(res.Body, 64<<10)).Decode(&f)
			_ = res.Body.Close()
			cancel()
			if !final {
				return "", errors.New("google Drive finished the upload before the archive ended")
			}
			if err != nil || f.ID == "" {
				return "", errors.New("google Drive didn't return the new file's ID")
			}
			return f.ID, nil
		case res.StatusCode == http.StatusPermanentRedirect: // "Resume Incomplete"
			got, perr := parseRange(res.Header.Get("Range"))
			drain(res)
			cancel()
			if perr != nil || got < start || got > end {
				return "", fmt.Errorf("google Drive reported an unexpected upload position (%q)", res.Header.Get("Range"))
			}
			stalled := got <= committed && !query
			committed, query = got, false
			if committed == end && !final {
				return "", nil
			}
			if stalled {
				failures++
				if failures > u.retries() {
					return "", errors.New("google Drive keeps refusing the same chunk")
				}
			}
			continue
		default:
			de := driveError(res)
			_ = res.Body.Close()
			cancel()
			if res.StatusCode == http.StatusNotFound || res.StatusCode == http.StatusGone {
				return "", errors.New("the Google Drive upload session expired; the next run starts a new one")
			}
			if !retryable(de) {
				return "", de
			}
			retry = de
		}
		failures++
		if failures > u.retries() {
			return "", fmt.Errorf("uploading to Google Drive: %w", retry)
		}
		if err := u.sleep(ctx, failures-1); err != nil {
			return "", err
		}
		query = true
	}
}

// parseRange reads a 308's Range header ("bytes=0-N") as the number of bytes
// Drive has. No header means none.
func parseRange(h string) (int64, error) {
	if h == "" {
		return 0, nil
	}
	_, last, ok := strings.Cut(strings.TrimPrefix(h, "bytes="), "-")
	if !ok || !strings.HasPrefix(h, "bytes=0-") {
		return 0, errors.New("bad range")
	}
	n, err := strconv.ParseInt(last, 10, 64)
	if err != nil || n < 0 {
		return 0, errors.New("bad range")
	}
	return n + 1, nil
}

// cancelSession discards a half-finished upload, so no partial file appears.
func (u *Uploader) cancelSession(ctx context.Context, session string) {
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	if res, err := u.do(ctx, http.MethodDelete, session, nil, nil); err == nil {
		drain(res)
	}
}

type driveFile struct {
	ID          string    `json:"id"`
	Name        string    `json:"name"`
	CreatedTime time.Time `json:"createdTime"`
}

// Prune deletes vesper-export-*.zip files in folderID beyond the newest
// retention, always keeping keep (the backup just uploaded). Other files in
// the folder are left alone. It returns the IDs it deleted.
func (u *Uploader) Prune(ctx context.Context, folderID, keep string, retention int) ([]string, error) {
	if retention <= 0 {
		return nil, nil
	}
	if !validFolderID.MatchString(folderID) {
		return nil, errors.New("isn't a Google Drive folder ID")
	}
	files, err := u.list(ctx, folderID)
	if err != nil {
		return nil, err
	}
	slices.SortFunc(files, func(a, b driveFile) int {
		if c := b.CreatedTime.Compare(a.CreatedTime); c != 0 {
			return c
		}
		return strings.Compare(b.Name, a.Name)
	})
	kept := 0
	if keep != "" {
		kept = 1
	}
	var deleted []string
	for _, f := range files {
		if f.ID == keep {
			continue
		}
		if kept < retention {
			kept++
			continue
		}
		if err := u.delete(ctx, f.ID); err != nil {
			return deleted, err
		}
		deleted = append(deleted, f.ID)
	}
	return deleted, nil
}

// list returns the backups in folderID, every page.
func (u *Uploader) list(ctx context.Context, folderID string) ([]driveFile, error) {
	q := fmt.Sprintf("'%s' in parents and name contains '%s' and trashed = false", folderID, filePrefix)
	var out []driveFile
	page := ""
	for range 1000 {
		v := url.Values{"q": {q}, "fields": {"nextPageToken,files(id,name,createdTime)"}, "pageSize": {"1000"},
			"supportsAllDrives": {"true"}, "includeItemsFromAllDrives": {"true"}}
		if page != "" {
			v.Set("pageToken", page)
		}
		res, err := u.do(ctx, http.MethodGet, u.base()+"/drive/v3/files?"+v.Encode(), nil, nil)
		if err != nil {
			return nil, err
		}
		if res.StatusCode != http.StatusOK {
			de := driveError(res)
			_ = res.Body.Close()
			return nil, de
		}
		var body struct {
			NextPageToken string      `json:"nextPageToken"`
			Files         []driveFile `json:"files"`
		}
		err = json.NewDecoder(io.LimitReader(res.Body, 16<<20)).Decode(&body)
		_ = res.Body.Close()
		if err != nil {
			return nil, fmt.Errorf("reading the Google Drive file list: %w", err)
		}
		for _, f := range body.Files {
			if backupName.MatchString(f.Name) {
				out = append(out, f)
			}
		}
		if body.NextPageToken == "" {
			return out, nil
		}
		page = body.NextPageToken
	}
	return nil, errors.New("google Drive's file list didn't end")
}

func (u *Uploader) delete(ctx context.Context, id string) error {
	res, err := u.do(ctx, http.MethodDelete, u.base()+"/drive/v3/files/"+url.PathEscape(id)+"?supportsAllDrives=true", nil, nil)
	if err != nil {
		return err
	}
	defer drain(res)
	if res.StatusCode == http.StatusNoContent || res.StatusCode == http.StatusOK || res.StatusCode == http.StatusNotFound {
		return nil // 404: already gone
	}
	return driveError(res)
}
