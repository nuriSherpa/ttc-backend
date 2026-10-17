-- ============================================================================
-- walk/002_calibrate_walks.sql
--
-- 1. Widen app.user_preferences.correction_ratio CHECK from [0.5, 2.0]
--    to [0.5, 3.0] so slow walkers (elderly, wheelchair, carrying things)
--    are not capped and do not abort the nightly UPDATE.
--
-- 2. Add app.calibrate_walks(): nightly per-user walk calibration using
--    a Bayesian prior / shrinkage blend.
--
-- Design: every user starts fully generic (correction_ratio = NULL, walk
-- pipeline uses the generic 1.40 m/s × 1.3 detour formula). Personal data
-- pulls the ratio toward the user's observed mean gradually:
--
--     blended = (k * 1.00 + n * avg_ratio) / (k + n)
--
--   k   = prior strength, in "generic pseudo-walks" at ratio 1.00
--   n   = valid observations in the rolling window
--   1.00 = the generic formula, fully trusted
--
-- k = 10 means: personal data reaches 50% weight at 10 walks, 67% at 20,
-- 80% at 40. Extreme users (real ratio 1.40) cross the 0.05 churn guard at
-- ~2 walks; typical slow walkers (~1.15) cross it at ~5; users who are
-- actually average (~1.05) never cross it and stay on generic forever.
-- That is the intended behavior: generic first, personal later, smoothly.
--
-- To retune later without a migration:
--   SELECT app.calibrate_walks(p_prior_strength := 15);   -- slower
--   SELECT app.calibrate_walks(p_prior_strength := 5);    -- faster
--
-- Per-user isolation: one user's failure (constraint, lock, whatever) is
-- caught, warned, and counted; the rest of the batch proceeds.
--
-- SECURITY DEFINER: the maintainer may connect as ttc_worker, which is
-- subject to RLS on user_preferences / walk_observation. SECURITY DEFINER
-- (owned by the migration role) bypasses RLS so the UPDATE is never
-- silently filtered to zero rows.
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Widen CHECK on correction_ratio to match outlier clip.
-- ---------------------------------------------------------------------------

ALTER TABLE app.user_preferences
  DROP CONSTRAINT IF EXISTS user_preferences_correction_ratio_check;

ALTER TABLE app.user_preferences
  ADD CONSTRAINT user_preferences_correction_ratio_check
  CHECK (correction_ratio IS NULL
         OR correction_ratio BETWEEN 0.5 AND 3.0);

COMMENT ON COLUMN app.user_preferences.correction_ratio IS
  'Learned multiplier: actual_walk_seconds / estimated_seconds. '
  'NULL = not calibrated yet (walk pipeline uses generic formula). '
  'Updated nightly by app.calibrate_walks() using a shrinkage blend '
  'that starts at 1.00 (generic) and converges toward the user''s '
  'observed mean as observations accumulate.';

-- ---------------------------------------------------------------------------
-- 2. Calibration function.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION app.calibrate_walks(
  p_prior_strength   numeric DEFAULT 10,   -- k: pseudo-walks at ratio 1.00
  p_min_observations integer DEFAULT 3,    -- absolute safety floor
  p_window_days      integer DEFAULT 90    -- how far back to look
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = app, pg_temp
AS $$
DECLARE
  r            RECORD;
  n_calibrated integer := 0;
  n_skipped    integer := 0;
  n_failed     integer := 0;
BEGIN
  IF p_prior_strength < 0 THEN
    RAISE EXCEPTION 'p_prior_strength must be >= 0 (got %)', p_prior_strength;
  END IF;
  IF p_min_observations < 1 THEN
    RAISE EXCEPTION 'p_min_observations must be >= 1 (got %)', p_min_observations;
  END IF;
  IF p_window_days < 1 THEN
    RAISE EXCEPTION 'p_window_days must be >= 1 (got %)', p_window_days;
  END IF;

  FOR r IN
    WITH recent_walks AS (
      SELECT
        user_id,
        actual_seconds::numeric / estimated_seconds AS ratio
      FROM app.walk_observation
      WHERE created_at > now() - (p_window_days || ' days')::interval
        AND estimated_seconds > 0
        AND actual_seconds BETWEEN 10 AND 3600
        -- Outlier clip: reject "got lost" / "stopped for coffee" walks.
        AND actual_seconds::numeric / estimated_seconds BETWEEN 0.5 AND 3.0
    ),
    stats AS (
      SELECT
        user_id,
        count(*)         AS n,
        avg(ratio)       AS mean_ratio
      FROM recent_walks
      GROUP BY user_id
      HAVING count(*) >= p_min_observations
    )
    SELECT
      user_id,
      n,
      round(
        (p_prior_strength * 1.00 + n * mean_ratio)
        / (p_prior_strength + n)
      , 2) AS blended
    FROM stats
  LOOP
    BEGIN
      UPDATE app.user_preferences p
      SET correction_ratio = r.blended
      WHERE p.user_id = r.user_id
        AND (p.correction_ratio IS NULL
             OR abs(p.correction_ratio - r.blended) > 0.05);

      IF FOUND THEN
        n_calibrated := n_calibrated + 1;
      ELSE
        -- Below churn guard, or no user_preferences row for this user.
        n_skipped := n_skipped + 1;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      n_failed := n_failed + 1;
      RAISE WARNING 'calibrate_walks: user % failed: %', r.user_id, SQLERRM;
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'calibrated',        n_calibrated,
    'skipped_no_change', n_skipped,
    'failed',            n_failed,
    'prior_strength',    p_prior_strength,
    'min_observations',  p_min_observations,
    'window_days',       p_window_days
  );
END;
$$;

REVOKE ALL ON FUNCTION app.calibrate_walks(numeric, integer, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.calibrate_walks(numeric, integer, integer) TO ttc_worker;

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ttc_admin') THEN
    GRANT EXECUTE ON FUNCTION app.calibrate_walks(numeric, integer, integer) TO ttc_admin;
  END IF;
END $$;

COMMENT ON FUNCTION app.calibrate_walks(numeric, integer, integer) IS
  'Nightly per-user walk calibration via shrinkage blend: '
  'blended = (k*1.00 + n*mean_ratio)/(k+n). '
  'Defaults: k=10, min observations=3, window=90 days, outlier clip [0.5,3.0], '
  'churn guard 0.05. Returns {calibrated, skipped_no_change, failed, ...}.';

COMMIT;