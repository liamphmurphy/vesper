-- name: CreateArtifact :one
INSERT INTO artifacts (workspace_id, project_id, epic_id, type, title, number, summary, author_type, author_id, path, audience, owner_user_id)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, sqlc.arg(audience), sqlc.narg(owner_user_id))
RETURNING *;

-- name: NextADRNumber :one
-- Serialized by the caller's advisory lock on the workspace.
SELECT (coalesce(max(number), 0) + 1)::int FROM artifacts WHERE workspace_id = $1 AND type = 'adr';

-- name: ADRNumberTaken :one
SELECT EXISTS (SELECT 1 FROM artifacts WHERE workspace_id = $1 AND type = 'adr' AND number = $2);

-- name: LockArtifactNumbering :exec
SELECT pg_advisory_xact_lock(hashtextextended('artifact-numbering:' || $1::uuid::text, 0));

-- name: GetArtifact :one
SELECT * FROM artifacts WHERE artifact_visible(audience, owner_user_id, sqlc.narg(viewer)::uuid) AND id = $1 AND workspace_id = $2;

-- name: LockArtifact :one
SELECT * FROM artifacts WHERE id = $1 AND workspace_id = $2 AND artifact_visible(audience, owner_user_id, sqlc.narg(viewer)::uuid) FOR UPDATE;

-- name: SetArtifactCurrentVersion :exec
UPDATE artifacts SET current_version_id = $2, search_text = $3, summary = $4 WHERE id = $1;

-- name: UpdateArtifactMeta :one
UPDATE artifacts SET title = $2, summary = $3, epic_id = $4 WHERE id = $1 RETURNING *;

-- name: CreateArtifactVersion :one
INSERT INTO artifact_versions (artifact_id, seq, label, body_md, blob_key, filename, content_type, size_bytes, note, created_by_type, created_by_id, state, based_on_version_id, review_state, properties)
VALUES ($1, (SELECT coalesce(max(seq), 0) + 1 FROM artifact_versions WHERE artifact_id = $1), $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, sqlc.narg(review_state), coalesce(sqlc.narg(properties)::jsonb, '{}'::jsonb))
RETURNING *;

-- name: GetArtifactVersion :one
SELECT v.* FROM artifact_versions v JOIN artifacts a ON a.id = v.artifact_id
WHERE artifact_visible(a.audience, a.owner_user_id, sqlc.narg(viewer)::uuid) AND v.id = $1 AND v.artifact_id = $2 AND a.workspace_id = $3;

-- name: ListArtifactVersions :many
SELECT id, artifact_id, seq, label, filename, content_type, size_bytes, note, created_by_type, created_by_id, created_at,
  review_state, reviewed_by_user_id, reviewed_at, review_note, review_pins, review_snapshot_key, review_snapshot_renderer, review_snapshot_sha256
FROM artifact_versions WHERE artifact_id = $1 AND EXISTS (SELECT 1 FROM artifacts a WHERE a.id = artifact_id AND artifact_visible(a.audience, a.owner_user_id, sqlc.narg(viewer)::uuid)) AND state = 'published' AND label <> 'suggestion' ORDER BY seq DESC;

-- name: CountPublishedVersions :one
SELECT count(*)::int FROM artifact_versions WHERE artifact_id = $1 AND state = 'published' AND label <> 'suggestion';

-- name: InsertSection :exec
INSERT INTO artifact_sections (version_id, position, level, anchor, heading) VALUES ($1, $2, $3, $4, $5);

-- name: ListSectionsWithCitations :many
-- Citations count reads of a section by anchor across all versions, so
-- history isn't lost when a new version re-extracts the outline.
SELECT s.id, s.position, s.level, s.anchor, s.heading,
  (SELECT count(*) FROM artifact_reads r
     JOIN artifact_sections s2 ON s2.id = r.section_id
     JOIN artifact_versions v2 ON v2.id = s2.version_id
   WHERE v2.artifact_id = sqlc.arg(artifact_id) AND s2.anchor = s.anchor)::int AS citations
FROM artifact_sections s
WHERE EXISTS (SELECT 1 FROM artifact_versions v JOIN artifacts a ON a.id = v.artifact_id WHERE v.id = s.version_id AND artifact_visible(a.audience, a.owner_user_id, sqlc.narg(viewer)::uuid)) AND s.version_id = sqlc.arg(version_id)
ORDER BY s.position;

-- name: GetSectionByAnchor :one
SELECT * FROM artifact_sections WHERE version_id = $1 AND anchor = $2;

-- name: InsertArtifactRead :exec
INSERT INTO artifact_reads (version_id, section_id, agent_id, run_id, read_at)
VALUES ($1, $2, $3, $4, coalesce(sqlc.narg(read_at)::timestamptz, now()));

-- name: ListArtifactReaders :many
SELECT a.id, a.name, a.handle, a.color_index, count(*)::int AS reads, max(r.read_at)::timestamptz AS last_read_at
FROM artifact_reads r
JOIN artifact_versions v ON v.id = r.version_id
JOIN agents a ON a.id = r.agent_id
WHERE v.artifact_id = $1
GROUP BY a.id ORDER BY max(r.read_at) DESC;

-- name: ListArtifacts :many
SELECT
  ar.id, ar.type, ar.title, ar.number, ar.summary, ar.author_type, ar.author_id, ar.updated_at, ar.created_at, ar.path,
  p.key AS project_key, p.name AS project_name, p.color AS project_color,
  e.id AS epic_id, e.name AS epic_name,
  v.label AS version_label, v.seq AS version_seq, v.content_type, v.size_bytes, v.filename, v.review_state,
  (v.body_md IS NOT NULL)::bool AS is_markdown,
  (SELECT count(*) FROM artifact_sections s WHERE s.version_id = v.id)::int AS section_count,
  (SELECT count(*) FROM ticket_artifacts ta WHERE ta.artifact_id = ar.id)::int AS ticket_count
FROM artifacts ar
LEFT JOIN projects p ON p.id = ar.project_id
LEFT JOIN epics e ON e.id = ar.epic_id
JOIN artifact_versions v ON v.id = ar.current_version_id
WHERE artifact_visible(ar.audience, ar.owner_user_id, sqlc.narg(viewer)::uuid) AND (sqlc.arg(include_agent)::boolean OR ar.audience <> 'agent') AND ar.workspace_id = sqlc.arg(workspace_id)
  -- Notes have their own tab and stay out of "All".
  AND (CASE WHEN sqlc.narg(type)::text IS NULL THEN ar.type <> 'note' ELSE ar.type = sqlc.narg(type) END)
  AND (sqlc.narg(project_id)::uuid IS NULL OR ar.project_id = sqlc.narg(project_id))
  AND (sqlc.narg(q)::text IS NULL
       OR ar.search @@ websearch_to_tsquery('english', sqlc.narg(q))
       OR ar.title ILIKE '%' || sqlc.narg(q) || '%')
ORDER BY ar.updated_at DESC
LIMIT 500;

-- name: CountArtifactsByType :many
SELECT type, count(*)::int AS n FROM artifacts
WHERE artifact_visible(audience, owner_user_id, sqlc.narg(viewer)::uuid) AND (sqlc.arg(include_agent)::boolean OR audience <> 'agent') AND workspace_id = sqlc.arg(workspace_id) AND current_version_id IS NOT NULL
  AND (sqlc.narg(project_id)::uuid IS NULL OR project_id = sqlc.narg(project_id))
  AND (sqlc.narg(q)::text IS NULL
       OR search @@ websearch_to_tsquery('english', sqlc.narg(q))
       OR title ILIKE '%' || sqlc.narg(q) || '%')
GROUP BY type;

-- name: AttachArtifact :execrows
INSERT INTO ticket_artifacts (ticket_id, artifact_id, relation) VALUES ($1, $2, $3)
ON CONFLICT DO NOTHING;

-- name: DetachArtifact :execrows
DELETE FROM ticket_artifacts WHERE ticket_id = $1 AND artifact_id = $2;

-- name: ListTicketArtifacts :many
-- Doc cards on a ticket. read_by_assignee: has the ticket's agent read any version?
SELECT ar.id, ar.type, ar.title, ar.number, ar.author_type, ar.author_id, ta.relation,
  v.label AS version_label, v.review_state,
  EXISTS (
    SELECT 1 FROM artifact_reads r JOIN artifact_versions v2 ON v2.id = r.version_id
    WHERE v2.artifact_id = ar.id AND r.agent_id = sqlc.narg(assignee_agent_id)
  )::bool AS read_by_assignee
FROM ticket_artifacts ta
JOIN artifacts ar ON ar.id = ta.artifact_id
LEFT JOIN artifact_versions v ON v.id = ar.current_version_id
WHERE artifact_visible(ar.audience, ar.owner_user_id, sqlc.narg(viewer)::uuid) AND ta.ticket_id = sqlc.arg(ticket_id)
ORDER BY ta.relation, ta.created_at;

-- name: ListArtifactTickets :many
SELECT t.key, t.title, t.status, ta.relation
FROM ticket_artifacts ta JOIN tickets t ON t.id = ta.ticket_id
WHERE ta.artifact_id = $1
ORDER BY t.updated_at DESC;

-- name: GetADRByNumber :one
SELECT * FROM artifacts WHERE artifact_visible(audience, owner_user_id, sqlc.narg(viewer)::uuid) AND workspace_id = $1 AND type = 'adr' AND number = $2;

-- name: ReviewArtifactVersion :one
-- The snapshot columns belong to the latest decision: a review without one clears them.
UPDATE artifact_versions SET review_state = $2, reviewed_by_user_id = $3, reviewed_at = now(), review_note = $4, review_pins = $5,
  review_snapshot_key = sqlc.narg(snapshot_key), review_snapshot_renderer = sqlc.narg(snapshot_renderer), review_snapshot_sha256 = sqlc.narg(snapshot_sha256)
WHERE id = $1 RETURNING *;

-- name: MockupGateCandidates :many
-- Mockups that can satisfy a ticket's gate: attached to it, or in its epic.
SELECT ar.id, ar.title, v.id AS version_id, v.label AS version_label, v.review_state, v.review_note
FROM artifacts ar JOIN artifact_versions v ON v.id = ar.current_version_id
WHERE ar.type = 'mockup' AND ar.workspace_id = sqlc.arg(workspace_id)
  AND (EXISTS (SELECT 1 FROM ticket_artifacts ta WHERE ta.artifact_id = ar.id AND ta.ticket_id = sqlc.arg(ticket_id))
       OR (sqlc.narg(epic_id)::uuid IS NOT NULL AND ar.epic_id = sqlc.narg(epic_id)))
ORDER BY ar.created_at, ar.id;

-- name: ListTicketsGatedByMockup :many
-- Tickets a mockup can satisfy: attached to it, or in its epic.
SELECT t.id, t.key, t.epic_id,
  EXISTS (SELECT 1 FROM ticket_artifacts ta WHERE ta.ticket_id = t.id AND ta.artifact_id = sqlc.arg(artifact_id))::bool AS attached
FROM tickets t
WHERE t.workspace_id = sqlc.arg(workspace_id)
  AND (EXISTS (SELECT 1 FROM ticket_artifacts ta WHERE ta.ticket_id = t.id AND ta.artifact_id = sqlc.arg(artifact_id))
       OR (sqlc.narg(epic_id)::uuid IS NOT NULL AND t.epic_id = sqlc.narg(epic_id)))
ORDER BY t.key;

-- name: MockupReviewsSince :many
-- Decisions on any version of the ticket's gate candidates, for await_signal.
SELECT ar.id AS artifact_id, ar.title, v.label AS version_label, v.review_state, v.review_note, v.reviewed_at
FROM artifacts ar JOIN artifact_versions v ON v.artifact_id = ar.id
WHERE ar.type = 'mockup' AND ar.workspace_id = sqlc.arg(workspace_id)
  AND v.reviewed_at > sqlc.arg(since)::timestamptz AND v.review_state IN ('approved', 'changes_requested')
  AND (EXISTS (SELECT 1 FROM ticket_artifacts ta WHERE ta.artifact_id = ar.id AND ta.ticket_id = sqlc.arg(ticket_id))
       OR (sqlc.narg(epic_id)::uuid IS NOT NULL AND ar.epic_id = sqlc.narg(epic_id)))
ORDER BY v.reviewed_at, v.id;

-- name: SetArtifactChat :exec
-- The chat a persona made the artifact in (a mockup posted as a chat card):
-- reviews of it are told to that chat.
UPDATE artifacts SET chat_session_id = sqlc.arg(chat_id) WHERE id = sqlc.arg(id) AND workspace_id = sqlc.arg(workspace_id);

-- name: SetPageAudience :one
-- Person-only service; the lock above serializes edits with audience changes.
UPDATE artifacts SET audience=sqlc.arg(audience), owner_user_id=sqlc.narg(owner_user_id)
WHERE id=sqlc.arg(id) AND workspace_id=sqlc.arg(workspace_id)
 AND sqlc.narg(viewer)::uuid IS NOT NULL
 AND artifact_visible(audience, owner_user_id, sqlc.narg(viewer)::uuid)
RETURNING *;
