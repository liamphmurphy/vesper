package runs

import (
	"context"
	"encoding/json"
	"errors"
	"path"
	"strings"
	"unicode/utf8"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

// A chat's audio is rendered by the coding chat itself, with code, during its
// turn, the way a video is (chat_videos.go): the agent moves the job through
// its stages with the audio tools, the renderer it wrote reports progress as
// a file in the job's directory, and the runner copies that while the turn
// runs (runner/audio.go). There are no frames: the card shows the stages and
// then an inline player.

// Audio stages, in order. A job may skip one (e.g. no check) but never goes back.
const (
	AudioStageCompose = "compose"
	AudioStageRender  = "render"
	AudioStageCheck   = "check"
	AudioStageSave    = "save"
)

var audioStageOrder = map[string]int{AudioStageCompose: 0, AudioStageRender: 1, AudioStageCheck: 2, AudioStageSave: 3}

const (
	// MaxChatAudioJobsPerTurn caps start_audio calls in one reply.
	MaxChatAudioJobsPerTurn = 3
	// MaxAudioChecks bounds the checks the agent reports on its render.
	MaxAudioChecks = 8
	// MaxAudioMethodRunes matches chat_audio_jobs.method.
	MaxAudioMethodRunes = 200
	// AudioProgressFile is what a renderer writes to report progress.
	AudioProgressFile = "progress.json"
	// AudioOutputBase is the finished file's name without its extension: the
	// agent writes it with one of AudioOutputExts.
	AudioOutputBase = "audio"
)

// AudioOutputExts are the extensions finish_audio accepts for the output file.
var AudioOutputExts = []string{".wav", ".mp3", ".ogg", ".m4a"}

// AudioDir is a job's directory, relative to the workspace.
func AudioDir(id uuid.UUID) string { return path.Join(".lazyagents/audio", id.String()) }

// AudioOutputPaths are the files finish_audio looks for, in order.
func AudioOutputPaths(id uuid.UUID) []string {
	out := make([]string, len(AudioOutputExts))
	for i, ext := range AudioOutputExts {
		out[i] = path.Join(AudioDir(id), AudioOutputBase+ext)
	}
	return out
}

// AudioCheck is one thing the agent measured on its render; Passed nil means
// it hasn't been checked yet. A persona can't hear, so a check is a number:
// the length, the peak level, a stretch of silence.
type AudioCheck struct {
	Label  string `json:"label"`
	Passed *bool  `json:"passed"`
}

// StartChatAudioInput is start_audio's request.
type StartChatAudioInput struct {
	Title       string
	DurationSec float64
	Method      string
	Script      string
}

// StartChatAudio opens an audio job for the reply the chat is writing. Only a
// chat that may run code in its workspace can render one.
func (s *Service) StartChatAudio(ctx context.Context, ws, runID uuid.UUID, in StartChatAudioInput) (store.ChatAudioJob, error) {
	var job store.ChatAudioJob
	title := strings.TrimSpace(in.Title)
	if n := utf8.RuneCountInString(title); n < 1 || n > MaxVideoTitleRunes {
		return job, apperr.Invalid("title", "provide 1–%d characters", MaxVideoTitleRunes)
	}
	durMS := int(in.DurationSec * 1000)
	if durMS < 100 || durMS > 3600000 {
		return job, apperr.Invalid("duration_seconds", "must be 0.1–3600 seconds")
	}
	method, err := cleanAudioMethod(in.Method)
	if err != nil {
		return job, err
	}
	script, err := cleanVideoScript(in.Script)
	if err != nil {
		return job, err
	}
	q := store.New(s.Pool)
	run, chat, turn, err := s.audioTurn(ctx, q, ws, runID)
	if err != nil {
		return job, err
	}
	err = pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
		tq := store.New(tx)
		if _, err := tq.LockChatSession(ctx, store.LockChatSessionParams{ID: chat.ID, WorkspaceID: ws}); err != nil {
			return err
		}
		n, err := tq.CountChatAudioJobsForTurn(ctx, store.CountChatAudioJobsForTurnParams{RunID: &run.ID, TurnID: &turn.ID})
		if err != nil {
			return err
		}
		if n >= MaxChatAudioJobsPerTurn {
			return apperr.Conflict("You can render at most %d audio files in one reply; tell the person to ask again for more.", MaxChatAudioJobsPerTurn)
		}
		job, err = tq.CreateChatAudioJob(ctx, store.CreateChatAudioJobParams{WorkspaceID: ws, UserID: chat.CreatedBy, ChatID: &chat.ID, RunID: &run.ID, TurnID: &turn.ID,
			PersonaID: ChatSpeakerID(chat), Title: title, DurationMs: int32(durMS), ScriptPath: script, Method: method})
		return err
	})
	return job, err
}

// UpdateChatAudio moves a job on to stage (render or check), recording the
// checks the agent made on its render, the renderer's path and the method
// when given.
func (s *Service) UpdateChatAudio(ctx context.Context, ws, runID, id uuid.UUID, stage string, checks []AudioCheck, script, method *string) (store.ChatAudioJob, error) {
	if stage != AudioStageRender && stage != AudioStageCheck {
		return store.ChatAudioJob{}, apperr.Invalid("stage", "use render or check; finish_audio saves the file and fail_audio ends it")
	}
	var raw json.RawMessage
	if checks != nil {
		if len(checks) > MaxAudioChecks {
			return store.ChatAudioJob{}, apperr.Invalid("checks", "at most %d", MaxAudioChecks)
		}
		clean := make([]AudioCheck, 0, len(checks))
		for _, c := range checks {
			label := strings.TrimSpace(c.Label)
			if n := utf8.RuneCountInString(label); n < 1 || n > 120 {
				return store.ChatAudioJob{}, apperr.Invalid("checks", "each label must be 1–120 characters")
			}
			clean = append(clean, AudioCheck{Label: label, Passed: c.Passed})
		}
		raw, _ = json.Marshal(clean)
	}
	if script != nil {
		p, err := cleanVideoScript(*script)
		if err != nil {
			return store.ChatAudioJob{}, err
		}
		script = &p
	}
	if method != nil {
		m, err := cleanAudioMethod(*method)
		if err != nil {
			return store.ChatAudioJob{}, err
		}
		method = &m
	}
	return s.moveChatAudio(ctx, ws, runID, id, func(q *store.Queries, job store.ChatAudioJob) (store.ChatAudioJob, error) {
		if audioStageOrder[stage] < audioStageOrder[job.Stage] {
			return job, apperr.Conflict("This audio is already at %s; stages only move forward.", job.Stage)
		}
		return q.SetChatAudioStage(ctx, store.SetChatAudioStageParams{ID: job.ID, Stage: stage, Checks: raw, ScriptPath: script, Method: method})
	})
}

// FinishChatAudio asks the runner to save the job's file to the chat and the
// Library; the card shows it once it's stored.
func (s *Service) FinishChatAudio(ctx context.Context, ws, runID, id uuid.UUID) (store.ChatAudioJob, error) {
	return s.moveChatAudio(ctx, ws, runID, id, func(q *store.Queries, job store.ChatAudioJob) (store.ChatAudioJob, error) {
		return q.SetChatAudioStage(ctx, store.SetChatAudioStageParams{ID: job.ID, Stage: AudioStageSave})
	})
}

// FailChatAudio ends a job at the stage it reached, with why and the log tail.
func (s *Service) FailChatAudio(ctx context.Context, ws, runID, id uuid.UUID, reason, log string) (store.ChatAudioJob, error) {
	reason = strings.TrimSpace(reason)
	if reason == "" {
		return store.ChatAudioJob{}, apperr.Invalid("error", "say what went wrong")
	}
	if r := []rune(reason); len(r) > MaxVideoErrorRunes {
		reason = string(r[:MaxVideoErrorRunes])
	}
	log = TailBytes(strings.TrimSpace(log), MaxVideoLogBytes)
	return s.moveChatAudio(ctx, ws, runID, id, func(q *store.Queries, job store.ChatAudioJob) (store.ChatAudioJob, error) {
		return q.FailChatAudioJob(ctx, store.FailChatAudioJobParams{ID: job.ID, Error: &reason, FailureKind: &failureError, ErrorLog: log})
	})
}

// moveChatAudio applies change to one of the run's running jobs under its row lock.
func (s *Service) moveChatAudio(ctx context.Context, ws, runID, id uuid.UUID, change func(*store.Queries, store.ChatAudioJob) (store.ChatAudioJob, error)) (store.ChatAudioJob, error) {
	var out store.ChatAudioJob
	q := store.New(s.Pool)
	if _, _, _, err := s.audioTurn(ctx, q, ws, runID); err != nil {
		return out, err
	}
	err := pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
		tq := store.New(tx)
		job, err := tq.LockChatAudioJob(ctx, store.LockChatAudioJobParams{ID: id, RunID: &runID})
		if errors.Is(err, pgx.ErrNoRows) {
			return apperr.Invalid("audio_id", "not an audio file from this chat")
		}
		if err != nil {
			return err
		}
		if job.State != "running" {
			return apperr.Conflict("This audio already %s; start a new one with start_audio if the person wants another.", map[string]string{"done": "finished", "failed": "failed"}[job.State])
		}
		if job.Stage == AudioStageSave {
			return apperr.Conflict("This audio is being saved; it shows in the chat once it's stored.")
		}
		out, err = change(tq, job)
		return err
	})
	return out, err
}

func (s *Service) audioTurn(ctx context.Context, q *store.Queries, ws, runID uuid.UUID) (store.Run, store.ChatSession, store.RunTurn, error) {
	return s.codingChatTurn(ctx, q, ws, runID, "audio", "Rendering audio")
}

// ChatTurnForMusic validates that runID is an active chat turn capable of hosting a
// generate_music job. Unlike start_audio, music generation works in non-coding chats too.
func (s *Service) ChatTurnForMusic(ctx context.Context, ws, runID uuid.UUID) (store.Run, store.ChatSession, store.RunTurn, error) {
	q := store.New(s.Pool)
	run, err := q.GetRun(ctx, store.GetRunParams{ID: runID, WorkspaceID: ws})
	if err != nil {
		return run, store.ChatSession{}, store.RunTurn{}, err
	}
	if run.Purpose != "chat" {
		return run, store.ChatSession{}, store.RunTurn{}, apperr.Conflict("generate_music only works in a chat")
	}
	if run.State != "running" {
		return run, store.ChatSession{}, store.RunTurn{}, apperr.Conflict("generate_music only works while you are answering a message")
	}
	chat, err := q.ChatSessionForRun(ctx, &run.ID)
	if errors.Is(err, pgx.ErrNoRows) {
		return run, chat, store.RunTurn{}, apperr.Conflict("this chat run is no longer attached to a chat")
	}
	if err != nil {
		return run, chat, store.RunTurn{}, err
	}
	turn, err := q.RunningChatTurn(ctx, run.ID)
	if errors.Is(err, pgx.ErrNoRows) {
		return run, chat, turn, apperr.Conflict("generate_music only works while you are answering a message")
	}
	return run, chat, turn, err
}

// cleanAudioMethod trims the one line that says how the audio was made, e.g.
// "MIDI → FluidSynth (GeneralUser GS)".
func cleanAudioMethod(m string) (string, error) {
	m = strings.TrimSpace(strings.ReplaceAll(m, "\n", " "))
	if utf8.RuneCountInString(m) > MaxAudioMethodRunes {
		return "", apperr.Invalid("method", "at most %d characters", MaxAudioMethodRunes)
	}
	return m, nil
}
