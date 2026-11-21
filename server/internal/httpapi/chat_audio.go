package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/liamphmurphy/vesper/server/internal/api"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

func toChatAudio(j store.ChatAudioJob, peaks []byte) api.ChatAudio {
	out := api.ChatAudio{
		Id: j.ID, Title: j.Title, DurationMs: int(j.DurationMs), Method: j.Method, Stage: api.ChatAudioStage(j.Stage), State: api.ChatAudioState(j.State), Error: j.Error,
		ScriptPath: j.ScriptPath, Checks: []api.ChatVideoCheck{}, Percent: int(j.Percent), StageNote: j.StageNote,
		RunId: j.RunID, MessageId: j.MessageID, LibraryItemId: j.LibraryItemID, CreatedAt: j.CreatedAt, UpdatedAt: j.UpdatedAt, FinishedAt: j.FinishedAt,
	}
	if j.SourceKind != "" {
		sk := api.ChatAudioSourceKind(j.SourceKind)
		out.SourceKind = &sk
	}
	if j.ProviderID != "" {
		p := j.ProviderID
		out.ProviderId = &p
	}
	if j.Prompt != "" {
		pr := j.Prompt
		out.Prompt = &pr
	}
	if j.Lyrics != "" {
		ly := j.Lyrics
		out.Lyrics = &ly
	}
	if j.SourceKind == "music" || j.Instrumental {
		inst := j.Instrumental
		out.Instrumental = &inst
	}
	if j.ErrorKind != "" {
		ek := api.ChatAudioErrorKind(j.ErrorKind)
		out.ErrorKind = &ek
	}
	if j.FailureKind != nil {
		k := api.ChatAudioFailureKind(*j.FailureKind)
		out.FailureKind = &k
	}
	if j.ErrorLog != "" {
		out.ErrorLog = &j.ErrorLog
	}
	var checks []runs.AudioCheck
	if json.Unmarshal(j.Checks, &checks) == nil {
		for _, c := range checks {
			out.Checks = append(out.Checks, api.ChatVideoCheck{Label: c.Label, Passed: c.Passed})
		}
	}
	if j.State == "done" && j.OutputBlobKey != nil {
		o := api.ChatAudioOutput{Filename: deref(j.OutputFilename), ContentType: deref(j.OutputContentType)}
		if j.OutputSizeBytes != nil {
			o.SizeBytes = *j.OutputSizeBytes
		}
		if j.OutputDurationMs != nil {
			d := int(*j.OutputDurationMs)
			o.DurationMs = &d
		}
		out.Output = &o
		if len(peaks) > 0 {
			p := make([]int, len(peaks))
			for i, b := range peaks {
				p[i] = int(b)
			}
			out.Peaks = &p
		}
	}
	return out
}

func (s *Server) ListChatAudio(ctx context.Context, req api.ListChatAudioRequestObject) (api.ListChatAudioResponseObject, error) {
	c, err := s.ownChat(ctx, req.Id)
	if err != nil {
		return nil, err
	}
	jobs, err := s.Q.ListChatAudioJobs(ctx, &c.ID)
	if err != nil {
		return nil, err
	}
	out := api.ChatAudios{Audio: make([]api.ChatAudio, 0, len(jobs))}
	for _, j := range jobs {
		var peaks []byte
		if j.LibraryItemID != nil && j.State == "done" {
			// The waveform lives with the Library copy; a deleted copy leaves a flat one.
			if l, err := s.Q.GetLibraryItem(ctx, store.GetLibraryItemParams{ID: *j.LibraryItemID, WorkspaceID: c.WorkspaceID, UserID: j.UserID}); err == nil {
				peaks = l.Peaks
			}
		}
		out.Audio = append(out.Audio, toChatAudio(j, peaks))
	}
	return api.ListChatAudio200JSONResponse(out), nil
}

// ownChatAudio is one of the caller's chat's audio files, else 404.
func (s *Server) ownChatAudio(ctx context.Context, chatID, id uuid.UUID) (store.ChatAudioJob, error) {
	c, err := s.ownChat(ctx, chatID)
	if err != nil {
		return store.ChatAudioJob{}, err
	}
	j, err := s.Q.GetChatAudioJob(ctx, store.GetChatAudioJobParams{ID: id, WorkspaceID: c.WorkspaceID})
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && (j.ChatID == nil || *j.ChatID != c.ID)) {
		return j, apperr.ErrNotFound
	}
	return j, err
}

func (s *Server) GetChatAudioContent(ctx context.Context, req api.GetChatAudioContentRequestObject) (api.GetChatAudioContentResponseObject, error) {
	j, err := s.ownChatAudio(ctx, req.Id, req.AudioId)
	if err != nil {
		return nil, err
	}
	if j.State != "done" || j.OutputBlobKey == nil || j.OutputSizeBytes == nil {
		return nil, apperr.ErrNotFound
	}
	download := req.Params.Download != nil && *req.Params.Download
	resp, err := s.serveRanged(ctx, *j.OutputBlobKey, deref(j.OutputContentType), *j.OutputSizeBytes, deref(j.OutputFilename), !download, req.Params.Range)
	if err != nil {
		return nil, err
	}
	return resp, nil
}

func (r rangedResponse) VisitGetChatAudioContentResponse(w http.ResponseWriter) error {
	return r.write(w)
}
