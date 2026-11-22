-- +goose Up
-- A persona's spoken voice for the talking phase. voice_mode: off (silent),
-- popout (speaks only in the companion pop-out, the immersive view) or always.
-- An empty voice_name takes the provider's default voice; voice_style is a
-- short delivery direction such as "warm, unhurried".
ALTER TABLE personas
  ADD COLUMN voice_mode text NOT NULL DEFAULT 'off' CHECK (voice_mode IN ('off', 'popout', 'always')),
  ADD COLUMN voice_name text NOT NULL DEFAULT '' CHECK (length(voice_name) <= 60),
  ADD COLUMN voice_style text NOT NULL DEFAULT '' CHECK (length(voice_style) <= 200);

-- +goose Down
ALTER TABLE personas DROP COLUMN voice_mode, DROP COLUMN voice_name, DROP COLUMN voice_style;
