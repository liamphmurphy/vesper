package httpapi

import (
	"context"

	"github.com/liamphmurphy/vesper/server/internal/api"
	"github.com/liamphmurphy/vesper/server/internal/media"
	"github.com/liamphmurphy/vesper/server/internal/media/providers/gemini"
	"github.com/liamphmurphy/vesper/server/internal/secrets"
)

func defaultMediaRegistry() *media.Registry {
	reg := media.NewRegistry()
	gemini.Register(reg)
	media.RegisterLocalMLXPlaceholder(reg)
	return reg
}

func (s *Server) mediaRegistry() *media.Registry {
	if s.MediaRegistry != nil {
		return s.MediaRegistry
	}
	s.mediaRegOnce.Do(func() {
		s.defaultMediaReg = defaultMediaRegistry()
	})
	return s.defaultMediaReg
}

func (s *Server) mediaService() *media.Service {
	var box *secrets.Box
	if s.Secrets != nil {
		box = s.Secrets.Box
	}
	return &media.Service{
		Pool:     s.Pool,
		Box:      box,
		Registry: s.mediaRegistry(),
	}
}

func (s *Server) musicRunner() *media.MusicRunner {
	s.musicRunOnce.Do(func() {
		s.musicRun = &media.MusicRunner{
			Service: s.mediaService(),
			Pool:    s.Pool,
			Blobs:   s.Blobs,
			Bucket:  s.ArtifactBucket,
			Log:     s.Log,
		}
	})
	return s.musicRun
}

// CloseMedia cancels any in-flight media generation jobs and waits for them to exit.
func (s *Server) CloseMedia() {
	if s != nil && s.musicRun != nil {
		s.musicRun.Close()
	}
}

func toAPIMediaProvider(v media.ProviderView) api.MediaProvider {
	caps := make([]api.MediaCapability, len(v.Descriptor.Capabilities))
	for i, c := range v.Descriptor.Capabilities {
		caps[i] = api.MediaCapability(c)
	}
	fields := make([]api.MediaFieldSpec, len(v.Descriptor.Fields))
	for i, f := range v.Descriptor.Fields {
		fs := api.MediaFieldSpec{
			Key:   f.Key,
			Label: f.Label,
			Kind:  api.MediaFieldSpecKind(f.Kind),
		}
		if f.Required {
			req := true
			fs.Required = &req
		}
		if f.Default != "" {
			d := f.Default
			fs.Default = &d
		}
		if f.Placeholder != "" {
			p := f.Placeholder
			fs.Placeholder = &p
		}
		if f.Help != "" {
			h := f.Help
			fs.Help = &h
		}
		if len(f.Options) > 0 {
			opts := make([]api.MediaFieldOption, len(f.Options))
			for j, o := range f.Options {
				opts[j] = api.MediaFieldOption{Value: o.Value, Label: o.Label}
			}
			fs.Options = &opts
		}
		if len(f.ShowWhen) > 0 {
			sw := f.ShowWhen
			fs.ShowWhen = &sw
		}
		fields[i] = fs
	}
	settings := v.Settings
	if settings == nil {
		settings = map[string]string{}
	}
	secretsSet := v.SecretsSet
	if secretsSet == nil {
		secretsSet = map[string]bool{}
	}
	out := api.MediaProvider{
		Id:           v.Descriptor.ID,
		Label:        v.Descriptor.Label,
		Capabilities: caps,
		ComingSoon:   v.Descriptor.ComingSoon,
		Enabled:      v.Enabled,
		Available:    v.Available,
		Fields:       fields,
		Settings:     settings,
		SecretsSet:   secretsSet,
	}
	if v.Descriptor.Description != "" {
		desc := v.Descriptor.Description
		out.Description = &desc
	}
	if v.UnavailableReason != "" {
		r := v.UnavailableReason
		out.UnavailableReason = &r
	}
	return out
}

func toAPIMediaProviders(snap media.ProvidersSnapshot) api.MediaProvidersResponse {
	providers := make([]api.MediaProvider, len(snap.Providers))
	for i, p := range snap.Providers {
		providers[i] = toAPIMediaProvider(p)
	}
	defs := make(map[string]string, len(snap.Defaults))
	for k, v := range snap.Defaults {
		defs[string(k)] = v
	}
	return api.MediaProvidersResponse{
		Providers: providers,
		Defaults:  defs,
	}
}

func (s *Server) ListMediaProviders(ctx context.Context, _ api.ListMediaProvidersRequestObject) (api.ListMediaProvidersResponseObject, error) {
	_, _, ws := me(ctx)
	snap, err := s.mediaService().ListProviders(ctx, ws)
	if err != nil {
		return nil, err
	}
	return api.ListMediaProviders200JSONResponse(toAPIMediaProviders(snap)), nil
}

func (s *Server) UpdateMediaProvider(ctx context.Context, req api.UpdateMediaProviderRequestObject) (api.UpdateMediaProviderResponseObject, error) {
	_, _, ws := me(ctx)
	var (
		enabled       *bool
		settings      map[string]string
		secretUpdates map[string]string
	)
	if req.Body != nil {
		enabled = req.Body.Enabled
		if req.Body.Settings != nil {
			settings = *req.Body.Settings
		}
		if req.Body.Secrets != nil {
			secretUpdates = *req.Body.Secrets
		}
	}
	view, err := s.mediaService().SaveProvider(ctx, ws, req.Id, enabled, settings, secretUpdates)
	if err != nil {
		return nil, err
	}
	return api.UpdateMediaProvider200JSONResponse(toAPIMediaProvider(view)), nil
}

func (s *Server) ClearMediaProviderSecret(ctx context.Context, req api.ClearMediaProviderSecretRequestObject) (api.ClearMediaProviderSecretResponseObject, error) {
	_, _, ws := me(ctx)
	field := ""
	if req.Params.Field != nil {
		field = *req.Params.Field
	}
	if err := s.mediaService().ClearProviderSecret(ctx, ws, req.Id, field); err != nil {
		return nil, err
	}
	return api.ClearMediaProviderSecret204Response{}, nil
}

func (s *Server) CheckMediaProvider(ctx context.Context, req api.CheckMediaProviderRequestObject) (api.CheckMediaProviderResponseObject, error) {
	_, _, ws := me(ctx)
	res, err := s.mediaService().CheckProvider(ctx, ws, req.Id)
	if err != nil {
		return nil, err
	}
	out := api.MediaProviderCheckResponse{
		Ok:      res.OK,
		Message: res.Message,
	}
	if res.ErrorKind != "" {
		ek := api.ChatAudioErrorKind(res.ErrorKind)
		out.ErrorKind = &ek
	}
	return api.CheckMediaProvider200JSONResponse(out), nil
}

func (s *Server) SetMediaDefault(ctx context.Context, req api.SetMediaDefaultRequestObject) (api.SetMediaDefaultResponseObject, error) {
	_, _, ws := me(ctx)
	providerID := ""
	if req.Body != nil {
		providerID = req.Body.ProviderId
	}
	if err := s.mediaService().SetDefault(ctx, ws, media.Capability(req.Capability), providerID); err != nil {
		return nil, err
	}
	snap, err := s.mediaService().ListProviders(ctx, ws)
	if err != nil {
		return nil, err
	}
	return api.SetMediaDefault200JSONResponse(toAPIMediaProviders(snap)), nil
}
