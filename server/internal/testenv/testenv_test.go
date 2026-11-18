package testenv

import (
	"os"
	"reflect"
	"strings"
	"testing"
)

// Vesper's own CI is the case that started this: its Postgres service and
// localhost TEST_DATABASE_URL must become a service the turn reaches by name.
func TestInferFromVespersCI(t *testing.T) {
	ci, err := os.ReadFile("../../../.github/workflows/ci.yml")
	if err != nil {
		t.Fatal(err)
	}
	r := Infer(map[string][]byte{".github/workflows/ci.yml": ci})
	if len(r.Services) != 1 {
		t.Fatalf("services = %+v", r.Services)
	}
	s := r.Services[0]
	if s.Name != "postgres" || s.Image != "postgres:17-alpine" || s.Env["POSTGRES_PASSWORD"] != "lazyagents" {
		t.Fatalf("service = %+v", s)
	}
	if !reflect.DeepEqual(s.Healthcheck, []string{"CMD-SHELL", "pg_isready -U lazyagents"}) {
		t.Fatalf("healthcheck = %q", s.Healthcheck)
	}
	want := "postgres://lazyagents:lazyagents@postgres:5432/lazyagents?sslmode=disable"
	if s.Expose["TEST_DATABASE_URL"] != want {
		t.Fatalf("expose = %v, want TEST_DATABASE_URL=%s", s.Expose, want)
	}
}

func TestInferSkipsWhatOnlyActionsCanEvaluate(t *testing.T) {
	wf := `
jobs:
  test:
    services:
      db:
        image: ${{ matrix.db }}
      cache:
        image: redis:7
        env:
          TOKEN: ${{ secrets.TOKEN }}
        ports: ["6380:6379"]
    env:
      REDIS_URL: redis://localhost:6380/0
      OTHER: https://example.com
`
	r := Infer(map[string][]byte{".github/workflows/t.yml": []byte(wf)})
	if len(r.Services) != 1 || r.Services[0].Name != "cache" || r.Services[0].Env != nil {
		t.Fatalf("services = %+v", r.Services)
	}
	if got := r.Services[0].Expose; len(got) != 1 || got["REDIS_URL"] != "redis://cache:6379/0" {
		t.Fatalf("expose = %v", got)
	}
}

func TestInferFromComposeKeepsBackingServicesOnly(t *testing.T) {
	compose := `
services:
  api:
    build: ./server
  web:
    image: ghcr.io/acme/web:latest
  postgres:
    image: postgres:16
    environment:
      - POSTGRES_PASSWORD=pw
      - POSTGRES_USER=${PGUSER}
    healthcheck:
      test: ["CMD", "pg_isready"]
  redis:
    image: redis:7-alpine
`
	r := Infer(map[string][]byte{"docker-compose.yml": []byte(compose)})
	var names []string
	for _, s := range r.Services {
		names = append(names, s.Name)
	}
	if strings.Join(names, ",") != "postgres,redis" {
		t.Fatalf("services = %v", names)
	}
	if pg := r.Services[0]; pg.Env["POSTGRES_PASSWORD"] != "pw" || pg.Env["POSTGRES_USER"] != "" || pg.Healthcheck[0] != "CMD" {
		t.Fatalf("postgres = %+v", pg)
	}
}

func TestInferPrefersCIOverCompose(t *testing.T) {
	r := Infer(map[string][]byte{
		".github/workflows/ci.yml": []byte("jobs:\n  t:\n    services:\n      mysql:\n        image: mysql:8\n"),
		"compose.yaml":             []byte("services:\n  postgres:\n    image: postgres:17\n"),
	})
	if len(r.Services) != 1 || r.Services[0].Name != "mysql" {
		t.Fatalf("services = %+v", r.Services)
	}
}

func TestParseNixManifest(t *testing.T) {
	v2 := `{"version":2,"elements":[
	  {"attrPath":"legacyPackages.aarch64-linux.protobuf","originalUrl":"flake:nixpkgs","url":"github:NixOS/nixpkgs/abc"},
	  {"attrPath":"packages.x86_64-linux.default","originalUrl":"github:acme/tool"},
	  {"storePaths":["/nix/store/x-hand"]}]}`
	if got := ParseNixManifest([]byte(v2)); !reflect.DeepEqual(got, []string{"github:acme/tool#default", "nixpkgs#protobuf"}) {
		t.Fatalf("v2 = %v", got)
	}
	v3 := `{"version":3,"elements":{"jdk":{"attrPath":"legacyPackages.x86_64-linux.jdk21","originalUrl":"flake:nixpkgs"}}}`
	if got := ParseNixManifest([]byte(v3)); !reflect.DeepEqual(got, []string{"nixpkgs#jdk21"}) {
		t.Fatalf("v3 = %v", got)
	}
	if got := ParseNixManifest([]byte("not json")); got != nil {
		t.Fatalf("garbage = %v", got)
	}
}

func TestRecipeNixPackages(t *testing.T) {
	r, changed := Recipe{NixPackages: []string{"nixpkgs#jq"}}.AddNixPackages([]string{"nixpkgs#protobuf", "nixpkgs#jq", "bad; rm -rf /"})
	if !changed || !reflect.DeepEqual(r.NixPackages, []string{"nixpkgs#jq", "nixpkgs#protobuf"}) {
		t.Fatalf("add = %v %v", r.NixPackages, changed)
	}
	if _, changed := r.AddNixPackages([]string{"nixpkgs#jq"}); changed {
		t.Fatal("adding a known package reported a change")
	}
	script := r.NixInstallScript()
	if !strings.Contains(script, "nix profile install 'nixpkgs#jq' 'nixpkgs#protobuf' ||") {
		t.Fatalf("script = %s", script)
	}
	bad := Recipe{NixPackages: []string{"nixpkgs#x'; touch /tmp/p; '"}}
	if bad.Validate() == nil {
		t.Fatal("a package with shell in it validated")
	}
}

func TestRepoKey(t *testing.T) {
	for _, in := range []string{
		"git@github.com:Acme/App.git", "https://github.com/acme/app", "https://x-access-token@github.com/acme/app.git/",
		"ssh://git@github.com/acme/app.git",
	} {
		if got := RepoKey(in); got != "github.com/acme/app" {
			t.Errorf("RepoKey(%q) = %q", in, got)
		}
	}
}
