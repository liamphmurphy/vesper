-- +goose Up
-- Remove the built-in first-party Finance app tables and space constraint
-- ahead of user-built custom apps. Historical migrations remain intact; existing
-- Finance app chats/spaces are cleaned up so chat_spaces_app_check can tighten.
DELETE FROM dock_chats WHERE scope = 'app:finance';
DELETE FROM chat_sessions WHERE space_id IN (SELECT id FROM chat_spaces WHERE app = 'finance');
DELETE FROM chat_spaces WHERE app = 'finance';

ALTER TABLE chat_spaces DROP CONSTRAINT chat_spaces_app_check;
ALTER TABLE chat_spaces ADD CONSTRAINT chat_spaces_app_check CHECK (app IN ('docs', 'slides', 'designs'));

DROP TABLE IF EXISTS finance_pending_imports;
DROP TABLE IF EXISTS finance_csv_mappings;
DROP TABLE IF EXISTS finance_rules;
DROP TABLE IF EXISTS finance_transactions;
DROP TABLE IF EXISTS finance_imports;
DROP TABLE IF EXISTS finance_balances;
DROP TABLE IF EXISTS finance_accounts;

-- +goose Down
ALTER TABLE chat_spaces DROP CONSTRAINT chat_spaces_app_check;
ALTER TABLE chat_spaces ADD CONSTRAINT chat_spaces_app_check CHECK (app IN ('finance', 'docs', 'slides', 'designs'));

CREATE TABLE finance_accounts (
  id             uuid PRIMARY KEY DEFAULT uuid_v7(),
  workspace_id   uuid NOT NULL REFERENCES workspaces(id),
  user_id        uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  name           text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 80),
  kind           text NOT NULL CHECK (kind IN ('checking', 'savings', 'credit', 'brokerage', 'other')),
  mask           text NOT NULL DEFAULT '' CHECK (length(mask) <= 8),
  ofx_account_id text,
  created_at     timestamptz NOT NULL DEFAULT now(),
  UNIQUE (workspace_id, user_id, name)
);
CREATE UNIQUE INDEX finance_accounts_ofx ON finance_accounts (workspace_id, user_id, ofx_account_id) WHERE ofx_account_id IS NOT NULL;

CREATE TABLE finance_balances (
  account_id    uuid NOT NULL REFERENCES finance_accounts(id) ON DELETE CASCADE,
  as_of         date NOT NULL,
  balance_cents bigint NOT NULL,
  PRIMARY KEY (account_id, as_of)
);

CREATE TABLE finance_imports (
  id          uuid PRIMARY KEY DEFAULT uuid_v7(),
  account_id  uuid NOT NULL REFERENCES finance_accounts(id) ON DELETE CASCADE,
  filename    text NOT NULL,
  format      text NOT NULL CHECK (format IN ('csv', 'ofx')),
  parsed      integer NOT NULL,
  inserted    integer NOT NULL,
  duplicates  integer NOT NULL,
  transfers   integer NOT NULL,
  categorized integer NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX finance_imports_account ON finance_imports (account_id, created_at);

CREATE TABLE finance_transactions (
  id              uuid PRIMARY KEY DEFAULT uuid_v7(),
  account_id      uuid NOT NULL REFERENCES finance_accounts(id) ON DELETE CASCADE,
  import_id       uuid REFERENCES finance_imports(id) ON DELETE SET NULL,
  posted_on       date NOT NULL,
  amount_cents    bigint NOT NULL CHECK (amount_cents <> 0),
  description     text NOT NULL,
  merchant        text NOT NULL,
  category        text,
  category_source text CHECK (category_source IN ('default', 'rule', 'person', 'match')),
  transfer_id     uuid REFERENCES finance_transactions(id) ON DELETE SET NULL,
  dedupe_key      text NOT NULL,
  created_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE (account_id, dedupe_key),
  CHECK ((category IS NULL) = (category_source IS NULL))
);
CREATE INDEX finance_transactions_posted ON finance_transactions (account_id, posted_on);
CREATE INDEX finance_transactions_review ON finance_transactions (account_id, posted_on DESC) WHERE category IS NULL;

CREATE TABLE finance_rules (
  id           uuid PRIMARY KEY DEFAULT uuid_v7(),
  workspace_id uuid NOT NULL REFERENCES workspaces(id),
  user_id      uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  pattern      text NOT NULL CHECK (length(pattern) BETWEEN 1 AND 80),
  category     text NOT NULL,
  created_at   timestamptz NOT NULL DEFAULT now(),
  UNIQUE (workspace_id, user_id, pattern)
);

CREATE TABLE finance_csv_mappings (
  workspace_id uuid NOT NULL REFERENCES workspaces(id),
  user_id      uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  fingerprint  text NOT NULL,
  mapping      jsonb NOT NULL,
  updated_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (workspace_id, user_id, fingerprint)
);

CREATE TABLE finance_pending_imports (
  id           uuid PRIMARY KEY DEFAULT uuid_v7(),
  workspace_id uuid NOT NULL REFERENCES workspaces(id),
  user_id      uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  account_id   uuid NOT NULL REFERENCES finance_accounts(id) ON DELETE CASCADE,
  filename     text NOT NULL,
  data         bytea NOT NULL,
  prefill      jsonb NOT NULL,
  chat_id      uuid REFERENCES chat_sessions(id) ON DELETE SET NULL,
  mapping      jsonb,
  mapping_note text NOT NULL DEFAULT '' CHECK (length(mapping_note) <= 500),
  created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX finance_pending_imports_owner ON finance_pending_imports (workspace_id, user_id, created_at);
