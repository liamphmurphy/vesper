package runner_test

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
	"github.com/liamphmurphy/vesper/server/internal/runner"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/testenv"
)

// svcBackend is the fake backend plus fake services, recording what the
// turn was given.
type svcBackend struct {
	*runner.Fake
	fail     error
	mu       sync.Mutex
	started  []string
	stopped  int
	turnEnv  map[string]string
	turnNets []string
}

func (b *svcBackend) StartServices(_ context.Context, runID, key string, services []agentdef.Service) (string, func(), error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.fail != nil {
		return "", nil, b.fail
	}
	b.started = append(b.started, key)
	return "net-" + key, func() { b.mu.Lock(); b.stopped++; b.mu.Unlock() }, nil
}

func (b *svcBackend) Start(ctx context.Context, runID string, spec runner.ExecSpec) (runner.Process, error) {
	if strings.HasPrefix(spec.Name, "lazyagents-turn-") {
		b.mu.Lock()
		b.turnEnv, b.turnNets = spec.Env, spec.Networks
		b.mu.Unlock()
	}
	return b.Fake.Start(ctx, runID, spec)
}

func withServices(e env, key string) {
	e.t.Helper()
	svc, _ := json.Marshal([]agentdef.Service{{Name: "postgres", Image: "postgres:17-alpine",
		Expose: map[string]string{"TEST_DATABASE_URL": "postgres://postgres@postgres:5432/postgres"}}})
	if _, err := e.pool.Exec(e.ctx, `UPDATE runs SET resolved_spec = jsonb_set(resolved_spec, '{services}', $2::jsonb) WHERE id = $1`, e.run(key).ID, svc); err != nil {
		e.t.Fatal(err)
	}
}

// A turn runs with its services up, sees what they expose, joins their
// network, and they are stopped when it ends.
func TestTurnRunsWithItsServices(t *testing.T) {
	e := setup(t)
	b := &svcBackend{Fake: e.runner.Backend.(*runner.Fake)}
	e.runner.Backend = b
	e.dispatch("PAY-214")
	withServices(e, "PAY-214")
	e.until("waiting for approval", e.state("PAY-214=waiting"))
	b.mu.Lock()
	defer b.mu.Unlock()
	if len(b.started) != 1 || b.stopped != 1 {
		t.Fatalf("services started %v, stopped %d times", b.started, b.stopped)
	}
	if b.turnEnv["TEST_DATABASE_URL"] != "postgres://postgres@postgres:5432/postgres" || len(b.turnNets) != 1 || b.turnNets[0] != "net-"+b.started[0] {
		t.Fatalf("turn env %q networks %v", b.turnEnv["TEST_DATABASE_URL"], b.turnNets)
	}
	if evs := e.eventTypes(e.run("PAY-214").ID); !strings.Contains(evs, "lifecycle:services_ready") {
		t.Fatalf("no services_ready event: %s", evs)
	}
}

// A service that can't start fails the run, saying which and why.
func TestTurnFailsWhenItsServicesDont(t *testing.T) {
	e := setup(t)
	b := &svcBackend{Fake: e.runner.Backend.(*runner.Fake), fail: errors.New("service postgres: exited with code 1")}
	e.runner.Backend = b
	e.dispatch("PAY-214")
	withServices(e, "PAY-214")
	e.until("failed", e.state("PAY-214=failed"))
	if r := e.run("PAY-214"); r.Outcome == nil || !strings.Contains(*r.Outcome, "Couldn't start the run's services: service postgres") {
		t.Fatalf("outcome %v", r.Outcome)
	}
}

// The fake runner can't start services: the turn runs anyway and says so.
func TestFakeRunnerSkipsServices(t *testing.T) {
	e := setup(t)
	e.dispatch("PAY-214")
	withServices(e, "PAY-214")
	e.until("waiting for approval", e.state("PAY-214=waiting"))
	if evs := e.eventTypes(e.run("PAY-214").ID); !strings.Contains(evs, "lifecycle:services_skipped") {
		t.Fatalf("no services_skipped event: %s", evs)
	}
}

// learnBackend is svcBackend whose turns report a Nix profile, as Docker
// turns do once the agent installs something.
type learnBackend struct {
	*svcBackend
	manifest []byte
}

type nixProc struct {
	runner.Process
	manifest []byte
}

func (p nixProc) NixManifest() []byte { return p.manifest }

func (b *learnBackend) Start(ctx context.Context, runID string, spec runner.ExecSpec) (runner.Process, error) {
	p, err := b.svcBackend.Start(ctx, runID, spec)
	if err != nil || !strings.HasPrefix(spec.Name, "lazyagents-turn-") {
		return p, err
	}
	return nixProc{Process: p, manifest: b.manifest}, nil
}

// A repository nobody configured for Vesper: its CI Postgres becomes the
// turn's service before the first turn, and a tool the agent installs is
// remembered for the next run.
func TestTestEnvironmentIsInferredUsedAndLearned(t *testing.T) {
	e := setup(t)
	repo := t.TempDir()
	ci := "jobs:\n  test:\n    services:\n      postgres:\n        image: postgres:17-alpine\n        ports: [\"5432:5432\"]\n" +
		"    env:\n      TEST_DATABASE_URL: postgres://postgres:pw@localhost:5432/postgres\n"
	if err := os.MkdirAll(filepath.Join(repo, ".github", "workflows"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(repo, ".github", "workflows", "ci.yml"), []byte(ci), 0o644); err != nil {
		t.Fatal(err)
	}
	for _, args := range [][]string{{"init", "-q", "-b", "main"}, {"add", "."}, {"-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "ci"}} {
		if out, err := exec.Command("git", append([]string{"-C", repo}, args...)...).CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v %s", args, err, out)
		}
	}
	if _, err := e.pool.Exec(e.ctx, "UPDATE projects SET repo_url = $1, default_branch = 'main'", repo); err != nil {
		t.Fatal(err)
	}
	b := &learnBackend{svcBackend: &svcBackend{Fake: e.runner.Backend.(*runner.Fake)},
		manifest: []byte(`{"version":2,"elements":[{"attrPath":"legacyPackages.x86_64-linux.protobuf","originalUrl":"flake:nixpkgs"}]}`)}
	e.runner.Backend = b
	e.dispatch("PAY-214")
	e.until("waiting for approval", e.state("PAY-214=waiting"))

	b.mu.Lock()
	dbURL := b.turnEnv["TEST_DATABASE_URL"]
	b.mu.Unlock()
	if dbURL != "postgres://postgres:pw@postgres:5432/postgres" {
		t.Fatalf("turn TEST_DATABASE_URL = %q, want the inferred service by name", dbURL)
	}
	row, err := e.q.GetTestEnvironment(e.ctx, store.GetTestEnvironmentParams{WorkspaceID: e.ws, Repo: testenv.RepoKey(repo)})
	if err != nil {
		t.Fatal(err)
	}
	var rec testenv.Recipe
	if err := json.Unmarshal(row.Recipe, &rec); err != nil {
		t.Fatal(err)
	}
	if len(rec.Services) != 1 || rec.Services[0].Name != "postgres" || strings.Join(rec.NixPackages, ",") != "nixpkgs#protobuf" {
		t.Fatalf("recipe = %+v", rec)
	}
	if len(row.InferredFrom) != 1 || row.LearnedFromRunID == nil || *row.LearnedFromRunID != e.run("PAY-214").ID {
		t.Fatalf("provenance: inferred from %v, learned from %v", row.InferredFrom, row.LearnedFromRunID)
	}
	evs := e.eventTypes(e.run("PAY-214").ID)
	for _, want := range []string{"lifecycle:test_environment_inferred", "lifecycle:test_environment_learned"} {
		if !strings.Contains(evs, want) {
			t.Fatalf("no %s event: %s", want, evs)
		}
	}
}

// overlapBackend is svcBackend whose chat setup waits a while for the
// services to be started, recording whether they were.
type overlapBackend struct {
	*svcBackend
	servicesCalled chan struct{}
	once           sync.Once
	overlapped     bool
	failSetup      bool
}

func (b *overlapBackend) StartServices(ctx context.Context, runID, key string, services []agentdef.Service) (string, func(), error) {
	b.once.Do(func() { close(b.servicesCalled) })
	return b.svcBackend.StartServices(ctx, runID, key, services)
}

func (b *overlapBackend) Start(ctx context.Context, runID string, spec runner.ExecSpec) (runner.Process, error) {
	if strings.HasPrefix(spec.Name, "chat-repositories-") {
		select {
		case <-b.servicesCalled:
			b.mu.Lock()
			b.overlapped = true
			b.mu.Unlock()
		case <-time.After(5 * time.Second):
		}
		if b.failSetup {
			return nil, errors.New("setup could not start")
		}
	}
	return b.svcBackend.Start(ctx, runID, spec)
}

// codingChatWithRecipe is a coding chat on repo, whose test environment
// recipe (one Postgres service) is already known.
func codingChatWithRecipe(e env, repo string) uuid.UUID {
	e.t.Helper()
	if err := e.setOverride(agentdef.Override{Harness: agentdef.HarnessClaudeCode, Model: "opus-5.5"}); err != nil {
		e.t.Fatal(err)
	}
	p := e.persona("Pair", true, false, "https://github.com/acme/app")
	chat, err := e.runs.StartChat(e.ctx, e.ws, e.me.ID, runs.ChatInput{Project: "PAY", Title: "Code", PersonaID: &p.ID})
	if err != nil {
		e.t.Fatal(err)
	}
	if _, err := e.pool.Exec(e.ctx, `WITH attached AS (UPDATE chat_repositories SET repo_url=$2 WHERE chat_id=$1) UPDATE chat_sessions SET repo_url=$2 WHERE id=$1`, chat.ID, repo); err != nil {
		e.t.Fatal(err)
	}
	if _, err := e.pool.Exec(e.ctx, `UPDATE personas SET repos=ARRAY[$2]::text[] WHERE id=$1`, p.ID, repo); err != nil {
		e.t.Fatal(err)
	}
	recipe, _ := json.Marshal(testenv.Recipe{Services: []agentdef.Service{{Name: "postgres", Image: "postgres:17-alpine",
		Expose: map[string]string{"TEST_DATABASE_URL": "postgres://postgres@postgres:5432/postgres"}}}})
	if err := e.q.CreateInferredTestEnvironment(e.ctx, store.CreateInferredTestEnvironmentParams{
		WorkspaceID: e.ws, Repo: testenv.RepoKey(repo), Recipe: recipe, InferredFrom: []string{".github/workflows/ci.yml"},
	}); err != nil {
		e.t.Fatal(err)
	}
	return chat.ID
}

// A coding chat whose repository has a known recipe starts the turn's
// services while its checkout is prepared rather than after, and the turn
// still runs with them up.
func TestCodingChatStartsServicesDuringSetup(t *testing.T) {
	e := setup(t)
	t.Setenv("FAKE_HARNESS_MODE", "chat")
	chat := codingChatWithRecipe(e, bareRepo(t))
	b := &overlapBackend{svcBackend: &svcBackend{Fake: e.runner.Backend.(*runner.Fake)}, servicesCalled: make(chan struct{})}
	e.runner.Backend = b

	e.say(chat, "hello")

	b.mu.Lock()
	defer b.mu.Unlock()
	if !b.overlapped {
		t.Fatal("the chat's setup ran before its services were started")
	}
	if len(b.started) != 1 || b.stopped != 1 {
		t.Fatalf("services started %v, stopped %d times", b.started, b.stopped)
	}
	if b.turnEnv["TEST_DATABASE_URL"] != "postgres://postgres@postgres:5432/postgres" || len(b.turnNets) != 1 || b.turnNets[0] != "net-"+b.started[0] {
		t.Fatalf("turn env %q networks %v", b.turnEnv["TEST_DATABASE_URL"], b.turnNets)
	}
}

// Services started alongside a checkout that then fails are removed with
// the failed turn, which never runs the harness.
func TestCodingChatStopsServicesWhenSetupFails(t *testing.T) {
	e := setup(t)
	t.Setenv("FAKE_HARNESS_MODE", "chat")
	chat := codingChatWithRecipe(e, bareRepo(t))
	b := &overlapBackend{svcBackend: &svcBackend{Fake: e.runner.Backend.(*runner.Fake)}, servicesCalled: make(chan struct{}), failSetup: true}
	e.runner.Backend = b

	if _, err := e.runs.PostChatMessage(e.ctx, e.ws, e.me.ID, chat, runs.ChatMessageInput{Body: "hello"}); err != nil {
		t.Fatal(err)
	}
	e.until("the failed turn", func() bool { return e.chat(chat).State != "running" })

	b.mu.Lock()
	defer b.mu.Unlock()
	if b.turnEnv != nil {
		t.Fatal("the harness ran after its checkout failed")
	}
	if len(b.started) != 1 || b.stopped != 1 {
		t.Fatalf("services started %v, stopped %d times", b.started, b.stopped)
	}
}
