-- +goose Up
-- Keep PersonaDockChats O(active) and ListInbox O(matching) as history grows.
ALTER TABLE chat_sessions ADD COLUMN last_assistant_seq bigint NOT NULL DEFAULT 0;

UPDATE chat_sessions c
SET last_assistant_seq = m.max_seq
FROM (
  SELECT session_id, max(seq) AS max_seq
  FROM chat_messages
  WHERE role = 'assistant'
  GROUP BY session_id
) m
WHERE c.id = m.session_id;

-- +goose StatementBegin
CREATE FUNCTION chat_messages_sync_assistant_seq_ins() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM new_rows n
    JOIN chat_sessions c ON c.id = n.session_id
    WHERE n.role = 'assistant' AND n.seq > c.last_assistant_seq
  ) THEN
    UPDATE chat_sessions c
    SET last_assistant_seq = greatest(c.last_assistant_seq, n.max_seq)
    FROM (
      SELECT session_id, max(seq) AS max_seq
      FROM new_rows
      WHERE role = 'assistant'
      GROUP BY session_id
    ) n
    WHERE c.id = n.session_id AND n.max_seq > c.last_assistant_seq;
  END IF;
  RETURN NULL;
END;
$$;
-- +goose StatementEnd

-- +goose StatementBegin
CREATE FUNCTION chat_messages_sync_assistant_seq_del() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  -- Skip UPDATE when parent chat_sessions rows are gone (cascade delete) or when
  -- last_assistant_seq did not change; a 0-row UPDATE would emit an empty chat.updated.
  IF EXISTS (
    SELECT 1
    FROM (
      SELECT DISTINCT session_id
      FROM old_rows
      WHERE role = 'assistant'
    ) d
    JOIN chat_sessions c ON c.id = d.session_id
    WHERE c.last_assistant_seq IS DISTINCT FROM coalesce((
      SELECT max(m.seq)
      FROM chat_messages m
      WHERE m.session_id = d.session_id AND m.role = 'assistant'
    ), 0)
  ) THEN
    UPDATE chat_sessions c
    SET last_assistant_seq = sub.max_seq
    FROM (
      SELECT d.session_id, coalesce((
        SELECT max(m.seq)
        FROM chat_messages m
        WHERE m.session_id = d.session_id AND m.role = 'assistant'
      ), 0) AS max_seq
      FROM (
        SELECT DISTINCT session_id
        FROM old_rows
        WHERE role = 'assistant'
      ) d
    ) sub
    WHERE c.id = sub.session_id AND c.last_assistant_seq IS DISTINCT FROM sub.max_seq;
  END IF;
  RETURN NULL;
END;
$$;
-- +goose StatementEnd

CREATE TRIGGER chat_messages_assistant_seq_ins
  AFTER INSERT ON chat_messages
  REFERENCING NEW TABLE AS new_rows
  FOR EACH STATEMENT
  EXECUTE FUNCTION chat_messages_sync_assistant_seq_ins();

CREATE TRIGGER chat_messages_assistant_seq_del
  AFTER DELETE ON chat_messages
  REFERENCING OLD TABLE AS old_rows
  FOR EACH STATEMENT
  EXECUTE FUNCTION chat_messages_sync_assistant_seq_del();

-- PersonaDockChats indexes: active/unread chats, pending proposals, waiting chat runs, and last assistant reply.
CREATE INDEX chat_sessions_dock_active_idx
  ON chat_sessions (workspace_id, created_by)
  WHERE NOT archived AND NOT hidden AND (state = 'running' OR last_assistant_seq > last_read_seq);

CREATE INDEX persona_proposals_pending_idx
  ON persona_proposals (chat_id)
  WHERE state = 'pending';

CREATE INDEX runs_waiting_human_idx
  ON runs (workspace_id, id)
  WHERE state = 'waiting' AND wait_reason IN ('human_reply', 'approval');

CREATE INDEX chat_messages_assistant_seq_idx
  ON chat_messages (session_id, seq DESC)
  WHERE role = 'assistant';

-- ListInbox indexes: restrict scans to comments with '@', open/review tickets, active/latest-failed runs, and pending gates.
CREATE INDEX comments_workspace_at_idx
  ON comments (workspace_id, created_at DESC)
  WHERE strpos(body_md, '@') > 0;

CREATE INDEX comments_at_trgm_idx
  ON comments USING gin (lower(body_md) gin_trgm_ops)
  WHERE strpos(body_md, '@') > 0;

CREATE INDEX tickets_open_agent_idx
  ON tickets (workspace_id)
  WHERE assignee_agent_id IS NOT NULL AND status NOT IN ('done', 'canceled');

CREATE INDEX tickets_in_review_reviewer_idx
  ON tickets (workspace_id, reviewer_user_id)
  WHERE status = 'in_review';

CREATE INDEX runs_running_ticket_idx
  ON runs (workspace_id, ticket_id, started_at)
  WHERE state = 'running' AND ticket_id IS NOT NULL;

CREATE INDEX runs_failed_blocked_top_idx
  ON runs (workspace_id, ticket_id, started_at DESC)
  WHERE state IN ('blocked', 'failed') AND parent_run_id IS NULL AND ticket_id IS NOT NULL;

CREATE INDEX runs_ticket_top_started_idx
  ON runs (ticket_id, started_at DESC)
  WHERE parent_run_id IS NULL;

CREATE INDEX activity_events_pr_merged_idx
  ON activity_events (workspace_id, created_at DESC)
  WHERE verb = 'pr_merged';

CREATE INDEX artifact_versions_inbox_suggestions_idx
  ON artifact_versions (artifact_id, created_at DESC)
  WHERE state IN ('suggested', 'published', 'rejected') AND based_on_version_id IS NOT NULL;

CREATE INDEX artifact_versions_mockup_review_idx
  ON artifact_versions (artifact_id, created_at DESC)
  WHERE review_state IS NOT NULL;

CREATE INDEX workflow_steps_inbox_gate_idx
  ON workflow_steps (run_id, created_at DESC)
  WHERE state = 'waiting' OR decision <> '';

-- +goose Down
DROP INDEX IF EXISTS workflow_steps_inbox_gate_idx;
DROP INDEX IF EXISTS artifact_versions_mockup_review_idx;
DROP INDEX IF EXISTS artifact_versions_inbox_suggestions_idx;
DROP INDEX IF EXISTS activity_events_pr_merged_idx;
DROP INDEX IF EXISTS runs_ticket_top_started_idx;
DROP INDEX IF EXISTS runs_failed_blocked_top_idx;
DROP INDEX IF EXISTS runs_running_ticket_idx;
DROP INDEX IF EXISTS tickets_in_review_reviewer_idx;
DROP INDEX IF EXISTS tickets_open_agent_idx;
DROP INDEX IF EXISTS comments_at_trgm_idx;
DROP INDEX IF EXISTS comments_workspace_at_idx;
DROP INDEX IF EXISTS chat_messages_assistant_seq_idx;
DROP INDEX IF EXISTS runs_waiting_human_idx;
DROP INDEX IF EXISTS persona_proposals_pending_idx;
DROP INDEX IF EXISTS chat_sessions_dock_active_idx;
DROP TRIGGER IF EXISTS chat_messages_assistant_seq_del ON chat_messages;
DROP TRIGGER IF EXISTS chat_messages_assistant_seq_ins ON chat_messages;
DROP FUNCTION IF EXISTS chat_messages_sync_assistant_seq_del();
DROP FUNCTION IF EXISTS chat_messages_sync_assistant_seq_ins();
ALTER TABLE chat_sessions DROP COLUMN IF EXISTS last_assistant_seq;
