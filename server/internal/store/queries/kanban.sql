-- Kanban board, ticket estimates and epic criteria (Architecture/ADR - Kanban board,
-- estimates and epic criteria). Service-level rules (the scale constant, people-win
-- estimates, the epic done gate) live in the tracker package.

-- name: SetTicketEstimate :one
-- Sets a ticket's point estimate and bumps its revision. NULL points clears the
-- estimate together with its rationale, author and time.
UPDATE tickets SET
  estimate_points = sqlc.narg(points),
  estimate_rationale = CASE WHEN sqlc.narg(points)::int IS NULL THEN NULL ELSE sqlc.narg(rationale) END,
  estimated_by_type = CASE WHEN sqlc.narg(points)::int IS NULL THEN NULL ELSE sqlc.narg(by_type) END,
  estimated_by_id = CASE WHEN sqlc.narg(points)::int IS NULL THEN NULL ELSE sqlc.narg(by_id)::uuid END,
  estimated_at = CASE WHEN sqlc.narg(points)::int IS NULL THEN NULL ELSE now() END,
  revision = revision + 1,
  updated_at = now()
WHERE id = sqlc.arg(id)
RETURNING *;

-- name: SetEpicStatus :one
UPDATE epics SET status = $2, updated_at = now() WHERE id = $1 AND workspace_id = $3 RETURNING *;

-- name: EpicRollups :many
-- Per-epic rollups for the board, bootstrap and PATCH /epics. Canceled tickets are
-- excluded from every ticket and point count.
SELECT
  e.id AS epic_id,
  (SELECT count(*) FROM epic_criteria c WHERE c.epic_id = e.id)::int AS criteria_total,
  (SELECT count(*) FROM epic_criteria c WHERE c.epic_id = e.id AND c.done)::int AS criteria_done,
  coalesce((SELECT sum(t.estimate_points) FROM tickets t WHERE t.epic_id = e.id AND t.status <> 'canceled'), 0)::int AS points_total,
  coalesce((SELECT sum(t.estimate_points) FROM tickets t WHERE t.epic_id = e.id AND t.status = 'done'), 0)::int AS points_done,
  (SELECT count(*) FROM tickets t WHERE t.epic_id = e.id AND t.status <> 'canceled')::int AS tickets_total,
  (SELECT count(*) FROM tickets t WHERE t.epic_id = e.id AND t.status NOT IN ('done', 'canceled'))::int AS tickets_open
FROM epics e
WHERE e.id = ANY(sqlc.arg(epic_ids)::uuid[]);

-- name: EpicOpenTicketKeys :many
-- What blocks the epic done gate on the ticket side.
SELECT key FROM tickets WHERE epic_id = $1 AND status NOT IN ('done', 'canceled') ORDER BY number;

-- name: EpicReviewState :one
-- What the epic review trigger needs: ticket counts excluding the review ticket.
-- total skips canceled tickets, so an epic whose work was all canceled gets no review.
SELECT
  count(*) FILTER (WHERE NOT epic_review AND status <> 'canceled')::int AS total,
  count(*) FILTER (WHERE NOT epic_review AND status IN ('backlog', 'todo', 'in_progress'))::int AS unfinished,
  coalesce(bool_or(epic_review), false)::boolean AS has_review
FROM tickets WHERE epic_id = $1;

-- name: EpicTopAssignee :one
-- The agent holding most of the epic's regular tickets, newest activity breaking ties.
SELECT assignee_agent_id FROM tickets
WHERE epic_id = $1 AND NOT epic_review AND assignee_agent_id IS NOT NULL
GROUP BY assignee_agent_id
ORDER BY count(*) DESC, max(updated_at) DESC
LIMIT 1;

-- name: ListEpicReviewTickets :many
SELECT key, title, status, branch, pr_url, pr_state FROM tickets
WHERE epic_id = $1 AND NOT epic_review ORDER BY number;

-- name: ListEpicCriteria :many
SELECT * FROM epic_criteria WHERE epic_id = $1 ORDER BY position;

-- name: GetEpicCriterion :one
SELECT c.* FROM epic_criteria c JOIN epics e ON e.id = c.epic_id
WHERE c.id = $1 AND e.workspace_id = $2;

-- name: GetEpicCriterionByPosition :one
SELECT * FROM epic_criteria WHERE epic_id = $1 AND position = $2;

-- name: CreateEpicCriterion :one
-- Appends at the end. Concurrent appends collide on UNIQUE (epic_id, position): retry
-- on 23505. The constraint is deferrable, so it can't be an ON CONFLICT arbiter.
INSERT INTO epic_criteria (epic_id, position, text)
VALUES ($1, (SELECT coalesce(max(position), 0) + 1 FROM epic_criteria WHERE epic_id = $1), $2)
RETURNING *;

-- name: UpdateEpicCriterionText :one
UPDATE epic_criteria SET text = $2 WHERE id = $1 RETURNING *;

-- name: SetEpicCriterionDone :one
-- Records who checked it; unticking clears who and when.
UPDATE epic_criteria SET
  done = sqlc.arg(done),
  checked_by_type = CASE WHEN sqlc.arg(done) THEN sqlc.narg(by_type) ELSE NULL END,
  checked_by_id = CASE WHEN sqlc.arg(done) THEN sqlc.narg(by_id)::uuid ELSE NULL END,
  checked_at = CASE WHEN sqlc.arg(done) THEN now() ELSE NULL END
WHERE id = sqlc.arg(id)
RETURNING *;

-- name: DeleteEpicCriterion :one
DELETE FROM epic_criteria WHERE id = $1 RETURNING epic_id, position;

-- name: CompactEpicCriteria :exec
-- Closes the gap after a delete so positions stay 1..n. The deferrable unique
-- constraint lets this shift rows in one statement.
UPDATE epic_criteria SET position = position - 1 WHERE epic_id = $1 AND position > $2;

-- name: ReorderEpicCriterion :exec
UPDATE epic_criteria SET position = CASE
 WHEN id = sqlc.arg(id) THEN sqlc.arg(new_position)::int
 WHEN position > sqlc.arg(old_position)::int AND position <= sqlc.arg(new_position)::int THEN position - 1
 WHEN position < sqlc.arg(old_position)::int AND position >= sqlc.arg(new_position)::int THEN position + 1
 ELSE position END
WHERE epic_id = sqlc.arg(epic_id) AND position BETWEEN least(sqlc.arg(old_position)::int, sqlc.arg(new_position)::int) AND greatest(sqlc.arg(old_position)::int, sqlc.arg(new_position)::int);

-- name: BoardTickets :many
WITH ranked AS (
 SELECT t.id, t.key, t.number, t.title, t.status, t.priority, t.due_date, t.estimate_points,
 t.pr_number, t.pr_state, t.pr_url, t.updated_at, t.sort_order,
 p.key AS project_key, e.id AS epic_id, e.name AS epic_name,
 a.id AS agent_id, a.name AS agent_name, a.handle AS agent_handle, a.color_index AS agent_color_index,
 (SELECT count(*) FROM ticket_dependencies d JOIN tickets b ON b.id=d.blocker_id WHERE d.ticket_id=t.id AND b.status <> 'done')::int AS unmet_dependencies,
 (SELECT count(*) FROM acceptance_criteria c WHERE c.ticket_id=t.id)::int AS criteria_total,
 (SELECT count(*) FROM acceptance_criteria c WHERE c.ticket_id=t.id AND c.done)::int AS criteria_done,
 count(*) OVER (PARTITION BY t.status)::int AS column_count,
 coalesce(sum(t.estimate_points) OVER (PARTITION BY t.status),0)::int AS column_points,
 row_number() OVER (PARTITION BY t.status ORDER BY
   CASE WHEN t.status IN ('done','canceled') THEN t.updated_at END DESC,
   CASE WHEN t.status NOT IN ('done','canceled') THEN CASE t.priority WHEN 'urgent' THEN 0 WHEN 'high' THEN 1 WHEN 'medium' THEN 2 WHEN 'low' THEN 3 ELSE 4 END END,
   t.sort_order, t.number, t.id) AS row_num
 FROM tickets t JOIN projects p ON p.id=t.project_id
 LEFT JOIN epics e ON e.id=t.epic_id LEFT JOIN agents a ON a.id=t.assignee_agent_id
 WHERE t.workspace_id=sqlc.arg(workspace_id) AND t.project_id=sqlc.arg(project_id)
 AND (sqlc.narg(epic_id)::uuid IS NULL OR t.epic_id=sqlc.narg(epic_id))
 AND (sqlc.narg(assignee)::text IS NULL OR a.handle=sqlc.narg(assignee))
 AND (sqlc.arg(include_canceled)::bool OR t.status <> 'canceled')
)
SELECT * FROM ranked WHERE status NOT IN ('done','canceled') OR row_num <= 50
ORDER BY status, row_num;

-- name: GetEpicReviewTicket :one
SELECT * FROM tickets WHERE epic_id = $1 AND epic_review ORDER BY number LIMIT 1;

-- name: EpicUnfinishedKeys :many
-- Non-review tickets still being worked, for the final review's dispatch blocker.
SELECT key, status FROM tickets
WHERE epic_id = $1 AND NOT epic_review AND status IN ('backlog', 'todo', 'in_progress')
ORDER BY number;
