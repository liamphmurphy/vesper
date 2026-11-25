-- Conversation starters for a person's empty chats.

-- name: NextChatSuggestionsDue :one
-- The most recently active chat whose owner is due a new batch: it has gone
-- quiet since their last batch and nothing was attempted lately.
SELECT c.workspace_id, c.created_by, c.project_id, c.harness, c.model
FROM chat_sessions c
LEFT JOIN chat_suggestions s ON s.workspace_id = c.workspace_id AND s.user_id = c.created_by
WHERE NOT c.hidden AND NOT c.archived AND NOT c.temporary
  AND c.last_message_at < @quiet_before
  AND (s.generated_at IS NULL OR c.last_message_at > s.generated_at)
  AND (s.attempted_at IS NULL OR s.attempted_at < @retry_before)
ORDER BY c.last_message_at DESC
LIMIT 1;

-- name: ClaimChatSuggestions :one
-- No row when another runner claimed this person since retry_before.
INSERT INTO chat_suggestions (workspace_id, user_id, attempted_at)
VALUES (@workspace_id, @user_id, now())
ON CONFLICT (workspace_id, user_id) DO UPDATE SET attempted_at = now()
WHERE chat_suggestions.attempted_at < @retry_before
RETURNING attempted_at;

-- name: SaveChatSuggestions :execrows
-- No row when the batch was cleared after this generation claimed it.
UPDATE chat_suggestions SET items = @items, generated_at = now()
WHERE workspace_id = @workspace_id AND user_id = @user_id AND attempted_at = @attempted_at;

-- name: GetChatSuggestions :one
-- Old batches stop showing: they describe what the person was doing back then.
SELECT items FROM chat_suggestions
WHERE workspace_id = @workspace_id AND user_id = @user_id
  AND generated_at > now() - interval '14 days';

-- name: ClearChatSuggestions :exec
-- The person forgot a memory or deleted a chat a batch may have drawn on.
-- Deleting the row clears what's on screen, discards any in-flight save (which
-- requires its claimed attempted_at row to still exist), and lets the next
-- sweep regenerate without waiting out the retry window.
DELETE FROM chat_suggestions
WHERE workspace_id = @workspace_id AND user_id = @user_id;
