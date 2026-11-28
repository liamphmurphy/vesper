-- +goose Up
-- Opt-in IMAP/CardDAV Mail Butler: per-user account settings, synced Apple Contacts
-- allowlist, deterministic triage rules, idle-VM classification queue, and audit/undo log.

CREATE TABLE mail_accounts (
  id                       uuid PRIMARY KEY DEFAULT uuid_v7(),
  workspace_id             uuid NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  user_id                  uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  enabled                  boolean NOT NULL DEFAULT false,
  dry_run                  boolean NOT NULL DEFAULT true,
  email                    text NOT NULL CHECK (length(btrim(email)) BETWEEN 3 AND 320),
  imap_host                text NOT NULL DEFAULT 'imap.mail.me.com' CHECK (length(btrim(imap_host)) BETWEEN 1 AND 255),
  imap_port                integer NOT NULL DEFAULT 993 CHECK (imap_port BETWEEN 1 AND 65535),
  carddav_url              text NOT NULL DEFAULT 'https://contacts.icloud.com/' CHECK (length(carddav_url) <= 512),
  password_nonce           bytea NOT NULL,
  password_ciphertext      bytea NOT NULL,
  default_folder           text NOT NULL DEFAULT 'Low Priority' CHECK (length(btrim(default_folder)) BETWEEN 1 AND 200),
  allowed_folders          text[] NOT NULL DEFAULT ARRAY['Low Priority','Newsletters','Receipts'],
  triage_policy            text NOT NULL DEFAULT '' CHECK (length(triage_policy) <= 8000),
  pinned_model             text NOT NULL DEFAULT '' CHECK (length(pinned_model) <= 120),
  poll_interval_seconds    integer NOT NULL DEFAULT 60 CHECK (poll_interval_seconds BETWEEN 15 AND 3600),
  inbox_uid_validity       bigint NOT NULL DEFAULT 0,
  last_seen_uid            bigint NOT NULL DEFAULT 0,
  last_synced_at           timestamptz,
  last_contacts_synced_at  timestamptz,
  last_error               text NOT NULL DEFAULT '',
  created_at               timestamptz NOT NULL DEFAULT now(),
  updated_at               timestamptz NOT NULL DEFAULT now(),
  UNIQUE (workspace_id, user_id)
);

CREATE TABLE mail_contacts (
  account_id   uuid NOT NULL REFERENCES mail_accounts(id) ON DELETE CASCADE,
  email        text NOT NULL CHECK (length(btrim(email)) BETWEEN 3 AND 320),
  display_name text NOT NULL DEFAULT '',
  synced_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (account_id, email)
);

CREATE TABLE mail_rules (
  id            uuid PRIMARY KEY DEFAULT uuid_v7(),
  account_id    uuid NOT NULL REFERENCES mail_accounts(id) ON DELETE CASCADE,
  priority      integer NOT NULL DEFAULT 100,
  name          text NOT NULL DEFAULT '' CHECK (length(name) <= 120),
  match_field   text NOT NULL CHECK (match_field IN ('from_email', 'from_domain', 'subject', 'list_id')),
  match_value   text NOT NULL CHECK (length(btrim(match_value)) BETWEEN 1 AND 320),
  action        text NOT NULL CHECK (action IN ('keep', 'move')),
  target_folder text NOT NULL DEFAULT '' CHECK (length(target_folder) <= 200),
  enabled       boolean NOT NULL DEFAULT true,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX mail_rules_account_priority_idx
  ON mail_rules (account_id, priority, created_at, id);

CREATE TABLE mail_triage_queue (
  id               uuid PRIMARY KEY DEFAULT uuid_v7(),
  account_id       uuid NOT NULL REFERENCES mail_accounts(id) ON DELETE CASCADE,
  workspace_id     uuid NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  user_id          uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  imap_uid         bigint NOT NULL,
  uid_validity     bigint NOT NULL,
  message_id       text NOT NULL DEFAULT '',
  from_email       text NOT NULL,
  from_name        text NOT NULL DEFAULT '',
  subject          text NOT NULL DEFAULT '',
  list_unsubscribe boolean NOT NULL DEFAULT false,
  snippet          text NOT NULL DEFAULT '',
  received_at      timestamptz,
  status           text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'claimed', 'decided', 'applied', 'failed')),
  decision_action  text NOT NULL DEFAULT '' CHECK (decision_action IN ('', 'keep', 'move')),
  decision_folder  text NOT NULL DEFAULT '',
  decision_reason  text NOT NULL DEFAULT '',
  claimed_at       timestamptz,
  attempts         integer NOT NULL DEFAULT 0,
  last_error       text NOT NULL DEFAULT '',
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  UNIQUE (account_id, uid_validity, imap_uid)
);

CREATE INDEX mail_triage_queue_status_idx
  ON mail_triage_queue (status, created_at)
  WHERE status IN ('pending', 'claimed', 'decided');

CREATE TABLE mail_triage_log (
  id            uuid PRIMARY KEY DEFAULT uuid_v7(),
  account_id    uuid NOT NULL REFERENCES mail_accounts(id) ON DELETE CASCADE,
  imap_uid      bigint NOT NULL,
  uid_validity  bigint NOT NULL DEFAULT 0,
  message_id    text NOT NULL DEFAULT '',
  from_email    text NOT NULL,
  from_name     text NOT NULL DEFAULT '',
  subject       text NOT NULL DEFAULT '',
  source_folder text NOT NULL DEFAULT 'INBOX',
  action        text NOT NULL CHECK (action IN ('keep', 'move')),
  target_folder text NOT NULL DEFAULT '',
  tier          text NOT NULL CHECK (tier IN ('contact', 'rule', 'llm', 'manual')),
  reason        text NOT NULL DEFAULT '',
  dry_run       boolean NOT NULL DEFAULT false,
  undone_at     timestamptz,
  created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX mail_triage_log_account_created_idx
  ON mail_triage_log (account_id, created_at DESC, id DESC);

-- +goose Down
DROP TABLE mail_triage_log;
DROP TABLE mail_triage_queue;
DROP TABLE mail_rules;
DROP TABLE mail_contacts;
DROP TABLE mail_accounts;
