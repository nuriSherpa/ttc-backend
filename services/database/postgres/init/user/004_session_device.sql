-- ============================================================================
-- 004_session_device.sql
-- app.session (login tokens) and app.device (push targets).
-- ============================================================================

BEGIN;

CREATE TABLE app.session (
  session_id      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         uuid NOT NULL REFERENCES app.account(user_id) ON DELETE CASCADE,

  token_hash      text NOT NULL UNIQUE,

  platform        text NOT NULL CHECK (platform IN ('ios','android')),
  app_version     text NOT NULL,
  os_version      text,
  model           text,

  created_at      timestamptz NOT NULL DEFAULT now(),
  last_used_at    timestamptz NOT NULL DEFAULT now(),
  expires_at      timestamptz NOT NULL,
  revoked_at      timestamptz,
  revoked_reason  text CHECK (revoked_reason IN
                    ('logout','phrase_reset','admin','expired'))
);

CREATE INDEX app_session_user_active_idx
  ON app.session (user_id) WHERE revoked_at IS NULL;
CREATE INDEX app_session_expires_idx
  ON app.session (expires_at) WHERE revoked_at IS NULL;

CREATE TABLE app.device (
  device_id       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         uuid NOT NULL REFERENCES app.account(user_id) ON DELETE CASCADE,
  session_id      uuid REFERENCES app.session(session_id) ON DELETE SET NULL,

  platform        text NOT NULL CHECK (platform IN ('ios','android')),
  push_provider   text NOT NULL CHECK (push_provider IN ('apns','fcm')),
  push_token      text NOT NULL,
  app_version     text,
  locale          text,

  created_at      timestamptz NOT NULL DEFAULT now(),
  last_seen_at    timestamptz NOT NULL DEFAULT now(),
  invalidated_at  timestamptz,

  UNIQUE (push_provider, push_token)
);

CREATE INDEX app_device_user_active_idx
  ON app.device (user_id) WHERE invalidated_at IS NULL;

-- device.user_id is immutable: 009 attaches a composite FK from
-- app.device_calibration, and a re-association would silently orphan it.
CREATE OR REPLACE FUNCTION app.prevent_device_reassign() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.user_id <> OLD.user_id THEN
    RAISE EXCEPTION 'device.user_id is immutable';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_device_no_reassign BEFORE UPDATE ON app.device
  FOR EACH ROW EXECUTE FUNCTION app.prevent_device_reassign();

COMMIT;