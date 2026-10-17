BEGIN;
CREATE INDEX IF NOT EXISTS ref_departures_trip_stop_idx
  ON ref.departures (trip_id, stop_id);
INSERT INTO ops.schema_version (version, note)
VALUES ('045', 'ref.departures (trip_id, stop_id) index')
ON CONFLICT DO NOTHING;
COMMIT;