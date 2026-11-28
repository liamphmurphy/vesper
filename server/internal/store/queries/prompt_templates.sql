-- Reusable prompt templates scoped per user, optionally narrowed to a persona and/or space.

-- name: ListPromptTemplates :many
SELECT *
FROM prompt_templates
WHERE workspace_id = @workspace_id
  AND user_id = @user_id
ORDER BY slug, created_at, id;

-- name: GetPromptTemplate :one
SELECT *
FROM prompt_templates
WHERE id = @id
  AND workspace_id = @workspace_id
  AND user_id = @user_id;

-- name: CreatePromptTemplate :one
INSERT INTO prompt_templates (
  workspace_id, user_id, slug, title, description, body, persona_id, space_id
) VALUES (
  @workspace_id, @user_id, @slug, @title, @description, @body,
  sqlc.narg(persona_id), sqlc.narg(space_id)
)
RETURNING *;

-- name: UpdatePromptTemplate :one
UPDATE prompt_templates SET
  slug = coalesce(sqlc.narg(slug), slug),
  title = coalesce(sqlc.narg(title), title),
  description = coalesce(sqlc.narg(description), description),
  body = coalesce(sqlc.narg(body), body),
  persona_id = CASE WHEN @clear_persona::bool THEN NULL ELSE coalesce(sqlc.narg(persona_id), persona_id) END,
  space_id = CASE WHEN @clear_space::bool THEN NULL ELSE coalesce(sqlc.narg(space_id), space_id) END,
  updated_at = now()
WHERE id = @id
  AND workspace_id = @workspace_id
  AND user_id = @user_id
RETURNING *;

-- name: DeletePromptTemplate :one
DELETE FROM prompt_templates
WHERE id = @id
  AND workspace_id = @workspace_id
  AND user_id = @user_id
RETURNING id;
