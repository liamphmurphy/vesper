-- Personal assistant memory. Every query is scoped to one person:
-- (workspace_id, user_id) is always in the WHERE clause.
--
-- Within a person, persona_id splits the person's own memory (NULL) from each
-- persona's own memory. Queries that take @scope reach:
--   own       exactly persona_id = sqlc.narg(persona_id) (NULL: the person's own)
--   chat      the person's own plus that one persona's (a persona chat)
--   personas  every persona's, none of the person's own
--   all       everything the person has (the memory manager)
--
-- space_id splits the person's own memory further: an entry with a space is
-- only reached by an owner in that space (sqlc.narg(space_id)), or with scope all.

-- name: CreateMemory :one
INSERT INTO memories (workspace_id, user_id, persona_id, space_id, title, summary, body, tags, type, source, source_chat_id, source_run_id)
VALUES (@workspace_id, @user_id, sqlc.narg(persona_id), sqlc.narg(space_id), @title, @summary, @body, @tags::text[], @type, @source, sqlc.narg(source_chat_id), sqlc.narg(source_run_id))
RETURNING *;

-- name: UpdateMemory :one
-- Absent fields keep their value. A non-empty source replaces the old one (the
-- latest conversation that touched the entry). move sets persona_id to
-- to_persona_id (NULL: the person's own memory), which must be one of the
-- person's personas.
UPDATE memories SET
  title = coalesce(sqlc.narg(title), title),
  summary = coalesce(sqlc.narg(summary), summary),
  body = coalesce(sqlc.narg(body), body),
  tags = coalesce(sqlc.narg(tags)::text[], tags),
  type = coalesce(sqlc.narg(type), type),
  persona_id = CASE WHEN @move::bool THEN sqlc.narg(to_persona_id)::uuid ELSE persona_id END,
  -- A persona's own memory is never a space's.
  space_id = CASE WHEN @move::bool AND sqlc.narg(to_persona_id)::uuid IS NOT NULL THEN NULL ELSE space_id END,
  source = coalesce(sqlc.narg(source), source),
  source_chat_id = CASE WHEN sqlc.narg(source)::text IS NULL THEN source_chat_id ELSE sqlc.narg(source_chat_id) END,
  source_run_id = CASE WHEN sqlc.narg(source)::text IS NULL THEN source_run_id ELSE sqlc.narg(source_run_id) END,
  updated_at = now()
WHERE memories.id = @id AND memories.workspace_id = @workspace_id AND memories.user_id = @user_id
  AND CASE @scope::text WHEN 'all' THEN true WHEN 'personas' THEN memories.persona_id IS NOT NULL
        WHEN 'chat' THEN memories.persona_id IS NULL OR memories.persona_id = sqlc.narg(persona_id)
        ELSE memories.persona_id IS NOT DISTINCT FROM sqlc.narg(persona_id) END
  AND (@scope::text = 'all' OR memories.space_id IS NULL OR memories.space_id = sqlc.narg(space_id))
  AND (NOT @move::bool OR sqlc.narg(to_persona_id)::uuid IS NULL OR EXISTS (
    SELECT 1 FROM personas p WHERE p.id = sqlc.narg(to_persona_id) AND p.workspace_id = @workspace_id AND p.user_id = @user_id))
RETURNING *;

-- name: SetMemorySupersededBy :one
-- Retires an entry in favour of another of the same person's entries in the
-- same memory (the person's own or the same persona's), or restores it when
-- superseded_by is null.
-- Retiring records the reason and time; restoring clears them, and a person's
-- restore exempts the entry from consolidation. FOR SHARE on the new entry
-- waits out a concurrent retire of it, so two entries can't supersede each
-- other.
UPDATE memories m SET superseded_by = sqlc.narg(superseded_by),
  retired_reason = CASE WHEN sqlc.narg(superseded_by)::uuid IS NULL THEN '' ELSE @retired_reason::text END,
  retired_at = CASE WHEN sqlc.narg(superseded_by)::uuid IS NULL THEN NULL ELSE now() END,
  consolidation_exempt = consolidation_exempt OR (sqlc.narg(superseded_by)::uuid IS NULL AND @restored_by_person::bool),
  updated_at = now()
WHERE m.id = @id AND m.workspace_id = @workspace_id AND m.user_id = @user_id
  AND CASE @scope::text WHEN 'all' THEN true WHEN 'personas' THEN m.persona_id IS NOT NULL
        WHEN 'run' THEN (m.persona_id IS NULL AND m.type IN ('project', 'work')) OR m.persona_id = sqlc.narg(persona_id)
        WHEN 'chat' THEN m.persona_id IS NULL OR m.persona_id = sqlc.narg(persona_id) ELSE m.persona_id IS NOT DISTINCT FROM sqlc.narg(persona_id) END
  AND (@scope::text = 'all' OR m.space_id IS NULL OR m.space_id = sqlc.narg(space_id))
  AND (sqlc.narg(superseded_by)::uuid IS NULL OR EXISTS (
    SELECT 1 FROM memories n WHERE n.id = sqlc.narg(superseded_by) AND n.workspace_id = @workspace_id AND n.user_id = @user_id
      AND n.persona_id IS NOT DISTINCT FROM m.persona_id AND n.space_id IS NOT DISTINCT FROM m.space_id AND n.superseded_by IS NULL FOR SHARE))
RETURNING *;

-- name: RetireDuplicateMemory :one
-- The consolidation pass retires a live entry in favour of another live entry
-- of the same memory. No row when either was retired or changed meanwhile.
-- FOR SHARE: see SetMemorySupersededBy.
UPDATE memories m SET superseded_by = @keep_id, retired_reason = @retired_reason::text, retired_at = now(), updated_at = now()
WHERE m.id = @id AND m.workspace_id = @workspace_id AND m.user_id = @user_id
  AND m.superseded_by IS NULL AND m.updated_at = @updated_at
  AND EXISTS (SELECT 1 FROM memories n WHERE n.id = @keep_id AND n.workspace_id = @workspace_id AND n.user_id = @user_id
    AND n.persona_id IS NOT DISTINCT FROM m.persona_id AND n.space_id IS NOT DISTINCT FROM m.space_id AND n.superseded_by IS NULL FOR SHARE)
RETURNING *;

-- name: DuplicateMemoryPairs :many
-- Pairs of live entries of one memory (the person's own, or one persona's) of
-- the same type that look like the same thing: a similar title or a
-- near-identical summary, neither restored by the person after an earlier
-- merge. Moments are each their own thing and never pair. keep is the more
-- recently changed of the two. Newest keep first, best match first.
SELECT a.workspace_id, a.user_id, a.persona_id, a.id AS keep_id, a.title AS keep_title,
  b.id AS retire_id, b.title AS retire_title, b.updated_at AS retire_updated_at,
  greatest(similarity(lower(a.title), lower(b.title)),
           CASE WHEN a.summary <> '' AND b.summary <> '' THEN similarity(lower(a.summary), lower(b.summary)) ELSE 0 END)::float8 AS score
FROM memories a
JOIN memories b ON b.workspace_id = a.workspace_id AND b.user_id = a.user_id AND b.persona_id IS NOT DISTINCT FROM a.persona_id
  AND b.space_id IS NOT DISTINCT FROM a.space_id AND b.type = a.type
  AND (b.updated_at, b.id) < (a.updated_at, a.id) AND b.superseded_by IS NULL AND NOT b.consolidation_exempt
WHERE a.superseded_by IS NULL AND NOT a.consolidation_exempt AND a.type <> 'moment'
  AND (similarity(lower(a.title), lower(b.title)) >= @title_threshold::float8
       OR (a.summary <> '' AND b.summary <> '' AND similarity(lower(a.summary), lower(b.summary)) >= @summary_threshold::float8))
ORDER BY a.workspace_id, a.user_id, a.updated_at DESC, a.id DESC, score DESC
LIMIT @lim;

-- name: GetMemory :one
SELECT * FROM memories WHERE id = @id AND workspace_id = @workspace_id AND user_id = @user_id
  AND CASE @scope::text WHEN 'all' THEN true WHEN 'personas' THEN persona_id IS NOT NULL
        WHEN 'run' THEN (persona_id IS NULL AND type IN ('project', 'work')) OR persona_id = sqlc.narg(persona_id)
        WHEN 'chat' THEN persona_id IS NULL OR persona_id = sqlc.narg(persona_id) ELSE persona_id IS NOT DISTINCT FROM sqlc.narg(persona_id) END
  AND (@scope::text = 'all' OR space_id IS NULL OR space_id = sqlc.narg(space_id));

-- name: ListMemories :many
-- Newest change first, or newest first when by_created. Retired entries only
-- when include_retired.
SELECT * FROM memories
WHERE workspace_id = @workspace_id AND user_id = @user_id
  AND CASE @scope::text WHEN 'all' THEN true WHEN 'personas' THEN persona_id IS NOT NULL
        WHEN 'run' THEN (persona_id IS NULL AND type IN ('project', 'work')) OR persona_id = sqlc.narg(persona_id)
        WHEN 'chat' THEN persona_id IS NULL OR persona_id = sqlc.narg(persona_id) ELSE persona_id IS NOT DISTINCT FROM sqlc.narg(persona_id) END
  AND (@scope::text = 'all' OR space_id IS NULL OR space_id = sqlc.narg(space_id))
  AND (@include_retired::bool OR superseded_by IS NULL)
  AND (sqlc.narg(type)::text IS NULL OR type = sqlc.narg(type))
  AND (sqlc.narg(only_space)::uuid IS NULL OR space_id = sqlc.narg(only_space))
ORDER BY CASE WHEN @by_created::bool THEN created_at ELSE updated_at END DESC, id DESC
LIMIT @lim OFFSET @off;

-- name: ListIndexMemories :many
-- Candidate entries for the always-loaded Memory index: up to @lim most
-- recently changed non-project entries and up to @lim most recently changed
-- project entries, so project churn cannot evict personal facts or preferences.
SELECT m.* FROM memories m
WHERE m.workspace_id = @workspace_id AND m.user_id = @user_id
  AND m.id IN (
  SELECT ranked.id FROM (
    SELECT m2.id, row_number() OVER (
      PARTITION BY (m2.type = 'project')
      ORDER BY m2.updated_at DESC, m2.id DESC
    ) AS rn
    FROM memories m2
    WHERE m2.workspace_id = @workspace_id AND m2.user_id = @user_id
      AND m2.persona_id IS NULL
      AND (m2.space_id IS NULL OR m2.space_id = sqlc.narg(space_id))
      AND m2.superseded_by IS NULL
  ) ranked
  WHERE ranked.rn <= @lim::bigint
)
ORDER BY m.updated_at DESC, m.id DESC;

-- name: CountMemories :one
SELECT count(*) FROM memories
WHERE workspace_id = @workspace_id AND user_id = @user_id
  AND CASE @scope::text WHEN 'all' THEN true WHEN 'personas' THEN persona_id IS NOT NULL
        WHEN 'run' THEN (persona_id IS NULL AND type IN ('project', 'work')) OR persona_id = sqlc.narg(persona_id)
        WHEN 'chat' THEN persona_id IS NULL OR persona_id = sqlc.narg(persona_id) ELSE persona_id IS NOT DISTINCT FROM sqlc.narg(persona_id) END
  AND (@scope::text = 'all' OR space_id IS NULL OR space_id = sqlc.narg(space_id))
  AND (@include_retired::bool OR superseded_by IS NULL)
  AND (sqlc.narg(type)::text IS NULL OR type = sqlc.narg(type))
  AND (sqlc.narg(only_space)::uuid IS NULL OR space_id = sqlc.narg(only_space));

-- name: SearchMemories :many
-- Ranked full-text search over title, tags, summary and body, plus trigram
-- title similarity so partial words and typos still find an entry.
SELECT sqlc.embed(m),
  (ts_rank(memory_search_vector(m.title, m.summary, m.body, m.tags), websearch_to_tsquery('english', @q::text))
   + similarity(lower(m.title), lower(@q::text)))::float8 AS rank
FROM memories m
WHERE m.workspace_id = @workspace_id AND m.user_id = @user_id
  AND CASE @scope::text WHEN 'all' THEN true WHEN 'personas' THEN m.persona_id IS NOT NULL
        WHEN 'run' THEN (m.persona_id IS NULL AND m.type IN ('project', 'work')) OR m.persona_id = sqlc.narg(persona_id)
        WHEN 'chat' THEN m.persona_id IS NULL OR m.persona_id = sqlc.narg(persona_id) ELSE m.persona_id IS NOT DISTINCT FROM sqlc.narg(persona_id) END
  AND (@scope::text = 'all' OR m.space_id IS NULL OR m.space_id = sqlc.narg(space_id))
  AND (@include_retired::bool OR m.superseded_by IS NULL)
  AND (sqlc.narg(type)::text IS NULL OR m.type = sqlc.narg(type))
  AND (sqlc.narg(only_space)::uuid IS NULL OR m.space_id = sqlc.narg(only_space))
  AND (memory_search_vector(m.title, m.summary, m.body, m.tags) @@ websearch_to_tsquery('english', @q::text)
       OR similarity(lower(m.title), lower(@q::text)) >= 0.3)
ORDER BY rank DESC, m.updated_at DESC, m.id DESC
LIMIT @lim;

-- name: NearDuplicateMemory :one
-- The live entry of the same memory (the person's own, or the same persona's)
-- most like a new one: a similar title, or (when both have one) a
-- near-identical summary. Moments never match.
SELECT sqlc.embed(m),
  greatest(similarity(lower(m.title), lower(@title::text)),
           CASE WHEN @summary::text <> '' AND m.summary <> '' THEN similarity(lower(m.summary), lower(@summary::text)) ELSE 0 END)::float8 AS score,
  similarity(lower(m.title), lower(@title::text))::float8 AS title_score
FROM memories m
WHERE m.workspace_id = @workspace_id AND m.user_id = @user_id AND m.persona_id IS NOT DISTINCT FROM sqlc.narg(persona_id)
  AND m.space_id IS NOT DISTINCT FROM sqlc.narg(space_id)
  AND m.superseded_by IS NULL AND m.type <> 'moment'
  AND (similarity(lower(m.title), lower(@title::text)) >= @title_threshold::float8
       OR (@summary::text <> '' AND m.summary <> '' AND similarity(lower(m.summary), lower(@summary::text)) >= @summary_threshold::float8))
ORDER BY score DESC, m.updated_at DESC
LIMIT 1;

-- name: PersonaContextMemories :many
-- A persona's live entries for its always-loaded memory: who it is first
-- (most recently changed first), then its moments, newest first.
SELECT * FROM memories
WHERE workspace_id = @workspace_id AND user_id = @user_id AND persona_id = @persona_id AND superseded_by IS NULL
ORDER BY (type = 'moment'), CASE WHEN type = 'moment' THEN created_at ELSE updated_at END DESC, id DESC
LIMIT @lim;

-- name: DeleteMemory :execrows
DELETE FROM memories WHERE id = @id AND workspace_id = @workspace_id AND user_id = @user_id
  AND CASE @scope::text WHEN 'all' THEN true WHEN 'personas' THEN persona_id IS NOT NULL
        WHEN 'run' THEN (persona_id IS NULL AND type IN ('project', 'work')) OR persona_id = sqlc.narg(persona_id)
        WHEN 'chat' THEN persona_id IS NULL OR persona_id = sqlc.narg(persona_id) ELSE persona_id IS NOT DISTINCT FROM sqlc.narg(persona_id) END
  AND (@scope::text = 'all' OR space_id IS NULL OR space_id = sqlc.narg(space_id));

-- name: DeleteAllMemories :execrows
DELETE FROM memories WHERE workspace_id = @workspace_id AND user_id = @user_id
  AND CASE @scope::text WHEN 'all' THEN true WHEN 'personas' THEN persona_id IS NOT NULL
        WHEN 'run' THEN (persona_id IS NULL AND type IN ('project', 'work')) OR persona_id = sqlc.narg(persona_id)
        WHEN 'chat' THEN persona_id IS NULL OR persona_id = sqlc.narg(persona_id) ELSE persona_id IS NOT DISTINCT FROM sqlc.narg(persona_id) END
  AND (@scope::text = 'all' OR space_id IS NULL OR space_id = sqlc.narg(space_id));

-- name: ExportMemories :many
-- Everything the person has, retired entries and personas' memories
-- included, oldest first.
SELECT * FROM memories WHERE workspace_id = @workspace_id AND user_id = @user_id ORDER BY created_at, id;
