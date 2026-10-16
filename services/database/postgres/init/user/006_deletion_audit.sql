-- ============================================================================
-- 006_deletion_audit.sql
-- Permanent record that deletion requests were honored.
-- ============================================================================

BEGIN;

CREATE TABLE app.deletion_audit (
  deletion_id    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id        uuid NOT NULL,
  requested_at   timestamptz NOT NULL,
  executed_at    timestamptz,
  rows_deleted   jsonb,
  notes          text
);

CREATE INDEX app_deletion_audit_user_idx ON app.deletion_audit (user_id);
CREATE INDEX app_deletion_audit_executed_idx
  ON app.deletion_audit (executed_at) WHERE executed_at IS NOT NULL;

COMMENT ON TABLE app.deletion_audit IS
  'Retained forever. No FK to app.account: the user is gone.';

COMMIT;