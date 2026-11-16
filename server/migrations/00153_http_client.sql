-- +goose Up
-- Core HTTP Client utility: workspaces, environments, folders, requests, and execution history.
CREATE TABLE http_workspaces (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id uuid NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  name text NOT NULL,
  description text NOT NULL DEFAULT '',
  active_environment_id uuid,
  default_auth jsonb NOT NULL DEFAULT '{"type":"none"}'::jsonb,
  default_headers jsonb NOT NULL DEFAULT '[]'::jsonb,
  default_vars jsonb NOT NULL DEFAULT '[]'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE http_environments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  http_workspace_id uuid NOT NULL REFERENCES http_workspaces(id) ON DELETE CASCADE,
  name text NOT NULL,
  color text NOT NULL DEFAULT 'green',
  variables jsonb NOT NULL DEFAULT '[]'::jsonb,
  sort_order integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (http_workspace_id, name)
);

ALTER TABLE http_workspaces
  ADD CONSTRAINT http_workspaces_active_environment_fkey
  FOREIGN KEY (active_environment_id) REFERENCES http_environments(id) ON DELETE SET NULL;

CREATE TABLE http_folders (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  http_workspace_id uuid NOT NULL REFERENCES http_workspaces(id) ON DELETE CASCADE,
  parent_folder_id uuid REFERENCES http_folders(id) ON DELETE CASCADE,
  name text NOT NULL,
  default_auth jsonb NOT NULL DEFAULT '{"type":"inherit"}'::jsonb,
  default_headers jsonb NOT NULL DEFAULT '[]'::jsonb,
  sort_order integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE http_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  http_workspace_id uuid NOT NULL REFERENCES http_workspaces(id) ON DELETE CASCADE,
  folder_id uuid REFERENCES http_folders(id) ON DELETE CASCADE,
  name text NOT NULL,
  method text NOT NULL DEFAULT 'GET',
  url text NOT NULL DEFAULT '',
  params jsonb NOT NULL DEFAULT '[]'::jsonb,
  headers jsonb NOT NULL DEFAULT '[]'::jsonb,
  auth jsonb NOT NULL DEFAULT '{"type":"inherit"}'::jsonb,
  body_mode text NOT NULL DEFAULT 'none',
  body text NOT NULL DEFAULT '',
  body_form jsonb NOT NULL DEFAULT '[]'::jsonb,
  timeout_ms integer NOT NULL DEFAULT 30000,
  follow_redirects boolean NOT NULL DEFAULT true,
  sort_order integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE http_executions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  http_workspace_id uuid NOT NULL REFERENCES http_workspaces(id) ON DELETE CASCADE,
  request_id uuid REFERENCES http_requests(id) ON DELETE SET NULL,
  environment_id uuid REFERENCES http_environments(id) ON DELETE SET NULL,
  environment_name text NOT NULL DEFAULT '',
  method text NOT NULL,
  resolved_url text NOT NULL,
  request_headers jsonb NOT NULL DEFAULT '{}'::jsonb,
  request_body text NOT NULL DEFAULT '',
  status_code integer NOT NULL DEFAULT 0,
  status_text text NOT NULL DEFAULT '',
  duration_ms integer NOT NULL DEFAULT 0,
  size_bytes integer NOT NULL DEFAULT 0,
  response_headers jsonb NOT NULL DEFAULT '{}'::jsonb,
  response_body text NOT NULL DEFAULT '',
  response_truncated boolean NOT NULL DEFAULT false,
  error text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX http_workspaces_ws_idx ON http_workspaces(workspace_id, updated_at DESC);
CREATE INDEX http_environments_ws_idx ON http_environments(http_workspace_id, sort_order, created_at);
CREATE INDEX http_folders_ws_idx ON http_folders(http_workspace_id, sort_order, created_at);
CREATE INDEX http_requests_ws_idx ON http_requests(http_workspace_id, sort_order, created_at);
CREATE INDEX http_executions_req_idx ON http_executions(http_workspace_id, request_id, created_at DESC);

-- +goose Down
DROP TABLE IF EXISTS http_executions;
DROP TABLE IF EXISTS http_requests;
DROP TABLE IF EXISTS http_folders;
ALTER TABLE IF EXISTS http_workspaces DROP CONSTRAINT IF EXISTS http_workspaces_active_environment_fkey;
DROP TABLE IF EXISTS http_environments;
DROP TABLE IF EXISTS http_workspaces;
