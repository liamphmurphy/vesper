-- Personas are private to one person: every query filters on (workspace_id, user_id).

-- name: LockPersonaOwner :exec
-- Serializes one person's persona writes (default swap, the per-person cap,
-- name checks) for the rest of the transaction.
SELECT pg_advisory_xact_lock(hashtextextended('personas:' || sqlc.arg(workspace_id)::uuid::text || ':' || sqlc.arg(user_id)::uuid::text, 0));

-- name: ListPersonas :many
-- The default first, then most recently used, then by name.
SELECT * FROM personas WHERE workspace_id = $1 AND user_id = $2
ORDER BY is_default DESC, last_used_at DESC NULLS LAST, lower(btrim(name)), id;

-- name: CountPersonas :one
SELECT count(*)::int FROM personas WHERE workspace_id = $1 AND user_id = $2;

-- name: GetPersona :one
SELECT * FROM personas WHERE id = $1 AND workspace_id = $2 AND user_id = $3;

-- name: KeySharePersona :one
-- Checks a new chat's persona and holds it until the chat commits, so a
-- concurrent delete waits instead of failing the chat insert on the FK.
SELECT id FROM personas WHERE id = $1 AND workspace_id = $2 AND user_id = $3 FOR KEY SHARE;

-- name: LockPersonaChats :exec
-- Before a delete: lock the chats the persona hosts, speaks in or joined
-- first, in the same order a message post takes them (chat, then persona), so
-- the two never deadlock.
SELECT c.id FROM chat_sessions c
WHERE c.persona_id = sqlc.arg(persona_id)::uuid OR c.speaker_persona_id = sqlc.arg(persona_id)::uuid
   OR c.id IN (SELECT cp.chat_id FROM chat_participants cp WHERE cp.persona_id = sqlc.arg(persona_id)::uuid)
ORDER BY c.id FOR UPDATE OF c;

-- name: DefaultPersona :one
SELECT * FROM personas WHERE workspace_id = $1 AND user_id = $2 AND is_default;

-- name: PersonaNameTaken :one
-- Whether another of the person's personas already uses this name (case-insensitive, trimmed).
SELECT EXISTS (
  SELECT 1 FROM personas
  WHERE workspace_id = sqlc.arg(workspace_id) AND user_id = sqlc.arg(user_id)
    AND lower(btrim(name)) = lower(btrim(sqlc.arg(name)::text))
    AND id IS DISTINCT FROM sqlc.narg(except_id)::uuid
)::bool;

-- name: CreatePersona :one
INSERT INTO personas (workspace_id, user_id, name, tone, color, custom_instructions, is_default, can_code, can_generate_images, repos, can_create_personas, can_create_svgs, can_create_workflows, can_create_connectors, default_harness, default_model, default_effort)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17) RETURNING *;

-- name: UpdatePersona :one
-- Returns no row when the persona isn't the caller's or the revision is stale.
UPDATE personas SET
  name = COALESCE(sqlc.narg(name)::text, name),
  tone = COALESCE(sqlc.narg(tone)::text, tone),
  color = COALESCE(sqlc.narg(color)::text, color),
  custom_instructions = COALESCE(sqlc.narg(custom_instructions)::text, custom_instructions),
  can_code = COALESCE(sqlc.narg(can_code)::boolean, can_code),
  can_generate_images = COALESCE(sqlc.narg(can_generate_images)::boolean, can_generate_images),
  can_create_personas = COALESCE(sqlc.narg(can_create_personas)::boolean, can_create_personas),
  can_create_svgs = COALESCE(sqlc.narg(can_create_svgs)::boolean, can_create_svgs),
  can_create_workflows = COALESCE(sqlc.narg(can_create_workflows)::boolean, can_create_workflows),
  can_create_connectors = COALESCE(sqlc.narg(can_create_connectors)::boolean, can_create_connectors),
  repos = COALESCE(sqlc.narg(repos)::text[], repos),
  in_chat_list = COALESCE(sqlc.narg(in_chat_list)::boolean, in_chat_list),
  default_harness = COALESCE(sqlc.narg(default_harness)::text, default_harness),
  default_model = COALESCE(sqlc.narg(default_model)::text, default_model),
  default_effort = COALESCE(sqlc.narg(default_effort)::text, default_effort),
  revision = revision + 1, updated_at = now()
WHERE id = sqlc.arg(id) AND workspace_id = sqlc.arg(workspace_id) AND user_id = sqlc.arg(user_id) AND revision = sqlc.arg(revision)
RETURNING *;

-- name: ClearDefaultPersona :exec
-- Step one of a default swap: unset the current default unless it is keep_id.
UPDATE personas SET is_default = false, revision = revision + 1, updated_at = now()
WHERE workspace_id = sqlc.arg(workspace_id) AND user_id = sqlc.arg(user_id) AND is_default AND id <> sqlc.arg(keep_id);

-- name: MarkDefaultPersona :one
-- Step two of a default swap. A persona that is already the default is returned unchanged.
UPDATE personas SET is_default = true,
  revision = CASE WHEN is_default THEN revision ELSE revision + 1 END,
  updated_at = CASE WHEN is_default THEN updated_at ELSE now() END
WHERE id = $1 AND workspace_id = $2 AND user_id = $3
RETURNING *;

-- name: DeletePersona :one
DELETE FROM personas WHERE id = $1 AND workspace_id = $2 AND user_id = $3 RETURNING *;

-- name: PromoteDefaultPersona :exec
-- After the default is deleted: the most recently used remaining persona
-- (ties to the most recently created) becomes the default. No-op when none remain.
UPDATE personas SET is_default = true, revision = revision + 1, updated_at = now()
WHERE id = (
  SELECT p.id FROM personas p WHERE p.workspace_id = sqlc.arg(workspace_id) AND p.user_id = sqlc.arg(user_id)
  ORDER BY p.last_used_at DESC NULLS LAST, p.created_at DESC, p.id DESC LIMIT 1
) AND NOT EXISTS (
  SELECT 1 FROM personas d WHERE d.workspace_id = sqlc.arg(workspace_id) AND d.user_id = sqlc.arg(user_id) AND d.is_default
);

-- name: PersonaChatCounts :many
-- Personal chats (archived included, hidden and app conversations not) per persona.
SELECT c.persona_id::uuid AS persona_id, count(*)::int AS n FROM chat_sessions c
WHERE c.persona_id = ANY(sqlc.arg(ids)::uuid[]) AND NOT c.hidden
  AND NOT EXISTS (SELECT 1 FROM chat_spaces sp WHERE sp.id = c.space_id AND sp.app IS NOT NULL)
GROUP BY c.persona_id;

-- name: PersonaChatIDs :many
-- Chats that show the persona: as host or as a participant.
SELECT id FROM chat_sessions WHERE persona_id = sqlc.arg(persona_id)::uuid
UNION SELECT chat_id FROM chat_participants WHERE persona_id = sqlc.arg(persona_id)::uuid
ORDER BY 1;

-- name: PersonasByIDs :many
-- The summaries chat payloads embed; only the caller's own personas.
SELECT * FROM personas WHERE id = ANY(sqlc.arg(ids)::uuid[]) AND workspace_id = sqlc.arg(workspace_id) AND user_id = sqlc.arg(user_id);

-- name: TouchPersonaUsed :exec
-- A chat with this persona got a message; drives ordering and promotion on
-- delete. At most once a minute, so chatting doesn't flood persona.updated.
UPDATE personas SET last_used_at = now()
WHERE id = $1 AND (last_used_at IS NULL OR last_used_at < now() - interval '1 minute');

-- name: SeedDefaultPersona :one
-- A new person's built-in "Assistant" default; no row when they already have a default.
INSERT INTO personas (workspace_id, user_id, name, is_default,
    can_code, can_generate_images, can_create_personas, can_create_svgs,
    can_create_workflows, can_create_connectors)
VALUES ($1, $2, 'Assistant', true, true, true, true, true, true, true)
ON CONFLICT DO NOTHING RETURNING *;

-- name: NotifyChatsUpdated :exec
-- chat.updated for chats whose embedded persona summary changed without a
-- chat_sessions write (rename, colour, avatar). Delivered on commit.
SELECT pg_notify('lazyagents_changes', json_build_object('type', 'chat.updated', 'ids', sqlc.arg(ids)::text[])::text);

-- name: SetPersonaAvatar :one
-- Points the persona at a stored avatar, or clears it (and any SVG character) with both args null.
UPDATE personas SET
  avatar_key = sqlc.narg(avatar_key)::text,
  avatar_content_type = sqlc.narg(avatar_content_type)::text,
  character_svg = NULL,
  revision = revision + 1, updated_at = now()
WHERE id = sqlc.arg(id) AND workspace_id = sqlc.arg(workspace_id) AND user_id = sqlc.arg(user_id)
RETURNING *;

-- name: SetPersonaCharacter :one
-- Sets the persona's animated SVG character and optionally updates or clears its fallback raster avatar.
UPDATE personas SET
  character_svg = sqlc.arg(character_svg)::text,
  avatar_key = CASE WHEN sqlc.arg(set_avatar)::bool THEN sqlc.narg(avatar_key)::text ELSE avatar_key END,
  avatar_content_type = CASE WHEN sqlc.arg(set_avatar)::bool THEN sqlc.narg(avatar_content_type)::text ELSE avatar_content_type END,
  revision = revision + 1, updated_at = now()
WHERE id = sqlc.arg(id) AND workspace_id = sqlc.arg(workspace_id) AND user_id = sqlc.arg(user_id)
RETURNING *;

-- name: ClearPersonaCharacter :one
-- Clears the persona's SVG character and its fallback avatar blob pointers.
UPDATE personas SET
  character_svg = NULL,
  avatar_key = NULL,
  avatar_content_type = NULL,
  revision = revision + 1, updated_at = now()
WHERE id = sqlc.arg(id) AND workspace_id = sqlc.arg(workspace_id) AND user_id = sqlc.arg(user_id)
RETURNING *;

-- name: SetPersonaImageEngine :one
-- The engine ('' inherits the workspace's) is changed apart from UpdatePersona so
-- the optimistic update keeps its shape; it bumps the revision like any edit.
UPDATE personas SET image_engine = sqlc.arg(image_engine), revision = revision + 1, updated_at = now()
WHERE id = sqlc.arg(id) AND workspace_id = sqlc.arg(workspace_id) AND user_id = sqlc.arg(user_id)
RETURNING *;

-- name: SetPersonaTicketEdits :one
-- Whether its ticket edits wait for the person ('ask') or apply at once
-- ('allow'). Apart from UpdatePersona like the image engine, so "Always allow"
-- on a chat card needn't know the revision; it bumps the revision like any edit.
UPDATE personas SET ticket_edits = sqlc.arg(ticket_edits), revision = revision + 1, updated_at = now()
WHERE id = sqlc.arg(id) AND workspace_id = sqlc.arg(workspace_id) AND user_id = sqlc.arg(user_id)
RETURNING *;

-- name: ListPersonaWork :many
-- The work records of the person's personas: the agents rows sharing a persona's id, archived
-- ones included (an archived row is work turned off; turning it back on revives it).
SELECT a.* FROM agents a JOIN personas p ON p.id = a.id
WHERE p.workspace_id = $1 AND p.user_id = $2 AND a.kind = 'main';

-- name: PersonaOwnerOf :one
-- The person whose persona shares this agent's id; no row for a chat-only agent (the
-- Personal Assistant) or an archived agent that never became a persona.
SELECT p.* FROM personas p WHERE p.id = $1 AND p.workspace_id = $2;

-- name: CreatePersonaForAgent :one
-- The persona of a work record made outside a persona (the seed, POST /agents): the
-- record's own id, so the two stay one actor.
INSERT INTO personas (id, workspace_id, user_id, name, color, default_harness, default_model, default_effort)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8) RETURNING *;

-- name: SyncPersonaDefaultModel :one
-- Keeps a working persona's default harness/model/effort mirrored with its agent definition.
UPDATE personas SET
  default_harness = sqlc.arg(default_harness),
  default_model = sqlc.arg(default_model),
  default_effort = sqlc.arg(default_effort),
  revision = revision + 1, updated_at = now()
WHERE id = sqlc.arg(id) AND workspace_id = sqlc.arg(workspace_id)
RETURNING *;
