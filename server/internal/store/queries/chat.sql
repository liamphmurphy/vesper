-- name: CreateChatSession :one
-- Without a persona_id the chat gets its creator's default persona (none
-- when they have no default). Callers check that a given persona_id is the
-- creator's own.
INSERT INTO chat_sessions (workspace_id, project_id, title, created_by, agent_id, harness, model, effort, auto_model, persona_id, hidden, space_id, temporary)
VALUES (sqlc.arg(workspace_id), sqlc.arg(project_id), sqlc.arg(title), sqlc.arg(created_by), sqlc.arg(agent_id), sqlc.arg(harness), sqlc.arg(model), sqlc.arg(effort), sqlc.arg(auto_model),
  COALESCE(sqlc.narg(persona_id)::uuid, (SELECT p.id FROM personas p WHERE p.workspace_id = sqlc.arg(workspace_id) AND p.user_id = sqlc.arg(created_by) AND p.is_default)), sqlc.arg(hidden),
  sqlc.narg(space_id), sqlc.arg(temporary))
RETURNING *;

-- name: SetChatProject :one
-- Returns no row when the revision is stale.
UPDATE chat_sessions SET project_id = sqlc.narg(project_id), revision = revision + 1, updated_at = now()
WHERE id = sqlc.arg(id) AND workspace_id = sqlc.arg(workspace_id) AND revision = sqlc.arg(revision) RETURNING *;

-- name: SetChatConnectors :one
UPDATE chat_sessions SET connector_ids = $2 WHERE id = $1 RETURNING *;

-- name: SetChatRepo :one
-- The initial repository; subsequent selections use ActivateChatRepository.
UPDATE chat_sessions SET repo_url = $2 WHERE id = $1 RETURNING *;

-- name: SetChatCommitEmail :one
-- The address a coding chat's commits are authored as. Not a revision change:
-- it applies from the next turn and can be picked while one runs.
UPDATE chat_sessions SET commit_email = $3 WHERE id = $1 AND workspace_id = $2 RETURNING *;

-- name: AddChatWorkBranches :exec
-- Appends the branches a coding chat's persona pushed that it doesn't list
-- yet, keeping the order they were first seen in, up to @max_branches.
UPDATE chat_sessions SET work_branches = (
  SELECT COALESCE(array_agg(b ORDER BY first), '{}') FROM (
    SELECT b, min(n) AS first FROM unnest(work_branches || @branches::text[]) WITH ORDINALITY AS t(b, n)
    GROUP BY b ORDER BY first LIMIT @max_branches::int
  ) kept
)
WHERE id = @id AND repo_url IS NOT NULL;

-- name: ListChatSessions :many
SELECT c.* FROM chat_sessions c
WHERE c.workspace_id = $1 AND c.project_id = $2 AND c.created_by = $3 AND NOT c.archived AND NOT c.hidden
  AND NOT EXISTS (SELECT 1 FROM chat_spaces sp WHERE sp.id = c.space_id AND sp.app IS NOT NULL)
ORDER BY COALESCE(c.last_message_at, c.created_at) DESC, c.id DESC
LIMIT $4;

-- name: GetChatSession :one
SELECT * FROM chat_sessions WHERE id = $1 AND workspace_id = $2;

-- name: RenameChatSession :one
-- Returns no row when the revision is stale.
UPDATE chat_sessions SET title = $3, revision = revision + 1, updated_at = now()
WHERE id = $1 AND workspace_id = $2 AND revision = $4 RETURNING *;

-- name: ArchiveChatSession :one
UPDATE chat_sessions SET archived = true, revision = revision + 1, updated_at = now()
WHERE id = $1 AND workspace_id = $2 AND revision = $3 RETURNING *;

-- name: AppendChatMessage :one
-- seq is allocated in the statement; concurrent appenders to one session collide on
-- UNIQUE (session_id, seq) and the loser must retry.
WITH next AS (
  SELECT COALESCE(MAX(m.seq), 0) + 1 AS seq FROM chat_messages m WHERE m.session_id = sqlc.arg(session_id)
), ins AS (
  INSERT INTO chat_messages (session_id, seq, role, body_md, harness, model, run_id, run_turn_id, context_refs, citations, usage, persona_id)
  SELECT sqlc.arg(session_id), next.seq, sqlc.arg(role), sqlc.arg(body_md), sqlc.narg(harness), sqlc.narg(model), sqlc.narg(run_id), sqlc.narg(run_turn_id),
         sqlc.arg(context_refs), sqlc.arg(citations), sqlc.narg(usage), sqlc.narg(persona_id)
  FROM next RETURNING *
), touch AS (
  UPDATE chat_sessions SET last_message_at = (SELECT created_at FROM ins), updated_at = now()
  WHERE id = sqlc.arg(session_id)
)
SELECT * FROM ins;

-- name: SetChatMessageCodeChanges :exec
UPDATE chat_messages SET code_changes = $2 WHERE id = $1;

-- name: ListChatMessages :many
SELECT * FROM chat_messages WHERE session_id = $1 AND seq > $2 ORDER BY seq LIMIT $3;

-- name: LockChatSession :one
SELECT * FROM chat_sessions WHERE id = $1 AND workspace_id = $2 FOR UPDATE;

-- name: LockChatSessionByID :one
SELECT * FROM chat_sessions WHERE id = $1 FOR UPDATE;

-- name: ChatSessionForRun :one
SELECT * FROM chat_sessions WHERE current_run_id = $1;

-- name: SetChatRunState :one
UPDATE chat_sessions SET current_run_id = sqlc.narg(current_run_id), state = sqlc.arg(state),
 revision = revision + 1, updated_at = now()
WHERE id = $1 RETURNING *;

-- name: HasRunningChatTurn :one
SELECT EXISTS (SELECT 1 FROM run_turns WHERE run_id = $1 AND status = 'running')::bool;

-- name: FinishUnfinishedChatTurns :exec
UPDATE run_turns SET status = 'done', ended_at = coalesce(ended_at, now()), exit_code = 1
WHERE run_id = $1 AND status IN ('pending', 'running');

-- name: ChatTurnCitations :many
-- What a chat run read since a turn began, one row per (artifact, version, section).
SELECT a.id AS artifact_id, a.type, a.title, a.path, a.number,
       v.id AS version_id, v.label AS version, s.anchor AS section, max(r.read_at)::timestamptz AS read_at
FROM artifact_reads r
JOIN artifact_versions v ON v.id = r.version_id
JOIN artifacts a ON a.id = v.artifact_id
LEFT JOIN artifact_sections s ON s.id = r.section_id
WHERE r.run_id = sqlc.arg(run_id) AND r.read_at >= sqlc.arg(since)
GROUP BY a.id, v.id, s.anchor
ORDER BY min(r.read_at), a.id, s.anchor NULLS FIRST;

-- name: SetChatSelection :one
-- Stores the harness/model/effort the next segment turn should use, and
-- whether the model is routed automatically. Callers validate them and hold
-- the chat row lock; the runner applies them on the next message.
UPDATE chat_sessions SET harness = $2, model = $3, effort = $4, auto_model = $5, revision = revision + 1, updated_at = now()
WHERE id = $1 RETURNING *;

-- name: ListRecentChatMessages :many
-- Newest rows first, bounded by limit; bodies are clipped so the read stays small.
-- persona_name is who wrote an assistant message when the chat has several
-- personas ('' for the host or a deleted persona).
SELECT m.seq, m.role, m.harness, m.model, left(m.body_md, sqlc.arg(max_chars)::int)::text AS body_md, m.checklist_state, COALESCE(p.name, '')::text AS persona_name
FROM chat_messages m LEFT JOIN personas p ON p.id = m.persona_id
WHERE m.session_id = sqlc.arg(session_id) AND m.role IN ('user', 'assistant')
ORDER BY m.seq DESC LIMIT sqlc.arg(row_limit);

-- name: CountChatHistory :one
SELECT count(*)::bigint FROM chat_messages WHERE session_id = $1 AND role IN ('user', 'assistant');

-- name: ListChatsForUser :many
-- One page of a person's chats: archived or not, optionally one project.
SELECT c.* FROM chat_sessions c LEFT JOIN projects p ON p.id = c.project_id
WHERE c.workspace_id = $1 AND c.created_by = $2 AND c.archived = sqlc.arg(archived) AND NOT c.hidden
  AND (sqlc.narg(project_key)::text IS NULL OR p.key = sqlc.narg(project_key)::text)
  -- persona_filter: 'all', 'none' (chats without a persona) or 'id': chats
  -- the persona hosts or joined (chat_participants).
  AND CASE sqlc.arg(persona_filter)::text
    WHEN 'all' THEN true
    WHEN 'none' THEN c.persona_id IS NULL
    ELSE c.persona_id = sqlc.narg(persona_id)::uuid
      OR EXISTS (SELECT 1 FROM chat_participants cp WHERE cp.chat_id = c.id AND cp.persona_id = sqlc.narg(persona_id)::uuid) END
  -- App conversations are listed only by their app's explicit space id.
  -- space_filter: 'none' (outside any space), 'id' (space_id), else all personal chats.
  AND CASE sqlc.arg(space_filter)::text
    WHEN 'none' THEN c.space_id IS NULL
    WHEN 'id' THEN c.space_id = sqlc.narg(space_id)::uuid
    ELSE NOT EXISTS (SELECT 1 FROM chat_spaces sp WHERE sp.id = c.space_id AND sp.app IS NOT NULL) END
ORDER BY COALESCE(c.last_message_at, c.created_at) DESC, c.id DESC
LIMIT sqlc.arg(row_limit) OFFSET sqlc.arg(row_offset);

-- name: ChatMessageCounts :many
-- n: every message; unread: assistant replies past the person's read position.
SELECT m.session_id, count(*)::int AS n,
  (count(*) FILTER (WHERE m.role = 'assistant' AND m.seq > c.last_read_seq))::int AS unread
FROM chat_messages m JOIN chat_sessions c ON c.id = m.session_id
WHERE m.session_id = ANY(sqlc.arg(ids)::uuid[]) GROUP BY m.session_id;

-- name: ChatLastErrors :many
-- The newest system message of each chat; the API shows it as `error` while the chat is failed.
SELECT DISTINCT ON (session_id) session_id, body_md FROM chat_messages
WHERE session_id = ANY(sqlc.arg(ids)::uuid[]) AND role = 'system'
ORDER BY session_id, seq DESC;

-- name: PageChatMessages :many
-- Messages with after < seq < before (either bound optional). newest_first pages
-- back through history; the caller reverses the rows to oldest first.
SELECT * FROM chat_messages
WHERE session_id = sqlc.arg(session_id)
  AND (sqlc.narg(after_seq)::bigint IS NULL OR seq > sqlc.narg(after_seq)::bigint)
  AND (sqlc.narg(before_seq)::bigint IS NULL OR seq < sqlc.narg(before_seq)::bigint)
ORDER BY CASE WHEN sqlc.arg(newest_first)::bool THEN -seq ELSE seq END
LIMIT sqlc.arg(row_limit);

-- name: ChatMessageForTurn :one
SELECT * FROM chat_messages WHERE run_turn_id = $1 AND role = 'user';

-- name: ChatSessionForEndedRun :one
-- A segment no longer current is found through the messages it answered.
SELECT c.* FROM chat_sessions c
WHERE c.id = (SELECT m.session_id FROM chat_messages m WHERE m.run_id = $1 LIMIT 1);

-- name: UpdateChatTitleArchived :one
UPDATE chat_sessions SET title = $2, archived = $3, revision = revision + 1, updated_at = now()
WHERE id = $1 RETURNING *;

-- name: SetChatTitle :one
UPDATE chat_sessions SET title = $2, revision = revision + 1, updated_at = now()
WHERE id = $1 RETURNING *;

-- name: FirstChatUserMessageBody :one
SELECT body_md FROM chat_messages WHERE session_id = $1 AND role = 'user' ORDER BY seq LIMIT 1;

-- name: DeleteChatSession :exec
DELETE FROM chat_sessions WHERE id = $1;

-- name: DefaultChatAgent :one
-- The oldest main agent, ties broken by name then id so the choice is
-- deterministic. A new Personal Assistant starts on its harness and model.
SELECT * FROM agents WHERE workspace_id = $1 AND kind = 'main' AND archived_at IS NULL ORDER BY created_at, name, id LIMIT 1;

-- name: AssistantAgent :one
-- The workspace's Personal Assistant: the agent every chat runs as.
SELECT * FROM agents WHERE workspace_id = $1 AND kind = 'assistant';

-- name: OwnsChatRun :one
SELECT (
  EXISTS (
    SELECT 1 FROM chat_sessions s
    WHERE s.current_run_id = sqlc.arg(run_id)::uuid
      AND s.workspace_id = sqlc.arg(workspace_id)
      AND s.created_by = sqlc.arg(viewer)
  ) OR EXISTS (
    SELECT 1 FROM chat_messages m
    JOIN chat_sessions s ON s.id = m.session_id
    WHERE m.run_id = sqlc.arg(run_id)::uuid
      AND s.workspace_id = sqlc.arg(workspace_id)
      AND s.created_by = sqlc.arg(viewer)
  )
)::boolean;

-- name: CreateAssistantAgent :one
-- Creates the workspace's Personal Assistant. Returns no row when a concurrent
-- call already made it (or the handle is taken).
INSERT INTO agents (workspace_id, name, handle, color_index, role, specialty, model, status, kind)
VALUES ($1, $2, $3, $4, $5, $6, $7, 'idle', 'assistant')
ON CONFLICT DO NOTHING RETURNING *;

-- name: SetChatAgent :exec
UPDATE chat_sessions SET agent_id = $2 WHERE id = $1;

-- name: CreateChatAttachment :one
INSERT INTO chat_attachments (workspace_id, user_id, filename, content_type, size_bytes, blob_key)
VALUES ($1, $2, $3, $4, $5, $6) RETURNING *;

-- name: GetChatAttachment :one
SELECT * FROM chat_attachments WHERE id = $1 AND workspace_id = $2 AND user_id = $3;

-- name: AttachChatAttachments :many
-- Binds the caller's own unattached uploads to a message; ids that don't
-- qualify are simply not returned, so the caller compares counts.
UPDATE chat_attachments SET message_id = sqlc.arg(message_id)
WHERE id = ANY(sqlc.arg(ids)::uuid[]) AND workspace_id = sqlc.arg(workspace_id) AND user_id = sqlc.arg(user_id) AND message_id IS NULL
RETURNING *;

-- name: CreateGeneratedChatAttachment :one
-- An image the assistant generated, bound to its own message.
INSERT INTO chat_attachments (workspace_id, user_id, message_id, filename, content_type, size_bytes, blob_key, source)
VALUES ($1, $2, $3, $4, $5, $6, $7, 'generated') RETURNING *;

-- name: ChatAttachmentBytes :one
-- What a person has stored in uploads, for the per-person cap (generated
-- images don't count against what they may upload).
SELECT COALESCE(sum(size_bytes), 0)::bigint AS total FROM chat_attachments WHERE workspace_id = $1 AND user_id = $2 AND source = 'upload';

-- name: ChatGeneratedImageBytes :one
-- What a person's assistant chats have generated, for the separate cap on
-- generated images: each stored object once, whether a chat or the Library
-- (which keeps them after their chat is deleted) holds it.
SELECT COALESCE(sum(size_bytes), 0)::bigint AS total FROM (
  SELECT blob_key, size_bytes FROM chat_attachments WHERE chat_attachments.workspace_id = $1 AND chat_attachments.user_id = $2 AND source = 'generated'
  UNION
  SELECT blob_key, size_bytes FROM library_items WHERE library_items.workspace_id = $1 AND library_items.user_id = $2
  UNION
  SELECT i.blob_key, i.size_bytes FROM workflow_step_images i JOIN workflow_runs r ON r.id = i.run_id WHERE r.workspace_id = $1 AND r.user_id = $2
) stored;

-- name: DeleteStaleChatAttachments :many
-- Removes up to row_limit uploads never sent (or detached by a chat's
-- deletion) that are older than the cutoff, returning their blob keys. SKIP
-- LOCKED lets several runners sweep at once; a row a message is binding at
-- the same moment is re-checked after its lock and survives. Keys the
-- Library or a workflow run still holds are not returned: their objects stay.
WITH d AS (
  DELETE FROM chat_attachments
  WHERE id IN (
    SELECT id FROM chat_attachments
    WHERE message_id IS NULL AND created_at < sqlc.arg(cutoff)::timestamptz
    ORDER BY created_at LIMIT sqlc.arg(row_limit) FOR UPDATE SKIP LOCKED
  ) AND message_id IS NULL
  RETURNING blob_key
)
SELECT d.blob_key FROM d WHERE NOT EXISTS (SELECT 1 FROM library_items l WHERE l.blob_key = d.blob_key)
  AND NOT EXISTS (SELECT 1 FROM workflow_step_images i WHERE i.blob_key = d.blob_key);

-- name: ListChatAttachmentsForMessages :many
-- Images generated in one turn share a created_at (one transaction), so name
-- order breaks the tie.
SELECT * FROM chat_attachments WHERE message_id = ANY(sqlc.arg(message_ids)::uuid[]) ORDER BY created_at, filename, id;

-- name: ChatUserMentions :one
-- Whether the person wrote text in this run's conversation (any segment).
SELECT EXISTS (
  SELECT 1 FROM chat_messages m
  WHERE m.role = 'user' AND strpos(m.body_md, sqlc.arg(text)::text) > 0
    AND m.session_id IN (SELECT c.session_id FROM chat_messages c WHERE c.run_id = sqlc.arg(run_id))
) AS mentioned;

-- name: RunWebSearchEvents :many
-- A run's WebSearch calls and results, for the WebFetch allowlist.
SELECT type, payload FROM run_events
WHERE run_id = $1 AND type IN ('tool_call', 'tool_result') AND payload->>'tool' = 'WebSearch'
ORDER BY seq;

-- name: SetChatSpeaker :one
-- Who answers the next turn, who is queued after them, the relay count and
-- its limit. Not a revision bump: it changes together with the turn's state.
UPDATE chat_sessions SET speaker_persona_id = sqlc.narg(speaker_persona_id), queued_persona_ids = sqlc.arg(queued_persona_ids)::uuid[], relay_turns = sqlc.arg(relay_turns), relay_limit = sqlc.arg(relay_limit)
WHERE id = sqlc.arg(id) RETURNING *;

-- name: AddChatParticipant :exec
INSERT INTO chat_participants (chat_id, persona_id) VALUES ($1, $2) ON CONFLICT DO NOTHING;

-- name: ChatParticipants :many
-- Personas brought into these chats besides their hosts, in the order they joined.
SELECT chat_id, persona_id FROM chat_participants WHERE chat_id = ANY(sqlc.arg(chat_ids)::uuid[]) ORDER BY joined_at, persona_id;

-- name: CreatePersonaProposal :one
INSERT INTO persona_proposals (chat_id, run_id, proposed_by, name, tone, color, custom_instructions, reason, avatar_job_id, character_svg)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10) RETURNING *;

-- name: PersonaProposalAvatars :many
-- Where each proposal's picture stands. An image is linked to its job when
-- the turn that asked for it finishes, in the same transaction that ends the
-- turn; a turn that ended without one, or a failed job, made none.
SELECT p.id AS proposal_id, j.attachment_id,
  (CASE WHEN j.attachment_id IS NOT NULL THEN 'ready'
        WHEN j.state = 'failed' OR t.ended_at IS NOT NULL THEN 'failed'
        ELSE 'pending' END)::text AS avatar_state
FROM persona_proposals p
JOIN chat_image_jobs j ON j.id = p.avatar_job_id
JOIN run_turns t ON t.id = j.turn_id
WHERE p.id = ANY(sqlc.arg(ids)::uuid[]);

-- name: CountPendingPersonaProposals :one
SELECT count(*)::int FROM persona_proposals WHERE chat_id = $1 AND state = 'pending';

-- name: ListPersonaProposals :many
SELECT * FROM persona_proposals WHERE chat_id = $1 ORDER BY created_at, id;

-- name: LockPersonaProposal :one
SELECT * FROM persona_proposals WHERE id = $1 AND chat_id = $2 FOR UPDATE;

-- name: DecidePersonaProposal :one
UPDATE persona_proposals SET state = sqlc.arg(state), persona_id = sqlc.narg(persona_id), decided_at = now()
WHERE id = sqlc.arg(id) RETURNING *;

-- name: SupersedePendingCharacterProposals :exec
UPDATE persona_character_proposals
SET state = 'superseded', decided_at = now()
WHERE chat_id = $1 AND target_persona_id = $2 AND state = 'pending';

-- name: CreatePersonaCharacterProposal :one
INSERT INTO persona_character_proposals (chat_id, run_id, proposed_by, target_persona_id, character_svg, summary)
VALUES ($1, $2, $3, $4, $5, $6) RETURNING *;

-- name: CountPendingPersonaCharacterProposals :one
SELECT count(*)::int FROM persona_character_proposals WHERE chat_id = $1 AND state = 'pending';

-- name: ListPersonaCharacterProposals :many
SELECT * FROM persona_character_proposals WHERE chat_id = $1 ORDER BY created_at, id;

-- name: LockPersonaCharacterProposal :one
SELECT * FROM persona_character_proposals WHERE id = $1 AND chat_id = $2 FOR UPDATE;

-- name: DecidePersonaCharacterProposal :one
UPDATE persona_character_proposals SET state = sqlc.arg(state), decided_at = now()
WHERE id = sqlc.arg(id) RETURNING *;

-- name: BumpChatRevision :one
-- A change only the chat's payload shows (participants, proposals): clients
-- refetch on chat.updated.
UPDATE chat_sessions SET revision = revision + 1, updated_at = now() WHERE id = $1 RETURNING *;

-- name: SetChatInterrupt :one
-- The message waiting for an interrupted reply to stop; NULL clears it.
-- Not a revision bump: it changes together with the turn's state.
UPDATE chat_sessions SET interrupt_message_id = sqlc.narg(interrupt_message_id)
WHERE id = sqlc.arg(id) RETURNING *;

-- name: GetChatMessage :one
SELECT * FROM chat_messages WHERE id = $1;

-- name: SetChatMessageTurn :exec
-- Binds a waiting interruption to the turn that answers it, so the runner
-- loads its context refs and attachments.
UPDATE chat_messages SET run_id = $2, run_turn_id = $3, harness = $4, model = $5 WHERE id = $1;

-- name: PreviousChatUserMessage :one
SELECT * FROM chat_messages WHERE session_id = $1 AND role = 'user' AND seq < $2
ORDER BY seq DESC LIMIT 1;

-- name: InterruptedTurnEvents :many
-- What an interrupted reply had written and which tools it called, oldest first.
SELECT type, payload FROM run_events
WHERE run_id = $1 AND at >= $2 AND (type = 'tool_call' OR (type = 'message' AND payload->>'role' = 'assistant'))
ORDER BY seq LIMIT 200;

-- name: PendingChatTurn :one
-- The newest turn not yet claimed: what a chat interruption replaces when
-- the reply hadn't started.
SELECT * FROM run_turns WHERE run_id = $1 AND status = 'pending' ORDER BY seq DESC LIMIT 1;

-- name: MarkChatRead :exec
-- Moves the read position forward, never past the chat's last message.
UPDATE chat_sessions c SET last_read_seq = least(sqlc.arg(seq)::bigint, m.top)
FROM (SELECT coalesce(max(seq), 0) AS top FROM chat_messages WHERE session_id = sqlc.arg(id)) m
WHERE c.id = sqlc.arg(id) AND c.last_read_seq < least(sqlc.arg(seq)::bigint, m.top);

-- name: PersonaDockChats :many
-- A person's chats with live or unread activity, newest first.
WITH candidates AS (
  SELECT c.id FROM chat_sessions c
  WHERE c.workspace_id = $1 AND c.created_by = $2 AND NOT c.archived AND NOT c.hidden
    AND (c.state = 'running' OR c.last_assistant_seq > c.last_read_seq)
  UNION
  SELECT pp.chat_id AS id FROM persona_proposals pp
  WHERE pp.state = 'pending'
  UNION
  SELECT pcp.chat_id AS id FROM persona_character_proposals pcp
  WHERE pcp.state = 'pending'
  UNION
  SELECT tc.chat_id AS id FROM ticket_change_requests tc
  WHERE tc.state = 'pending'
  UNION
  SELECT ar.chat_id AS id FROM approval_requests ar
  WHERE ar.chat_id IS NOT NULL AND ar.state = 'pending'
  UNION
  SELECT ctr.chat_id AS id FROM runs r
  JOIN chat_ticket_runs ctr ON ctr.run_id = r.id
  WHERE r.workspace_id = $1 AND r.state = 'waiting' AND r.wait_reason IN ('human_reply', 'approval')
)
SELECT c.id, c.title, c.state, c.persona_id, c.speaker_persona_id, c.space_id,
  coalesce(c.last_message_at, c.created_at)::timestamptz AS last_activity_at,
  -- When the running turn began; a turn with no recorded start counts as started when the chat last moved.
  coalesce((SELECT t.started_at FROM run_turns t WHERE t.run_id = c.current_run_id AND t.status = 'running' ORDER BY t.seq DESC LIMIT 1),
    c.last_message_at, c.created_at)::timestamptz AS turn_started_at,
  coalesce((SELECT r.harness FROM runs r WHERE r.id = c.current_run_id), c.harness)::text AS harness,
  u.unread, p.waiting_approval, l.persona_id AS last_persona_id, coalesce(l.body_md, '')::text AS last_body, coalesce(l.seq, 0)::bigint AS last_seq
FROM candidates cand
JOIN chat_sessions c ON c.id = cand.id
CROSS JOIN LATERAL (SELECT count(*)::int AS unread FROM chat_messages m WHERE m.session_id = c.id AND m.role = 'assistant' AND m.seq > c.last_read_seq) u
-- waiting_approval: a persona, character, ticket change proposal, live tool approval, or a run this chat started waiting on the person.
CROSS JOIN LATERAL (SELECT coalesce(EXISTS(SELECT 1 FROM persona_proposals pp WHERE pp.chat_id = c.id AND pp.state = 'pending')
  OR EXISTS(SELECT 1 FROM persona_character_proposals pcp WHERE pcp.chat_id = c.id AND pcp.state = 'pending')
  OR EXISTS(SELECT 1 FROM ticket_change_requests tc WHERE tc.chat_id = c.id AND tc.state = 'pending')
  OR EXISTS(SELECT 1 FROM approval_requests ar WHERE ar.chat_id = c.id AND ar.state = 'pending')
  OR EXISTS(SELECT 1 FROM chat_ticket_runs ctr JOIN runs r ON r.id = ctr.run_id
    WHERE ctr.chat_id = c.id AND r.state = 'waiting' AND r.wait_reason IN ('human_reply', 'approval')), false)::bool AS waiting_approval) p
LEFT JOIN LATERAL (SELECT m.persona_id, m.body_md, m.seq FROM chat_messages m WHERE m.session_id = c.id AND m.role = 'assistant' ORDER BY m.seq DESC LIMIT 1) l ON true
WHERE c.workspace_id = $1 AND c.created_by = $2 AND NOT c.archived AND NOT c.hidden
  AND NOT EXISTS (SELECT 1 FROM chat_spaces sp WHERE sp.id = c.space_id AND sp.app IS NOT NULL)
  AND (c.state = 'running' OR u.unread > 0 OR p.waiting_approval)
ORDER BY last_activity_at DESC;

-- name: LastChatUserMessage :one
SELECT * FROM chat_messages WHERE session_id = $1 AND role = 'user' ORDER BY seq DESC LIMIT 1;

-- name: DeleteChatMessagesAfter :exec
DELETE FROM chat_messages WHERE session_id = $1 AND seq > $2;

-- name: SetChatMessageBody :exec
UPDATE chat_messages SET body_md = $2 WHERE id = $1;

-- name: SetChatMessageChecklistState :one
UPDATE chat_messages
SET checklist_state = $3
WHERE id = $1 AND session_id = $2
RETURNING *;

-- name: SetChatMessageBookmark :one
UPDATE chat_messages
SET bookmarked = $3,
    bookmarked_at = CASE WHEN $3 THEN now() ELSE NULL END
WHERE id = $1 AND session_id = $2
RETURNING *;

-- name: ListBookmarkedChatMessages :many
SELECT m.*, COALESCE(p.name, '') AS persona_name
FROM chat_messages m
LEFT JOIN personas p ON p.id = m.persona_id
WHERE m.session_id = $1 AND m.bookmarked = true
ORDER BY m.seq ASC
LIMIT $2;

-- name: ListRecentAssistantChecklistMessages :many
SELECT id, seq, body_md, checklist_state
FROM chat_messages
WHERE session_id = $1 AND role = 'assistant' AND checklist_state <> '{}'::jsonb
ORDER BY seq DESC
LIMIT 5;

-- name: SearchChatMessages :many
-- The caller's own messages matching a web-style query, best first. The snippet
-- marks each match with the private-use characters U+E000 and U+E001.
WITH q AS (SELECT websearch_to_tsquery('english', sqlc.arg(query)::text) AS tsq),
hits AS (
  SELECT m.id, m.session_id, m.seq, m.role, m.body_md, m.created_at, m.persona_id,
    ts_rank(to_tsvector('english', left(m.body_md, 200000)), q.tsq) AS rank
  FROM chat_messages m
  JOIN chat_sessions c ON c.id = m.session_id
  CROSS JOIN q
  WHERE c.workspace_id = sqlc.arg(workspace_id) AND c.created_by = sqlc.arg(user_id) AND NOT c.hidden AND NOT c.temporary
    AND NOT EXISTS (SELECT 1 FROM chat_spaces sp WHERE sp.id = c.space_id AND sp.app IS NOT NULL)
    AND m.role IN ('user', 'assistant')
    AND to_tsvector('english', left(m.body_md, 200000)) @@ q.tsq
  ORDER BY rank DESC, m.created_at DESC
  LIMIT sqlc.arg(row_limit)
)
SELECT h.id, h.session_id, h.seq, h.role, h.created_at, c.title AS chat_title, c.archived, pr.key AS project_key, p.name AS persona_name,
  ts_headline('english', left(h.body_md, 200000), q.tsq, 'StartSel=' || chr(57344) || ',StopSel=' || chr(57345) || ',MaxWords=30,MinWords=12,MaxFragments=1')::text AS snippet
FROM hits h
CROSS JOIN q
JOIN chat_sessions c ON c.id = h.session_id
LEFT JOIN projects pr ON pr.id = c.project_id
LEFT JOIN personas p ON p.id = COALESCE(h.persona_id, c.persona_id)
ORDER BY h.rank DESC, h.created_at DESC;

-- name: AddChatTicketRun :exec
INSERT INTO chat_ticket_runs (chat_id, run_id, message_id, ticket_id) VALUES ($1, $2, $3, $4);

-- name: ChatTicketRunForMessageTicket :one
-- The run a reply's dispatch card already started for this ticket.
SELECT * FROM chat_ticket_runs WHERE message_id = $1 AND ticket_id = $2;

-- name: ListChatTicketRuns :many
-- The ticket runs a chat started, oldest first, with what the tray shows.
SELECT r.id AS run_id, ctr.message_id, r.state, r.wait_reason, r.started_at, r.ended_at, r.cost_usd_micros,
  t.key AS ticket_key, t.title AS ticket_title, t.pr_url, t.pr_state, t.branch, p.repo_url AS repository, a.handle AS agent_handle,
  (SELECT count(*) FROM plan_steps ps WHERE ps.run_id = r.id)::int AS steps_total,
  (SELECT count(*) FROM plan_steps ps WHERE ps.run_id = r.id AND ps.state = 'done')::int AS steps_done,
  COALESCE((SELECT ps.text FROM plan_steps ps WHERE ps.run_id = r.id AND ps.state <> 'done' ORDER BY ps.position LIMIT 1), '')::text AS current_step,
  -- What the agent is doing: its latest tool call, with only the shell command
  -- (capped), which is all the tray's activity label reads.
  coalesce(tc.tool, '')::text AS activity_tool, coalesce(tc.command, '')::text AS activity_command,
  coalesce(ap.id::text, '')::text AS approval_id, coalesce(ap.scope, '')::text AS approval_scope, coalesce(ap.action_summary, '')::text AS approval_action,
  coalesce(ap.risk_summary, '')::text AS approval_risk, coalesce(left(ap.action_detail::text, 2000), '')::text AS approval_detail
FROM chat_ticket_runs ctr
JOIN runs r ON r.id = ctr.run_id
JOIN tickets t ON t.id = r.ticket_id
JOIN projects p ON p.id = t.project_id
JOIN agents a ON a.id = r.agent_id
LEFT JOIN LATERAL (SELECT e.payload->>'tool' AS tool, left(e.payload->'input'->>'command', 300) AS command
  FROM run_events e WHERE e.run_id = r.id AND e.type = 'tool_call' ORDER BY e.seq DESC LIMIT 1) tc ON true
LEFT JOIN LATERAL (SELECT * FROM approval_requests x WHERE x.run_id = r.id AND x.state = 'pending' ORDER BY x.created_at DESC LIMIT 1) ap ON true
WHERE ctr.chat_id = $1
ORDER BY ctr.created_at, r.id;

-- name: ChatTicketRunsToReport :many
-- Chat-started runs whose news the chat hasn't heard yet: waiting on the
-- person (each wait is keyed by the turn that asked), or ended. A cancelled
-- run isn't news: the person stopped it.
SELECT ctr.chat_id, ctr.run_id, ctr.reported, r.state, coalesce(r.wait_reason, '')::text AS wait_reason,
  coalesce((SELECT rt.id::text FROM run_turns rt WHERE rt.run_id = r.id ORDER BY rt.seq DESC LIMIT 1), '')::text AS last_turn
FROM chat_ticket_runs ctr JOIN runs r ON r.id = ctr.run_id
WHERE ((r.state = 'waiting' AND r.wait_reason IN ('human_reply', 'approval'))
    OR (r.state IN ('completed', 'failed', 'blocked') AND ctr.reported <> r.state))
ORDER BY ctr.created_at;

-- name: LockChatTicketRun :one
SELECT * FROM chat_ticket_runs WHERE chat_id = $1 AND run_id = $2 FOR UPDATE;

-- name: SetChatTicketRunReported :exec
UPDATE chat_ticket_runs SET reported = $3, reported_at = now() WHERE chat_id = $1 AND run_id = $2;

-- name: RunWaitQuestion :one
-- What a run's agent asked when it last called await_human ('' if it said nothing).
SELECT coalesce((SELECT nullif(trim(e.payload->>'reason'), '') FROM activity_events e
  WHERE e.ticket_id = sqlc.arg(ticket_id) AND e.verb = 'waiting_for_human' AND e.payload->>'run_id' = sqlc.arg(run_id)::text
  ORDER BY e.created_at DESC LIMIT 1), '')::text AS question;

-- name: PendingApprovalForRun :one
SELECT * FROM approval_requests WHERE run_id = $1 AND state = 'pending' ORDER BY created_at DESC LIMIT 1;

-- name: SearchChatHistory :many
-- Past chats a chat's persona may look back on, best match first: the
-- person's own chats other than this one, never hidden or temporary ones, and
-- unless any_persona only the chats this persona hosted or spoke in (a chat
-- without a persona sees only chats without one). One row per chat, its best
-- matching message, with the snippet marked like SearchChatMessages.
WITH q AS (SELECT websearch_to_tsquery('english', sqlc.arg(query)::text) AS tsq),
hits AS (
  SELECT DISTINCT ON (m.session_id) m.session_id, m.seq, m.role, m.body_md, m.created_at, m.persona_id,
    ts_rank(to_tsvector('english', left(m.body_md, 200000)), q.tsq) AS rank
  FROM chat_messages m
  JOIN chat_sessions c ON c.id = m.session_id
  CROSS JOIN q
  WHERE c.workspace_id = sqlc.arg(workspace_id) AND c.created_by = sqlc.arg(user_id)
    AND c.id <> sqlc.arg(current_chat_id) AND NOT c.hidden AND NOT c.temporary
    AND (sqlc.arg(any_persona)::bool
      OR c.persona_id IS NOT DISTINCT FROM sqlc.narg(persona_id)::uuid
      OR EXISTS (SELECT 1 FROM chat_messages pm WHERE pm.session_id = c.id AND pm.persona_id = sqlc.narg(persona_id)::uuid))
    AND m.role IN ('user', 'assistant')
    AND to_tsvector('english', left(m.body_md, 200000)) @@ q.tsq
  ORDER BY m.session_id, rank DESC, m.seq DESC
)
SELECT h.session_id, h.seq, h.role, h.created_at, c.title AS chat_title, c.archived, COALESCE(p.name, '')::text AS persona_name,
  ts_headline('english', left(h.body_md, 200000), q.tsq, 'StartSel=' || chr(57344) || ',StopSel=' || chr(57345) || ',MaxWords=30,MinWords=12,MaxFragments=1')::text AS snippet
FROM hits h
CROSS JOIN q
JOIN chat_sessions c ON c.id = h.session_id
LEFT JOIN personas p ON p.id = COALESCE(h.persona_id, c.persona_id)
ORDER BY h.rank DESC, h.created_at DESC
LIMIT sqlc.arg(row_limit);

-- name: ChatHistorySession :one
-- One past chat, under the same rules as SearchChatHistory; no row when this
-- chat's persona may not read it.
SELECT c.* FROM chat_sessions c
WHERE c.id = sqlc.arg(id) AND c.workspace_id = sqlc.arg(workspace_id) AND c.created_by = sqlc.arg(user_id)
  AND NOT c.hidden AND NOT c.temporary
  AND (sqlc.arg(any_persona)::bool
    OR c.persona_id IS NOT DISTINCT FROM sqlc.narg(persona_id)::uuid
    OR EXISTS (SELECT 1 FROM chat_messages pm WHERE pm.session_id = c.id AND pm.persona_id = sqlc.narg(persona_id)::uuid));

-- name: ExpiredTemporaryChats :many
-- Temporary chats idle since before the cutoff, with nothing running, oldest
-- first: the sweep deletes them.
SELECT id, workspace_id, created_by FROM chat_sessions
WHERE temporary AND state <> 'running' AND COALESCE(last_message_at, created_at) < sqlc.arg(cutoff)
ORDER BY COALESCE(last_message_at, created_at)
LIMIT sqlc.arg(row_limit);

-- name: CreateChatSteer :one
INSERT INTO chat_steers (session_id, run_id, message_id, body)
VALUES ($1, $2, $3, $4) RETURNING *;

-- name: ClaimNextChatSteer :one
UPDATE chat_steers SET state = 'delivered', delivered_at = now()
WHERE chat_steers.id = (
  SELECT cs.id FROM chat_steers cs WHERE cs.run_id = $1 AND cs.state = 'pending'
  ORDER BY cs.created_at, cs.id LIMIT 1 FOR UPDATE SKIP LOCKED
)
RETURNING *;

-- name: MarkChatSteerState :exec
UPDATE chat_steers SET state = $2 WHERE id = $1;

-- name: TakeNextPendingChatSteer :one
UPDATE chat_steers SET state = 'fallback', delivered_at = now()
WHERE chat_steers.id = (
  SELECT cs.id FROM chat_steers cs WHERE cs.run_id = $1 AND cs.state = 'pending'
  ORDER BY cs.created_at, cs.id LIMIT 1 FOR UPDATE SKIP LOCKED
)
RETURNING *;

-- name: ExpireRunChatSteers :exec
UPDATE chat_steers SET state = 'expired' WHERE run_id = $1 AND state = 'pending';

-- name: SetChatCompactPending :one
UPDATE chat_sessions
SET compact_pending = $2, compact_focus = $3, updated_at = now(), revision = revision + 1
WHERE id = $1
RETURNING *;

-- name: SetChatAutoRollover :one
UPDATE chat_sessions
SET auto_rollover_tokens = $2, updated_at = now(), revision = revision + 1
WHERE id = $1
RETURNING *;

-- name: SetChatForkOrigin :one
UPDATE chat_sessions
SET forked_from_chat_id = $2, forked_from_message_id = $3
WHERE id = $1
RETURNING *;

-- name: CreateForkedChatSession :one
INSERT INTO chat_sessions (
  workspace_id, project_id, title, created_by, agent_id, harness, model, effort, auto_model,
  persona_id, speaker_persona_id, repo_url, commit_email, space_id, connector_ids, secret_ids,
  auto_rollover_tokens, forked_from_chat_id, forked_from_message_id, last_message_at
)
VALUES (
  $1, $2, $3, $4, $5, $6, $7, $8, $9,
  $10, $11, $12, $13, $14, $15, $16,
  $17, $18, $19, $20
)
RETURNING *;

-- name: GetChatMessageByID :one
SELECT * FROM chat_messages WHERE id = $1 AND session_id = $2;

-- name: ListChatMessagesUpToSeq :many
SELECT * FROM chat_messages WHERE session_id = $1 AND seq <= $2 ORDER BY seq ASC;

-- name: CopyChatMessageForFork :one
INSERT INTO chat_messages (
  session_id, seq, role, body_md, harness, model, context_refs, citations, code_changes, persona_id, git_branch, git_commit_sha
)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)
RETURNING *;

-- name: SetChatMessageGitRef :exec
UPDATE chat_messages SET git_branch = $2, git_commit_sha = $3 WHERE id = $1;
