-- name: CreateTicket :one
INSERT INTO tickets (
  workspace_id, project_id, number, key, title, description_md, status, priority,
  epic_id, assignee_agent_id, reviewer_user_id, created_by_user_id, estimate, due_date, sort_order, requires_mockup, epic_review
) VALUES (
  $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14,
  (SELECT coalesce(max(sort_order), 0) + 1 FROM tickets WHERE project_id = $2), $15, $16
) RETURNING *;

-- name: GetTicketByKey :one
SELECT * FROM tickets WHERE workspace_id = $1 AND key = $2;

-- name: TicketKeysByNumber :many
-- A bare ticket number ("251") resolved across the workspace's active projects.
SELECT t.key, p.key AS project_key
FROM tickets t JOIN projects p ON p.id = t.project_id
WHERE t.workspace_id = $1 AND t.number = $2 AND NOT p.archived
ORDER BY p.key;

-- name: LockTicketByKey :one
SELECT * FROM tickets WHERE workspace_id = $1 AND key = $2 FOR UPDATE;

-- name: LockTicketByID :one
SELECT * FROM tickets WHERE workspace_id = $1 AND id = $2 FOR UPDATE;

-- name: TicketProjectID :one
SELECT project_id FROM tickets WHERE workspace_id = $1 AND id = $2;

-- name: UpdateTicket :one
-- Callers load the row, apply the patch in Go and write every field back.
UPDATE tickets SET
  title = $2, description_md = $3, status = $4, priority = $5, epic_id = $6,
  assignee_agent_id = $7, reviewer_user_id = $8, estimate = $9, due_date = $10, requires_mockup = $11,
  revision = revision + 1, estimate_points = $12, estimate_rationale = $13,
  estimated_by_type = $14, estimated_by_id = $15, estimated_at = $16
WHERE id = $1
RETURNING *;

-- name: ListTickets :many
SELECT
  t.id, t.key, t.number, t.title, t.status, t.priority, t.due_date, t.estimate, t.estimate_points,
  t.pr_number, t.pr_state, t.pr_url, t.sort_order, t.created_at, t.updated_at,
  (SELECT count(*) FROM ticket_dependencies d JOIN tickets b ON b.id=d.blocker_id WHERE d.ticket_id=t.id AND b.status<>'done')::int AS unmet_dependencies,
  p.key AS project_key, p.color AS project_color,
  e.id AS epic_id, e.name AS epic_name,
  a.id AS agent_id, a.name AS agent_name, a.handle AS agent_handle, a.color_index AS agent_color_index,
  (SELECT count(*) FROM acceptance_criteria c WHERE c.ticket_id = t.id)::int AS criteria_total,
  (SELECT count(*) FROM acceptance_criteria c WHERE c.ticket_id = t.id AND c.done)::int AS criteria_done
FROM tickets t
JOIN projects p ON p.id = t.project_id
LEFT JOIN epics e ON e.id = t.epic_id
LEFT JOIN agents a ON a.id = t.assignee_agent_id
WHERE t.workspace_id = sqlc.arg(workspace_id)
  AND (NOT p.archived OR sqlc.narg(project_id)::uuid IS NOT NULL)
  AND (NOT sqlc.arg(ready)::boolean OR (
    NOT p.archived AND t.assignee_agent_id IS NOT NULL AND t.status NOT IN ('done', 'canceled')
    AND NOT EXISTS(SELECT 1 FROM runs r WHERE r.ticket_id=t.id AND r.state NOT IN ('completed','failed','cancelled'))
    AND NOT EXISTS(SELECT 1 FROM ticket_dependencies d JOIN tickets b ON b.id=d.blocker_id WHERE d.ticket_id=t.id AND b.status<>'done')
  ))
  AND (NOT sqlc.arg(needs_human)::bool OR t.status='in_review' OR EXISTS (SELECT 1 FROM approval_requests ap WHERE ap.ticket_id=t.id AND ap.state='pending'))
  AND (sqlc.narg(epic_id)::uuid IS NULL OR t.epic_id=sqlc.narg(epic_id))
  AND (sqlc.narg(project_id)::uuid IS NULL OR t.project_id = sqlc.narg(project_id))
  AND (sqlc.narg(statuses)::text[] IS NULL OR t.status = ANY (sqlc.narg(statuses)::text[]))
  AND (sqlc.narg(assignee_agent_id)::uuid IS NULL OR t.assignee_agent_id = sqlc.narg(assignee_agent_id))
  AND (NOT sqlc.arg(only_agent_owned)::bool OR t.assignee_agent_id IS NOT NULL)
  AND (sqlc.narg(label_id)::uuid IS NULL OR EXISTS (
        SELECT 1 FROM ticket_labels tl WHERE tl.ticket_id = t.id AND tl.label_id = sqlc.narg(label_id)))
  AND (sqlc.narg(q)::text IS NULL
       OR t.search @@ websearch_to_tsquery('english', sqlc.narg(q))
       OR t.key ILIKE sqlc.narg(q) || '%'
       OR t.number::text = ltrim(sqlc.narg(q), '#')
       OR t.title ILIKE '%' || sqlc.narg(q) || '%')
ORDER BY
  CASE t.status WHEN 'in_progress' THEN 0 WHEN 'in_review' THEN 1 WHEN 'todo' THEN 2 WHEN 'backlog' THEN 3 ELSE 4 END,
  CASE t.priority WHEN 'urgent' THEN 0 WHEN 'high' THEN 1 WHEN 'medium' THEN 2 WHEN 'low' THEN 3 ELSE 4 END,
  t.updated_at DESC
LIMIT CASE WHEN sqlc.narg(project_id)::uuid IS NOT NULL OR sqlc.narg(epic_id)::uuid IS NOT NULL THEN NULL ELSE 500 END;

-- name: ListLabelsForTickets :many
SELECT tl.ticket_id, l.id, l.name, l.color
FROM ticket_labels tl JOIN labels l ON l.id = tl.label_id
WHERE tl.ticket_id = ANY (sqlc.arg(ticket_ids)::uuid[])
ORDER BY l.name;

-- name: ClearTicketLabels :exec
DELETE FROM ticket_labels WHERE ticket_id = $1;

-- name: AddTicketLabels :exec
INSERT INTO ticket_labels (ticket_id, label_id)
SELECT $1, unnest(sqlc.arg(label_ids)::uuid[])
ON CONFLICT DO NOTHING;

-- name: ListCriteria :many
SELECT * FROM acceptance_criteria WHERE ticket_id = $1 ORDER BY position, created_at;

-- name: CreateCriterion :one
INSERT INTO acceptance_criteria (ticket_id, position, text)
VALUES ($1, (SELECT coalesce(max(position), 0) + 1 FROM acceptance_criteria WHERE ticket_id = $1), $2)
RETURNING *;

-- name: CreateCriterionAt :one
INSERT INTO acceptance_criteria (ticket_id, position, text, done) VALUES ($1, $2, $3, $4) RETURNING *;

-- name: SaveCriterionDraft :one
UPDATE acceptance_criteria SET position = $2, text = $3, done = $4 WHERE id = $1 RETURNING *;

-- name: GetCriterion :one
SELECT c.* FROM acceptance_criteria c JOIN tickets t ON t.id = c.ticket_id
WHERE c.id = $1 AND t.workspace_id = $2;

-- name: UpdateCriterion :one
UPDATE acceptance_criteria SET text = $2, done = $3 WHERE id = $1 RETURNING *;

-- name: DeleteCriterion :exec
DELETE FROM acceptance_criteria WHERE id = $1;

-- name: CreateComment :one
INSERT INTO comments (workspace_id, ticket_id, parent_comment_id, author_type, author_id, body_md)
VALUES ($1, $2, $3, $4, $5, $6) RETURNING *;

-- name: GetComment :one
SELECT * FROM comments WHERE id = $1 AND ticket_id = $2;

-- name: InsertActivity :one
INSERT INTO activity_events (workspace_id, ticket_id, epic_id, actor_type, actor_id, verb, payload, created_at)
-- clock_timestamp, not now(): events from one transaction must keep their order.
VALUES ($1, $2, $3, $4, $5, $6, $7, coalesce(sqlc.narg(created_at)::timestamptz, clock_timestamp()))
RETURNING *;

-- name: ListTicketActivity :many
SELECT * FROM activity_events WHERE ticket_id = $1 ORDER BY created_at, seq;

-- name: SetTicketCode :exec
-- Branch and PR fields. Agents set these via the Agent API (Phase 4); the PR
-- sync job (Phase 5) refreshes state and diff stats.
UPDATE tickets SET branch = $2, pr_number = $3, pr_url = $4, pr_state = $5, pr_additions = $6, pr_deletions = $7
WHERE id = $1;

-- name: GetTicketByID :one
SELECT * FROM tickets WHERE id = $1;

-- name: HumanCommentsSince :many
-- Comments by people on a ticket after a point in time (await_signal).
SELECT c.id, c.body_md, c.created_at, u.name AS author
FROM comments c JOIN users u ON u.id = c.author_id
WHERE c.ticket_id = $1 AND c.author_type = 'user' AND c.created_at > $2
ORDER BY c.created_at;

-- name: ListTicketComments :many
-- Recent comments with author names, for get_ticket.
SELECT c.id, c.parent_comment_id, c.author_type, c.body_md, c.created_at,
  coalesce(u.name, a.name, 'Unknown')::text AS author
FROM comments c
LEFT JOIN users u ON c.author_type = 'user' AND u.id = c.author_id
LEFT JOIN agents a ON c.author_type = 'agent' AND a.id = c.author_id
WHERE c.ticket_id = $1
ORDER BY c.created_at DESC
LIMIT 20;

-- name: AgentQueue :many
-- Tickets assigned to an agent that aren't done, most urgent first.
SELECT t.key, t.title, t.status, t.priority FROM tickets t JOIN projects p ON p.id=t.project_id
WHERE NOT p.archived AND t.assignee_agent_id = $1 AND t.status NOT IN ('done', 'canceled')
ORDER BY CASE t.priority WHEN 'urgent' THEN 0 WHEN 'high' THEN 1 WHEN 'medium' THEN 2 WHEN 'low' THEN 3 ELSE 4 END,
  CASE t.status WHEN 'in_progress' THEN 0 WHEN 'todo' THEN 1 WHEN 'backlog' THEN 2 ELSE 3 END, t.created_at
LIMIT 20;
