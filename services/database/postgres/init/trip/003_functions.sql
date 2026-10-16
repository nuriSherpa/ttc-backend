-- ============================================================================
-- 003_functions.sql
-- RLS, grants, and the stats refresh function.
-- ============================================================================

BEGIN;

-- Row Level Security on trip tables
ALTER TABLE app.trip ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.trip FORCE ROW LEVEL SECURITY;
CREATE POLICY owner_all ON app.trip FOR ALL TO ttc_app
  USING (user_id = app.current_user_id())
  WITH CHECK (user_id = app.current_user_id());
CREATE POLICY worker_all ON app.trip FOR ALL TO ttc_worker
  USING (true) WITH CHECK (true);

ALTER TABLE app.trip_stop ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.trip_stop FORCE ROW LEVEL SECURITY;
CREATE POLICY owner_mod ON app.trip_stop FOR ALL TO ttc_app
  USING (trip_id IN (SELECT trip_id FROM app.trip WHERE user_id = app.current_user_id()))
  WITH CHECK (trip_id IN (SELECT trip_id FROM app.trip WHERE user_id = app.current_user_id()));
CREATE POLICY worker_all ON app.trip_stop FOR ALL TO ttc_worker
  USING (true) WITH CHECK (true);

ALTER TABLE app.user_route_stat ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.user_route_stat FORCE ROW LEVEL SECURITY;
CREATE POLICY owner_all ON app.user_route_stat FOR ALL TO ttc_app
  USING (user_id = app.current_user_id())
  WITH CHECK (user_id = app.current_user_id());
CREATE POLICY worker_all ON app.user_route_stat FOR ALL TO ttc_worker
  USING (true) WITH CHECK (true);

ALTER TABLE app.user_stop_stat ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.user_stop_stat FORCE ROW LEVEL SECURITY;
CREATE POLICY owner_all ON app.user_stop_stat FOR ALL TO ttc_app
  USING (user_id = app.current_user_id())
  WITH CHECK (user_id = app.current_user_id());
CREATE POLICY worker_all ON app.user_stop_stat FOR ALL TO ttc_worker
  USING (true) WITH CHECK (true);

-- Grants
GRANT SELECT, INSERT, UPDATE, DELETE ON
  app.trip, app.trip_stop, app.user_route_stat, app.user_stop_stat
TO ttc_app;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA app TO ttc_app;
GRANT ALL ON ALL TABLES IN SCHEMA app TO ttc_worker;

-- Refresh aggregates from app.trip
CREATE OR REPLACE FUNCTION app.refresh_user_stats(p_user_id uuid DEFAULT NULL)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO app.user_route_stat (user_id, route_id, ride_count, last_ridden_on)
  SELECT user_id, route_id, count(*)::int, max(boarded_at)::date
  FROM app.trip
  WHERE (p_user_id IS NULL OR user_id = p_user_id)
  GROUP BY user_id, route_id
  ON CONFLICT (user_id, route_id) DO UPDATE SET
    ride_count     = EXCLUDED.ride_count,
    last_ridden_on = EXCLUDED.last_ridden_on;

  INSERT INTO app.user_stop_stat (user_id, stop_id, board_count, alight_count, last_used_on)
  WITH b AS (
    SELECT user_id, board_stop_id AS stop_id, count(*)::int AS c, max(boarded_at)::date AS d
    FROM app.trip WHERE (p_user_id IS NULL OR user_id = p_user_id)
    GROUP BY user_id, board_stop_id
  ), a AS (
    SELECT user_id, alight_stop_id AS stop_id, count(*)::int AS c, max(alighted_at)::date AS d
    FROM app.trip WHERE (p_user_id IS NULL OR user_id = p_user_id)
    GROUP BY user_id, alight_stop_id
  )
  SELECT
    coalesce(b.user_id, a.user_id),
    coalesce(b.stop_id,  a.stop_id),
    coalesce(b.c, 0),
    coalesce(a.c, 0),
    greatest(coalesce(b.d, '1970-01-01'::date), coalesce(a.d, '1970-01-01'::date))
  FROM b FULL OUTER JOIN a
    ON b.user_id = a.user_id AND b.stop_id = a.stop_id
  ON CONFLICT (user_id, stop_id) DO UPDATE SET
    board_count  = EXCLUDED.board_count,
    alight_count = EXCLUDED.alight_count,
    last_used_on = EXCLUDED.last_used_on;
END $$;

COMMENT ON FUNCTION app.refresh_user_stats(uuid) IS
  'Refresh aggregates from app.trip. Pass a user_id for one user, NULL for all.';

COMMIT;