-- ============================================================================
-- 001_trip_stop.sql
-- Per-stop timeline for a trip. Two rows minimum (board + alight).
-- Full stop list only present when the user consented to segment tracking.
-- ============================================================================

BEGIN;

CREATE TABLE app.trip_stop (
  trip_id               uuid NOT NULL,
  boarded_at            timestamptz NOT NULL,      -- denorm for partition pruning
  ordinal               smallint NOT NULL,

  stop_id               text NOT NULL,
  stop_name             text NOT NULL,
  stop_lat              numeric(9,6),
  stop_lon              numeric(9,6),

  is_board              boolean NOT NULL DEFAULT false,
  is_alight             boolean NOT NULL DEFAULT false,

  scheduled_arrival_at  timestamptz,
  observed_arrival_at   timestamptz,
  observed_departure_at timestamptz,
  dwell_seconds         integer,

  PRIMARY KEY (trip_id, ordinal)
);

CREATE INDEX app_trip_stop_stop_idx ON app.trip_stop (stop_id);
CREATE INDEX app_trip_stop_trip_idx ON app.trip_stop (trip_id);

COMMENT ON TABLE app.trip_stop IS
  'Two rows minimum (board, alight). Full stop list when segment_contribution=true. '
  'observed_* timestamps come from device-local GPS; raw coordinates never leave.';

COMMIT;