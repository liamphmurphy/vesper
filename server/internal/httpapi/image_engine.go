package httpapi

import (
	"context"

	"github.com/liamphmurphy/vesper/server/internal/api"
)

func (s *Server) imageEngineSettings(ctx context.Context) (api.ImageEngineSettings, error) {
	_, _, ws := me(ctx)
	engine, err := s.Runs.WorkspaceImageEngine(ctx, ws)
	if err != nil {
		return api.ImageEngineSettings{}, err
	}
	opts, err := s.Runs.ImageEngineOptions(ctx, ws)
	if err != nil {
		return api.ImageEngineSettings{}, err
	}
	out := api.ImageEngineSettings{Engine: api.ImageEngineSettingsEngine(engine), Options: make([]struct {
		Available bool                                 `json:"available"`
		Engine    api.ImageEngineSettingsOptionsEngine `json:"engine"`
		Label     string                               `json:"label"`
		Model     *string                              `json:"model,omitempty"`
		Reason    *string                              `json:"reason,omitempty"`
	}, len(opts))}
	for i, o := range opts {
		out.Options[i].Engine, out.Options[i].Label, out.Options[i].Available = api.ImageEngineSettingsOptionsEngine(o.Engine), o.Label, o.Available
		if o.Reason != "" {
			reason := o.Reason
			out.Options[i].Reason = &reason
		}
		if o.Model != "" {
			model := o.Model
			out.Options[i].Model = &model
		}
	}
	return out, nil
}

func (s *Server) GetImageEngine(ctx context.Context, _ api.GetImageEngineRequestObject) (api.GetImageEngineResponseObject, error) {
	out, err := s.imageEngineSettings(ctx)
	return api.GetImageEngine200JSONResponse(out), err
}

func (s *Server) UpdateImageEngine(ctx context.Context, req api.UpdateImageEngineRequestObject) (api.UpdateImageEngineResponseObject, error) {
	_, _, ws := me(ctx)
	if err := s.Runs.SetWorkspaceImageEngine(ctx, ws, string(req.Body.Engine)); err != nil {
		return nil, err
	}
	out, err := s.imageEngineSettings(ctx)
	return api.UpdateImageEngine200JSONResponse(out), err
}
