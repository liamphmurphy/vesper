package agentdef

import (
	"errors"
	"reflect"
	"strings"
	"testing"
)

func base() Spec {
	s := Spec{
		Harness: HarnessClaudeCode, Model: "opus-5.5", Instructions: "You own backend changes.\n",
		Scopes: map[string]Mode{
			"repo:write": Allowed, "tests:run": Allowed, "db:migrate": RequiresApproval, "deploy:staging": Denied,
		},
		Budget:         Budget{MaxRuntime: "2h", MaxTurns: 20},
		MCPServers:     []MCPServer{{Name: "context7", URL: "https://mcp.context7.com/mcp"}},
		HarnessOptions: map[string]map[string]string{"claude-code": {"permission_mode": "acceptEdits"}, "codex": {"sandbox": "workspace-write"}},
	}
	if err := s.Normalize(); err != nil {
		panic(err)
	}
	return s
}

func scopes(r Resolved) map[string]Mode {
	m := map[string]Mode{}
	for _, s := range r.Scopes {
		m[s.Scope] = s.Mode
	}
	return m
}

func TestResolveWithoutOverrideIsTheAgent(t *testing.T) {
	r := Resolve(base(), nil)
	if r.Harness != "claude-code" || r.Model != "opus-5.5" || len(r.Provenance) != 0 {
		t.Fatalf("resolved = %+v", r)
	}
	if r.HarnessOptions["permission_mode"] != "acceptEdits" || r.HarnessOptions["sandbox"] != "" {
		t.Fatalf("only the resolved harness's options should apply: %v", r.HarnessOptions)
	}
}

func TestProjectsCanOnlyTighten(t *testing.T) {
	o := &Override{Scopes: map[string]Mode{
		"repo:write":     Denied,  // tighten: applies
		"db:migrate":     Allowed, // loosen: ignored
		"deploy:staging": Allowed, // loosen: ignored
		"tests:run":      RequiresApproval,
		"secrets:read":   Allowed, // the agent never granted it: stays denied
	}}
	if err := o.Normalize(); err != nil {
		t.Fatal(err)
	}
	r := Resolve(base(), o)
	want := map[string]Mode{
		"repo:write": Denied, "db:migrate": RequiresApproval, "deploy:staging": Denied,
		"tests:run": RequiresApproval, "secrets:read": Denied,
	}
	if got := scopes(r); !reflect.DeepEqual(got, want) {
		t.Fatalf("scopes = %v\nwant     %v", got, want)
	}
	for _, s := range r.Scopes {
		wantSrc := FromProject
		if s.Scope == "db:migrate" || s.Scope == "deploy:staging" {
			wantSrc = FromAgent // the project's looser value didn't take
		}
		if s.Source != wantSrc {
			t.Errorf("%s source = %s, want %s", s.Scope, s.Source, wantSrc)
		}
	}
}

func TestWildcardDenialCoversMatchingScopes(t *testing.T) {
	s := base()
	s.Scopes["prod:read"] = Allowed
	s.Scopes["prod:deploy"] = RequiresApproval
	o := &Override{Scopes: map[string]Mode{"prod:*": Denied}}
	r := Resolve(s, o)
	for _, sc := range []string{"prod:read", "prod:deploy", "prod:anything-later"} {
		if m := r.Mode(sc); m != Denied {
			t.Errorf("%s = %s, want denied", sc, m)
		}
	}
	if r.Mode("repo:write") != Allowed {
		t.Error("wildcard leaked onto another prefix")
	}
	// An agent-level wildcard can't be loosened by a project's exact scope.
	s2 := base()
	s2.Scopes["prod:*"] = Denied
	r2 := Resolve(s2, &Override{Scopes: map[string]Mode{"prod:read": Allowed}})
	if r2.Mode("prod:read") != Denied {
		t.Error("project loosened an agent wildcard")
	}
}

func TestScalarsAppendsAndBudget(t *testing.T) {
	o := &Override{
		Harness: "codex", InstructionsAppend: "Follow ADR-012 for partitioning.",
		MCPServersAdd: []MCPServer{{Name: "postgres-staging", URL: "https://pg.internal/mcp"}, {Name: "context7", URL: "https://evil.example/mcp"}},
		Budget:        Budget{MaxRuntime: "3h", MaxTurns: 10}, // runtime looser (ignored), turns tighter (applies)
		Setup:         []string{"make deps"},
	}
	if err := o.Normalize(); err != nil {
		t.Fatal(err)
	}
	r := Resolve(base(), o)
	if r.Harness != "codex" || r.HarnessOptions["sandbox"] != "workspace-write" || r.HarnessOptions["permission_mode"] != "" {
		t.Fatalf("harness swap: %s %v", r.Harness, r.HarnessOptions)
	}
	if r.Instructions != "You own backend changes.\n\nFollow ADR-012 for partitioning.\n" {
		t.Fatalf("instructions = %q", r.Instructions)
	}
	if len(r.MCPServers) != 2 || r.MCPServers[0].URL != "https://mcp.context7.com/mcp" || r.MCPServers[1].Name != "postgres-staging" {
		t.Fatalf("a project may add servers but not redefine the agent's: %+v", r.MCPServers)
	}
	if r.Budget != (Budget{MaxRuntime: "2h", MaxTurns: 10}) {
		t.Fatalf("budget = %+v", r.Budget)
	}
	for _, f := range []string{"harness", "instructions", "mcp_servers", "budget", "setup"} {
		if r.Provenance[f] != FromProject {
			t.Errorf("provenance[%s] = %q", f, r.Provenance[f])
		}
	}
}

func TestValidation(t *testing.T) {
	cases := map[string]Spec{
		"harness":  {Harness: "aider", Model: "x"},
		"model":    {Harness: "codex"},
		"scope":    {Model: "x", Scopes: map[string]Mode{"Repo Write": Allowed}},
		"mode":     {Model: "x", Scopes: map[string]Mode{"repo:write": "sometimes"}},
		"budget":   {Model: "x", Budget: Budget{MaxRuntime: "two hours"}},
		"reserved": {Model: "x", MCPServers: []MCPServer{{Name: "lazyagents", URL: "http://x"}}},
		"url":      {Model: "x", MCPServers: []MCPServer{{Name: "files", URL: "file:///etc"}}},
	}
	for name, s := range cases {
		if err := s.Normalize(); err == nil {
			t.Errorf("%s: want error", name)
		}
	}
	ok := Spec{Model: "opus-5.5"}
	if err := ok.Normalize(); err != nil || ok.Harness != HarnessClaudeCode || ok.MaxConcurrency != 1 {
		t.Fatalf("defaults: %+v %v", ok, err)
	}
}

func TestEnforcement(t *testing.T) {
	cases := []struct {
		scope   string
		mode    Mode
		harness string
		want    Enforcement
	}{
		{"db:migrate", RequiresApproval, HarnessClaudeCode, ByBroker},
		{"repo:write", Allowed, HarnessCodex, ByCredential},
		{"tests:run", Allowed, HarnessClaudeCode, ByHarness},
		{"tests:run", Allowed, HarnessCodex, ByHarness},
		{"tests:run", RequiresApproval, HarnessClaudeCode, ByHarness},
		{"tests:run", RequiresApproval, HarnessCodex, ByHarness},
		{"tests:run", RequiresApproval, HarnessAntigravity, ByHarness},
		{"deploy:staging", Denied, HarnessClaudeCode, ByCredential},
	}
	for _, c := range cases {
		if got, _ := EnforcementFor(c.scope, c.mode, c.harness); got != c.want {
			t.Errorf("%s %s on %s = %s, want %s", c.scope, c.mode, c.harness, got, c.want)
		}
	}
}

func TestChanges(t *testing.T) {
	o := Override{Harness: "codex", Scopes: map[string]Mode{"prod:*": Denied}, InstructionsAppend: "Follow ADR-012.\nMore."}
	want := []string{"harness → codex", "+ instructions: “Follow ADR-012.”", "prod:* → denied"}
	if got := o.Changes(); !reflect.DeepEqual(got, want) {
		t.Fatalf("Changes = %q", got)
	}
}

func TestSkillValidation(t *testing.T) {
	ok := Skill{Name: "go-errors", Description: "  Use when\nhandling errors ", Body: "  body \n"}
	s := base()
	s.Skills = []Skill{ok}
	if err := s.Normalize(); err != nil {
		t.Fatal(err)
	}
	if got := s.Skills[0]; got.Description != "Use when handling errors" || got.Body != "body" {
		t.Fatalf("not normalized: %+v", got)
	}
	if r := Resolve(s, nil); len(r.Skills) != 1 || r.Skills[0].Name != "go-errors" {
		t.Fatalf("resolved skills %+v", r.Skills)
	}
	for name, sk := range map[string][]Skill{
		"bad name":    {{Name: "Go Errors", Description: "d", Body: "b"}},
		"no desc":     {{Name: "a", Body: "b"}},
		"no body":     {{Name: "a", Description: "d"}},
		"duplicate":   {ok, ok},
		"huge body":   {{Name: "a", Description: "d", Body: string(make([]byte, MaxSkillBodyBytes+1))}},
		"path escape": {{Name: "../x", Description: "d", Body: "b"}},
	} {
		s := base()
		s.Skills = sk
		if s.Normalize() == nil {
			t.Errorf("%s: accepted", name)
		}
	}
}

func sk(name string) Skill {
	return Skill{Name: name, Description: "Use when " + name, Body: "body " + name}
}

func skillNames(r Resolved) []string {
	out := []string{}
	for _, k := range r.Skills {
		out = append(out, k.Name)
	}
	return out
}

func withSkills(names ...string) Spec {
	s := base()
	for _, n := range names {
		s.Skills = append(s.Skills, sk(n))
	}
	return s
}

func TestSkillOverrides(t *testing.T) {
	s := withSkills("a", "b", "c")
	cases := []struct {
		name     string
		o        Override
		want     []string
		provence bool
	}{
		{"add", Override{SkillsAdd: []Skill{sk("x"), sk("y")}}, []string{"a", "b", "c", "x", "y"}, true},
		{"remove", Override{SkillsRemove: []string{"b"}}, []string{"a", "c"}, true},
		{"unknown remove", Override{SkillsRemove: []string{"zzz"}}, []string{"a", "b", "c"}, false},
		{"collision skipped", Override{SkillsAdd: []Skill{{Name: "a", Description: "d", Body: "other"}}}, []string{"a", "b", "c"}, false},
		{"replace goes last", Override{SkillsRemove: []string{"a"}, SkillsAdd: []Skill{{Name: "a", Description: "d", Body: "new"}}}, []string{"b", "c", "a"}, true},
	}
	for _, c := range cases {
		o := c.o
		if err := o.Normalize(); err != nil {
			t.Fatalf("%s: %v", c.name, err)
		}
		r := Resolve(s, &o)
		if got := skillNames(r); !reflect.DeepEqual(got, c.want) {
			t.Errorf("%s: skills = %v, want %v", c.name, got, c.want)
		}
		if got := r.Provenance["skills"] == FromProject; got != c.provence {
			t.Errorf("%s: provenance project = %v, want %v", c.name, got, c.provence)
		}
	}
	// The replacement carries the new content.
	o := Override{SkillsRemove: []string{"a"}, SkillsAdd: []Skill{{Name: "a", Description: "d", Body: "new"}}}
	if r := Resolve(s, &o); r.Skills[2].Body != "new" {
		t.Fatalf("replacement body = %q", r.Skills[2].Body)
	}
	// Resolve must not mutate the agent's skills.
	if len(s.Skills) != 3 || s.Skills[0].Name != "a" {
		t.Fatalf("agent skills mutated: %+v", s.Skills)
	}
}

func TestSkillOverrideCap(t *testing.T) {
	var names []string
	for i := 0; i < MaxSkills-1; i++ {
		names = append(names, "agent"+itoa(i))
	}
	s := withSkills(names...)
	o := Override{SkillsAdd: []Skill{sk("p1"), sk("p2"), sk("p3")}}
	r := Resolve(s, &o)
	if len(r.Skills) != MaxSkills || r.Skills[MaxSkills-1].Name != "p1" || r.Skills[0].Name != "agent0" {
		t.Fatalf("cap: len=%d last=%s", len(r.Skills), r.Skills[len(r.Skills)-1].Name)
	}
	// Adds that are all truncated leave the list unchanged: no provenance.
	full := withSkills(append(names, "last")...)
	if r := Resolve(full, &o); len(r.Skills) != MaxSkills || r.Provenance["skills"] == FromProject {
		t.Fatalf("full list: len=%d prov=%v", len(r.Skills), r.Provenance)
	}
}

func TestSkillOverrideNormalizeAndEmpty(t *testing.T) {
	for name, o := range map[string]Override{
		"bad add":       {SkillsAdd: []Skill{{Name: "Bad Name", Description: "d", Body: "b"}}},
		"bad remove":    {SkillsRemove: []string{"../x"}},
		"dup remove":    {SkillsRemove: []string{"a", "a"}},
		"empty remove":  {SkillsRemove: []string{""}},
		"too many adds": {SkillsAdd: make([]Skill, MaxSkills+1)},
	} {
		err := o.Normalize()
		var ve *ValidationError
		if !errors.As(err, &ve) {
			t.Errorf("%s: err = %v", name, err)
			continue
		}
		want := "skills_add"
		if strings.Contains(name, "remove") {
			want = "skills_remove"
		}
		if ve.Field != want {
			t.Errorf("%s: field = %s, want %s", name, ve.Field, want)
		}
	}
	if (Override{SkillsAdd: []Skill{sk("x")}}).Empty() || (Override{SkillsRemove: []string{"x"}}).Empty() || !(Override{}).Empty() {
		t.Fatal("Empty ignores skills")
	}
}

func TestSkillChanges(t *testing.T) {
	o := Override{SkillsRemove: []string{"a", "b"}, SkillsAdd: []Skill{sk("x")}}
	want := []string{"− skill a", "− skill b", "+ skill x"}
	if got := o.Changes(); !reflect.DeepEqual(got, want) {
		t.Fatalf("Changes = %q", got)
	}
}

func TestEffortOption(t *testing.T) {
	for _, e := range Efforts {
		s := base()
		s.HarnessOptions = map[string]map[string]string{HarnessCodex: {"effort": e}}
		if err := s.Normalize(); err != nil {
			t.Errorf("effort %q: %v", e, err)
		}
	}
	s := base()
	s.HarnessOptions = map[string]map[string]string{HarnessClaudeCode: {"effort": "extreme"}}
	var ve *ValidationError
	if err := s.Normalize(); !errors.As(err, &ve) || ve.Field != "harness_options" {
		t.Fatalf("bad effort = %v", err)
	}
	s = base()
	s.HarnessOptions = map[string]map[string]string{HarnessClaudeCode: {"other": "x"}}
	if err := s.Normalize(); err != nil {
		t.Fatalf("unknown options must stay accepted: %v", err)
	}
}

func TestResolvedValidateRejectsUnknownHarness(t *testing.T) {
	ok := Resolved{Harness: HarnessCodex, Fallbacks: []Fallback{{Harness: HarnessClaudeCode, Model: "m"}}}
	if err := ok.Validate(); err != nil {
		t.Fatal(err)
	}
	if err := (Resolved{Harness: "gone"}).Validate(); err == nil {
		t.Fatal("unknown primary harness accepted")
	}
	if err := (Resolved{Harness: HarnessCodex, Fallbacks: []Fallback{{Harness: "gone", Model: "m"}}}).Validate(); err == nil {
		t.Fatal("unknown fallback harness accepted")
	}
}
