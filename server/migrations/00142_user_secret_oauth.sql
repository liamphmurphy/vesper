-- +goose Up
-- OAuth secrets: the person signs in once and Vesper keeps a fresh access
-- token, refreshing it when a request needs it. The sealed value is then a
-- JSON credential (client secret, access and refresh tokens, expiry) instead
-- of the token itself, and it always goes out as Authorization: Bearer.
ALTER TABLE user_secrets
  ADD COLUMN kind text NOT NULL DEFAULT 'static' CHECK (kind IN ('static', 'oauth')),
  -- Public sign-in settings (endpoints, client ID, scopes), plus the PKCE
  -- verifier and redirect for the few minutes a sign-in is in progress.
  ADD COLUMN oauth jsonb NOT NULL DEFAULT '{}',
  ADD COLUMN oauth_state text,
  -- Set when a sign-in finishes; NULL means requests can't be sent yet.
  ADD COLUMN signed_in_at timestamptz,
  -- Why the last refresh failed (e.g. the grant was revoked); cleared on sign-in.
  ADD COLUMN oauth_error text NOT NULL DEFAULT '',
  ADD CONSTRAINT user_secrets_oauth_bearer CHECK (kind = 'static' OR placement = 'bearer');
CREATE UNIQUE INDEX user_secrets_oauth_state ON user_secrets (oauth_state) WHERE oauth_state IS NOT NULL;

-- +goose Down
DELETE FROM user_secrets WHERE kind = 'oauth';
DROP INDEX user_secrets_oauth_state;
ALTER TABLE user_secrets
  DROP CONSTRAINT user_secrets_oauth_bearer,
  DROP COLUMN oauth_error,
  DROP COLUMN signed_in_at,
  DROP COLUMN oauth_state,
  DROP COLUMN oauth,
  DROP COLUMN kind;
