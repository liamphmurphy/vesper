-- name: CreateLibraryItem :one
INSERT INTO library_items (workspace_id, user_id, kind, title, filename, content_type, size_bytes, blob_key, chat_id, message_id, persona_id)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11) RETURNING *;

-- name: CreateUploadedLibraryItem :one
-- An image the person uploaded straight into their Library.
INSERT INTO library_items (workspace_id, user_id, kind, title, filename, content_type, size_bytes, blob_key, source)
VALUES ($1, $2, 'image', $3, $4, $5, $6, $7, 'upload') RETURNING *;

-- name: CreateLibraryDiagram :one
-- Saving a diagram again returns the row it already has.
INSERT INTO library_items (workspace_id, user_id, kind, title, filename, content_type, size_bytes, blob_key, chat_id, message_id, persona_id)
VALUES ($1, $2, 'diagram', $3, $4, $5, $6, $7, $8, $9, $10)
ON CONFLICT (workspace_id, user_id, blob_key) WHERE kind = 'diagram' DO UPDATE SET blob_key = EXCLUDED.blob_key
RETURNING *;

-- name: GetLibraryDiagram :one
-- The caller's saved diagram with this content, if any.
SELECT * FROM library_items WHERE workspace_id = $1 AND user_id = $2 AND blob_key = $3 AND kind = 'diagram';

-- name: GetLibraryDocumentByBlob :one
-- The caller's saved document with this content, if any.
SELECT * FROM library_items WHERE workspace_id = $1 AND user_id = $2 AND blob_key = $3 AND kind = 'document';

-- name: ListLibraryItems :many
-- The caller's own items, newest first, with where each came from (the chat's
-- title and the persona's name, while they still exist).
SELECT l.*, c.title AS chat_title, p.name AS persona_name, pr.key AS project_key, rp.name AS reference_persona_name,
  sc.title AS source_title, sc.kind AS source_kind, sc.updated_at AS source_updated_at
FROM library_items l
LEFT JOIN chat_canvases sc ON sc.id = l.source_id
LEFT JOIN chat_sessions c ON c.id = l.chat_id
LEFT JOIN personas p ON p.id = l.persona_id
LEFT JOIN personas rp ON rp.id = l.reference_persona_id
LEFT JOIN projects pr ON pr.id = c.project_id
WHERE l.workspace_id = sqlc.arg(workspace_id) AND l.user_id = sqlc.arg(user_id)
  AND (sqlc.narg(kind)::text IS NULL OR l.kind = sqlc.narg(kind))
ORDER BY l.created_at DESC, l.id DESC
LIMIT sqlc.arg(row_limit) OFFSET sqlc.arg(row_offset);

-- name: GetLibraryItem :one
SELECT * FROM library_items WHERE id = $1 AND workspace_id = $2 AND user_id = $3;

-- name: GetLibraryItemDetail :one
-- One item of the caller's with its joined chat, persona and export source fields.
SELECT l.*, c.title AS chat_title, p.name AS persona_name, pr.key AS project_key, rp.name AS reference_persona_name,
  sc.title AS source_title, sc.kind AS source_kind, sc.updated_at AS source_updated_at
FROM library_items l
LEFT JOIN chat_canvases sc ON sc.id = l.source_id
LEFT JOIN chat_sessions c ON c.id = l.chat_id
LEFT JOIN personas p ON p.id = l.persona_id
LEFT JOIN personas rp ON rp.id = l.reference_persona_id
LEFT JOIN projects pr ON pr.id = c.project_id
WHERE l.id = $1 AND l.workspace_id = $2 AND l.user_id = $3;

-- name: DeleteLibraryItem :one
-- Removes one of the caller's items. orphaned says no chat attachment,
-- workflow image, chat video or other item still uses its object, so the
-- caller may delete it. A video's poster belongs to the item alone.
WITH d AS (
  DELETE FROM library_items WHERE library_items.id = sqlc.arg(id) AND library_items.workspace_id = sqlc.arg(workspace_id) AND library_items.user_id = sqlc.arg(user_id)
  RETURNING blob_key, poster_key
)
SELECT d.blob_key, d.poster_key,
  (NOT EXISTS (SELECT 1 FROM chat_attachments a WHERE a.blob_key = d.blob_key)
   AND NOT EXISTS (SELECT 1 FROM workflow_step_images i WHERE i.blob_key = d.blob_key)
   AND NOT EXISTS (SELECT 1 FROM chat_video_jobs v WHERE v.output_blob_key = d.blob_key)
   AND NOT EXISTS (SELECT 1 FROM chat_audio_jobs a WHERE a.output_blob_key = d.blob_key)
   AND NOT EXISTS (SELECT 1 FROM library_items o WHERE o.blob_key = d.blob_key AND o.id <> sqlc.arg(id)))::boolean AS orphaned
FROM d;

-- name: LockLibraryReferences :exec
-- Serializes one person's reference changes, so replacing one never trips
-- the one-per-role unique indexes.
SELECT pg_advisory_xact_lock(hashtextextended('library-references:' || sqlc.arg(workspace_id)::uuid::text || ':' || sqlc.arg(user_id)::uuid::text, 0));

-- name: ClearLibraryReferenceRole :exec
-- Unsets the caller's current reference for a role: 'self', or 'persona' for
-- one persona.
UPDATE library_items SET reference = NULL, reference_persona_id = NULL
WHERE workspace_id = sqlc.arg(workspace_id) AND user_id = sqlc.arg(user_id) AND reference = sqlc.arg(role)::text
  AND (sqlc.arg(role)::text = 'self' OR reference_persona_id = sqlc.narg(persona_id)::uuid);

-- name: LibraryItemByBlobKey :one
-- The person's Library copy of a generated chat image, which shares the
-- attachment's object.
SELECT * FROM library_items
WHERE workspace_id = $1 AND user_id = $2 AND blob_key = $3 AND kind = 'image'
ORDER BY created_at LIMIT 1;

-- name: SetLibraryReference :one
-- Marks (or, with a NULL role, unmarks) one of the caller's items.
UPDATE library_items SET reference = sqlc.narg(role)::text, reference_persona_id = sqlc.narg(persona_id)::uuid
WHERE id = sqlc.arg(id) AND workspace_id = sqlc.arg(workspace_id) AND user_id = sqlc.arg(user_id)
RETURNING *;

-- name: LibraryReferences :many
-- A person's reference images that apply in a chat with the given persona
-- (NULL: the built-in Assistant): theirs, and that persona's.
SELECT * FROM library_items
WHERE workspace_id = sqlc.arg(workspace_id) AND user_id = sqlc.arg(user_id)
  AND (reference = 'self' OR (reference = 'persona' AND reference_persona_id = sqlc.narg(persona_id)::uuid))
ORDER BY reference;

-- name: GetLibraryLink :one
-- The caller's saved copy of this link, if any.
SELECT * FROM library_items WHERE workspace_id = $1 AND user_id = $2 AND url = $3 AND kind = 'link';

-- name: CreateLibraryLink :one
-- Saving a link again returns the row it already has.
INSERT INTO library_items (workspace_id, user_id, kind, title, filename, content_type, size_bytes, blob_key, chat_id, message_id, persona_id, url, note, site, video_id)
VALUES ($1, $2, 'link', $3, 'link', $4, $5, $6, $7, $8, $9, $10, $11, $12, $13)
ON CONFLICT (workspace_id, user_id, url) WHERE kind = 'link' DO UPDATE SET url = EXCLUDED.url
RETURNING *;

-- name: SavedLibraryLinks :many
-- Which of these URLs the caller has in their Library.
SELECT url FROM library_items WHERE workspace_id = $1 AND user_id = $2 AND kind = 'link' AND url = ANY(sqlc.arg(urls)::text[]);

-- name: SetLibraryLinkStatus :one
UPDATE library_items SET link_status = $4
WHERE id = $1 AND workspace_id = $2 AND user_id = $3 AND kind = 'link'
RETURNING *;

-- name: SetLibraryLinkSummary :one
UPDATE library_items SET summary = $4
WHERE id = $1 AND workspace_id = $2 AND user_id = $3 AND kind = 'link'
RETURNING *;

-- name: ListSavedLinks :many
-- A person's saved links for their personas, newest first, optionally one status.
SELECT * FROM library_items
WHERE workspace_id = sqlc.arg(workspace_id) AND user_id = sqlc.arg(user_id) AND kind = 'link'
  AND (sqlc.narg(status)::text IS NULL OR link_status = sqlc.narg(status))
ORDER BY created_at DESC, id DESC
LIMIT sqlc.arg(row_limit);

-- name: SearchLibraryItems :many
-- The caller's items for a persona to find, newest first: optionally one kind,
-- and only those whose title, file name, note, site, address or summary holds
-- every word. Documents are left out: they're the person's own (Docs), never
-- agent context.
SELECT l.id, l.kind, l.title, l.filename, l.url, l.site, l.note, l.link_status, l.width, l.height, l.duration_ms, l.chat_id, l.created_at,
  c.title AS chat_title, p.name AS persona_name
FROM library_items l
LEFT JOIN chat_sessions c ON c.id = l.chat_id
LEFT JOIN personas p ON p.id = l.persona_id
WHERE l.workspace_id = sqlc.arg(workspace_id) AND l.user_id = sqlc.arg(user_id) AND l.kind <> 'document'
  AND (sqlc.narg(kind)::text IS NULL OR l.kind = sqlc.narg(kind))
  AND NOT EXISTS (
    SELECT 1 FROM unnest(sqlc.arg(words)::text[]) w
    WHERE concat_ws(' ', l.title, l.filename, l.note, l.site, l.url, l.summary) NOT ILIKE '%' || w || '%')
ORDER BY l.created_at DESC, l.id DESC
LIMIT sqlc.arg(row_limit);

-- name: CreateLibraryAudio :one
-- An audio file: uploaded by the person, or rendered by a persona in a chat.
-- peaks and duration_ms are NULL for a format the server can't decode.
INSERT INTO library_items (workspace_id, user_id, kind, title, filename, content_type, size_bytes, blob_key, source, chat_id, message_id, persona_id, duration_ms, peaks, method)
VALUES ($1, $2, 'audio', $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14) RETURNING *;

-- name: RenameLibraryItem :one
-- Renames one of the caller's items.
UPDATE library_items SET title = sqlc.arg(title) WHERE id = sqlc.arg(id) AND workspace_id = sqlc.arg(workspace_id) AND user_id = sqlc.arg(user_id)
RETURNING *;

-- name: CreateLibraryFile :one
-- A file the person uploaded or a persona handed over. detail is the tile's
-- one-line summary, worked out when the file is stored.
INSERT INTO library_items (workspace_id, user_id, kind, title, filename, content_type, size_bytes, blob_key, source, chat_id, message_id, persona_id, detail)
VALUES ($1, $2, 'file', $3, $4, $5, $6, $7, $8, $9, $10, $11, $12) RETURNING *;

-- name: CreateLibraryExport :one
-- A frozen copy of what an app exported, linked to its source canvas. Saving
-- the same content again returns the row it already made.
INSERT INTO library_items (workspace_id, user_id, kind, title, filename, content_type, size_bytes, blob_key, chat_id, detail, source_id, source_stamp)
VALUES ($1, $2, 'export', $3, $4, $5, $6, $7, $8, $9, $10, $11) RETURNING *;

-- name: GetLibraryExportByBlob :one
SELECT * FROM library_items WHERE workspace_id = $1 AND user_id = $2 AND blob_key = $3 AND kind = 'export';
