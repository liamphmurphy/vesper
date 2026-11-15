-- name: AddChatFollowup :one
INSERT INTO chat_followups (session_id, body) VALUES ($1, $2) RETURNING *;

-- name: ListChatFollowups :many
SELECT * FROM chat_followups WHERE session_id = $1 ORDER BY created_at, id;

-- name: CountChatFollowups :one
SELECT count(*) FROM chat_followups WHERE session_id = $1;

-- name: DeleteChatFollowup :execrows
DELETE FROM chat_followups WHERE id = $1 AND session_id = $2;

-- name: TakeNextChatFollowup :one
-- The oldest queued follow-up, removed as it is taken. The caller holds the
-- chat lock, so two turns ending can't take the same one.
DELETE FROM chat_followups WHERE id = (
  SELECT f.id FROM chat_followups f WHERE f.session_id = $1 ORDER BY f.created_at, f.id LIMIT 1
) RETURNING *;

-- name: SetChatParent :one
-- Makes a new hidden chat an aside of its parent, a thread when it is
-- anchored to one of the parent's messages, or a second opinion when run on
-- a chosen harness/model without disturbing the parent's prompt cache.
UPDATE chat_sessions SET parent_chat_id = sqlc.arg(parent_chat_id), anchor_message_id = sqlc.narg(anchor_message_id), second_opinion = sqlc.arg(second_opinion) WHERE id = sqlc.arg(id) RETURNING *;

-- name: ListChatAsides :many
-- A chat's asides, oldest first.
SELECT * FROM chat_sessions WHERE parent_chat_id = $1 ORDER BY created_at, id;

-- name: OpenChatTurnStart :one
-- When the run's newest unfinished turn began: what an aside sees of a reply
-- in progress starts here.
SELECT started_at FROM run_turns WHERE run_id = $1 AND status IN ('pending', 'running')
ORDER BY seq DESC LIMIT 1;

-- name: LiveTurnEvents :many
-- A running reply's latest text, tool calls and tool results, newest first:
-- an aside reads them back oldest first.
SELECT type, payload, at FROM run_events
WHERE run_id = $1 AND at >= $2
  AND (type IN ('tool_call', 'tool_result') OR (type = 'message' AND payload->>'role' = 'assistant'))
ORDER BY seq DESC LIMIT sqlc.arg(row_limit);
