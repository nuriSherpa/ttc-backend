-- ============================================================================
-- 001_account.sql
-- app.account — the anchor row for every user.
-- ============================================================================

BEGIN;

CREATE TABLE app.account (
  user_id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),

  recovery_key_lookup     bytea NOT NULL UNIQUE,
  recovery_key_hash       text  NOT NULL,
  recovery_key_updated_at timestamptz NOT NULL DEFAULT now(),

  created_at              timestamptz NOT NULL DEFAULT now(),
  updated_at              timestamptz NOT NULL DEFAULT now(),
  last_active_at          timestamptz,

  status                  text NOT NULL DEFAULT 'active'
                          CHECK (status IN
                            ('active','suspended','pending_deletion','deleted')),
  deletion_requested_at   timestamptz,
  deletion_scheduled_at   timestamptz,

  referral_code           text UNIQUE,
  referred_by             uuid REFERENCES app.account(user_id) ON DELETE SET NULL,
  feature_flags           jsonb NOT NULL DEFAULT '{}'::jsonb,

  install_count           integer NOT NULL DEFAULT 1 CHECK (install_count >= 1),
  first_install_at        timestamptz NOT NULL DEFAULT now(),
  app_version_at_signup   text,
  platform_at_signup      text CHECK (platform_at_signup IN ('ios','android')),

  CONSTRAINT account_deletion_chk CHECK (
    status <> 'pending_deletion'
    OR (deletion_requested_at IS NOT NULL AND deletion_scheduled_at IS NOT NULL)),
  CONSTRAINT account_no_self_referral CHECK (referred_by <> user_id)
);

CREATE INDEX app_account_status_active_idx
  ON app.account (status) WHERE status = 'active';
CREATE INDEX app_account_deletion_scheduled_idx
  ON app.account (deletion_scheduled_at) WHERE deletion_scheduled_at IS NOT NULL;
CREATE INDEX app_account_referred_by_idx
  ON app.account (referred_by) WHERE referred_by IS NOT NULL;

CREATE TRIGGER trg_account_touch BEFORE UPDATE ON app.account
  FOR EACH ROW EXECUTE FUNCTION app.touch_updated_at();

COMMIT;