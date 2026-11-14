-- name: SetPageControls :one
UPDATE artifacts SET persona_direct = sqlc.arg(direct), persona_paused = sqlc.arg(paused)
WHERE id = sqlc.arg(id) AND workspace_id = sqlc.arg(workspace_id)
AND artifact_visible(audience, owner_user_id, sqlc.narg(viewer)::uuid) RETURNING *;

-- name: SetPageChat :exec
-- The page opens on this chat from now on, and its dock lists it (dock_chats).
WITH page AS (
  UPDATE artifacts a SET chat_session_id = sqlc.narg(chat_id)
  WHERE a.id = sqlc.arg(id)::uuid AND a.workspace_id = sqlc.arg(workspace_id)::uuid
  AND artifact_visible(a.audience, a.owner_user_id, sqlc.narg(viewer)::uuid)
  RETURNING a.id, a.workspace_id
)
INSERT INTO dock_chats (workspace_id, user_id, scope, chat_id)
SELECT page.workspace_id, c.created_by, 'page:' || page.id, c.id
FROM page JOIN chat_sessions c ON c.id = sqlc.narg(chat_id)::uuid AND c.workspace_id = page.workspace_id
ON CONFLICT (user_id, scope, chat_id) DO UPDATE SET attached_at = now();

-- name: SetPageChanges :one
UPDATE artifact_versions v SET changes = sqlc.arg(changes), review_state = sqlc.narg(review_state)
FROM artifacts a WHERE v.id = sqlc.arg(id) AND a.id = v.artifact_id
AND a.workspace_id = sqlc.arg(workspace_id)
AND artifact_visible(a.audience, a.owner_user_id, sqlc.narg(viewer)::uuid) RETURNING v.*;

-- name: ListPageReviews :many
SELECT v.* FROM artifact_versions v JOIN artifacts a ON a.id = v.artifact_id
WHERE a.id = sqlc.arg(id) AND a.workspace_id = sqlc.arg(workspace_id)
AND artifact_visible(a.audience, a.owner_user_id, sqlc.narg(viewer)::uuid)
AND (v.state = 'suggested' OR (v.created_by_type = 'agent' AND v.review_state = 'pending'))
ORDER BY v.seq;

-- name: QueryPages :many
SELECT a.*, v.properties,
  coalesce((SELECT cv.kind FROM chat_canvases cv WHERE cv.id = a.canvas_id), '')::text AS canvas_kind,
  (SELECT count(*) FROM knowledge_links l WHERE l.source_kind = 'artifact' AND l.source_id = a.id AND l.target_kind = 'unresolved')::int AS unresolved,
  (SELECT count(*) FROM artifact_versions s WHERE s.artifact_id = a.id AND (s.state = 'suggested' OR (s.created_by_type = 'agent' AND s.review_state = 'pending')))::int AS pending
FROM artifacts a JOIN artifact_versions v ON v.id = a.current_version_id
WHERE a.workspace_id = sqlc.arg(workspace_id) AND a.type = 'note'
AND artifact_visible(a.audience, a.owner_user_id, sqlc.narg(viewer)::uuid)
AND (sqlc.arg(include_agent)::boolean OR a.audience <> 'agent')
AND (sqlc.arg(audience)::text = '' OR a.audience = sqlc.arg(audience))
AND (sqlc.arg(folder)::text = '' OR starts_with(a.path, sqlc.arg(folder)::text || '/'))
AND (sqlc.arg(text_query)::text = '' OR a.search @@ websearch_to_tsquery('english', sqlc.arg(text_query)) OR a.title ILIKE '%' || sqlc.arg(text_query) || '%')
AND (sqlc.arg(tag)::text = '' OR EXISTS (SELECT 1 FROM page_tags t WHERE t.artifact_id = a.id AND t.tag = lower(sqlc.arg(tag))))
AND v.properties @> sqlc.arg(properties)::jsonb
AND (sqlc.narg(after_date)::timestamptz IS NULL OR a.updated_at >= sqlc.narg(after_date))
AND (sqlc.narg(before_date)::timestamptz IS NULL OR a.updated_at < sqlc.narg(before_date))
AND (sqlc.narg(links_to)::uuid IS NULL OR EXISTS (SELECT 1 FROM knowledge_links l WHERE l.source_kind = 'artifact' AND l.source_id = a.id AND l.target_id = sqlc.narg(links_to)))
AND (NOT sqlc.arg(orphans)::boolean OR NOT EXISTS (
 SELECT 1 FROM knowledge_links l WHERE (l.source_kind = 'artifact' AND l.source_id = a.id)
 OR (l.target_id = a.id AND (l.source_kind <> 'artifact' OR EXISTS (SELECT 1 FROM artifacts src WHERE src.id = l.source_id AND artifact_visible(src.audience,src.owner_user_id,sqlc.narg(viewer)::uuid))))))
AND (NOT sqlc.arg(unresolved_only)::boolean OR EXISTS (SELECT 1 FROM knowledge_links l WHERE l.source_kind = 'artifact' AND l.source_id = a.id AND l.target_kind = 'unresolved'))
ORDER BY a.updated_at DESC, a.id
LIMIT sqlc.arg(page_limit) OFFSET sqlc.arg(page_offset);

-- name: PutKnowledgeAsset :one
INSERT INTO knowledge_assets (workspace_id,owner_user_id,content_hash,blob_key,filename,content_type,size_bytes)
VALUES ($1,$2,$3,$4,$5,$6,$7)
ON CONFLICT (workspace_id,owner_user_id,content_hash) DO UPDATE SET filename=knowledge_assets.filename RETURNING *;

-- name: GetKnowledgeAsset :one
SELECT k.* FROM knowledge_assets k
WHERE k.id=sqlc.arg(id) AND k.workspace_id=sqlc.arg(workspace_id)
AND (k.owner_user_id=sqlc.narg(viewer)::uuid OR EXISTS (
 SELECT 1 FROM page_asset_refs r JOIN artifact_versions v ON v.id=r.version_id JOIN artifacts a ON a.id=v.artifact_id
 WHERE r.asset_id=k.id AND artifact_visible(a.audience,a.owner_user_id,sqlc.narg(viewer)::uuid))) FOR KEY SHARE OF k;

-- name: AddPageAssetRef :exec
INSERT INTO page_asset_refs(version_id,asset_id)
SELECT v.id,k.id FROM artifact_versions v JOIN artifacts a ON a.id=v.artifact_id
JOIN knowledge_assets k ON k.id=sqlc.arg(asset_id) AND k.workspace_id=a.workspace_id
WHERE v.id=sqlc.arg(version_id) AND artifact_visible(a.audience,a.owner_user_id,sqlc.narg(viewer)::uuid)
AND (k.owner_user_id=sqlc.narg(viewer)::uuid OR EXISTS (SELECT 1 FROM page_asset_refs r JOIN artifact_versions ov ON ov.id=r.version_id JOIN artifacts oa ON oa.id=ov.artifact_id WHERE r.asset_id=k.id AND artifact_visible(oa.audience,oa.owner_user_id,sqlc.narg(viewer)::uuid)))
ON CONFLICT DO NOTHING;



-- name: GetDocPageRedirect :one
SELECT a.* FROM doc_page_redirects d JOIN artifacts a ON a.id=d.artifact_id
WHERE d.canvas_id=sqlc.arg(canvas_id) AND a.workspace_id=sqlc.arg(workspace_id)
AND artifact_visible(a.audience,a.owner_user_id,sqlc.narg(viewer)::uuid);

-- name: UnindexedDocPages :many
-- System backfill only; the migration's trusted mapping supplies the owner.
SELECT a.* FROM doc_page_redirects d JOIN artifacts a ON a.id=d.artifact_id WHERE NOT d.indexed;

-- name: MarkDocPageIndexed :exec
UPDATE doc_page_redirects SET indexed=true WHERE artifact_id=$1;

-- name: OwnKnowledgeAssetByHash :one
SELECT * FROM knowledge_assets WHERE workspace_id=$1 AND owner_user_id=$2 AND content_hash=$3;

-- name: ExportKnowledgeAssets :many
SELECT k.* FROM knowledge_assets k WHERE k.workspace_id=sqlc.arg(workspace_id)
AND (k.owner_user_id=sqlc.narg(viewer)::uuid OR EXISTS(
 SELECT 1 FROM page_asset_refs r JOIN artifact_versions v ON v.id=r.version_id JOIN artifacts a ON a.id=v.artifact_id
 WHERE r.asset_id=k.id AND artifact_visible(a.audience,a.owner_user_id,sqlc.narg(viewer)::uuid))) ORDER BY k.content_hash,k.id;

-- name: LockKnowledgeBlob :exec
SELECT pg_advisory_xact_lock(hashtextextended('knowledge-blob:' || $1::text,0));

-- name: StageOrphanKnowledgeAssets :exec
WITH orphan AS (
 SELECT k.id FROM knowledge_assets k WHERE k.created_at<now()-interval '24 hours'
 AND NOT EXISTS(SELECT 1 FROM page_asset_refs r WHERE r.asset_id=k.id)
 AND NOT EXISTS(SELECT 1 FROM knowledge_import_files f JOIN knowledge_imports i ON i.id=f.import_id WHERE f.asset_id=k.id AND i.state<>'undone')
 ORDER BY k.created_at LIMIT 100 FOR UPDATE SKIP LOCKED
), removed AS (
 DELETE FROM knowledge_assets k USING orphan o WHERE k.id=o.id
 AND NOT EXISTS(SELECT 1 FROM page_asset_refs r WHERE r.asset_id=k.id)
 RETURNING k.blob_key
)
INSERT INTO knowledge_asset_deletions(blob_key)SELECT blob_key FROM removed ON CONFLICT DO NOTHING;

-- name: ListKnowledgeAssetDeletions :many
SELECT * FROM knowledge_asset_deletions ORDER BY created_at LIMIT 100;

-- name: KnowledgeBlobInUse :one
SELECT EXISTS(SELECT 1 FROM knowledge_assets WHERE blob_key=$1);

-- name: ClearKnowledgeAssetDeletion :exec
DELETE FROM knowledge_asset_deletions WHERE blob_key=$1;

-- name: FinishedKnowledgeArchives :many
SELECT id,blob_key FROM knowledge_imports WHERE NOT archive_deleted AND state IN('done','failed','undone') AND updated_at<now()-interval '24 hours' ORDER BY updated_at LIMIT 100;

-- name: MarkKnowledgeArchiveDeleted :exec
UPDATE knowledge_imports SET archive_deleted=true WHERE id=$1;

-- name: DeleteUndoneImportVersion :exec
DELETE FROM artifact_versions v USING artifacts a WHERE v.id=sqlc.arg(id) AND v.artifact_id=a.id AND a.id=sqlc.arg(artifact_id)
AND a.current_version_id IS DISTINCT FROM v.id AND artifact_visible(a.audience,a.owner_user_id,sqlc.narg(viewer)::uuid);

-- name: RestoreMigratedPageTimes :exec
UPDATE artifacts a SET created_at=c.created_at,updated_at=c.updated_at
FROM doc_page_redirects d JOIN chat_canvases c ON c.id=d.canvas_id
WHERE a.id=d.artifact_id AND a.id=sqlc.arg(id) AND NOT d.merged
AND artifact_visible(a.audience,a.owner_user_id,sqlc.narg(viewer)::uuid);

-- name: ImportUndoHasLaterWork :one
SELECT EXISTS(SELECT 1 FROM artifact_versions newer WHERE newer.artifact_id=a.id AND newer.seq>v.seq AND newer.created_at>sqlc.arg(applied_at)::timestamptz)
 OR EXISTS(SELECT 1 FROM page_comments c WHERE c.artifact_id=a.id AND c.created_at>sqlc.arg(applied_at)::timestamptz)
FROM artifacts a JOIN artifact_versions v ON v.artifact_id=a.id AND v.id=sqlc.arg(version_id)
WHERE a.id=sqlc.arg(id) AND artifact_visible(a.audience,a.owner_user_id,sqlc.narg(viewer)::uuid);

-- name: CopyCanvasCommentsToPage :exec
-- Save to Knowledge moves a chat canvas's comments onto the page it becomes.
INSERT INTO page_comments(id,artifact_id,parent_id,seq,author_type,author_id,body,anchor,target_lost,status,suggestion,sent_in_message_id,created_at,updated_at)
SELECT c.id,a.id,c.parent_id,c.seq,c.author_type,c.author_id,c.body,c.anchor,c.target_lost,c.status,c.suggestion,c.sent_in_message_id,c.created_at,c.updated_at
FROM chat_canvas_comments c JOIN artifacts a ON a.id=sqlc.arg(artifact_id) AND a.workspace_id=sqlc.arg(workspace_id)
WHERE c.canvas_id=sqlc.arg(canvas_id) AND artifact_visible(a.audience,a.owner_user_id,sqlc.narg(viewer)::uuid);

-- name: KnowledgeNetworkNodes :many
-- Every note the viewer may see, for the whole-vault graph and maintenance lists.
SELECT a.id, a.title, a.path, a.audience FROM artifacts a
WHERE a.workspace_id=sqlc.arg(workspace_id) AND a.type='note'
AND artifact_visible(a.audience,a.owner_user_id,sqlc.narg(viewer)::uuid)
AND (sqlc.arg(include_agent)::boolean OR a.audience<>'agent')
ORDER BY a.path LIMIT 20000;

-- name: KnowledgeNetworkLinks :many
-- Links between notes the viewer may see, and links that resolve to nothing yet.
SELECT l.source_id, l.target_kind, l.target_id, l.target_text FROM knowledge_links l
JOIN artifacts s ON s.id=l.source_id AND s.type='note'
LEFT JOIN artifacts t ON t.id=l.target_id
WHERE l.workspace_id=sqlc.arg(workspace_id) AND l.source_kind='artifact'
AND artifact_visible(s.audience,s.owner_user_id,sqlc.narg(viewer)::uuid)
AND (sqlc.arg(include_agent)::boolean OR s.audience<>'agent')
AND (l.target_kind='unresolved' OR (l.target_kind='artifact' AND t.type='note'
  AND artifact_visible(t.audience,t.owner_user_id,sqlc.narg(viewer)::uuid)
  AND (sqlc.arg(include_agent)::boolean OR t.audience<>'agent')))
LIMIT 50000;

-- name: LockNotesInFolder :many
-- The pages under a folder in one explorer view (agent knowledge, or the
-- person's own), locked for a move or delete of the whole folder.
SELECT a.* FROM artifacts a
WHERE a.workspace_id = sqlc.arg(workspace_id) AND a.type = 'note'
AND starts_with(a.path, sqlc.arg(folder)::text || '/')
AND artifact_visible(a.audience, a.owner_user_id, sqlc.narg(viewer)::uuid)
AND (a.audience = 'agent') = sqlc.arg(agent)::boolean
ORDER BY a.path
FOR UPDATE;
