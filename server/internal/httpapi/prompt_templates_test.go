package httpapi

import (
	"net/http"
	"testing"
)

func TestPromptTemplatesCRUDAndScoping(t *testing.T) {
	e := newChatEnv(t)

	persona := e.want("POST", "/personas", map[string]any{"name": "Judy"}, http.StatusCreated)
	personaID := persona["id"].(string)
	space := e.want("POST", "/chat-spaces", map[string]any{"name": "Backend"}, http.StatusCreated)
	spaceID := space["id"].(string)

	// Built-in slash command slugs are rejected.
	e.want("POST", "/prompt-templates", map[string]any{
		"slug":  "compact",
		"title": "Override compact",
		"body":  "Nope",
	}, http.StatusUnprocessableEntity)

	// Create a personal template.
	personal := e.want("POST", "/prompt-templates", map[string]any{
		"slug":        "tldr",
		"title":       "TL;DR Summary",
		"description": "3-bullet summary",
		"body":        "Summarize in 3 crisp bullets:\n\n{{input}}",
	}, http.StatusCreated)
	personalID := personal["id"].(string)

	// Duplicate slug in same scope fails with 409.
	e.want("POST", "/prompt-templates", map[string]any{
		"slug":  "tldr",
		"title": "Duplicate",
		"body":  "Again",
	}, http.StatusConflict)

	// Same slug scoped to a persona is allowed.
	scoped := e.want("POST", "/prompt-templates", map[string]any{
		"slug":       "tldr",
		"title":      "Judy TL;DR",
		"body":       "Give me the engineering TL;DR of:\n\n{{clipboard}}",
		"persona_id": personaID,
	}, http.StatusCreated)
	scopedID := scoped["id"].(string)

	// Space-scoped template.
	spaceTpl := e.want("POST", "/prompt-templates", map[string]any{
		"slug":     "pr-check",
		"title":    "PR Checklist",
		"body":     "Review this PR for races & migrations: {{input}}",
		"space_id": spaceID,
	}, http.StatusCreated)
	spaceTplID := spaceTpl["id"].(string)

	// List all returns 3 templates.
	all := e.want("GET", "/prompt-templates", nil, http.StatusOK)
	if got := len(all["templates"].([]any)); got != 3 {
		t.Fatalf("expected 3 templates, got %d", got)
	}

	// Filter by persona_id returns personal + persona-scoped + space-scoped (unscoped by persona).
	byPersona := e.want("GET", "/prompt-templates?persona_id="+personaID, nil, http.StatusOK)
	if got := len(byPersona["templates"].([]any)); got != 3 {
		t.Fatalf("expected 3 templates matching persona filter, got %d", got)
	}

	// Update title and clear persona scope (fails if slug collides with personal "tldr").
	e.want("PATCH", "/prompt-templates/"+scopedID, map[string]any{
		"persona_id": nil,
	}, http.StatusConflict)

	updated := e.want("PATCH", "/prompt-templates/"+spaceTplID, map[string]any{
		"title": "Backend PR Checklist",
	}, http.StatusOK)
	if updated["title"] != "Backend PR Checklist" {
		t.Fatalf("expected updated title, got %v", updated["title"])
	}

	// Delete personal template and confirm count drops.
	e.want("DELETE", "/prompt-templates/"+personalID, nil, http.StatusNoContent)
	after := e.want("GET", "/prompt-templates", nil, http.StatusOK)
	if got := len(after["templates"].([]any)); got != 2 {
		t.Fatalf("expected 2 templates after delete, got %d", got)
	}
}
