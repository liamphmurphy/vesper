package httpclient

import (
	"archive/zip"
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"path"
	"sort"
	"strings"

	"github.com/google/uuid"
	"gopkg.in/yaml.v3"

	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

// ImportFile represents one uploaded text file (e.g. a .bru file).
type ImportFile struct {
	Path    string `json:"path"`
	Content string `json:"content"`
}

// ImportInput imports Bruno (.bru / zip), OpenAPI 3, or cURL into an existing workspace.
type ImportInput struct {
	Format    string       `json:"format"` // bru | openapi | curl
	Content   string       `json:"content,omitempty"`
	ZipBase64 string       `json:"zip_base64,omitempty"`
	Files     []ImportFile `json:"files,omitempty"`
	FolderID  *uuid.UUID   `json:"folder_id,omitempty"`
}

// ImportResult summarizes created items from an import.
type ImportResult struct {
	FoldersCreated      int      `json:"folders_created"`
	RequestsCreated     int      `json:"requests_created"`
	EnvironmentsCreated int      `json:"environments_created"`
	Warnings            []string `json:"warnings,omitempty"`
}

// ImportCollection parses and imports Bruno, OpenAPI 3, or cURL into httpWS.
func (s *Service) ImportCollection(ctx context.Context, ws, httpWS uuid.UUID, in ImportInput) (ImportResult, error) {
	var res ImportResult
	if _, err := s.Q.GetHTTPWorkspace(ctx, store.GetHTTPWorkspaceParams{ID: httpWS, WorkspaceID: ws}); err != nil {
		return res, mapNotFound(err)
	}
	if in.FolderID != nil {
		f, err := s.Q.GetHTTPFolder(ctx, store.GetHTTPFolderParams{ID: *in.FolderID, WorkspaceID: ws})
		if err != nil || f.HttpWorkspaceID != httpWS {
			return res, apperr.Invalid("folder_id", "unknown folder in this workspace")
		}
	}

	switch strings.ToLower(strings.TrimSpace(in.Format)) {
	case "bru", "bruno":
		return s.importBruno(ctx, ws, httpWS, in)
	case "curl":
		return s.importCurl(ctx, ws, httpWS, in)
	case "openapi":
		return s.importOpenAPI(ctx, ws, httpWS, in)
	default:
		return res, apperr.Invalid("format", "must be bru, openapi, or curl")
	}
}

func (s *Service) importBruno(ctx context.Context, ws, httpWS uuid.UUID, in ImportInput) (ImportResult, error) {
	var res ImportResult
	files := append([]ImportFile{}, in.Files...)
	if in.ZipBase64 != "" {
		zipFiles, err := extractBruZip(in.ZipBase64)
		if err != nil {
			return res, err
		}
		files = append(files, zipFiles...)
	}
	if len(files) == 0 && strings.TrimSpace(in.Content) != "" {
		files = append(files, ImportFile{Path: "request.bru", Content: in.Content})
	}
	if len(files) == 0 {
		return res, apperr.Invalid("files", "provide .bru files, zip_base64, or content")
	}

	// Sort so environments and folder.bru come cleanly and paths are deterministic.
	sort.Slice(files, func(i, j int) bool { return files[i].Path < files[j].Path })

	// Strip common top-level directory prefix if all files share one (e.g. my-collection/...).
	files = stripCommonRoot(files)

	folderCache := map[string]uuid.UUID{}
	ensureFolderPath := func(relDir string) (*uuid.UUID, error) {
		relDir = strings.Trim(path.Clean(relDir), "./")
		if relDir == "" || relDir == "." {
			return in.FolderID, nil
		}
		parts := strings.Split(relDir, "/")
		parent := in.FolderID
		accum := ""
		for _, part := range parts {
			if part == "" || part == "." {
				continue
			}
			if accum == "" {
				accum = part
			} else {
				accum += "/" + part
			}
			if id, ok := folderCache[accum]; ok {
				p := id
				parent = &p
				continue
			}
			created, err := s.CreateFolder(ctx, ws, httpWS, FolderInput{
				ParentFolderID: parent,
				Name:           part,
				DefaultAuth:    AuthConfig{Type: AuthInherit},
			})
			if err != nil {
				return nil, err
			}
			res.FoldersCreated++
			folderCache[accum] = created.ID
			p := created.ID
			parent = &p
		}
		return parent, nil
	}

	// First pass: environments and folder.bru metadata.
	for _, f := range files {
		clean := strings.TrimPrefix(path.Clean(strings.ReplaceAll(f.Path, "\\", "/")), "./")
		lower := strings.ToLower(clean)
		if !strings.HasSuffix(lower, ".bru") {
			continue
		}
		if strings.HasPrefix(lower, "environments/") || strings.Contains(lower, "/environments/") {
			name := strings.TrimSuffix(path.Base(clean), path.Ext(clean))
			vars := parseBruEnvironment(f.Content)
			color := "blue"
			if strings.Contains(strings.ToLower(name), "prod") && !strings.Contains(strings.ToLower(name), "non") {
				color = "red"
			} else if strings.Contains(strings.ToLower(name), "nonprod") || strings.Contains(strings.ToLower(name), "dev") {
				color = "green"
			}
			if _, err := s.CreateEnvironment(ctx, ws, httpWS, EnvironmentInput{
				Name:      name,
				Color:     color,
				Variables: vars,
			}); err != nil {
				res.Warnings = append(res.Warnings, fmt.Sprintf("skipped environment %s: %v", name, err))
			} else {
				res.EnvironmentsCreated++
			}
			continue
		}
		if strings.EqualFold(path.Base(clean), "folder.bru") {
			dir := path.Dir(clean)
			fid, err := ensureFolderPath(dir)
			if err != nil {
				return res, err
			}
			if fid != nil {
				parsed := parseBruRequest(path.Base(dir), f.Content)
				if parsed.Auth.Type != AuthInherit || len(parsed.Headers) > 0 {
					folderRow, err := s.Q.GetHTTPFolder(ctx, store.GetHTTPFolderParams{ID: *fid, WorkspaceID: ws})
					if err == nil {
						_, _ = s.UpdateFolder(ctx, ws, *fid, FolderInput{
							ParentFolderID: folderRow.ParentFolderID,
							Name:           folderRow.Name,
							DefaultAuth:    parsed.Auth,
							DefaultHeaders: parsed.Headers,
							SortOrder:      int(folderRow.SortOrder),
						})
					}
				}
			}
		}
	}

	// Second pass: request .bru files.
	for _, f := range files {
		clean := strings.TrimPrefix(path.Clean(strings.ReplaceAll(f.Path, "\\", "/")), "./")
		lower := strings.ToLower(clean)
		if !strings.HasSuffix(lower, ".bru") {
			continue
		}
		if strings.HasPrefix(lower, "environments/") || strings.Contains(lower, "/environments/") || strings.EqualFold(path.Base(clean), "folder.bru") || strings.EqualFold(path.Base(clean), "collection.bru") {
			continue
		}
		dir := path.Dir(clean)
		fid, err := ensureFolderPath(dir)
		if err != nil {
			return res, err
		}
		fallbackName := strings.TrimSuffix(path.Base(clean), path.Ext(clean))
		reqIn := parseBruRequest(fallbackName, f.Content)
		reqIn.FolderID = fid
		if _, err := s.CreateRequest(ctx, ws, httpWS, reqIn); err != nil {
			res.Warnings = append(res.Warnings, fmt.Sprintf("skipped %s: %v", clean, err))
			continue
		}
		res.RequestsCreated++
	}
	return res, nil
}

func extractBruZip(b64 string) ([]ImportFile, error) {
	raw, err := base64.StdEncoding.DecodeString(strings.TrimSpace(b64))
	if err != nil {
		return nil, apperr.Invalid("zip_base64", "invalid base64 zip")
	}
	if len(raw) > 20<<20 {
		return nil, apperr.Invalid("zip_base64", "zip exceeds 20 MB limit")
	}
	zr, err := zip.NewReader(bytes.NewReader(raw), int64(len(raw)))
	if err != nil {
		return nil, apperr.Invalid("zip_base64", "invalid zip archive")
	}
	var out []ImportFile
	for _, f := range zr.File {
		if f.FileInfo().IsDir() || !strings.HasSuffix(strings.ToLower(f.Name), ".bru") {
			continue
		}
		rc, err := f.Open()
		if err != nil {
			continue
		}
		data, err := io.ReadAll(io.LimitReader(rc, 2<<20))
		_ = rc.Close()
		if err != nil {
			continue
		}
		out = append(out, ImportFile{Path: f.Name, Content: string(data)})
	}
	return out, nil
}

func stripCommonRoot(files []ImportFile) []ImportFile {
	if len(files) <= 1 {
		return files
	}
	var prefix string
	for i, f := range files {
		clean := strings.TrimPrefix(path.Clean(strings.ReplaceAll(f.Path, "\\", "/")), "./")
		parts := strings.Split(clean, "/")
		if len(parts) < 2 {
			return files
		}
		if i == 0 {
			prefix = parts[0] + "/"
		} else if !strings.HasPrefix(clean, prefix) {
			return files
		}
	}
	if prefix == "" {
		return files
	}
	out := make([]ImportFile, len(files))
	for i, f := range files {
		clean := strings.TrimPrefix(path.Clean(strings.ReplaceAll(f.Path, "\\", "/")), "./")
		out[i] = ImportFile{Path: strings.TrimPrefix(clean, prefix), Content: f.Content}
	}
	return out
}

type bruBlock struct {
	Name string
	Kind string // "map" | "text" | "list"
	Body string
}

func parseBruBlocks(src string) []bruBlock {
	lines := strings.Split(strings.ReplaceAll(src, "\r\n", "\n"), "\n")
	var blocks []bruBlock
	i := 0
	for i < len(lines) {
		line := strings.TrimSpace(lines[i])
		if line == "" || strings.HasPrefix(line, "#") {
			i++
			continue
		}
		var name, kind string
		switch {
		case strings.HasSuffix(line, "{"):
			name = strings.TrimSpace(strings.TrimSuffix(line, "{"))
			kind = "map"
		case strings.HasSuffix(line, "["):
			name = strings.TrimSpace(strings.TrimSuffix(line, "["))
			kind = "list"
		default:
			i++
			continue
		}
		closeChar := "}"
		if kind == "list" {
			closeChar = "]"
		}
		i++
		var body []string
		depth := 1
		isRawBody := strings.HasPrefix(strings.ToLower(name), "body:json") ||
			strings.HasPrefix(strings.ToLower(name), "body:text") ||
			strings.HasPrefix(strings.ToLower(name), "body:xml") ||
			strings.HasPrefix(strings.ToLower(name), "body:graphql")
		for i < len(lines) {
			cur := lines[i]
			trimmed := strings.TrimSpace(cur)
			if isRawBody {
				// For raw JSON/text blocks, Bruno terminates on a top-level closing "}" at column 0 (or dedented).
				if cur == "}" {
					i++
					break
				}
			} else {
				if kind == "map" {
					if strings.HasSuffix(trimmed, "{") {
						depth++
					}
					if trimmed == "}" {
						depth--
						if depth == 0 {
							i++
							break
						}
					}
				} else if trimmed == closeChar {
					i++
					break
				}
			}
			body = append(body, cur)
			i++
		}
		blocks = append(blocks, bruBlock{Name: strings.ToLower(name), Kind: kind, Body: strings.Join(body, "\n")})
	}
	return blocks
}

func parseBruKV(body string) []KeyValue {
	var out []KeyValue
	for _, rawLine := range strings.Split(body, "\n") {
		trimmed := strings.TrimSpace(rawLine)
		if trimmed == "" || strings.HasPrefix(trimmed, "#") {
			continue
		}
		enabled := true
		if strings.HasPrefix(trimmed, "~") {
			enabled = false
			trimmed = strings.TrimSpace(strings.TrimPrefix(trimmed, "~"))
		}
		k, v, ok := strings.Cut(trimmed, ":")
		if !ok {
			continue
		}
		key := strings.TrimSpace(k)
		val := strings.TrimSpace(v)
		out = append(out, KeyValue{Key: key, Value: val, Enabled: enabled})
	}
	return out
}

func kvToMap(kvs []KeyValue) map[string]string {
	m := map[string]string{}
	for _, kv := range kvs {
		if kv.Enabled {
			m[strings.ToLower(kv.Key)] = kv.Value
		}
	}
	return m
}

func dedentBlock(body string) string {
	lines := strings.Split(body, "\n")
	for i, l := range lines {
		lines[i] = strings.TrimPrefix(l, "  ")
	}
	return strings.TrimSpace(strings.Join(lines, "\n"))
}

func parseBruEnvironment(src string) []EnvVar {
	var out []EnvVar
	for _, b := range parseBruBlocks(src) {
		switch b.Name {
		case "vars":
			for _, kv := range parseBruKV(b.Body) {
				out = append(out, EnvVar{Key: kv.Key, Value: kv.Value, Enabled: kv.Enabled})
			}
		case "vars:secret":
			for _, line := range strings.Split(b.Body, "\n") {
				k := strings.TrimSpace(strings.TrimSuffix(strings.TrimSpace(line), ","))
				if k == "" || strings.HasPrefix(k, "#") {
					continue
				}
				out = append(out, EnvVar{Key: k, Value: "", SecretHandle: strings.ToLower(k), Enabled: true})
			}
		}
	}
	return out
}

func parseBruRequest(fallbackName, src string) RequestInput {
	req := RequestInput{
		Name:     fallbackName,
		Method:   "GET",
		BodyMode: BodyNone,
		Auth:     AuthConfig{Type: AuthInherit},
	}
	for _, b := range parseBruBlocks(src) {
		switch b.Name {
		case "meta":
			m := kvToMap(parseBruKV(b.Body))
			if name := strings.TrimSpace(m["name"]); name != "" {
				req.Name = name
			}
		case "get", "post", "put", "patch", "delete", "head", "options":
			req.Method = strings.ToUpper(b.Name)
			m := kvToMap(parseBruKV(b.Body))
			if u := strings.TrimSpace(m["url"]); u != "" {
				req.URL = u
			}
			switch strings.ToLower(m["auth"]) {
			case "none":
				req.Auth = AuthConfig{Type: AuthNone}
			case "inherit":
				req.Auth = AuthConfig{Type: AuthInherit}
			}
		case "headers":
			req.Headers = append(req.Headers, parseBruKV(b.Body)...)
		case "params:query", "query":
			req.Params = append(req.Params, parseBruKV(b.Body)...)
		case "auth:bearer":
			m := kvToMap(parseBruKV(b.Body))
			req.Auth = AuthConfig{Type: AuthBearer, Token: m["token"]}
		case "auth:basic":
			m := kvToMap(parseBruKV(b.Body))
			req.Auth = AuthConfig{Type: AuthBasic, Username: m["username"], Password: m["password"]}
		case "auth:apikey":
			m := kvToMap(parseBruKV(b.Body))
			in := APIKeyInHeader
			if strings.EqualFold(m["placement"], "queryparams") || strings.EqualFold(m["placement"], "query") {
				in = APIKeyInQuery
			}
			req.Auth = AuthConfig{Type: AuthAPIKey, APIKeyName: m["key"], APIKeyValue: m["value"], APIKeyIn: in}
		case "auth:oauth2":
			m := kvToMap(parseBruKV(b.Body))
			req.Auth = AuthConfig{
				Type: AuthOAuth2,
				OAuth2: &OAuth2Config{
					GrantType:    "client_credentials",
					TokenURL:     m["access_token_url"],
					ClientID:     m["client_id"],
					ClientSecret: m["client_secret"],
					Scope:        m["scope"],
				},
			}
		case "body:json":
			req.BodyMode = BodyJSON
			req.Body = dedentBlock(b.Body)
		case "body:text", "body:xml", "body:graphql":
			req.BodyMode = BodyRaw
			req.Body = dedentBlock(b.Body)
		case "body:form-urlencoded":
			req.BodyMode = BodyFormURLEncoded
			req.BodyForm = parseBruKV(b.Body)
		case "body:multipart-form":
			req.BodyMode = BodyMultipart
			req.BodyForm = parseBruKV(b.Body)
		}
	}
	return req
}

func (s *Service) importCurl(ctx context.Context, ws, httpWS uuid.UUID, in ImportInput) (ImportResult, error) {
	var res ImportResult
	req, err := parseCurl(in.Content)
	if err != nil {
		return res, err
	}
	req.FolderID = in.FolderID
	if _, err := s.CreateRequest(ctx, ws, httpWS, req); err != nil {
		return res, err
	}
	res.RequestsCreated = 1
	return res, nil
}

// parseCurl turns a pasted cURL command (including a browser's "Copy as cURL")
// into a request. Flags it doesn't model (-L, -s, --compressed, -o …) are ignored.
func parseCurl(content string) (RequestInput, error) {
	tokens := splitShellTokens(strings.ReplaceAll(strings.ReplaceAll(content, "\\\r\n", " "), "\\\n", " "))
	if len(tokens) == 0 {
		return RequestInput{}, apperr.Invalid("content", "enter a cURL command")
	}
	req := RequestInput{
		Method:   "GET",
		BodyMode: BodyNone,
		Auth:     AuthConfig{Type: AuthInherit},
	}
	hasHeader := func(name string) bool {
		for _, h := range req.Headers {
			if strings.EqualFold(h.Key, name) {
				return true
			}
		}
		return false
	}
	addHeader := func(raw string) {
		if k, v, ok := strings.Cut(raw, ":"); ok {
			req.Headers = append(req.Headers, KeyValue{Key: strings.TrimSpace(k), Value: strings.TrimSpace(v), Enabled: true})
		}
	}
	var dataParts []string
	jsonBody, explicitMethod := false, false
	for i := 0; i < len(tokens); i++ {
		tok := tokens[i]
		if i == 0 && strings.EqualFold(tok, "curl") {
			continue
		}
		// --opt=value is the same as --opt value; -XPOST the same as -X POST.
		var inline *string
		if strings.HasPrefix(tok, "--") {
			if k, v, ok := strings.Cut(tok, "="); ok {
				tok, inline = k, &v
			}
		} else if len(tok) > 2 && tok[0] == '-' && tok[1] == 'X' {
			v := tok[2:]
			tok, inline = "-X", &v
		}
		next := func() string {
			if inline != nil {
				return *inline
			}
			if i+1 < len(tokens) {
				i++
				return tokens[i]
			}
			return ""
		}
		switch {
		case tok == "-X" || tok == "--request":
			req.Method = strings.ToUpper(next())
			explicitMethod = true
		case tok == "-I" || tok == "--head":
			req.Method, explicitMethod = "HEAD", true
		case tok == "-H" || tok == "--header":
			addHeader(next())
		case tok == "-b" || tok == "--cookie":
			if c := next(); strings.Contains(c, "=") {
				addHeader("Cookie: " + c)
			}
		case tok == "-d" || tok == "--data" || tok == "--data-raw" || tok == "--data-binary" || tok == "--data-ascii" || tok == "--data-urlencode":
			dataParts = append(dataParts, next())
		case tok == "--json":
			dataParts = append(dataParts, next())
			jsonBody = true
		case tok == "-u" || tok == "--user":
			u, p, _ := strings.Cut(next(), ":")
			req.Auth = AuthConfig{Type: AuthBasic, Username: u, Password: p}
		case tok == "--url":
			req.URL = next()
		case strings.HasPrefix(tok, "http://") || strings.HasPrefix(tok, "https://") || strings.HasPrefix(tok, "{{"):
			req.URL = tok
		}
	}
	if req.URL == "" {
		return RequestInput{}, apperr.Invalid("content", "could not find URL in cURL command")
	}
	if len(dataParts) > 0 {
		if !explicitMethod {
			req.Method = "POST"
		}
		joined := strings.Join(dataParts, "&")
		req.Body = joined
		trimmed := strings.TrimSpace(joined)
		if jsonBody || strings.HasPrefix(trimmed, "{") || strings.HasPrefix(trimmed, "[") {
			req.BodyMode = BodyJSON
		} else {
			req.BodyMode = BodyRaw
		}
		if jsonBody {
			if !hasHeader("Content-Type") {
				addHeader("Content-Type: application/json")
			}
			if !hasHeader("Accept") {
				addHeader("Accept: application/json")
			}
		}
	}
	req.Name = req.Method + " " + req.URL
	if len(req.Name) > 80 {
		req.Name = req.Name[:80]
	}
	return req, nil
}

// splitShellTokens splits a command line the way a POSIX shell would: single and
// double quotes, backslash escapes, and bash's $'…' (which browsers emit for
// bodies with newlines or quotes).
func splitShellTokens(s string) []string {
	var out []string
	var cur strings.Builder
	var quote rune
	escaped, started := false, false
	flush := func() {
		if started {
			out = append(out, cur.String())
			cur.Reset()
			started = false
		}
	}
	runes := []rune(s)
	for i := 0; i < len(runes); i++ {
		r := runes[i]
		if escaped {
			cur.WriteRune(r)
			escaped = false
			continue
		}
		switch quote {
		case '\'': // single quotes: literal
			if r == '\'' {
				quote = 0
			} else {
				cur.WriteRune(r)
			}
			continue
		case '$': // $'…': C-style escapes
			switch {
			case r == '\'':
				quote = 0
			case r == '\\' && i+1 < len(runes):
				i++
				switch runes[i] {
				case 'n':
					cur.WriteRune('\n')
				case 'r':
					cur.WriteRune('\r')
				case 't':
					cur.WriteRune('\t')
				default:
					cur.WriteRune(runes[i])
				}
			default:
				cur.WriteRune(r)
			}
			continue
		case '"':
			switch {
			case r == '\\' && i+1 < len(runes):
				escaped = true
			case r == '"':
				quote = 0
			default:
				cur.WriteRune(r)
			}
			continue
		}
		switch {
		case r == '$' && i+1 < len(runes) && runes[i+1] == '\'':
			quote, started = '$', true
			i++
		case r == '\\':
			escaped, started = true, true
		case r == '\'' || r == '"':
			quote, started = r, true
		case r == ' ' || r == '\t' || r == '\n' || r == '\r':
			flush()
		default:
			cur.WriteRune(r)
			started = true
		}
	}
	flush()
	return out
}

func (s *Service) importOpenAPI(ctx context.Context, ws, httpWS uuid.UUID, in ImportInput) (ImportResult, error) {
	var res ImportResult
	raw := strings.TrimSpace(in.Content)
	if raw == "" {
		return res, apperr.Invalid("content", "OpenAPI JSON or YAML is required")
	}
	var doc struct {
		Servers []struct {
			URL string `json:"url" yaml:"url"`
		} `json:"servers" yaml:"servers"`
		Paths map[string]map[string]struct {
			Summary     string   `json:"summary" yaml:"summary"`
			OperationID string   `json:"operationId" yaml:"operationId"`
			Tags        []string `json:"tags" yaml:"tags"`
			Parameters  []struct {
				Name string `json:"name" yaml:"name"`
				In   string `json:"in" yaml:"in"`
			} `json:"parameters" yaml:"parameters"`
			RequestBody *struct {
				Content map[string]struct {
					Example any `json:"example" yaml:"example"`
				} `json:"content" yaml:"content"`
			} `json:"requestBody" yaml:"requestBody"`
		} `json:"paths" yaml:"paths"`
	}
	if err := yaml.Unmarshal([]byte(raw), &doc); err != nil {
		return res, apperr.Invalid("content", "invalid OpenAPI JSON/YAML: %v", err)
	}
	if len(doc.Paths) == 0 {
		return res, apperr.Invalid("content", "OpenAPI document has no paths")
	}

	baseURL := "{{base_url}}"
	if len(doc.Servers) > 0 && strings.TrimSpace(doc.Servers[0].URL) != "" {
		baseURL = strings.TrimRight(strings.TrimSpace(doc.Servers[0].URL), "/")
	}

	tagFolders := map[string]uuid.UUID{}
	pathKeys := make([]string, 0, len(doc.Paths))
	for p := range doc.Paths {
		pathKeys = append(pathKeys, p)
	}
	sort.Strings(pathKeys)

	for _, p := range pathKeys {
		ops := doc.Paths[p]
		for _, method := range validMethods {
			op, ok := ops[strings.ToLower(method)]
			if !ok {
				continue
			}
			folderID := in.FolderID
			if len(op.Tags) > 0 && strings.TrimSpace(op.Tags[0]) != "" {
				tag := strings.TrimSpace(op.Tags[0])
				if fid, exists := tagFolders[tag]; exists {
					f := fid
					folderID = &f
				} else {
					created, err := s.CreateFolder(ctx, ws, httpWS, FolderInput{
						ParentFolderID: in.FolderID,
						Name:           tag,
						DefaultAuth:    AuthConfig{Type: AuthInherit},
					})
					if err != nil {
						return res, err
					}
					res.FoldersCreated++
					tagFolders[tag] = created.ID
					f := created.ID
					folderID = &f
				}
			}
			name := strings.TrimSpace(op.Summary)
			if name == "" {
				name = strings.TrimSpace(op.OperationID)
			}
			if name == "" {
				name = method + " " + p
			}
			var params, headers []KeyValue
			for _, prm := range op.Parameters {
				switch prm.In {
				case "query":
					params = append(params, KeyValue{Key: prm.Name, Value: "", Enabled: true})
				case "header":
					headers = append(headers, KeyValue{Key: prm.Name, Value: "", Enabled: true})
				}
			}
			bodyMode := BodyNone
			body := ""
			if op.RequestBody != nil {
				if jc, ok := op.RequestBody.Content["application/json"]; ok {
					bodyMode = BodyJSON
					if jc.Example != nil {
						if b, err := json.MarshalIndent(jc.Example, "", "  "); err == nil {
							body = string(b)
						}
					} else {
						body = "{}"
					}
				}
			}
			if _, err := s.CreateRequest(ctx, ws, httpWS, RequestInput{
				FolderID: folderID,
				Name:     name,
				Method:   method,
				URL:      baseURL + p,
				Params:   params,
				Headers:  headers,
				Auth:     AuthConfig{Type: AuthInherit},
				BodyMode: bodyMode,
				Body:     body,
			}); err != nil {
				res.Warnings = append(res.Warnings, fmt.Sprintf("skipped %s %s: %v", method, p, err))
				continue
			}
			res.RequestsCreated++
		}
	}
	return res, nil
}
