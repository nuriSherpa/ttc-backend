-- ============================================================================
-- walk/001_correction_ratio.sql
-- Add per-user walk speed correction factor.
-- ============================================================================

BEGIN;

ALTER TABLE app.user_preferences
  ADD COLUMN IF NOT EXISTS correction_ratio numeric(4,2)
  CHECK (correction_ratio IS NULL
         OR (correction_ratio BETWEEN 0.5 AND 2.0));

COMMENT ON COLUMN app.user_preferences.correction_ratio IS
  'Learned multiplier: actual_walk_seconds / estimated_seconds. '
  'NULL = not calibrated yet. Updated nightly from app.walk_observation.';

COMMIT;