-- ============================================================================
-- 002_cleanup.sql
-- Journey expiry and retention.
-- ============================================================================

BEGIN;

-- Nightly: mark stale journeys expired, delete old terminal ones.
CREATE OR REPLACE FUNCTION app.expire_old_journeys()
RETURNS table(marked_expired integer, deleted integer)
LANGUAGE plpgsql AS $$
DECLARE
  v_marked  integer;
  v_deleted integer;
BEGIN
  UPDATE app.journey
     SET status = 'expired'
   WHERE status IN ('planned','in_progress')
     AND expires_at < now();
  GET DIAGNOSTICS v_marked = ROW_COUNT;

  DELETE FROM app.journey
   WHERE status IN ('completed','missed','abandoned','expired')
     AND created_at < now() - interval '90 days';
  GET DIAGNOSTICS v_deleted = ROW_COUNT;

  RETURN QUERY SELECT v_marked, v_deleted;
END $$;

COMMENT ON FUNCTION app.expire_old_journeys() IS
  'Mark stale active journeys as expired, delete terminal rows older than 90 days. '
  'Called nightly by the maintainer.';

COMMIT;