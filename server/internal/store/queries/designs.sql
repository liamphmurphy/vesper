-- name: ClearDesignFrameLinks :exec
DELETE FROM design_frame_links WHERE canvas_id = $1;

-- name: AddDesignFrameLinks :exec
-- Indexes a design's frame → ticket links from its current body. Ticket keys
-- resolve within the design's workspace; unknown keys are skipped.
INSERT INTO design_frame_links (canvas_id, node_id, ticket_id)
SELECT DISTINCT @canvas_id::uuid, n.node_id, t.id
FROM unnest(@node_ids::text[]) WITH ORDINALITY AS n(node_id, i)
JOIN unnest(@ticket_keys::text[]) WITH ORDINALITY AS k(ticket_key, i) USING (i)
JOIN chat_canvases cv ON cv.id = @canvas_id::uuid
JOIN chat_sessions c ON c.id = cv.session_id
JOIN tickets t ON t.workspace_id = c.workspace_id AND t.key = k.ticket_key
ON CONFLICT DO NOTHING;

-- name: ListDesignFrameLinks :many
SELECT l.node_id, t.key AS ticket_key FROM design_frame_links l JOIN tickets t ON t.id = l.ticket_id
WHERE l.canvas_id = $1 ORDER BY l.node_id, t.key;

-- name: ListUserDesigns :many
-- The person's designs with their current bodies, most recently changed first.
SELECT cv.id, cv.title, cv.updated_at, c.id AS chat_id, v.seq, v.body, s.project_id,
  (SELECT count(*) FROM design_proposals p WHERE p.canvas_id = cv.id AND p.status = 'pending')::int AS pending_proposals,
  EXISTS (SELECT 1 FROM chat_canvas_versions a WHERE a.canvas_id = cv.id AND a.author_type = 'agent')::boolean AS persona_edited
FROM chat_canvases cv
JOIN chat_sessions c ON c.id = cv.session_id
JOIN LATERAL (SELECT seq, body FROM chat_canvas_versions WHERE canvas_id = cv.id ORDER BY seq DESC LIMIT 1) v ON true
LEFT JOIN design_settings s ON s.canvas_id = cv.id
WHERE c.workspace_id = @workspace_id AND c.created_by = @user_id AND cv.kind = 'design' AND NOT c.hidden
  AND (sqlc.narg(project_id)::uuid IS NULL OR s.project_id = sqlc.narg(project_id)::uuid)
ORDER BY cv.updated_at DESC, cv.id DESC
LIMIT 200;

-- name: GetDesignSettings :one
-- A design's switches; a design without a row has the defaults.
SELECT cv.id AS canvas_id,
  COALESCE(s.direct_edit, false)::boolean AS direct_edit,
  COALESCE(s.persona_paused, false)::boolean AS persona_paused,
  s.project_id
FROM chat_canvases cv LEFT JOIN design_settings s ON s.canvas_id = cv.id
WHERE cv.id = $1;

-- name: UpsertDesignSettings :exec
INSERT INTO design_settings (canvas_id, direct_edit, persona_paused, project_id)
VALUES (@canvas_id, @direct_edit, @persona_paused, @project_id)
ON CONFLICT (canvas_id) DO UPDATE SET direct_edit = EXCLUDED.direct_edit, persona_paused = EXCLUDED.persona_paused,
  project_id = EXCLUDED.project_id, updated_at = now();

-- name: CreateDesignAsset :one
INSERT INTO design_assets (canvas_id, id, workspace_id, user_id, blob_key, mime, width, height, size_bytes)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9) RETURNING *;

-- name: GetDesignAsset :one
SELECT * FROM design_assets WHERE canvas_id = $1 AND id = $2;

-- name: CopyDesignAssets :exec
INSERT INTO design_assets (canvas_id, id, workspace_id, user_id, blob_key, mime, width, height, size_bytes)
SELECT @to_canvas::uuid, id, workspace_id, user_id, blob_key, mime, width, height, size_bytes FROM design_assets WHERE canvas_id = @from_canvas::uuid;

-- name: DesignAssetBytes :one
-- Each stored design image once per person, for the shared Library quota.
SELECT COALESCE(sum(size_bytes), 0)::bigint AS total FROM (
  SELECT DISTINCT blob_key, size_bytes FROM design_assets WHERE workspace_id = $1 AND user_id = $2
) a;

-- name: DeleteDesignAsset :exec
DELETE FROM design_assets WHERE canvas_id = $1 AND id = $2;

-- name: UserHasDesignBlob :one
SELECT EXISTS (SELECT 1 FROM design_assets WHERE workspace_id = $1 AND user_id = $2 AND blob_key = $3);

-- name: CreateDesignProposal :one
INSERT INTO design_proposals (canvas_id, chat_id, run_id, turn_id, agent_id, base_seq, summary, ops, status, result_seq, resolved_at)
VALUES (@canvas_id, @chat_id, @run_id, sqlc.narg(turn_id), @agent_id, @base_seq, @summary, @ops, @status, sqlc.narg(result_seq),
  CASE WHEN @status::text IN ('pending', 'draft') THEN NULL ELSE now() END)
RETURNING *;

-- name: ListDesignProposals :many
-- Oldest first, as the review shows them. Drafts are the persona's work in
-- progress, never shown.
SELECT * FROM design_proposals
WHERE canvas_id = @canvas_id AND status <> 'draft' AND (sqlc.narg(status)::text IS NULL OR status = sqlc.narg(status)::text)
ORDER BY created_at, id
LIMIT 200;

-- name: GetDesignDraft :one
-- The draft a turn is building on a design.
SELECT * FROM design_proposals WHERE canvas_id = @canvas_id AND turn_id = @turn_id AND status = 'draft';

-- name: LockDesignDraft :one
SELECT * FROM design_proposals WHERE id = @id AND status = 'draft' FOR UPDATE;

-- name: UpdateDesignDraft :one
UPDATE design_proposals SET ops = @ops, summary = @summary WHERE id = @id AND status = 'draft' RETURNING *;

-- name: SettledDesignDrafts :many
-- Drafts whose turn has ended (or is gone), on one design or from one turn,
-- oldest first: they are ready to publish.
SELECT p.* FROM design_proposals p
LEFT JOIN run_turns t ON t.id = p.turn_id
WHERE p.status = 'draft'
  AND (sqlc.narg(canvas_id)::uuid IS NULL OR p.canvas_id = sqlc.narg(canvas_id)::uuid)
  AND (sqlc.narg(turn_id)::uuid IS NULL OR p.turn_id = sqlc.narg(turn_id)::uuid)
  AND (t.id IS NULL OR t.status <> 'running')
ORDER BY p.created_at, p.id;

-- name: PublishDesignDraft :one
UPDATE design_proposals SET status = @status, ops = @ops, base_seq = @base_seq, result_seq = sqlc.narg(result_seq),
  resolved_at = CASE WHEN @status::text = 'applied' THEN now() ELSE NULL END
WHERE id = @id AND status = 'draft' RETURNING *;

-- name: DeleteDesignDraft :exec
DELETE FROM design_proposals WHERE id = @id AND status = 'draft';

-- name: DesignHasOnlyPersonaWork :one
-- True while the person hasn't changed the design since it was made (version
-- 1, blank or a starter, is scaffolding) or reviewed a suggestion on it: a
-- persona's draft then has nothing of theirs to change.
SELECT (NOT EXISTS (SELECT 1 FROM chat_canvas_versions v WHERE v.canvas_id = @canvas_id AND v.author_type = 'user' AND v.seq > 1)
   AND NOT EXISTS (SELECT 1 FROM design_proposals p WHERE p.canvas_id = @canvas_id AND p.status IN ('pending', 'resolved')))::bool AS only_persona;

-- name: LockDesignProposal :one
SELECT * FROM design_proposals WHERE id = @id AND canvas_id = @canvas_id FOR UPDATE;

-- name: ResolveDesignProposal :one
UPDATE design_proposals SET status = 'resolved', decisions = @decisions, result_seq = sqlc.narg(result_seq), resolved_at = now()
WHERE id = @id RETURNING *;

-- name: DesignFeedbackBetween :many
-- The review feedback notices (system messages that carry a canvas ref) posted
-- after one user message and before another, for the later one's turn.
SELECT * FROM chat_messages
WHERE session_id = @session_id AND role = 'system' AND seq > @after_seq AND seq < @before_seq
  AND context_refs @> '[{"kind": "canvas"}]'::jsonb
ORDER BY seq;

-- name: CountDesignProposalsByCanvas :many
SELECT canvas_id, count(*)::int AS pending FROM design_proposals
WHERE canvas_id = ANY(@ids::uuid[]) AND status = 'pending' GROUP BY canvas_id;

-- name: ListTicketDesignFrames :many
-- The design frames linked to a ticket, or for an epic review (epic_id set)
-- to any ticket of the epic, with their design's current body. Most recently
-- changed designs first; at most 10 frames reach a run.
SELECT l.canvas_id, l.node_id, cv.title, v.body
FROM (SELECT DISTINCT fl.canvas_id, fl.node_id, t.workspace_id FROM design_frame_links fl JOIN tickets t ON t.id = fl.ticket_id
      WHERE t.id = @ticket_id OR (sqlc.narg(epic_id)::uuid IS NOT NULL AND t.epic_id = sqlc.narg(epic_id)::uuid)) l
JOIN chat_canvases cv ON cv.id = l.canvas_id AND cv.kind = 'design'
JOIN chat_sessions c ON c.id = cv.session_id AND c.workspace_id = l.workspace_id
JOIN LATERAL (SELECT body FROM chat_canvas_versions WHERE canvas_id = cv.id ORDER BY seq DESC LIMIT 1) v ON true
ORDER BY cv.updated_at DESC, l.node_id
LIMIT 10;
