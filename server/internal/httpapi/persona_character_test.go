package httpapi

import (
	"bytes"
	"context"
	"encoding/base64"
	"errors"
	"net/http"
	"strings"
	"testing"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/personas"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

const testCharacterSVG = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" fill="none">
  <title>Sparky</title>
  <ellipse data-part="shadow" data-motion="shadow" data-pivot="32 58" cx="32" cy="58" rx="14" ry="3" fill="#000" opacity="0.22"/>
  <g data-part="body" data-pivot="32 36" data-motion-idle="breathe" data-motion-reading="nod" data-motion-coding="type" data-motion-creating="bounce" data-motion-needs-you="wave">
    <circle cx="32" cy="36" r="16" fill="currentColor"/>
    <g data-part="eyes" data-motion="blink" data-motion-reading="glance">
      <circle cx="26" cy="34" r="2" fill="#18181b"/>
      <circle cx="38" cy="34" r="2" fill="#18181b"/>
    </g>
    <path data-show="coding creating" data-motion="spark" data-pivot="50 18" d="M50 12l2 4 4 2-4 2-2 4-2-4-4-2 4-2z" fill="#ffd6a0"/>
  </g>
</svg>`

const testCharacterSVGv2 = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" fill="none">
  <title>Sparky v2</title>
  <g data-part="body" data-pivot="32 34" data-motion-idle="float" data-motion-coding="tap">
    <rect x="16" y="18" width="32" height="32" rx="10" fill="currentColor"/>
    <circle cx="26" cy="32" r="2.2" fill="#18181b"/>
    <circle cx="38" cy="32" r="2.2" fill="#18181b"/>
  </g>
</svg>`

func TestPersonaCharacterUploadDeleteAndFallbackPNG(t *testing.T) {
	e, fake := newAvatarEnv(t)
	p := e.want("POST", "/personas", map[string]any{"name": "Sparky", "color": "#8b8fff"}, http.StatusCreated)
	id := p["id"].(string)
	chat := e.newChat(map[string]any{"persona_id": id})
	prefix := avatarBucket + "/personas/" + e.me.WorkspaceID.String() + "/" + e.me.ID.String() + "/" + id + "/"

	pngBytes := avatarPNG(t)
	pngB64 := base64.StdEncoding.EncodeToString(pngBytes)

	// Invalid SVG is rejected with 422 before storing any fallback blob.
	e.invalid("PUT", "/personas/"+id+"/character", map[string]any{
		"character_svg":       `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><script>alert(1)</script></svg>`,
		"fallback_png_base64": pngB64,
	}, "character_svg", "allowed")
	if keys := fake.keys(prefix); len(keys) != 0 {
		t.Fatalf("invalid character stored blob %v", keys)
	}

	// Valid character + PNG fallback sets both character_svg and avatar_url.
	got := e.want("PUT", "/personas/"+id+"/character", map[string]any{
		"character_svg":       testCharacterSVG,
		"fallback_png_base64": pngB64,
	}, 200)
	if got["character_svg"] != testCharacterSVG || got["avatar_url"] == nil || got["revision"].(float64) != 2 {
		t.Fatalf("set character = %v", got)
	}
	res, body := e.getAvatar(id)
	if res.StatusCode != 200 || res.Header.Get("Content-Type") != "image/png" || !bytes.Equal(body, pngBytes) {
		t.Fatalf("fallback avatar = %d %q (%d bytes)", res.StatusCode, res.Header.Get("Content-Type"), len(body))
	}
	// Chat summary reports has_character without embedding the full SVG.
	summary := e.want("GET", "/chats/"+chat["id"].(string), nil, 200)["persona"].(map[string]any)
	if summary["has_character"] != true || summary["avatar_url"] != got["avatar_url"] {
		t.Fatalf("chat summary = %v", summary)
	}
	if _, leaked := summary["character_svg"]; leaked {
		t.Fatalf("chat summary embedded character_svg: %v", summary)
	}

	// Uploading a raster photo replaces the character and clears character_svg.
	jpegImg := avatarJPEG(t)
	code, photo := e.uploadAvatar(id, "photo.jpg", "image/jpeg", jpegImg)
	if code != 200 || photo["character_svg"] != nil {
		t.Fatalf("upload photo = %d %v", code, photo)
	}
	// Deleting character while using a photo is a no-op that preserves the photo.
	stillPhoto := e.want("DELETE", "/personas/"+id+"/character", nil, 200)
	if stillPhoto["avatar_url"] == nil || stillPhoto["revision"] != photo["revision"] {
		t.Fatalf("delete character touched photo: %v", stillPhoto)
	}

	// Switching back to a character, then deleting avatar clears both character and fallback.
	got2 := e.want("PUT", "/personas/"+id+"/character", map[string]any{
		"character_svg":       testCharacterSVGv2,
		"fallback_png_base64": pngB64,
	}, 200)
	if got2["character_svg"] != testCharacterSVGv2 || len(fake.keys(prefix)) != 1 {
		t.Fatalf("re-set character = %v, keys=%v", got2, fake.keys(prefix))
	}
	cleared := e.want("DELETE", "/personas/"+id+"/avatar", nil, 200)
	if cleared["avatar_url"] != nil || cleared["character_svg"] != nil || len(fake.keys(prefix)) != 0 {
		t.Fatalf("delete avatar left character/blob: %v, keys=%v", cleared, fake.keys(prefix))
	}

	// Setting character without fallback PNG, then DELETE /character clears it cleanly.
	got3 := e.want("PUT", "/personas/"+id+"/character", map[string]any{"character_svg": testCharacterSVG}, 200)
	if got3["character_svg"] != testCharacterSVG || got3["avatar_url"] != nil {
		t.Fatalf("set without fallback = %v", got3)
	}
	delChar := e.want("DELETE", "/personas/"+id+"/character", nil, 200)
	if delChar["character_svg"] != nil || delChar["revision"].(float64) != got3["revision"].(float64)+1 {
		t.Fatalf("delete character = %v", delChar)
	}
	// Idempotent second delete.
	again := e.want("DELETE", "/personas/"+id+"/character", nil, 200)
	if again["revision"] != delChar["revision"] {
		t.Fatalf("second delete bumped revision: %v", again)
	}

	// Stranger / missing persona is 404.
	stranger := e.strangerPersona()
	for _, target := range []string{stranger, uuid.NewString()} {
		e.want("PUT", "/personas/"+target+"/character", map[string]any{"character_svg": testCharacterSVG}, http.StatusNotFound)
		e.want("DELETE", "/personas/"+target+"/character", nil, http.StatusNotFound)
	}
}

func TestPersonaCharacterProposalFlow(t *testing.T) {
	e, fake := newAvatarEnv(t)
	ctx := context.Background()
	ws := e.me.WorkspaceID
	svc := &personas.Service{Pool: e.pool}
	owner := personas.Owner{WorkspaceID: ws, UserID: e.me.ID}

	sparky, err := svc.Create(ctx, owner, personas.NewInput{Name: "Sparky"})
	if err != nil {
		t.Fatal(err)
	}
	buddy, err := svc.Create(ctx, owner, personas.NewInput{Name: "Buddy"})
	if err != nil {
		t.Fatal(err)
	}
	chat, err := e.runs.StartChat(ctx, ws, e.me.ID, runs.ChatInput{
		Project:   "PAY",
		PersonaID: &sparky.ID,
		Message:   &runs.ChatMessageInput{Body: "design yourself a character"},
	})
	if err != nil {
		t.Fatal(err)
	}
	chat, _ = e.q.GetChatSession(ctx, store.GetChatSessionParams{ID: chat.ID, WorkspaceID: ws})
	runID := *chat.CurrentRunID
	if _, err := e.pool.Exec(ctx, "UPDATE runs SET state='running' WHERE id=$1", runID); err != nil {
		t.Fatal(err)
	}

	// Unknown target persona fails validation cleanly.
	var ve *apperr.ValidationError
	if _, _, err := e.runs.ProposePersonaCharacter(ctx, ws, runID, runs.PersonaCharacterProposalInput{
		PersonaName: "Ghost", SVG: testCharacterSVG,
	}); !errors.As(err, &ve) || ve.Field != "persona" {
		t.Fatalf("expected validation error for unknown persona, got %v", err)
	}

	// Propose first draft (defaults to Sparky as speaker).
	p1, target1, err := e.runs.ProposePersonaCharacter(ctx, ws, runID, runs.PersonaCharacterProposalInput{
		SVG: testCharacterSVG, Summary: "First draft",
	})
	if err != nil || target1.ID != sparky.ID || p1.State != "pending" {
		t.Fatalf("first proposal = %+v, target=%+v, err=%v", p1, target1, err)
	}

	// Dock sees waiting_approval=true while a character proposal is pending.
	dock := e.want("GET", "/persona-dock", nil, 200)
	entries := dock["personas"].([]any)
	if len(entries) == 0 || !entries[0].(map[string]any)["chats"].([]any)[0].(map[string]any)["waiting_approval"].(bool) {
		t.Fatalf("dock did not report waiting_approval for pending character proposal: %v", dock)
	}

	// Re-proposing for Sparky supersedes p1.
	p2, _, err := e.runs.ProposePersonaCharacter(ctx, ws, runID, runs.PersonaCharacterProposalInput{
		SVG: testCharacterSVGv2, Summary: "Sharper silhouette",
	})
	if err != nil {
		t.Fatal(err)
	}
	list := e.want("GET", "/chats/"+chat.ID.String()+"/persona-character-proposals", nil, 200)["proposals"].([]any)
	if len(list) != 2 {
		t.Fatalf("expected 2 proposals, got %d", len(list))
	}
	if list[0].(map[string]any)["state"] != "superseded" || list[1].(map[string]any)["state"] != "pending" {
		t.Fatalf("unexpected states: %v", list)
	}
	// Superseded proposal cannot be approved.
	if code, _ := e.do("POST", "/chats/"+chat.ID.String()+"/persona-character-proposals/"+p1.ID.String(), map[string]any{"decision": "approve"}); code != http.StatusConflict {
		t.Fatalf("approving superseded proposal returned %d, want 409", code)
	}

	// Approve p2 with fallback PNG.
	pngBytes := avatarPNG(t)
	pngB64 := base64.StdEncoding.EncodeToString(pngBytes)
	approved := e.want("POST", "/chats/"+chat.ID.String()+"/persona-character-proposals/"+p2.ID.String(), map[string]any{
		"decision":            "approve",
		"fallback_png_base64": pngB64,
	}, 200)
	if approved["state"] != "approved" {
		t.Fatalf("approved = %v", approved)
	}
	gotSparky := e.want("GET", "/personas/"+sparky.ID.String(), nil, 200)
	if gotSparky["character_svg"] != testCharacterSVGv2 || gotSparky["avatar_url"] == nil {
		t.Fatalf("sparky after approval = %v", gotSparky)
	}
	if res, body := e.getAvatar(sparky.ID.String()); res.StatusCode != 200 || !bytes.Equal(body, pngBytes) {
		t.Fatalf("sparky fallback PNG = %d (%d bytes)", res.StatusCode, len(body))
	}
	if keys := fake.keys(avatarBucket + "/"); len(keys) != 1 {
		t.Fatalf("expected 1 stored fallback blob, got %v", keys)
	}

	// Propose for Buddy by name (case-insensitive) and decline.
	pBuddy, targetBuddy, err := e.runs.ProposePersonaCharacter(ctx, ws, runID, runs.PersonaCharacterProposalInput{
		PersonaName: "buddy", SVG: testCharacterSVG, Summary: "For Buddy",
	})
	if err != nil || targetBuddy.ID != buddy.ID {
		t.Fatalf("buddy proposal = %+v %+v %v", pBuddy, targetBuddy, err)
	}
	declined := e.want("POST", "/chats/"+chat.ID.String()+"/persona-character-proposals/"+pBuddy.ID.String(), map[string]any{
		"decision": "decline",
	}, 200)
	if declined["state"] != "declined" {
		t.Fatalf("declined = %v", declined)
	}
	gotBuddy := e.want("GET", "/personas/"+buddy.ID.String(), nil, 200)
	if _, ok := gotBuddy["character_svg"]; ok {
		t.Fatalf("declined proposal mutated Buddy: %v", gotBuddy)
	}
}

func TestProposePersonaWithCharacterSVG(t *testing.T) {
	e, fake := newAvatarEnv(t)
	ctx := context.Background()
	ws := e.me.WorkspaceID
	yes := true
	maker, err := (&personas.Service{Pool: e.pool}).Create(ctx, personas.Owner{WorkspaceID: ws, UserID: e.me.ID}, personas.NewInput{
		Name: "Maker", Images: &yes, Personas: &yes,
	})
	if err != nil {
		t.Fatal(err)
	}
	chat, err := e.runs.StartChat(ctx, ws, e.me.ID, runs.ChatInput{
		Project: "PAY", PersonaID: &maker.ID, Message: &runs.ChatMessageInput{Body: "make Sprite with an SVG character"},
	})
	if err != nil {
		t.Fatal(err)
	}
	chat, _ = e.q.GetChatSession(ctx, store.GetChatSessionParams{ID: chat.ID, WorkspaceID: ws})
	runID := *chat.CurrentRunID
	if _, err := e.pool.Exec(ctx, "UPDATE runs SET state='running', harness='claude' WHERE id=$1", runID); err != nil {
		t.Fatal(err)
	}
	if _, err := e.pool.Exec(ctx, "UPDATE run_turns SET status='running', ended_at=NULL WHERE run_id=$1", runID); err != nil {
		t.Fatal(err)
	}

	// Cannot combine avatar_prompt and character_svg.
	if _, err := e.runs.ProposePersona(ctx, ws, runID, runs.PersonaProposalInput{
		Name: "Sprite", AvatarPrompt: "a sprite", CharacterSVG: testCharacterSVG,
	}); err == nil || !strings.Contains(err.Error(), "not both") {
		t.Fatalf("expected mutual exclusivity error, got %v", err)
	}

	prop, err := e.runs.ProposePersona(ctx, ws, runID, runs.PersonaProposalInput{
		Name: "Sprite", Tone: "playful", Color: "#4fd1c5", Instructions: "Be nimble.", Reason: "For UI craft.", CharacterSVG: testCharacterSVG,
	})
	if err != nil || prop.CharacterSvg == nil {
		t.Fatalf("propose = %+v %v", prop, err)
	}

	pngBytes := avatarPNG(t)
	pngB64 := base64.StdEncoding.EncodeToString(pngBytes)
	out := e.want("POST", "/chats/"+chat.ID.String()+"/persona-proposals/"+prop.ID.String(), map[string]any{
		"decision":            "approve",
		"fallback_png_base64": pngB64,
	}, 200)
	persona, _ := out["persona"].(map[string]any)
	if persona == nil || persona["has_character"] != true || persona["avatar_url"] == nil {
		t.Fatalf("approved persona summary = %v", out)
	}
	got := e.want("GET", "/personas/"+persona["id"].(string), nil, 200)
	if got["character_svg"] != testCharacterSVG {
		t.Fatalf("created persona character_svg = %v", got)
	}
	if res, body := e.getAvatar(persona["id"].(string)); res.StatusCode != 200 || !bytes.Equal(body, pngBytes) {
		t.Fatalf("created persona fallback avatar = %d (%d bytes)", res.StatusCode, len(body))
	}
	if keys := fake.keys(avatarBucket + "/"); len(keys) != 1 {
		t.Fatalf("expected 1 fallback blob, got %v", keys)
	}
}
