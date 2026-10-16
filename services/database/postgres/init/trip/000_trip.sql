-- ============================================================================
-- 000_trip.sql
-- app.trip — one row per completed ride. Partitioned monthly.
-- Soft FKs to ref/cur (never hard FKs: those schemas rebuild per feed).
-- Snapshot fields (route_color, stop_name, lat, lon) freeze the display state
-- at trip time so historical rows never break on a feed rebuild.
-- No GPS coordinates are ever stored here.
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION app.ensure_trip_partition(p_date date)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  start_date date := date_trunc('month', p_date)::date;
  end_date   date := (date_trunc('month', p_date) + interval '1 month')::date;
  part_name  text := 'trip_' || to_char(start_date, 'YYYY_MM');
BEGIN
  EXECUTE format(
    'CREATE TABLE IF NOT EXISTS app.%I PARTITION OF app.trip
       FOR VALUES FROM (%L) TO (%L)',
    part_name, start_date, end_date);
END $$;

CREATE TABLE app.trip (
  trip_id                 uuid NOT NULL DEFAULT gen_random_uuid(),
  user_id                 uuid NOT NULL,

  journey_id              uuid,

  -- Route: soft FK + snapshot
  route_id                text NOT NULL,
  route_short_name        text,
  route_long_name         text,
  route_color             text,
  route_type              smallint,

  direction_id            smallint NOT NULL,
  headsign                text,

  vehicle_id              text,
  vehicle_label           text,

  -- Boarding: soft FK + snapshot
  board_stop_id           text NOT NULL,
  board_stop_name         text NOT NULL,
  board_stop_lat          numeric(9,6),
  board_stop_lon          numeric(9,6),
  boarded_at              timestamptz NOT NULL,
  scheduled_board_at      timestamptz,
  delay_seconds           integer,

  -- Alighting: soft FK + snapshot
  alight_stop_id          text NOT NULL,
  alight_stop_name        text NOT NULL,
  alight_stop_lat         numeric(9,6),
  alight_stop_lon         numeric(9,6),
  alighted_at             timestamptz NOT NULL,

  -- Walk context: durations only, never coordinates
  walk_to_board_seconds   integer,
  walk_from_alight_seconds integer,

  -- Summary (denormalized for fast list view)
  ride_seconds            integer NOT NULL,
  num_stops               smallint NOT NULL,
  num_intermediate_stops  smallint NOT NULL DEFAULT 0,

  -- Provenance
  detection_method        text NOT NULL CHECK (detection_method IN ('auto','manual')),
  detected_via            text NOT NULL CHECK (detected_via IN ('ttc_feed','gps','manual')),

  created_at              timestamptz NOT NULL DEFAULT now(),

  PRIMARY KEY (trip_id, boarded_at)
) PARTITION BY RANGE (boarded_at);

CREATE INDEX app_trip_user_time_idx
  ON app.trip (user_id, boarded_at DESC);
CREATE INDEX app_trip_user_route_idx
  ON app.trip (user_id, route_id);
CREATE INDEX app_trip_user_board_stop_idx
  ON app.trip (user_id, board_stop_id);
CREATE INDEX app_trip_journey_idx
  ON app.trip (journey_id) WHERE journey_id IS NOT NULL;

COMMENT ON TABLE app.trip IS
  'One row per completed ride. Soft FKs to ref/cur, snapshot display fields. '
  'Never holds GPS coordinates. Retention: 12 months rolling.';

-- Seed the next 3 months
SELECT app.ensure_trip_partition(now()::date);
SELECT app.ensure_trip_partition((now() + interval '1 month')::date);
SELECT app.ensure_trip_partition((now() + interval '2 months')::date);

COMMIT;