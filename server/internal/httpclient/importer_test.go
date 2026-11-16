package httpclient

import (
	"archive/zip"
	"bytes"
	"context"
	"encoding/base64"
	"testing"

	"github.com/liamphmurphy/vesper/server/internal/seed"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/testdb"
)

func TestImportBrunoCurlOpenAPI(t *testing.T) {
	ctx := context.Background()
	pool := testdb.New(t)
	if _, err := seed.Run(ctx, pool, seed.Options{Demo: true}); err != nil {
		t.Fatal(err)
	}
	q := store.New(pool)
	me, _ := q.GetLocalUser(ctx)
	ws := me.WorkspaceID
	svc := &Service{Q: q}

	bundle, err := svc.CreateWorkspace(ctx, ws, me.ID, WorkspaceInput{Name: "Imported"})
	if err != nil {
		t.Fatal(err)
	}

	// Build a zip with Bruno folder, request, and environment files.
	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)
	writeZipFile := func(name, body string) {
		w, err := zw.Create(name)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := w.Write([]byte(body)); err != nil {
			t.Fatal(err)
		}
	}
	writeZipFile("my-api/environments/nonprod.bru", `vars {
  base_url: https://nonprod.example.com
}
vars:secret [
  api_token
]`)
	writeZipFile("my-api/users/folder.bru", `auth:bearer {
  token: {{api_token}}
}`)
	writeZipFile("my-api/users/create-user.bru", `meta {
  name: Create User
  type: http
  seq: 1
}

post {
  url: {{base_url}}/v1/users
  body: json
  auth: inherit
}

headers {
  X-Trace: 123
  ~X-Disabled: nope
}

params:query {
  dry_run: true
}

body:json {
  {
    "email": "dev@example.com"
  }
}`)
	if err := zw.Close(); err != nil {
		t.Fatal(err)
	}

	bruRes, err := svc.ImportCollection(ctx, ws, bundle.Workspace.ID, ImportInput{
		Format:    "bru",
		ZipBase64: base64.StdEncoding.EncodeToString(buf.Bytes()),
	})
	if err != nil {
		t.Fatal(err)
	}
	if bruRes.EnvironmentsCreated != 1 || bruRes.FoldersCreated != 1 || bruRes.RequestsCreated != 1 {
		t.Fatalf("unexpected bru import result: %+v", bruRes)
	}

	// Import cURL.
	curlRes, err := svc.ImportCollection(ctx, ws, bundle.Workspace.ID, ImportInput{
		Format:  "curl",
		Content: `curl -X PATCH "https://api.example.com/v1/items/9" -H "X-Custom: abc" -d '{"active":true}'`,
	})
	if err != nil || curlRes.RequestsCreated != 1 {
		t.Fatalf("unexpected curl import result: %+v, err=%v", curlRes, err)
	}

	// Import OpenAPI 3 YAML.
	oaRes, err := svc.ImportCollection(ctx, ws, bundle.Workspace.ID, ImportInput{
		Format: "openapi",
		Content: `openapi: 3.0.3
servers:
  - url: https://api.example.com
paths:
  /v1/widgets:
    get:
      summary: List Widgets
      tags: [Widgets]
      parameters:
        - name: page
          in: query`,
	})
	if err != nil || oaRes.FoldersCreated != 1 || oaRes.RequestsCreated != 1 {
		t.Fatalf("unexpected openapi import result: %+v, err=%v", oaRes, err)
	}

	updated, err := svc.GetWorkspaceBundle(ctx, ws, bundle.Workspace.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(updated.Environments) != 1 || len(updated.Folders) != 2 || len(updated.Requests) != 3 {
		t.Fatalf("expected 1 env, 2 folders, 3 requests; got %d / %d / %d", len(updated.Environments), len(updated.Folders), len(updated.Requests))
	}
}
