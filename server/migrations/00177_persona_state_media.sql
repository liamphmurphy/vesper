-- +goose Up
-- A persona's photorealistic state loops: one transparent Animated WebP per
-- character state, made from the persona's portrait with an image-to-video
-- provider (Gemini Omni) and matted locally (internal/media/looppack). A row
-- keeps its last good loop while a regeneration runs or after one fails, so a
-- failed retry never takes away a state that worked.
CREATE TABLE persona_state_media (
  persona_id     uuid NOT NULL REFERENCES personas(id) ON DELETE CASCADE,
  state          text NOT NULL CHECK (state IN ('idle', 'thinking', 'reading', 'coding', 'creating', 'needs_you')),
  -- The latest generation attempt; ready and failed keep any earlier loop.
  status         text NOT NULL DEFAULT 'queued' CHECK (status IN ('queued', 'running', 'ready', 'failed')),
  -- Identifies the attempt, so a superseded or cleared one can't write back.
  job_id         uuid NOT NULL,
  percent        integer NOT NULL DEFAULT 0 CHECK (percent BETWEEN 0 AND 100),
  stage_note     text NOT NULL DEFAULT '' CHECK (length(stage_note) <= 300),
  prompt         text NOT NULL DEFAULT '' CHECK (length(prompt) <= 4000),
  tweak          text NOT NULL DEFAULT '' CHECK (length(tweak) <= 1000),
  provider_id    text NOT NULL DEFAULT '',
  model          text NOT NULL DEFAULT '',
  -- The provider's conversation handle for this loop, for follow-up edits.
  interaction_id text,
  -- The matting backend that made the loop: vision or ffmpeg-chroma.
  backend        text NOT NULL DEFAULT '',
  blob_key       text,
  content_type   text,
  head_key       text,
  width          integer,
  height         integer,
  frames         integer,
  duration_ms    integer,
  size_bytes     bigint,
  error          text CHECK (length(error) <= 2000),
  error_kind     text,
  created_at     timestamptz NOT NULL DEFAULT now(),
  updated_at     timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (persona_id, state),
  CONSTRAINT persona_state_media_blob CHECK ((blob_key IS NULL) = (content_type IS NULL)),
  CONSTRAINT persona_state_media_ready CHECK (status <> 'ready' OR blob_key IS NOT NULL),
  CONSTRAINT persona_state_media_error CHECK ((error IS NOT NULL) = (status = 'failed'))
);

-- +goose Down
DROP TABLE persona_state_media;
