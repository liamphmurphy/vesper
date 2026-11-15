-- +goose Up
-- Default harness, model, and reasoning effort per persona.
-- Empty harness+model means Auto in chats; active work personas mirror their
-- agent definition's primary harness, model, and effort.
ALTER TABLE personas
    ADD COLUMN default_harness text NOT NULL DEFAULT ''
        CHECK (default_harness IN ('', 'claude-code', 'codex', 'antigravity')),
    ADD COLUMN default_model text NOT NULL DEFAULT '',
    ADD COLUMN default_effort text NOT NULL DEFAULT ''
        CHECK (default_effort IN ('', 'low', 'medium', 'high', 'xhigh', 'max')),
    ADD CONSTRAINT personas_default_model_pair_check
        CHECK ((default_harness = '') = (default_model = ''));

UPDATE personas p
SET
    default_harness = COALESCE(NULLIF(v.spec->>'harness', ''), 'claude-code'),
    default_model = COALESCE(NULLIF(v.spec->>'model', ''), a.model),
    default_effort = CASE
        WHEN COALESCE(v.spec->'harness_options'->COALESCE(NULLIF(v.spec->>'harness', ''), 'claude-code')->>'effort', '')
            IN ('low', 'medium', 'high', 'xhigh', 'max')
        THEN v.spec->'harness_options'->COALESCE(NULLIF(v.spec->>'harness', ''), 'claude-code')->>'effort'
        ELSE ''
    END
FROM agents a
LEFT JOIN agent_definition_versions v ON v.id = a.current_definition_version_id
WHERE a.id = p.id
  AND a.archived_at IS NULL
  AND a.kind IN ('main', 'sub')
  AND COALESCE(NULLIF(v.spec->>'harness', ''), 'claude-code') IN ('claude-code', 'codex', 'antigravity')
  AND COALESCE(NULLIF(v.spec->>'model', ''), NULLIF(a.model, '')) IS NOT NULL;

-- +goose Down
ALTER TABLE personas
    DROP CONSTRAINT IF EXISTS personas_default_model_pair_check,
    DROP COLUMN IF EXISTS default_effort,
    DROP COLUMN IF EXISTS default_model,
    DROP COLUMN IF EXISTS default_harness;
