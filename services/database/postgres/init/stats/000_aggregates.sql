-- ============================================================================
-- stats/000_aggregates.sql
-- Pre-computed reliability. Read-only for the API.
-- Refreshed nightly by the worker via stats.refresh_all().
-- Depends on: data schema (source of observations).
-- ============================================================================

BEGIN;

CREATE SCHEMA IF NOT EXISTS stats;
COMMENT ON SCHEMA stats IS 'Pre-computed aggregates. Read-only for the API.';

-- ---------------------------------------------------------------------------
-- Route-level reliability
-- ---------------------------------------------------------------------------

CREATE TABLE stats.route_reliability (
  route_id           text NOT NULL,
  direction_id       smallint NOT NULL,
  day_type           text NOT NULL CHECK (day_type IN ('weekday','sat','sun')),
  hour_bucket        smallint NOT NULL CHECK (hour_bucket BETWEEN 0 AND 23),
  sample_count       integer NOT NULL,
  mean_delay_s       integer,
  p50_delay_s        integer,
  p90_delay_s        integer,
  on_time_pct        numeric(5,2),
  computed_at        timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (route_id, direction_id, day_type, hour_bucket)
);

-- ---------------------------------------------------------------------------
-- Stop-level reliability (delay at boarding stop)
-- ---------------------------------------------------------------------------

CREATE TABLE stats.stop_reliability (
  route_id           text NOT NULL,
  direction_id       smallint NOT NULL,
  stop_id            text NOT NULL,
  day_type           text NOT NULL CHECK (day_type IN ('weekday','sat','sun')),
  hour_bucket        smallint NOT NULL CHECK (hour_bucket BETWEEN 0 AND 23),
  sample_count       integer NOT NULL,
  mean_delay_s       integer,
  p50_delay_s        integer,
  p90_delay_s        integer,
  on_time_pct        numeric(5,2),
  computed_at        timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (route_id, direction_id, stop_id, day_type, hour_bucket)
);

-- ---------------------------------------------------------------------------
-- Segment travel time (feeds the router's edge weights)
-- ---------------------------------------------------------------------------

CREATE TABLE stats.segment_travel_time (
  route_id           text NOT NULL,
  direction_id       smallint NOT NULL,
  from_stop_id       text NOT NULL,
  to_stop_id         text NOT NULL,
  day_type           text NOT NULL CHECK (day_type IN ('weekday','sat','sun')),
  hour_bucket        smallint NOT NULL CHECK (hour_bucket BETWEEN 0 AND 23),
  sample_count       integer NOT NULL,
  mean_travel_s      integer,
  p50_travel_s       integer,
  p90_travel_s       integer,
  mean_dwell_s       integer,
  computed_at        timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (route_id, direction_id, from_stop_id, to_stop_id, day_type, hour_bucket)
);

-- ---------------------------------------------------------------------------
-- Refresh function
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION stats.refresh_all(
  p_window       interval DEFAULT '90 days',
  p_min_samples  integer  DEFAULT 10
) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_cutoff date := (now() - p_window)::date;
BEGIN
  -- Route reliability
  INSERT INTO stats.route_reliability
    (route_id, direction_id, day_type, hour_bucket, sample_count,
     mean_delay_s, p50_delay_s, p90_delay_s, on_time_pct, computed_at)
  WITH base AS (
    SELECT route_id, direction_id, hour_bucket, delay_seconds,
           CASE WHEN day_of_week BETWEEN 1 AND 5 THEN 'weekday'
                WHEN day_of_week = 6 THEN 'sat' ELSE 'sun' END AS day_type
      FROM data.trip_observation
     WHERE observed_date >= v_cutoff AND delay_seconds IS NOT NULL
  )
  SELECT route_id, direction_id, day_type, hour_bucket,
         count(*)::int,
         avg(delay_seconds)::int,
         percentile_disc(0.50) WITHIN GROUP (ORDER BY delay_seconds),
         percentile_disc(0.90) WITHIN GROUP (ORDER BY delay_seconds),
         round(100.0 * count(*) FILTER (WHERE delay_seconds BETWEEN -60 AND 300)
               / count(*), 2),
         now()
    FROM base
   GROUP BY route_id, direction_id, day_type, hour_bucket
  HAVING count(*) >= p_min_samples
  ON CONFLICT (route_id, direction_id, day_type, hour_bucket) DO UPDATE SET
    sample_count = EXCLUDED.sample_count,
    mean_delay_s = EXCLUDED.mean_delay_s,
    p50_delay_s  = EXCLUDED.p50_delay_s,
    p90_delay_s  = EXCLUDED.p90_delay_s,
    on_time_pct  = EXCLUDED.on_time_pct,
    computed_at  = EXCLUDED.computed_at;

  DELETE FROM stats.route_reliability WHERE computed_at < now();

  -- Stop reliability
  INSERT INTO stats.stop_reliability
    (route_id, direction_id, stop_id, day_type, hour_bucket, sample_count,
     mean_delay_s, p50_delay_s, p90_delay_s, on_time_pct, computed_at)
  WITH base AS (
    SELECT route_id, direction_id, board_stop_id AS stop_id, hour_bucket, delay_seconds,
           CASE WHEN day_of_week BETWEEN 1 AND 5 THEN 'weekday'
                WHEN day_of_week = 6 THEN 'sat' ELSE 'sun' END AS day_type
      FROM data.trip_observation
     WHERE observed_date >= v_cutoff AND delay_seconds IS NOT NULL
  )
  SELECT route_id, direction_id, stop_id, day_type, hour_bucket,
         count(*)::int,
         avg(delay_seconds)::int,
         percentile_disc(0.50) WITHIN GROUP (ORDER BY delay_seconds),
         percentile_disc(0.90) WITHIN GROUP (ORDER BY delay_seconds),
         round(100.0 * count(*) FILTER (WHERE delay_seconds BETWEEN -60 AND 300)
               / count(*), 2),
         now()
    FROM base
   GROUP BY route_id, direction_id, stop_id, day_type, hour_bucket
  HAVING count(*) >= p_min_samples
  ON CONFLICT (route_id, direction_id, stop_id, day_type, hour_bucket) DO UPDATE SET
    sample_count = EXCLUDED.sample_count,
    mean_delay_s = EXCLUDED.mean_delay_s,
    p50_delay_s  = EXCLUDED.p50_delay_s,
    p90_delay_s  = EXCLUDED.p90_delay_s,
    on_time_pct  = EXCLUDED.on_time_pct,
    computed_at  = EXCLUDED.computed_at;

  DELETE FROM stats.stop_reliability WHERE computed_at < now();

  -- Segment travel time
  INSERT INTO stats.segment_travel_time
    (route_id, direction_id, from_stop_id, to_stop_id, day_type, hour_bucket,
     sample_count, mean_travel_s, p50_travel_s, p90_travel_s, mean_dwell_s, computed_at)
  WITH base AS (
    SELECT route_id, direction_id, from_stop_id, to_stop_id, hour_bucket,
           travel_seconds, dwell_seconds,
           CASE WHEN day_of_week BETWEEN 1 AND 5 THEN 'weekday'
                WHEN day_of_week = 6 THEN 'sat' ELSE 'sun' END AS day_type
      FROM data.segment_observation
     WHERE observed_date >= v_cutoff
  )
  SELECT route_id, direction_id, from_stop_id, to_stop_id, day_type, hour_bucket,
         count(*)::int,
         avg(travel_seconds)::int,
         percentile_disc(0.50) WITHIN GROUP (ORDER BY travel_seconds),
         percentile_disc(0.90) WITHIN GROUP (ORDER BY travel_seconds),
         avg(dwell_seconds)::int,
         now()
    FROM base
   GROUP BY route_id, direction_id, from_stop_id, to_stop_id, day_type, hour_bucket
  HAVING count(*) >= p_min_samples
  ON CONFLICT (route_id, direction_id, from_stop_id, to_stop_id, day_type, hour_bucket)
  DO UPDATE SET
    sample_count  = EXCLUDED.sample_count,
    mean_travel_s = EXCLUDED.mean_travel_s,
    p50_travel_s  = EXCLUDED.p50_travel_s,
    p90_travel_s  = EXCLUDED.p90_travel_s,
    mean_dwell_s  = EXCLUDED.mean_dwell_s,
    computed_at   = EXCLUDED.computed_at;

  DELETE FROM stats.segment_travel_time WHERE computed_at < now();
END $$;

REVOKE ALL ON FUNCTION stats.refresh_all(interval, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION stats.refresh_all(interval, integer) TO ttc_worker;

GRANT USAGE ON SCHEMA stats TO ttc_app, ttc_worker;
GRANT SELECT ON ALL TABLES IN SCHEMA stats TO ttc_app;
GRANT ALL    ON ALL TABLES IN SCHEMA stats TO ttc_worker;

INSERT INTO ops.schema_version (version, note)
VALUES ('012', 'stats aggregates')
ON CONFLICT DO NOTHING;

COMMIT;