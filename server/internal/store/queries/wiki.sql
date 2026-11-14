-- Wiki pages, [[links]] and backlinks (docs/dev/plan.md §12).

-- name: GetNoteByPath :one
SELECT * FROM artifacts WHERE artifact_visible(audience, owner_user_id, sqlc.narg(viewer)::uuid) AND workspace_id = $1 AND type = 'note' AND lower(path) = lower(sqlc.arg(path)) ORDER BY (audience = 'private') DESC LIMIT 1;

-- name: FindNotesByTitle :many
-- Several notes can share a title in different folders; the shortest path wins.
SELECT * FROM artifacts WHERE artifact_visible(audience, owner_user_id, sqlc.narg(viewer)::uuid) AND workspace_id = $1 AND type = 'note' AND lower(title) = lower(sqlc.arg(title))
  AND current_version_id IS NOT NULL
ORDER BY (audience = 'private') DESC, length(path), path;

-- name: FindArtifactByTitle :one
SELECT * FROM artifacts WHERE artifact_visible(audience, owner_user_id, sqlc.narg(viewer)::uuid) AND workspace_id = $1 AND type <> 'note' AND lower(title) = lower(sqlc.arg(title))
ORDER BY updated_at DESC LIMIT 1;

-- name: FindNoteByAlias :one
SELECT ar.* FROM artifact_aliases al JOIN artifacts ar ON ar.id = al.artifact_id
WHERE artifact_visible(ar.audience, ar.owner_user_id, sqlc.narg(viewer)::uuid) AND al.workspace_id = $1 AND lower(al.path) = lower(sqlc.arg(path))
ORDER BY (ar.audience = 'private') DESC, al.created_at DESC LIMIT 1;

-- name: AddAlias :exec
INSERT INTO artifact_aliases (workspace_id, artifact_id, path) VALUES ($1, $2, $3)
ON CONFLICT (artifact_id, path) DO UPDATE SET artifact_id = EXCLUDED.artifact_id, kind = 'moved', created_at = now();

-- name: DeleteAlias :exec
DELETE FROM artifact_aliases WHERE workspace_id = $1 AND artifact_id=sqlc.arg(artifact_id) AND lower(path) = lower(sqlc.arg(path)) AND kind='moved';

-- name: FindEpicByName :one
SELECT * FROM epics WHERE workspace_id = $1 AND lower(name) = lower(sqlc.arg(name)) LIMIT 1;

-- name: SetNotePath :one
UPDATE artifacts SET path = $2, title = $3, audience = CASE WHEN lower($2::text) LIKE 'agents/%' OR lower($2::text) LIKE 'patterns/proposed/%' THEN 'agent' WHEN audience = 'agent' THEN 'shared' ELSE audience END WHERE id = $1 RETURNING *;

-- name: ListNotes :many
SELECT ar.id, ar.path, ar.title, ar.audience, ar.author_type, ar.author_id, ar.updated_at, ar.project_id,
  (ar.current_version_id IS NOT NULL)::bool AS published,
  (SELECT count(*) FROM artifact_versions v WHERE v.artifact_id = ar.id AND v.state = 'suggested')::int AS suggestions,
  ar.canvas_id, coalesce((SELECT cv.kind FROM chat_canvases cv WHERE cv.id = ar.canvas_id), '')::text AS canvas_kind
FROM artifacts ar
WHERE artifact_visible(ar.audience, ar.owner_user_id, sqlc.narg(viewer)::uuid) AND (sqlc.arg(include_agent)::boolean OR ar.audience <> 'agent') AND ar.workspace_id = $1 AND ar.type = 'note'
  AND (sqlc.narg(tag)::text IS NULL OR EXISTS (SELECT 1 FROM page_tags pt WHERE pt.artifact_id = ar.id AND pt.tag = lower(sqlc.narg(tag))))
ORDER BY lower(ar.path);

-- name: DeleteLinksFromSource :exec
DELETE FROM knowledge_links WHERE source_kind = $1 AND source_id = $2;

-- name: InsertLink :exec
INSERT INTO knowledge_links (workspace_id, source_kind, source_id, source_version_id, source_ticket_id,
  target_kind, target_id, target_anchor, target_text, raw_text, snippet, position)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12);

-- name: UnresolvedTargets :many
SELECT DISTINCT target_text FROM knowledge_links WHERE workspace_id = $1 AND target_kind = 'unresolved';

-- name: ResolveLinks :execrows
-- Points every unresolved link with this text at a target that now exists.
UPDATE knowledge_links SET
  target_kind = CASE WHEN target_anchor <> '' AND sqlc.arg(target_kind)::text = 'artifact' THEN 'section' ELSE sqlc.arg(target_kind)::text END,
  target_id = sqlc.arg(target_id)
WHERE knowledge_links.workspace_id = $1 AND knowledge_links.target_kind = 'unresolved' AND lower(knowledge_links.target_text) = lower(sqlc.arg(target_text))
  AND (sqlc.arg(target_kind)::text NOT IN ('artifact', 'section') OR EXISTS (
    SELECT 1 FROM artifacts dst WHERE dst.id = sqlc.arg(target_id)
      AND (dst.audience <> 'private' OR EXISTS (
        SELECT 1 FROM artifacts src WHERE knowledge_links.source_kind = 'artifact'
          AND src.id = knowledge_links.source_id AND src.owner_user_id = dst.owner_user_id
      ))
  ));

-- name: LinksFromSource :many
SELECT * FROM knowledge_links WHERE source_kind = $1 AND source_id = $2 ORDER BY position;

-- name: Backlinks :many
-- Links to a target (an artifact's sections count as the artifact), with
-- what the UI needs to name the source.
SELECT l.id, l.source_kind, l.source_id, l.target_kind, l.target_anchor, l.raw_text, l.snippet, l.created_at,
  ar.type AS source_type, ar.title AS source_title, ar.path AS source_path, ar.number AS source_number,
  t.key AS ticket_key, t.title AS ticket_title,
  c.author_type AS comment_author_type, c.author_id AS comment_author_id
FROM knowledge_links l
LEFT JOIN artifacts ar ON l.source_kind = 'artifact' AND ar.id = l.source_id
LEFT JOIN tickets t ON t.id = l.source_ticket_id
LEFT JOIN comments c ON l.source_kind = 'comment' AND c.id = l.source_id
WHERE (l.source_kind <> 'artifact' OR (artifact_visible(ar.audience, ar.owner_user_id, sqlc.narg(viewer)::uuid)))
  AND (l.target_kind NOT IN ('artifact','section') OR EXISTS (SELECT 1 FROM artifacts dst WHERE dst.id = l.target_id AND artifact_visible(dst.audience, dst.owner_user_id, sqlc.narg(viewer)::uuid)))
  AND l.workspace_id = sqlc.arg(workspace_id)
  AND l.target_id = sqlc.arg(target_id)
  AND (l.target_kind = sqlc.arg(target_kind) OR (sqlc.arg(target_kind) = 'artifact' AND l.target_kind = 'section'))
ORDER BY l.created_at DESC, l.position
LIMIT 200;

-- name: CountBacklinks :one
SELECT count(DISTINCT (source_kind, source_id))::int FROM knowledge_links l LEFT JOIN artifacts src ON l.source_kind = 'artifact' AND src.id = l.source_id
WHERE (l.source_kind <> 'artifact' OR (artifact_visible(src.audience, src.owner_user_id, sqlc.narg(viewer)::uuid))) AND target_id = sqlc.arg(target_id) AND target_kind IN ('artifact', 'section');

-- name: MentionCandidatesArtifacts :many
-- Markdown artifacts whose text mentions a phrase (for unlinked mentions).
SELECT ar.id, ar.type, ar.title, ar.path, ar.number, v.body_md
FROM artifacts ar JOIN artifact_versions v ON v.id = ar.current_version_id
WHERE artifact_visible(ar.audience, ar.owner_user_id, sqlc.narg(viewer)::uuid) AND (sqlc.arg(include_agent)::boolean OR ar.audience <> 'agent') AND ar.workspace_id = $1 AND v.body_md IS NOT NULL AND ar.type <> 'mockup' AND ar.id <> sqlc.arg(exclude_id)
  AND (ar.search @@ phraseto_tsquery('english', sqlc.arg(phrase)) OR v.body_md ILIKE '%' || sqlc.arg(phrase) || '%')
LIMIT 50;

-- name: MentionCandidatesTickets :many
SELECT id, key, title, description_md FROM tickets
WHERE workspace_id = $1 AND id <> sqlc.arg(exclude_id)
  AND (search @@ phraseto_tsquery('english', sqlc.arg(phrase)) OR description_md ILIKE '%' || sqlc.arg(phrase) || '%')
LIMIT 50;

-- name: SearchKnowledgeArtifacts :many
-- Full-text search over artifacts, boosted by how many sources link to them.
SELECT ar.id, ar.type, ar.title, ar.path, ar.number, ar.summary, ar.project_id, ar.updated_at,
  ts_headline('english', ar.search_text, websearch_to_tsquery('english', sqlc.arg(q)),
    'MaxWords=30, MinWords=10, MaxFragments=1, StartSel=«, StopSel=»')::text AS snippet,
  (ts_rank(ar.search, websearch_to_tsquery('english', sqlc.arg(q))) *
    (1 + ln(1 + (SELECT count(DISTINCT (l.source_kind, l.source_id)) FROM knowledge_links l LEFT JOIN artifacts src ON l.source_kind = 'artifact' AND src.id = l.source_id
                 WHERE (l.source_kind <> 'artifact' OR (artifact_visible(src.audience, src.owner_user_id, sqlc.narg(viewer)::uuid) AND (sqlc.arg(include_agent)::boolean OR src.audience <> 'agent'))) AND l.target_id = ar.id AND l.target_kind IN ('artifact', 'section'))))
   + CASE WHEN sqlc.arg(fuzzy)::boolean THEN word_similarity(lower(sqlc.arg(q)), lower(ar.title)) ELSE 0 END)::float8 AS score
FROM artifacts ar
WHERE artifact_visible(ar.audience, ar.owner_user_id, sqlc.narg(viewer)::uuid) AND (sqlc.arg(include_agent)::boolean OR ar.audience <> 'agent') AND ar.workspace_id = sqlc.arg(workspace_id) AND ar.current_version_id IS NOT NULL
  AND (ar.search @@ websearch_to_tsquery('english', sqlc.arg(q)) OR ar.title ILIKE '%' || sqlc.arg(q) || '%'
       OR (sqlc.arg(fuzzy)::boolean AND word_similarity(lower(sqlc.arg(q)), lower(ar.title)) >= 0.3))
  AND (sqlc.narg(types)::text[] IS NULL OR ar.type = ANY(sqlc.narg(types)::text[]))
  AND (sqlc.narg(project_id)::uuid IS NULL OR ar.project_id IS NULL OR ar.project_id = sqlc.narg(project_id))
ORDER BY score DESC, ar.updated_at DESC
LIMIT sqlc.arg(lim);

-- name: SearchKnowledgeTickets :many
SELECT t.id, t.key, t.title, t.status, t.project_id,
  ts_headline('english', t.title || E'\n' || t.description_md, websearch_to_tsquery('english', sqlc.arg(q)),
    'MaxWords=30, MinWords=10, MaxFragments=1, StartSel=«, StopSel=»')::text AS snippet,
  ((ts_rank(t.search, websearch_to_tsquery('english', sqlc.arg(q)))
    + CASE WHEN sqlc.arg(fuzzy)::boolean THEN word_similarity(lower(sqlc.arg(q)), lower(t.title)) ELSE 0 END)
   * CASE WHEN sqlc.arg(fuzzy)::boolean AND t.status IN ('done', 'canceled') THEN 0.7 ELSE 1 END)::float8 AS score
FROM tickets t
WHERE t.workspace_id = sqlc.arg(workspace_id)
  AND (t.search @@ websearch_to_tsquery('english', sqlc.arg(q)) OR t.key = upper(sqlc.arg(q))
       OR (sqlc.arg(fuzzy)::boolean AND (t.title ILIKE '%' || sqlc.arg(q) || '%'
           OR word_similarity(lower(sqlc.arg(q)), lower(t.title)) >= 0.3)))
  AND (sqlc.narg(project_id)::uuid IS NULL OR t.project_id = sqlc.narg(project_id))
ORDER BY score DESC, t.updated_at DESC
LIMIT sqlc.arg(lim);

-- name: SuggestTargets :many
-- [[ autocomplete: notes, artifacts, tickets, epics and agents by prefix or substring.
SELECT kind, id, label, sub, sort FROM (
  SELECT 'note'::text AS kind, ar.id, ar.title AS label, ar.path AS sub, 0 AS sort, ar.updated_at AS at
    FROM artifacts ar WHERE artifact_visible(ar.audience, ar.owner_user_id, sqlc.narg(viewer)::uuid) AND (sqlc.arg(include_agent)::boolean OR ar.audience <> 'agent') AND ar.workspace_id = $1 AND ar.type = 'note' AND ar.current_version_id IS NOT NULL
      AND (ar.path ILIKE '%' || sqlc.arg(q) || '%')
  UNION ALL
  SELECT ar.type, ar.id, CASE WHEN ar.type = 'adr' THEN 'ADR-' || lpad(ar.number::text, 3, '0') ELSE ar.title END,
         CASE WHEN ar.type = 'adr' THEN ar.title ELSE upper(ar.type) END, 1, ar.updated_at
    FROM artifacts ar WHERE artifact_visible(ar.audience, ar.owner_user_id, sqlc.narg(viewer)::uuid) AND (sqlc.arg(include_agent)::boolean OR ar.audience <> 'agent') AND ar.workspace_id = $1 AND ar.type <> 'note' AND ar.current_version_id IS NOT NULL
      AND (ar.title ILIKE '%' || sqlc.arg(q) || '%'
           OR (ar.type = 'adr' AND ('ADR-' || lpad(ar.number::text, 3, '0')) ILIKE '%' || sqlc.arg(q) || '%'))
  UNION ALL
  SELECT 'ticket', t.id, t.key, t.title, 2, t.updated_at
    FROM tickets t WHERE t.workspace_id = $1 AND (t.key ILIKE sqlc.arg(q) || '%' OR t.title ILIKE '%' || sqlc.arg(q) || '%')
  UNION ALL
  SELECT 'epic', e.id, e.name, 'Epic', 3, e.created_at
    FROM epics e WHERE e.workspace_id = $1 AND e.name ILIKE '%' || sqlc.arg(q) || '%'
  UNION ALL
  SELECT 'agent', a.id, '@' || a.handle, a.name, 4, a.created_at
    FROM agents a WHERE a.workspace_id = $1 AND a.archived_at IS NULL AND (a.handle ILIKE sqlc.arg(q) || '%' OR a.name ILIKE sqlc.arg(q) || '%'
                                                 OR ('@' || a.handle) ILIKE sqlc.arg(q) || '%')
) s
ORDER BY (lower(label) LIKE lower(sqlc.arg(q)) || '%') DESC, sort, at DESC
LIMIT 12;

-- name: ListSuggestions :many
-- Pending agent edits to shared notes, oldest first.
SELECT v.id, v.artifact_id, v.label, v.note, v.body_md, v.created_by_type, v.created_by_id, v.created_at,
  v.based_on_version_id, ar.path, ar.title, ar.current_version_id
FROM artifact_versions v JOIN artifacts ar ON ar.id = v.artifact_id
WHERE artifact_visible(ar.audience, ar.owner_user_id, sqlc.narg(viewer)::uuid) AND ar.workspace_id = $1 AND v.state = 'suggested'
  AND (sqlc.narg(artifact_id)::uuid IS NULL OR v.artifact_id = sqlc.narg(artifact_id))
ORDER BY v.created_at;

-- name: CountSuggestions :one
SELECT count(*)::int FROM artifact_versions v JOIN artifacts ar ON ar.id = v.artifact_id
WHERE artifact_visible(ar.audience, ar.owner_user_id, sqlc.narg(viewer)::uuid) AND ar.workspace_id = $1 AND v.state = 'suggested';

-- name: LockSuggestion :one
SELECT v.* FROM artifact_versions v JOIN artifacts ar ON ar.id = v.artifact_id
WHERE artifact_visible(ar.audience, ar.owner_user_id, sqlc.narg(viewer)::uuid) AND v.id = $1 AND ar.workspace_id = $2 FOR UPDATE OF v;

-- name: DecideVersion :exec
UPDATE artifact_versions SET state = $2, decided_by_id = $3, decided_at = now() WHERE id = $1;

-- name: ExportNotes :many
SELECT ar.id, ar.path, ar.title, ar.audience, ar.author_type, ar.author_id, ar.created_at, ar.updated_at, v.body_md, v.properties, p.key AS project_key
FROM artifacts ar
JOIN artifact_versions v ON v.id = ar.current_version_id
LEFT JOIN projects p ON p.id = ar.project_id
WHERE artifact_visible(ar.audience, ar.owner_user_id, sqlc.narg(viewer)::uuid) AND ar.workspace_id = $1 AND ar.type = 'note'
ORDER BY lower(ar.path);

-- name: GraphEdges :many
-- Resolved links among artifacts, tickets, epics and agents: (source, target)
-- pairs for the local graph. Comment links count as their ticket's.
SELECT DISTINCT
  CASE WHEN l.source_kind = 'artifact' THEN 'artifact' ELSE 'ticket' END::text AS source_kind,
  CASE WHEN l.source_kind = 'artifact' THEN l.source_id ELSE l.source_ticket_id END::uuid AS source_id,
  CASE WHEN l.target_kind = 'section' THEN 'artifact' ELSE l.target_kind END::text AS target_kind,
  l.target_id::uuid AS target_id
FROM knowledge_links l
WHERE (l.source_kind <> 'artifact' OR EXISTS (SELECT 1 FROM artifacts src WHERE src.id = l.source_id AND artifact_visible(src.audience, src.owner_user_id, sqlc.narg(viewer)::uuid) AND (sqlc.arg(include_agent)::boolean OR src.audience <> 'agent')))
 AND (l.target_kind NOT IN ('artifact','section') OR EXISTS (SELECT 1 FROM artifacts dst WHERE dst.id = l.target_id AND artifact_visible(dst.audience, dst.owner_user_id, sqlc.narg(viewer)::uuid) AND (sqlc.arg(include_agent)::boolean OR dst.audience <> 'agent')))
 AND l.workspace_id = sqlc.arg(workspace_id) AND l.target_kind <> 'unresolved'
  AND (
    (CASE WHEN l.source_kind = 'artifact' THEN l.source_id ELSE l.source_ticket_id END) = ANY(sqlc.arg(ids)::uuid[])
    OR l.target_id = ANY(sqlc.arg(ids)::uuid[])
  );

-- name: TicketsByIDs :many
SELECT id, key, title, status FROM tickets WHERE workspace_id = sqlc.arg(workspace_id) AND id = ANY(sqlc.arg(ids)::uuid[]);

-- name: ArtifactsByIDs :many
SELECT id, type, title, path, number FROM artifacts WHERE workspace_id = sqlc.arg(workspace_id) AND artifact_visible(audience, owner_user_id, sqlc.narg(viewer)::uuid) AND (sqlc.arg(include_agent)::boolean OR audience <> 'agent') AND id = ANY(sqlc.arg(ids)::uuid[]);

-- name: EpicsByIDs :many
SELECT id, name FROM epics WHERE workspace_id = sqlc.arg(workspace_id) AND id = ANY(sqlc.arg(ids)::uuid[]);

-- name: AgentsByIDs :many
SELECT id, name, handle, color_index FROM agents WHERE workspace_id = sqlc.arg(workspace_id) AND id = ANY(sqlc.arg(ids)::uuid[]);

-- name: TicketArtifactIDs :many
SELECT artifact_id FROM ticket_artifacts WHERE ticket_id = $1;

-- name: SetTicketDescription :exec
UPDATE tickets SET description_md = $2 WHERE id = $1;

-- name: DeleteArtifact :exec
DELETE FROM artifacts WHERE id = $1 AND workspace_id = $2;

-- name: RelabelVersion :exec
UPDATE artifact_versions SET label = $2 WHERE id = $1;

-- name: NoteLinksTo :one
-- Does a note already link to this artifact (memory index bookkeeping)?
SELECT EXISTS (SELECT 1 FROM knowledge_links WHERE source_kind = 'artifact' AND source_id = $1 AND target_id = $2)::bool;

-- name: LinksFromTicket :many
-- Links in a ticket's description and its comments.
SELECT * FROM knowledge_links WHERE source_ticket_id = $1 ORDER BY created_at, position;

-- name: FindPatterns :many
-- Published patterns only (Patterns/<Topic>/<Title>, never Patterns/Proposed/).
-- Rank blends trigram similarity (typos, partial words; title, Tags line and
-- path), full-text rank and the link-count boost. An empty q browses by topic
-- then title.
WITH cand AS (
  SELECT ar.id, ar.title, ar.path, ar.search, ar.search_text, v.body_md,
    lower(ar.title) AS ltitle,
    lower(coalesce(substring(v.body_md FROM '(?im)^tags:[ \t]*(.*)$'), '')) AS ltags,
    lower(sqlc.arg(q)::text) AS lq,
    websearch_to_tsquery('english', sqlc.arg(q)::text) AS tsq
  FROM artifacts ar JOIN artifact_versions v ON v.id = ar.current_version_id
  WHERE artifact_visible(ar.audience, ar.owner_user_id, sqlc.narg(viewer)::uuid) AND ar.workspace_id = sqlc.arg(workspace_id) AND ar.type = 'note' AND v.body_md IS NOT NULL
    AND lower(ar.path) LIKE 'patterns/%/%' AND lower(ar.path) NOT LIKE 'patterns/proposed/%'
    AND (sqlc.narg(topic)::text IS NULL OR lower(split_part(ar.path, '/', 2)) = lower(sqlc.narg(topic)::text))
), scored AS (
  SELECT c.*,
    greatest(word_similarity(c.lq, c.ltitle), similarity(c.lq, c.ltitle),
             0.8 * word_similarity(c.lq, c.ltags), 0.5 * word_similarity(c.lq, lower(c.path))) AS sim,
    CASE WHEN c.lq = '' THEN 0 ELSE ts_rank(c.search, c.tsq, 32) END AS fts,
    (c.lq <> '' AND (c.search @@ c.tsq OR c.ltitle LIKE '%' || c.lq || '%' OR lower(c.path) LIKE '%' || c.lq || '%')) AS exact
  FROM cand c
)
SELECT s.id, s.title, s.path, s.body_md,
  CASE WHEN s.lq = '' THEN '' ELSE ts_headline('english', s.search_text, s.tsq,
    'MaxWords=30, MinWords=10, MaxFragments=1, StartSel=«, StopSel=»') END::text AS snippet,
  ((s.sim + s.fts + CASE WHEN s.exact THEN 0.5 ELSE 0 END) *
    (1 + ln(1 + (SELECT count(DISTINCT (l.source_kind, l.source_id)) FROM knowledge_links l LEFT JOIN artifacts src ON l.source_kind = 'artifact' AND src.id = l.source_id
                 WHERE (l.source_kind <> 'artifact' OR (artifact_visible(src.audience, src.owner_user_id, sqlc.narg(viewer)::uuid) AND (sqlc.arg(include_agent)::boolean OR src.audience <> 'agent'))) AND l.target_id = s.id AND l.target_kind IN ('artifact', 'section')))))::float8 AS score
FROM scored s
WHERE s.lq = '' OR s.exact OR s.sim >= 0.3
ORDER BY score DESC, lower(split_part(s.path, '/', 2)), s.ltitle
LIMIT sqlc.arg(lim);

-- name: RelevantPatterns :many
-- Published patterns that share at least two distinct words with a ticket, at
-- least one of them in the title or Tags line. Exact (stemmed) word matches
-- only: no trigram fuzziness and no link-count boost. Title/tag matches weigh
-- 3, body-only matches 1.
WITH cand AS (
  SELECT ar.id, ar.title, ar.path, ar.search,
    to_tsvector('english', ar.title || ' ' || coalesce(substring(v.body_md FROM '(?im)^tags:[ \t]*(.*)$'), '')) AS head
  FROM artifacts ar JOIN artifact_versions v ON v.id = ar.current_version_id
  WHERE artifact_visible(ar.audience, ar.owner_user_id, sqlc.narg(viewer)::uuid) AND ar.workspace_id = sqlc.arg(workspace_id) AND ar.type = 'note' AND v.body_md IS NOT NULL
    AND lower(ar.path) LIKE 'patterns/%/%' AND lower(ar.path) NOT LIKE 'patterns/proposed/%'
), hits AS (
  SELECT c.id, c.title, c.path, w.word,
    (c.head @@ plainto_tsquery('english', w.word)) AS in_head,
    (c.search @@ plainto_tsquery('english', w.word)) AS in_any
  FROM cand c CROSS JOIN unnest(sqlc.arg(words)::text[]) AS w(word)
)
SELECT h.id, h.title, h.path,
  (3 * count(*) FILTER (WHERE h.in_head) + count(*) FILTER (WHERE h.in_any AND NOT h.in_head))::float8 AS score
FROM hits h
GROUP BY h.id, h.title, h.path
HAVING count(*) FILTER (WHERE h.in_head) >= 1
   AND count(*) FILTER (WHERE h.in_head OR h.in_any) >= 2
ORDER BY score DESC, lower(h.path)
LIMIT sqlc.arg(lim);

-- name: ListADRDocs :many
-- ADR documents and published wiki pages titled "ADR …" (outside agent
-- memory and Patterns/), with their current body for status parsing.
SELECT ar.id, ar.type, ar.title, ar.path, ar.number, ar.updated_at, v.body_md
FROM artifacts ar JOIN artifact_versions v ON v.id = ar.current_version_id
WHERE artifact_visible(ar.audience, ar.owner_user_id, sqlc.narg(viewer)::uuid) AND (sqlc.arg(include_agent)::boolean OR ar.audience <> 'agent') AND ar.workspace_id = $1 AND v.body_md IS NOT NULL
  AND (ar.type = 'adr'
       OR (ar.type = 'note' AND ar.title ~* '^adr([^a-z]|$)'
           AND lower(ar.path) NOT LIKE 'agents/%' AND lower(ar.path) NOT LIKE 'patterns/%'))
ORDER BY ar.updated_at DESC;

-- name: ListArtifactCitations :many
-- Reads of an artifact grouped by the run that made them (runs that still
-- exist, in the workspace), with the run's ticket or chat. Chats are private
-- to their creator: another person's chat run keeps its purpose but no chat.
SELECT ru.id AS run_id, ru.purpose, a.id AS agent_id, a.name AS agent_name, a.handle AS agent_handle, a.color_index AS agent_color_index,
  t.key AS ticket_key, t.title AS ticket_title,
  coalesce(cs.id::text, '')::text AS chat_id, coalesce(cs.title, '')::text AS chat_title,
  count(*)::int AS reads, max(r.read_at)::timestamptz AS last_read_at
FROM artifact_reads r
JOIN artifact_versions v ON v.id = r.version_id
JOIN runs ru ON ru.id = r.run_id AND ru.workspace_id = sqlc.arg(workspace_id)
JOIN agents a ON a.id = r.agent_id
LEFT JOIN tickets t ON t.id = ru.ticket_id
LEFT JOIN LATERAL (
  SELECT s.id, s.title FROM chat_sessions s
  WHERE ru.purpose = 'chat' AND s.workspace_id = ru.workspace_id AND s.created_by = sqlc.arg(viewer)::uuid
    AND (s.current_run_id = ru.id OR EXISTS (SELECT 1 FROM chat_messages m WHERE m.session_id = s.id AND m.run_id = ru.id))
  LIMIT 1
) cs ON true
WHERE v.artifact_id = sqlc.arg(artifact_id)
GROUP BY ru.id, a.id, t.id, cs.id, cs.title
ORDER BY max(r.read_at) DESC;

-- name: ListArtifactUnlinkedReaders :many
-- Reads with no run (older data) or whose run is gone, per agent.
SELECT a.id, a.name, a.handle, a.color_index, count(*)::int AS reads, max(r.read_at)::timestamptz AS last_read_at
FROM artifact_reads r
JOIN artifact_versions v ON v.id = r.version_id
JOIN agents a ON a.id = r.agent_id
WHERE v.artifact_id = $1 AND (r.run_id IS NULL OR NOT EXISTS (SELECT 1 FROM runs ru WHERE ru.id = r.run_id))
GROUP BY a.id ORDER BY max(r.read_at) DESC;

-- name: NotePathTaken :one
-- A path is unique within its audience scope, not across private/shared pages.
SELECT EXISTS (SELECT 1 FROM artifacts a
 WHERE a.workspace_id=sqlc.arg(workspace_id) AND a.type='note' AND lower(a.path)=lower(sqlc.arg(path))
 AND artifact_visible(a.audience, a.owner_user_id, sqlc.narg(viewer)::uuid)
 AND ((sqlc.arg(audience)::text='private' AND a.audience='private' AND a.owner_user_id=sqlc.narg(viewer)::uuid)
      OR (sqlc.arg(audience)::text<>'private' AND a.audience<>'private'))
 AND (sqlc.narg(exclude_id)::uuid IS NULL OR a.id<>sqlc.narg(exclude_id)))::bool;

-- name: LockNotePaths :exec
SELECT pg_advisory_xact_lock(hashtextextended('note-paths:' || $1::uuid::text, 0));

-- name: DeletePageTags :exec
DELETE FROM page_tags WHERE artifact_id = $1;

-- name: AddPageTags :exec
INSERT INTO page_tags (artifact_id, tag) SELECT sqlc.arg(artifact_id)::uuid, unnest(sqlc.arg(tags)::text[]) ON CONFLICT DO NOTHING;

-- name: PageTags :many
SELECT pt.tag FROM page_tags pt JOIN artifacts a ON a.id=pt.artifact_id WHERE pt.artifact_id = $1 AND artifact_visible(a.audience,a.owner_user_id,sqlc.narg(viewer)::uuid) ORDER BY pt.tag;

-- name: DeletePropertyAliases :exec
DELETE FROM artifact_aliases WHERE artifact_id = $1 AND kind = 'alias';

-- name: AddPropertyAlias :exec
INSERT INTO artifact_aliases (workspace_id, artifact_id, path, kind) VALUES ($1, $2, $3, 'alias')
ON CONFLICT (artifact_id, path) DO NOTHING;

-- name: PropertyAliasTaken :one
SELECT EXISTS (SELECT 1 FROM artifact_aliases al JOIN artifacts a ON a.id=al.artifact_id WHERE al.workspace_id = $1 AND lower(al.path) = lower(sqlc.arg(path)) AND al.kind = 'alias' AND artifact_visible(a.audience,a.owner_user_id,sqlc.narg(viewer)::uuid));

-- name: UnresolveLinksTo :exec
-- A deleted page's inbound links go back to unresolved, keeping their text,
-- so [[Name]] shows as a page to create and reattaches if one is made.
UPDATE knowledge_links SET target_kind = 'unresolved', target_id = NULL
WHERE workspace_id = $1 AND target_id = $2 AND target_kind IN ('artifact', 'section');

-- name: GetCanvasPage :one
-- The Knowledge page a deck or design is (LAZYAGENTS-212), for the old /apps URLs and new decks.
SELECT ar.id, ar.path, ar.title FROM artifacts ar
WHERE ar.canvas_id = $1 AND ar.workspace_id = $2 AND artifact_visible(ar.audience, ar.owner_user_id, sqlc.narg(viewer)::uuid);

-- name: CanvasKind :one
SELECT kind FROM chat_canvases WHERE id = $1;
