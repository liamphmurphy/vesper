// Package artifacts is the domain service for PRDs, specs, ADRs, reports and
// designs: versioned markdown in Postgres, binary files in object storage,
// outlines extracted from headings, and agent read tracking (docs/dev/plan.md §4).
package artifacts

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"path"
	"regexp"
	"slices"
	"sort"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/links"
	"github.com/liamphmurphy/vesper/server/internal/pageview"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

var Types = []string{"prd", "spec", "adr", "report", "design", "note", "mockup"}

// Version states. Suggested versions are agent edits to shared notes waiting
// for a person (docs/dev/plan.md §12.5); they never become current on their own.
const (
	Published = "published"
	Suggested = "suggested"
	Rejected  = "rejected"
)

const (
	// MaxMarkdownBytes bounds text bodies kept in Postgres.
	MaxMarkdownBytes = 2 << 20
	// MaxFileBytes bounds uploads to object storage.
	MaxFileBytes = 25 << 20
)

// Blobs is the subset of blob.Store the service needs.
type Blobs interface {
	Put(ctx context.Context, bucket, key string, body io.Reader, size int64, contentType string) error
	Delete(ctx context.Context, bucket, key string) error
}

type Service struct {
	Pool   *pgxpool.Pool
	Blobs  Blobs
	Bucket string
}

// Actor is the author of an artifact or version.
type Actor struct {
	Type string // user | agent
	ID   uuid.UUID
}

// File is an uploaded file, already spooled so its size is known.
type File struct {
	Name        string
	ContentType string
	Size        int64
	Body        io.Reader
}

// Content is exactly one of a markdown body or a file.
type Content struct {
	BodyMD *string
	File   *File
}

type NewArtifact struct {
	Audience     string // trusted person-only creation override; never exposed to agent tools
	Properties   json.RawMessage
	ProjectKey   string // required for PRDs, specs and ADRs; optional for the rest (a chat has no project to file under)
	Path         string // notes only: "Payments/Ledger/Rollback runbook"
	Type         string
	Title        string
	Summary      string
	EpicID       *uuid.UUID
	VersionLabel string
	Content      Content
	// Number keeps an existing ADR's number on import; nil takes the next one.
	Number *int32
	// State is Suggested for a note an agent proposes but may not publish:
	// it has no current version until a person accepts it.
	State string
}

type NewVersion struct {
	Properties json.RawMessage // nil inherits the current version
	Label      string
	Note       string
	Content    Content
	// State defaults to published. A suggested version is stored without
	// becoming current; BasedOn records the version it was written against.
	State   string
	BasedOn *uuid.UUID
}

// IsMarkdown reports whether an upload should be stored as text.
func IsMarkdown(name, contentType string) bool {
	ext := strings.ToLower(path.Ext(name))
	ct := strings.ToLower(strings.TrimSpace(strings.Split(contentType, ";")[0]))
	return ext == ".md" || ext == ".markdown" || ct == "text/markdown" || ct == "text/x-markdown"
}

// resolved is content ready to store: markdown text or an uploaded blob.
type resolved struct {
	properties  json.RawMessage
	body        *string
	blobKey     *string
	filename    *string
	contentType string
	size        int64
}

// resolve validates content, reads markdown files into text and uploads other
// files. The returned cleanup deletes an uploaded blob if the caller's
// transaction fails.
func (s *Service) resolve(ctx context.Context, ws uuid.UUID, typ string, c Content) (resolved, func(), error) {
	noop := func() {}
	if (c.BodyMD == nil) == (c.File == nil) {
		return resolved{}, noop, apperr.Invalid("content", "send exactly one of body_md or file")
	}
	mockup := typ == "mockup"
	if mockup && c.File != nil && !IsSVG(c.File.Name, c.File.ContentType) {
		return resolved{}, noop, apperr.Invalid("file", "mockups are SVG files")
	}
	if c.File != nil && (mockup || IsMarkdown(c.File.Name, c.File.ContentType)) {
		if c.File.Size > MaxMarkdownBytes {
			return resolved{}, noop, apperr.Invalid("file", "text files are limited to 2 MB")
		}
		b, err := io.ReadAll(io.LimitReader(c.File.Body, MaxMarkdownBytes+1))
		if err != nil {
			return resolved{}, noop, err
		}
		text := string(b)
		c = Content{BodyMD: &text}
	}
	if c.BodyMD != nil {
		body := strings.ReplaceAll(*c.BodyMD, "\r\n", "\n")
		// A Knowledge page may be empty, as a new note in Obsidian is; every
		// other artifact needs text. write_note still refuses an empty body,
		// so a persona can't blank a page.
		if strings.TrimSpace(body) == "" && typ != "note" {
			return resolved{}, noop, apperr.Invalid("body_md", "is empty")
		}
		if len(body) > MaxMarkdownBytes {
			return resolved{}, noop, apperr.Invalid("body_md", "is limited to 2 MB")
		}
		if !utf8.ValidString(body) {
			return resolved{}, noop, apperr.Invalid("body_md", "must be UTF-8 text")
		}
		if mockup {
			// Every new version must conform to profile v1, so simple CSS is
			// rewritten first and the rewritten source is what's stored
			// (docs/dev/mockup-svg-profile.md).
			body, err := NormalizeMockupSVG(body)
			if err != nil {
				return resolved{}, noop, err
			}
			if err := ValidSVG(body); err != nil {
				return resolved{}, noop, err
			}
			if err := ValidateMockupProfile(body); err != nil {
				return resolved{}, noop, err
			}
			return resolved{body: &body, contentType: MockupContentType, size: int64(len(body))}, noop, nil
		}
		return resolved{body: &body, contentType: "text/markdown", size: int64(len(body))}, noop, nil
	}

	f := c.File
	if f.Size <= 0 {
		return resolved{}, noop, apperr.Invalid("file", "is empty")
	}
	if f.Size > MaxFileBytes {
		return resolved{}, noop, apperr.Invalid("file", "files are limited to 25 MB")
	}
	if s.Blobs == nil {
		return resolved{}, noop, errors.New("artifacts: no blob store configured")
	}
	name := safeFilename(f.Name)
	key := fmt.Sprintf("%s/%s/%s", ws, uuid.New(), name)
	ct := f.ContentType
	if ct == "" {
		ct = "application/octet-stream"
	}
	if err := s.Blobs.Put(ctx, s.Bucket, key, f.Body, f.Size, ct); err != nil {
		return resolved{}, noop, err
	}
	cleanup := func() { _ = s.Blobs.Delete(context.Background(), s.Bucket, key) }
	return resolved{blobKey: &key, filename: &name, contentType: ct, size: f.Size}, cleanup, nil
}

var unsafeName = regexp.MustCompile(`[^A-Za-z0-9._-]+`)

func safeFilename(name string) string {
	name = path.Base(strings.ReplaceAll(name, "\\", "/"))
	name = strings.Trim(unsafeName.ReplaceAllString(name, "-"), "-.")
	if name == "" {
		return "file"
	}
	if len(name) > 120 {
		ext := path.Ext(name)
		name = name[:120-len(ext)] + ext
	}
	return name
}

func defaultTitle(r resolved, given string, fileName string) string {
	if t := strings.TrimSpace(given); t != "" {
		return t
	}
	if r.body != nil && r.contentType != MockupContentType {
		for _, s := range Outline(*r.body) {
			if s.Level == 1 {
				return s.Heading
			}
		}
	}
	if fileName != "" {
		return strings.TrimSuffix(path.Base(fileName), path.Ext(fileName))
	}
	return ""
}

func validTitle(t string) (string, error) {
	t = strings.TrimSpace(t)
	if t == "" {
		return "", apperr.Invalid("title", "is required (or start the document with a # heading)")
	}
	if utf8.RuneCountInString(t) > 300 {
		return "", apperr.Invalid("title", "must be at most 300 characters")
	}
	return t, nil
}

// writeVersion inserts a version and extracts its outline. Published
// versions become current and have their [[links]] indexed.
func writeVersion(ctx context.Context, q *store.Queries, a store.Artifact, r resolved, label, note string, by Actor, summary, state string, basedOn *uuid.UUID) (store.ArtifactVersion, error) {
	if state == "" {
		state = Published
	}
	var review *string
	if a.Type == "mockup" {
		pending := ReviewPending
		review = &pending
	}
	if r.properties == nil && a.CurrentVersionID != nil {
		cur, err := q.GetArtifactVersion(ctx, store.GetArtifactVersionParams{ID: *a.CurrentVersionID, ArtifactID: a.ID, WorkspaceID: a.WorkspaceID, Viewer: pageview.From(ctx).UserID})
		if err != nil {
			return store.ArtifactVersion{}, err
		}
		r.properties = cur.Properties
	}
	if r.properties != nil {
		var p Properties
		if err := json.Unmarshal(r.properties, &p); err != nil || p == nil {
			return store.ArtifactVersion{}, apperr.Invalid("properties", "must be an object")
		}
		var err error
		r.properties, err = NormalizeProperties(p)
		if err != nil {
			return store.ArtifactVersion{}, err
		}
	}
	v, err := q.CreateArtifactVersion(ctx, store.CreateArtifactVersionParams{
		ArtifactID: a.ID, Label: label, Properties: r.properties, BodyMd: r.body, BlobKey: r.blobKey, Filename: r.filename,
		ContentType: r.contentType, SizeBytes: r.size, Note: note, CreatedByType: by.Type, CreatedByID: by.ID,
		State: state, BasedOnVersionID: basedOn, ReviewState: review,
	})
	if err != nil {
		return v, err
	}
	if a.Type == "note" && r.body != nil && (by.Type == "agent" || state == Suggested) {
		oldBody := ""
		oldProps := Properties{}
		if a.CurrentVersionID != nil {
			base, err := q.GetArtifactVersion(ctx, store.GetArtifactVersionParams{ID: *a.CurrentVersionID, ArtifactID: a.ID, WorkspaceID: a.WorkspaceID, Viewer: pageview.From(ctx).UserID})
			if err != nil {
				return v, err
			}
			if base.BodyMd != nil {
				oldBody = *base.BodyMd
			}
			oldProps = DecodeProperties(base.Properties)
		}
		changes, err := json.Marshal(PageChanges(oldBody, *r.body, oldProps, DecodeProperties(v.Properties), note))
		if err != nil {
			return v, err
		}
		pending := "pending"
		v, err = q.SetPageChanges(ctx, store.SetPageChangesParams{ID: v.ID, WorkspaceID: a.WorkspaceID, Viewer: pageview.From(ctx).UserID, Changes: changes, ReviewState: &pending})
		if err != nil {
			return v, err
		}
	}
	if r.body != nil && a.Type != "mockup" {
		for i, sec := range Outline(*r.body) {
			if err := q.InsertSection(ctx, store.InsertSectionParams{
				VersionID: v.ID, Position: int32(i + 1), Level: int32(sec.Level), Anchor: sec.Anchor, Heading: sec.Heading,
			}); err != nil {
				return v, err
			}
		}
	}
	if r.body != nil && a.Type == "note" {
		ids := []string{}
		for id := range links.Blocks(*r.body) {
			ids = append(ids, id)
		}
		sort.Strings(ids)
		for i, id := range ids {
			if err := q.InsertSection(ctx, store.InsertSectionParams{VersionID: v.ID, Position: int32(100000 + i), Level: 6, Anchor: "^" + id, Heading: "^" + id}); err != nil {
				return v, err
			}
		}
	}
	if r.body != nil && a.Type == "note" {
		for _, ref := range links.Parse(*r.body) {
			var assetID uuid.UUID
			if raw, ok := strings.CutPrefix(ref.Target, "attachment:"); ok {
				id, err := uuid.Parse(strings.SplitN(raw, "/", 2)[0])
				if err != nil {
					continue
				}
				_, err = q.GetKnowledgeAsset(ctx, store.GetKnowledgeAssetParams{ID: id, WorkspaceID: a.WorkspaceID, Viewer: pageview.From(ctx).UserID})
				if errors.Is(err, pgx.ErrNoRows) {
					continue
				}
				if err != nil {
					return v, err
				}
				assetID = id
			} else if ref.Embed && ref.Anchor == "" && !strings.Contains(ref.Target, ":") {
				candidate := strings.TrimSpace(strings.ReplaceAll(ref.Target, "\\", "/"))
				if strings.HasPrefix(strings.ToLower(candidate), "attachments/") {
					candidate = candidate[len("attachments/"):]
				}
				if candidate == "" || strings.Contains(candidate, "/") || !strings.Contains(candidate, ".") {
					continue
				}
				asset, err := q.FindKnowledgeAssetByFilename(ctx, store.FindKnowledgeAssetByFilenameParams{
					WorkspaceID: a.WorkspaceID,
					Filename:    candidate,
					Viewer:      pageview.From(ctx).UserID,
				})
				if errors.Is(err, pgx.ErrNoRows) {
					continue
				}
				if err != nil {
					return v, err
				}
				assetID = asset.ID
			} else {
				continue
			}
			if err = q.AddPageAssetRef(ctx, store.AddPageAssetRefParams{VersionID: v.ID, AssetID: assetID, Viewer: pageview.From(ctx).UserID}); err != nil {
				return v, err
			}
		}
	}
	if state != Published {
		return v, nil
	}
	return v, makeCurrent(ctx, q, a, v, summary)
}

// makeCurrent points the artifact at a version, refreshes its search text
// and summary, and re-indexes the links it contains.
func makeCurrent(ctx context.Context, q *store.Queries, a store.Artifact, v store.ArtifactVersion, summary string) error {
	if err := IndexProperties(ctx, q, a, v); err != nil {
		return err
	}
	search := ""
	mockup := a.Type == "mockup"
	if mockup && v.BodyMd != nil {
		search = SVGText(*v.BodyMd)
	} else if v.BodyMd != nil {
		search = PlainText(*v.BodyMd)
		if a.Type == "note" {
			search += "\n" + strings.Join(Tags(DecodeProperties(v.Properties), *v.BodyMd), " ")
		}
		if summary == "" || a.Type == "note" {
			summary = Summary(*v.BodyMd)
		}
	} else if v.Filename != nil {
		search = *v.Filename
	}
	if err := q.SetArtifactCurrentVersion(ctx, store.SetArtifactCurrentVersionParams{
		ID: a.ID, CurrentVersionID: &v.ID, SearchText: search, Summary: summary,
	}); err != nil {
		return err
	}
	body := ""
	if v.BodyMd != nil && !mockup {
		body = *v.BodyMd
	}
	if err := links.Index(ctx, q, a.WorkspaceID, links.Source{Kind: links.SourceArtifact, ID: a.ID, VersionID: &v.ID}, body); err != nil {
		return err
	}
	if a.Type == "note" {
		return links.ResolvePending(ctx, q, a.WorkspaceID)
	}
	return nil
}

// Publish makes a stored (suggested) version current. The caller marks the
// version published and holds the artifact lock.
func Publish(ctx context.Context, q *store.Queries, a store.Artifact, v store.ArtifactVersion) error {
	return makeCurrent(ctx, q, a, v, a.Summary)
}

// Create stores a new artifact and its first version.
func (s *Service) Create(ctx context.Context, ws uuid.UUID, by Actor, in NewArtifact) (store.Artifact, error) {
	return s.CreateThen(ctx, ws, by, in, nil)
}

// CreateThen is Create plus a step that runs in the same transaction (for
// example attaching the new artifact to a ticket). If it fails, nothing is
// created and an uploaded blob is cleaned up.
func (s *Service) CreateThen(ctx context.Context, ws uuid.UUID, by Actor, in NewArtifact, then func(q *store.Queries, a store.Artifact) error) (store.Artifact, error) {
	if !slices.Contains(Types, in.Type) {
		return store.Artifact{}, apperr.Invalid("type", "must be one of %s", strings.Join(Types, ", "))
	}
	if in.Type != "note" && in.Path != "" {
		return store.Artifact{}, apperr.Invalid("path", "only notes have a path")
	}
	if in.Type == "note" && in.Content.File != nil && !IsMarkdown(in.Content.File.Name, in.Content.File.ContentType) {
		return store.Artifact{}, apperr.Invalid("file", "notes are markdown")
	}
	r, cleanup, err := s.resolve(ctx, ws, in.Type, in.Content)
	if err != nil {
		return store.Artifact{}, err
	}
	var a store.Artifact
	err = pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
		var err error
		q := store.New(tx)
		if in.Type == "note" {
			if err := q.LockNotePaths(ctx, ws); err != nil {
				return err
			}
		}
		a, err = s.create(ctx, q, ws, by, in, r)
		if err == nil && then != nil {
			err = then(q, a)
		}
		return err
	})
	if err != nil {
		cleanup()
	}
	return a, err
}

// NoteMetadata supplies the display title and versioned frontmatter when
// creating a page through the lightweight wiki save path.
type NoteMetadata struct {
	Audience   string
	Title      string
	Properties json.RawMessage
}

// CreateNoteTx creates a markdown note inside the caller's transaction.
func (s *Service) CreateNoteTx(ctx context.Context, q *store.Queries, ws uuid.UUID, by Actor, path, projectKey, body, state string, metadata ...NoteMetadata) (store.Artifact, error) {
	in := NewArtifact{Type: "note", Path: path, ProjectKey: projectKey, Content: Content{BodyMD: &body}, State: state}
	if len(metadata) > 0 {
		in.Title = metadata[0].Title
		in.Properties = metadata[0].Properties
		in.Audience = metadata[0].Audience
	}
	r, _, err := s.resolve(ctx, ws, "note", in.Content) // markdown: nothing to clean up
	if err != nil {
		return store.Artifact{}, err
	}
	return s.create(ctx, q, ws, by, in, r)
}

// CreateMockupTx creates a mockup from SVG source inside the caller's transaction.
func (s *Service) CreateMockupTx(ctx context.Context, q *store.Queries, ws uuid.UUID, by Actor, projectKey, title string, epicID *uuid.UUID, svg string) (store.Artifact, error) {
	in := NewArtifact{Type: "mockup", ProjectKey: projectKey, Title: title, EpicID: epicID, Content: Content{BodyMD: &svg}}
	r, _, err := s.resolve(ctx, ws, "mockup", in.Content) // text: nothing to clean up
	if err != nil {
		return store.Artifact{}, err
	}
	return s.create(ctx, q, ws, by, in, r)
}

func (s *Service) create(ctx context.Context, q *store.Queries, ws uuid.UUID, by Actor, in NewArtifact, r resolved) (store.Artifact, error) {
	var a store.Artifact
	fileName := ""
	if in.Content.File != nil {
		fileName = in.Content.File.Name
	}
	r.properties = in.Properties
	var notePath *string
	title := ""
	if in.Type == "note" {
		if in.Path == "" {
			var err error
			in.Path, err = DerivedNotePath(ctx, q, ws, in.Title)
			if err != nil {
				return a, err
			}
		}
		p, err := ValidNotePath(in.Path)
		if err != nil {
			return a, err
		}
		notePath, title = &p, links.TitleOf(p)
		if in.Title != "" {
			title = in.Title
		}
		title, err = ValidPageTitle(title)
		if err != nil {
			return a, err
		}
	} else {
		var err error
		if title, err = validTitle(defaultTitle(r, in.Title, fileName)); err != nil {
			return a, err
		}
	}
	label := strings.TrimSpace(in.VersionLabel)
	if label == "" {
		label = "v1"
	}
	var projectID *uuid.UUID
	if in.ProjectKey != "" || !projectOptional[in.Type] {
		p, err := q.LockProjectByKey(ctx, store.LockProjectByKeyParams{WorkspaceID: ws, Key: in.ProjectKey})
		if errors.Is(err, pgx.ErrNoRows) {
			return a, apperr.Invalid("project_key", "unknown project")
		} else if err != nil {
			return a, err
		}
		if p.Archived {
			return a, apperr.Conflict("restore the archived project before creating artifacts")
		}
		projectID = &p.ID
	}
	if in.EpicID != nil {
		e, err := q.GetEpic(ctx, store.GetEpicParams{ID: *in.EpicID, WorkspaceID: ws})
		if err != nil || projectID == nil || e.ProjectID != *projectID {
			return a, apperr.Invalid("epic_id", "unknown epic in this project")
		}
	}
	if notePath != nil {
		audience, _ := NoteAudience(ctx, *notePath, in.Audience)
		taken, err := q.NotePathTaken(ctx, store.NotePathTakenParams{WorkspaceID: ws, Path: *notePath, Audience: audience, Viewer: pageview.From(ctx).UserID})
		if err != nil {
			return a, err
		}
		if taken {
			return a, apperr.Invalid("path", "a page called %q already exists", *notePath)
		}
		taken, err = q.PropertyAliasTaken(ctx, store.PropertyAliasTakenParams{WorkspaceID: ws, Path: *notePath, Viewer: pageview.From(ctx).UserID})
		if err != nil {
			return a, err
		}
		if taken {
			return a, apperr.Invalid("path", "%q is another page's frontmatter alias", *notePath)
		}
	}

	var number *int32
	if in.Number != nil && in.Type != "adr" {
		return a, apperr.Invalid("number", "only ADRs are numbered")
	}
	if in.Type == "adr" {
		if err := q.LockArtifactNumbering(ctx, ws); err != nil {
			return a, err
		}
		if in.Number != nil {
			if *in.Number < 1 {
				return a, apperr.Invalid("number", "must be positive")
			}
			taken, err := q.ADRNumberTaken(ctx, store.ADRNumberTakenParams{WorkspaceID: ws, Number: in.Number})
			if err != nil {
				return a, err
			}
			if taken {
				return a, apperr.Invalid("number", "ADR-%03d already exists", *in.Number)
			}
			number = in.Number
		} else {
			n, err := q.NextADRNumber(ctx, ws)
			if err != nil {
				return a, err
			}
			number = &n
		}
	}
	audience := "shared"
	var owner *uuid.UUID
	if notePath != nil {
		audience, owner = NoteAudience(ctx, *notePath, in.Audience)
	}

	a, err := q.CreateArtifact(ctx, store.CreateArtifactParams{Audience: audience, OwnerUserID: owner,
		WorkspaceID: ws, ProjectID: projectID, EpicID: in.EpicID, Type: in.Type, Title: title, Number: number,
		Summary: strings.TrimSpace(in.Summary), AuthorType: by.Type, AuthorID: by.ID, Path: notePath,
	})
	if err != nil {
		return a, err
	}
	if in.State == Suggested {
		label = "suggestion"
	}
	if _, err = writeVersion(ctx, q, a, r, label, "", by, a.Summary, in.State, nil); err != nil {
		return a, err
	}
	if in.State == Suggested {
		return a, nil // nothing to resolve to until a person accepts it
	}
	// Notes already resolve pending aliases when their version is published.
	if in.Type == "note" {
		return a, nil
	}
	// Ghost links naming this artifact now resolve to it.
	return a, links.ResolvePending(ctx, q, ws)
}

// AddVersion makes new content current. Labels default to v<seq>.
func (s *Service) AddVersion(ctx context.Context, ws uuid.UUID, by Actor, id uuid.UUID, in NewVersion) (store.Artifact, error) {
	cur, err := store.New(s.Pool).GetArtifact(ctx, store.GetArtifactParams{ID: id, WorkspaceID: ws, Viewer: pageview.From(ctx).UserID})
	if errors.Is(err, pgx.ErrNoRows) {
		return store.Artifact{}, apperr.ErrNotFound
	} else if err != nil {
		return store.Artifact{}, err
	}
	r, cleanup, err := s.resolve(ctx, ws, cur.Type, in.Content)
	if err != nil {
		return store.Artifact{}, err
	}
	var a store.Artifact
	err = pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
		q := store.New(tx)
		if cur.Type == "note" {
			if err := q.LockNotePaths(ctx, ws); err != nil {
				return err
			}
		}
		var err error
		if a, err = q.LockArtifact(ctx, store.LockArtifactParams{ID: id, WorkspaceID: ws, Viewer: pageview.From(ctx).UserID}); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return apperr.ErrNotFound
			}
			return err
		}
		_, err = AddVersionTx(ctx, q, a, r, by, in)
		return err
	})
	if err != nil {
		cleanup()
	}
	return a, err
}

// AddVersionTx adds a version to a locked artifact in the caller's
// transaction. Labels count published versions: a suggestion accepted later
// is relabelled then.
func AddVersionTx(ctx context.Context, q *store.Queries, a store.Artifact, r resolved, by Actor, in NewVersion) (store.ArtifactVersion, error) {
	if a.Type == "note" && r.body == nil {
		return store.ArtifactVersion{}, apperr.Invalid("file", "notes are markdown")
	}
	if a.Type == "mockup" && (r.body == nil || r.contentType != MockupContentType) {
		return store.ArtifactVersion{}, apperr.Invalid("content", "mockups take SVG text")
	}
	label := strings.TrimSpace(in.Label)
	if label == "" {
		n, err := q.CountPublishedVersions(ctx, a.ID)
		if err != nil {
			return store.ArtifactVersion{}, err
		}
		label = fmt.Sprintf("v%d", n+1)
		if in.State == Suggested {
			label = "suggestion"
		}
	}
	r.properties = in.Properties
	return writeVersion(ctx, q, a, r, label, strings.TrimSpace(in.Note), by, a.Summary, in.State, in.BasedOn)
}

// Markdown validates a markdown body for AddVersionTx.
func Markdown(body string) (resolved, error) {
	var s Service
	r, _, err := s.resolve(context.Background(), uuid.Nil, "", Content{BodyMD: &body})
	return r, err
}

// Mockup validates SVG source for AddVersionTx.
func Mockup(body string) (resolved, error) {
	var s Service
	r, _, err := s.resolve(context.Background(), uuid.Nil, "mockup", Content{BodyMD: &body})
	return r, err
}

// ValidNotePath normalizes a wiki path and checks it can be linked to.
func ValidNotePath(p string) (string, error) {
	p = links.NormalizePath(p)
	if p == "" {
		return "", apperr.Invalid("path", "is required, e.g. Payments/Rollback runbook")
	}
	if strings.ContainsAny(p, "[]#|^") {
		return "", apperr.Invalid("path", "can't contain [ ] # | or ^, which would break [[links]] to it")
	}
	if utf8.RuneCountInString(p) > 300 {
		return "", apperr.Invalid("path", "must be at most 300 characters")
	}
	if strings.Count(p, "/") > 8 {
		return "", apperr.Invalid("path", "can be at most 9 levels deep")
	}
	for _, seg := range strings.Split(p, "/") {
		if seg == "." || seg == ".." {
			return "", apperr.Invalid("path", "can't contain . or .. segments")
		}
	}
	return p, nil
}

type MetaPatch struct {
	Title   *string
	Summary *string
	EpicSet bool
	EpicID  *uuid.UUID
}

func (s *Service) UpdateMeta(ctx context.Context, ws uuid.UUID, id uuid.UUID, p MetaPatch) (store.Artifact, error) {
	var a store.Artifact
	err := pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
		q := store.New(tx)
		if err := q.LockNotePaths(ctx, ws); err != nil {
			return err
		}
		cur, err := q.LockArtifact(ctx, store.LockArtifactParams{ID: id, WorkspaceID: ws, Viewer: pageview.From(ctx).UserID})
		if errors.Is(err, pgx.ErrNoRows) {
			return apperr.ErrNotFound
		} else if err != nil {
			return err
		}
		next := store.UpdateArtifactMetaParams{ID: cur.ID, Title: cur.Title, Summary: cur.Summary, EpicID: cur.EpicID}
		if p.Title != nil {
			if cur.Type == "note" {
				cur, err = RenameNoteTitleTx(ctx, q, cur, *p.Title)
				if err != nil {
					return err
				}
				next.Title = cur.Title
			} else if next.Title, err = validTitle(*p.Title); err != nil {
				return err
			}
		}
		if p.Summary != nil {
			next.Summary = strings.TrimSpace(*p.Summary)
		}
		if p.EpicSet {
			if p.EpicID != nil {
				e, err := q.GetEpic(ctx, store.GetEpicParams{ID: *p.EpicID, WorkspaceID: ws})
				if err != nil || cur.ProjectID == nil || e.ProjectID != *cur.ProjectID {
					return apperr.Invalid("epic_id", "unknown epic in this project")
				}
			}
			next.EpicID = p.EpicID
		}
		a, err = q.UpdateArtifactMeta(ctx, next)
		return err
	})
	return a, err
}

// RecordRead logs an agent reading the current version, optionally one
// section by anchor. The Agent API (Phase 4) calls this from read_artifact.
func RecordRead(ctx context.Context, q *store.Queries, a store.Artifact, agentID uuid.UUID, runID *uuid.UUID, anchor string, at *time.Time) error {
	if a.CurrentVersionID == nil {
		return apperr.Invalid("artifact", "has no content")
	}
	var section *uuid.UUID
	if anchor != "" {
		sec, err := q.GetSectionByAnchor(ctx, store.GetSectionByAnchorParams{VersionID: *a.CurrentVersionID, Anchor: anchor})
		if errors.Is(err, pgx.ErrNoRows) {
			return apperr.Invalid("section", "no section %q in this version", anchor)
		} else if err != nil {
			return err
		}
		section = &sec.ID
	}
	return q.InsertArtifactRead(ctx, store.InsertArtifactReadParams{
		VersionID: *a.CurrentVersionID, SectionID: section, AgentID: agentID, RunID: runID, ReadAt: at,
	})
}

// projectOptional are the types that can live outside any project: what a
// chat saves, since a chat is above projects. The project documents (PRD,
// spec, ADR) stay required.
var projectOptional = map[string]bool{"note": true, "report": true, "mockup": true, "design": true}

// DisplayID is the human ID for numbered types: ADR-012.
func DisplayID(typ string, number *int32) *string {
	if typ != "adr" || number == nil {
		return nil
	}
	s := fmt.Sprintf("ADR-%03d", *number)
	return &s
}

// NoteAudience chooses a new note's audience from trusted request identity.
// Overrides are validated by the person-only save service. Agent namespaces
// always determine their own audience, including on publication/move.
func NoteAudience(ctx context.Context, path, override string) (string, *uuid.UUID) {
	p := strings.ToLower(path)
	if strings.HasPrefix(p, "agents/") || strings.HasPrefix(p, "patterns/proposed/") {
		return "agent", nil
	}
	audience := "shared"
	owner := pageview.From(ctx).UserID
	if owner != nil {
		audience = "private"
	}
	if override != "" {
		audience = override
	}
	if audience != "private" {
		owner = nil
	}
	return audience, owner
}
