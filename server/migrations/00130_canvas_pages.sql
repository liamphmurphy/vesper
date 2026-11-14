-- +goose Up
-- Decks and designs are Knowledge pages (LAZYAGENTS-212). The deck or design stays a chat canvas
-- (its versions, reviews, suggestions and the persona's canvas and design tools all work on
-- canvases), and a private page links to it: the page is where it lives in Knowledge (its path,
-- tags, backlinks, tabs), the canvas is its body. One page per deck or design, made with it.
ALTER TABLE artifacts
  ADD COLUMN canvas_id uuid UNIQUE REFERENCES chat_canvases(id) ON DELETE CASCADE,
  ADD CONSTRAINT artifacts_canvas_pages CHECK (canvas_id IS NULL OR type = 'note');

-- +goose StatementBegin
-- The page for a deck or design canvas, at Slides/<title> or Designs/<title> (" (2)", " (3)"… when
-- the owner already has a page there), private to the person whose chat holds it, with that chat as
-- the page's chat. Does nothing for other kinds or when the page exists.
CREATE FUNCTION ensure_canvas_page(cid uuid) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  c record;
  base text;
  candidate text;
  n int := 1;
  aid uuid;
  vid uuid;
BEGIN
  SELECT cv.id, cv.kind, cv.title, cv.created_at, cv.updated_at, s.id AS session_id, s.workspace_id, s.created_by
    INTO c
    FROM chat_canvases cv JOIN chat_sessions s ON s.id = cv.session_id
   WHERE cv.id = cid;
  IF NOT FOUND OR c.kind NOT IN ('deck', 'design') OR EXISTS (SELECT 1 FROM artifacts WHERE canvas_id = cid) THEN
    RETURN;
  END IF;
  -- A slash in a title would make folders out of it.
  base := CASE c.kind WHEN 'deck' THEN 'Slides/' ELSE 'Designs/' END || replace(c.title, '/', '-');
  candidate := base;
  WHILE EXISTS (
    SELECT 1 FROM artifacts a
     WHERE a.workspace_id = c.workspace_id AND lower(a.path) = lower(candidate)
       AND (a.audience <> 'private' OR a.owner_user_id = c.created_by)
  ) LOOP
    n := n + 1;
    candidate := base || ' (' || n || ')';
  END LOOP;
  INSERT INTO artifacts (workspace_id, type, title, author_type, author_id, path, audience, owner_user_id,
                         canvas_id, chat_session_id, created_at, updated_at)
  VALUES (c.workspace_id, 'note', c.title, 'user', c.created_by, candidate, 'private', c.created_by,
          c.id, c.session_id, c.created_at, c.updated_at)
  RETURNING id INTO aid;
  -- A published first version, empty: the page's tags and properties live on its versions, and a
  -- page without one doesn't open. Its body is the canvas.
  INSERT INTO artifact_versions (artifact_id, seq, label, body_md, created_by_type, created_by_id, state, created_at)
  VALUES (aid, 1, 'v1', '', 'user', c.created_by, 'published', c.created_at)
  RETURNING id INTO vid;
  UPDATE artifacts SET current_version_id = vid WHERE id = aid;
END $$;

-- Every deck or design gets its page as it's made, wherever it's made: the Slides and Designs
-- editors, or a persona's design_create in any chat.
CREATE FUNCTION canvas_page_on_insert() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  PERFORM ensure_canvas_page(NEW.id);
  RETURN NEW;
END $$;

-- A renamed deck or design renames its page (its path stays where the person put it).
CREATE FUNCTION canvas_page_on_rename() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  UPDATE artifacts SET title = left(NEW.title, 300), updated_at = now() WHERE canvas_id = NEW.id;
  RETURN NEW;
END $$;

-- A page renamed in Knowledge (a rename sets its title from its path) renames its deck or design,
-- so the next rename of either doesn't undo the other. Each trigger stops when the titles match.
CREATE FUNCTION canvas_page_title_to_canvas() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  UPDATE chat_canvases SET title = left(NEW.title, 200), updated_at = now()
   WHERE id = NEW.canvas_id AND title IS DISTINCT FROM left(NEW.title, 200) AND length(NEW.title) > 0;
  RETURN NEW;
END $$;

-- Deleting the page deletes the deck or design it is: the two are one thing in Knowledge.
CREATE FUNCTION canvas_page_on_delete() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  DELETE FROM chat_canvases WHERE id = OLD.canvas_id;
  RETURN OLD;
END $$;
-- +goose StatementEnd

CREATE TRIGGER chat_canvases_page AFTER INSERT ON chat_canvases
  FOR EACH ROW WHEN (NEW.kind IN ('deck', 'design')) EXECUTE FUNCTION canvas_page_on_insert();
CREATE TRIGGER chat_canvases_page_title AFTER UPDATE OF title ON chat_canvases
  FOR EACH ROW WHEN (NEW.title IS DISTINCT FROM OLD.title) EXECUTE FUNCTION canvas_page_on_rename();
CREATE TRIGGER artifacts_canvas_title AFTER UPDATE OF title ON artifacts
  FOR EACH ROW WHEN (OLD.canvas_id IS NOT NULL AND NEW.title IS DISTINCT FROM OLD.title) EXECUTE FUNCTION canvas_page_title_to_canvas();
CREATE TRIGGER artifacts_canvas_delete AFTER DELETE ON artifacts
  FOR EACH ROW WHEN (OLD.canvas_id IS NOT NULL) EXECUTE FUNCTION canvas_page_on_delete();

-- Existing decks and designs, oldest first so the earliest keeps the plain path.
-- +goose StatementBegin
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT id FROM chat_canvases WHERE kind IN ('deck', 'design') ORDER BY created_at, id LOOP
    PERFORM ensure_canvas_page(r.id);
  END LOOP;
END $$;
-- +goose StatementEnd

-- +goose Down
DROP TRIGGER artifacts_canvas_delete ON artifacts;
DROP TRIGGER artifacts_canvas_title ON artifacts;
DROP TRIGGER chat_canvases_page_title ON chat_canvases;
DROP TRIGGER chat_canvases_page ON chat_canvases;
DROP FUNCTION canvas_page_on_delete();
DROP FUNCTION canvas_page_title_to_canvas();
DROP FUNCTION canvas_page_on_rename();
DROP FUNCTION canvas_page_on_insert();
DROP FUNCTION ensure_canvas_page(uuid);
-- The pages go (the delete trigger is gone, so their decks and designs stay in their chats as before).
DELETE FROM artifacts WHERE canvas_id IS NOT NULL;
ALTER TABLE artifacts DROP CONSTRAINT artifacts_canvas_pages, DROP COLUMN canvas_id;
