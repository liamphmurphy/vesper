-- +goose Up
-- Spaces gain live 0..N Git repositories, live 0..N Knowledge folder/page links,
-- and an optional lightweight flat checklist of tasks.

CREATE TABLE chat_space_repositories (
  id         uuid PRIMARY KEY DEFAULT uuid_v7(),
  space_id   uuid NOT NULL REFERENCES chat_spaces(id) ON DELETE CASCADE,
  repo_url   text NOT NULL CHECK (length(btrim(repo_url)) > 0),
  read_only  boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (space_id, repo_url)
);
CREATE INDEX chat_space_repositories_space ON chat_space_repositories (space_id, created_at);

-- Preserve any repository already configured on a space that tracked work.
INSERT INTO chat_space_repositories (space_id, repo_url)
SELECT p.space_id, btrim(p.repo_url)
FROM projects p
WHERE p.space_id IS NOT NULL
  AND p.repo_url IS NOT NULL
  AND btrim(p.repo_url) <> ''
ON CONFLICT (space_id, repo_url) DO NOTHING;

CREATE TABLE chat_space_knowledge_links (
  id                uuid PRIMARY KEY DEFAULT uuid_v7(),
  space_id          uuid NOT NULL REFERENCES chat_spaces(id) ON DELETE CASCADE,
  kind              text NOT NULL CHECK (kind IN ('folder', 'page')),
  path              text NOT NULL CHECK (length(btrim(path)) BETWEEN 1 AND 500),
  is_default_target boolean NOT NULL DEFAULT false,
  pinned            boolean NOT NULL DEFAULT false,
  created_at        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (space_id, kind, path)
);
CREATE INDEX chat_space_knowledge_links_space ON chat_space_knowledge_links (space_id, created_at);

CREATE TABLE chat_space_tasks (
  id         uuid PRIMARY KEY DEFAULT uuid_v7(),
  space_id   uuid NOT NULL REFERENCES chat_spaces(id) ON DELETE CASCADE,
  title      text NOT NULL CHECK (length(btrim(title)) BETWEEN 1 AND 300),
  notes      text NOT NULL DEFAULT '' CHECK (length(notes) <= 4000),
  done       boolean NOT NULL DEFAULT false,
  chat_id    uuid REFERENCES chat_sessions(id) ON DELETE SET NULL,
  position   integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX chat_space_tasks_space ON chat_space_tasks (space_id, done, position, created_at);

-- +goose Down
DROP TABLE chat_space_tasks;
DROP TABLE chat_space_knowledge_links;
DROP TABLE chat_space_repositories;
