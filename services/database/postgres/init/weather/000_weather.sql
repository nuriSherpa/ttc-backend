-- ============================================================================
-- 013_weather.sql
-- Weather grid + hourly history. Lives in ref.* but is NOT touched by
-- ref.rebuild() / ops.activate_feed(), which only delete the GTFS-derived
-- tables they name explicitly. Weather history therefore survives feed swaps.
-- ============================================================================
BEGIN;

CREATE TABLE IF NOT EXISTS ref.weather_grid (
  grid_lat    numeric(7,3) NOT NULL,
  grid_lon    numeric(7,3) NOT NULL,
  sample_lat  double precision NOT NULL,   -- mean of the stops in the cell
  sample_lon  double precision NOT NULL,
  stop_count  integer NOT NULL DEFAULT 0,
  updated_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (grid_lat, grid_lon)
);

CREATE TABLE IF NOT EXISTS ref.weather_hourly (
  grid_lat         numeric(7,3) NOT NULL,
  grid_lon         numeric(7,3) NOT NULL,
  observed_at_utc  timestamptz  NOT NULL,
  local_date       date         NOT NULL,   -- America/Toronto
  local_hour       smallint     NOT NULL CHECK (local_hour BETWEEN 0 AND 23),
  temp_c           real,
  precip_mm        real NOT NULL DEFAULT 0,
  snow_cm          real NOT NULL DEFAULT 0,
  wind_kph         real,
  weather_code     smallint,
  condition        text NOT NULL CHECK (condition IN ('clear','cloudy','fog','rain','snow','storm')),
  severity         smallint NOT NULL CHECK (severity BETWEEN 0 AND 3),
  PRIMARY KEY (grid_lat, grid_lon, observed_at_utc)
);
CREATE INDEX IF NOT EXISTS weather_hourly_time_idx ON ref.weather_hourly (observed_at_utc);
CREATE INDEX IF NOT EXISTS weather_hourly_local_idx ON ref.weather_hourly (local_date, local_hour);

-- 0.05 degrees ~ 5.5 km N-S, ~4 km E-W at Toronto's latitude.
-- Idempotent. Returns the number of live cells (cells containing >= 1 stop).
-- Cells that lost all their stops are kept (history stays joinable) with
-- stop_count = 0; the service ignores them.
CREATE OR REPLACE FUNCTION ref.rebuild_weather_grid(p_cell double precision DEFAULT 0.05)
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE v_n integer;
BEGIN
  IF p_cell <= 0 THEN RAISE EXCEPTION 'cell size must be > 0'; END IF;

  WITH cells AS (
    SELECT round((round(stop_lat / p_cell) * p_cell)::numeric, 3) AS grid_lat,
           round((round(stop_lon / p_cell) * p_cell)::numeric, 3) AS grid_lon,
           avg(stop_lat) AS sample_lat, avg(stop_lon) AS sample_lon,
           count(*)::int AS stop_count
      FROM ref.stop_points
     WHERE stop_lat IS NOT NULL AND stop_lon IS NOT NULL
       AND stop_lat BETWEEN -90 AND 90 AND stop_lon BETWEEN -180 AND 180
       AND NOT (stop_lat = 0 AND stop_lon = 0)
     GROUP BY 1, 2
  )
  INSERT INTO ref.weather_grid (grid_lat, grid_lon, sample_lat, sample_lon, stop_count, updated_at)
  SELECT grid_lat, grid_lon, sample_lat, sample_lon, stop_count, now() FROM cells
  ON CONFLICT (grid_lat, grid_lon) DO UPDATE SET
    sample_lat = EXCLUDED.sample_lat, sample_lon = EXCLUDED.sample_lon,
    stop_count = EXCLUDED.stop_count, updated_at = EXCLUDED.updated_at;

  UPDATE ref.weather_grid g SET stop_count = 0, updated_at = now()
   WHERE g.stop_count <> 0
     AND NOT EXISTS (
       SELECT 1 FROM ref.stop_points s
        WHERE s.stop_lat IS NOT NULL AND s.stop_lon IS NOT NULL
          AND round((round(s.stop_lat / p_cell) * p_cell)::numeric, 3) = g.grid_lat
          AND round((round(s.stop_lon / p_cell) * p_cell)::numeric, 3) = g.grid_lon);

  SELECT count(*) INTO v_n FROM ref.weather_grid WHERE stop_count > 0;
  RETURN v_n;
END $$;

GRANT SELECT ON ref.weather_grid, ref.weather_hourly TO ttc_app, ttc_worker;

INSERT INTO ops.schema_version (version, note)
VALUES ('013', 'weather grid + hourly history') ON CONFLICT DO NOTHING;

COMMIT;