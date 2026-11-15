package agents

import (
	"context"
	"fmt"
	"strings"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/store"
)

// Hues are the agent palette (web/styles/tokens.css --agent-*, light theme) in color_index
// order: the colour a work record's persona takes, and the hue a persona's runs show.
var Hues = [...]string{"#4547c9", "#0b7a6e", "#b42f48", "#1d5fb0", "#8a6100", "#277538", "#a44a18", "#6c3bb8"}

// HueColor is the palette colour for a color_index.
func HueColor(i int) string { return Hues[((i%len(Hues))+len(Hues))%len(Hues)] }

// NearestHue is the color_index whose colour is closest to a #rrggbb persona colour.
func NearestHue(color string) int {
	rgb := func(h string) (int, int, int) {
		var r, g, b int
		fmt.Sscanf(strings.TrimPrefix(h, "#"), "%02x%02x%02x", &r, &g, &b)
		return r, g, b
	}
	r, g, b := rgb(color)
	best, bestD := 0, 1<<30
	for i, h := range Hues {
		hr, hg, hb := rgb(h)
		if d := (r-hr)*(r-hr) + (g-hg)*(g-hg) + (b-hb)*(b-hb); d < bestD {
			best, bestD = i, d
		}
	}
	return best
}

// GivePersona makes the persona of a work record created outside one (the seed, POST
// /agents), owned by owner, with the record's id and name ("Name 2"… when the owner already
// has a persona by that name). Agents and personas are one actor (migration 00134).
func GivePersona(ctx context.Context, q *store.Queries, a store.Agent, owner uuid.UUID) error {
	name := a.Name
	for n := 2; ; n++ {
		taken, err := q.PersonaNameTaken(ctx, store.PersonaNameTakenParams{WorkspaceID: a.WorkspaceID, UserID: owner, Name: name})
		if err != nil {
			return err
		}
		if !taken {
			break
		}
		if n > 99 {
			return fmt.Errorf("no free persona name for %q", a.Name)
		}
		name = fmt.Sprintf("%s %d", a.Name, n)
	}
	harness, model, effort := "", "", ""
	if spec, _, err := CurrentSpec(ctx, q, a); err == nil {
		harness, model, effort = spec.Harness, spec.Model, spec.Effort()
	}
	_, err := q.CreatePersonaForAgent(ctx, store.CreatePersonaForAgentParams{
		ID: a.ID, WorkspaceID: a.WorkspaceID, UserID: owner, Name: name, Color: HueColor(int(a.ColorIndex)),
		DefaultHarness: harness, DefaultModel: model, DefaultEffort: effort,
	})
	return err
}
