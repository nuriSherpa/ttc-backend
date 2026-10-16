-- ============================================================================
-- walk/000_walk_observation.sql
-- Per-user walk timing observations. Feeds personal calibration.
-- ============================================================================

BEGIN;

CREATE TABLE app.walk_observation (
  observation_id     bigserial PRIMARY KEY,
  user_id            uuid NOT NULL REFERENCES app.account(user_id) ON DELETE CASCADE,

  kind               text NOT NULL CHECK (kind IN ('access','egress','transfer')),
  distance_m         integer NOT NULL CHECK (distance_m > 0),
  estimated_seconds  integer NOT NULL CHECK (estimated_seconds > 0),
  actual_seconds     integer NOT NULL CHECK (actual_seconds > 0),
  created_at         timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX app_walk_observation_user_time_idx
  ON app.walk_observation (user_id, created_at DESC);

ALTER TABLE app.walk_observation ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.walk_observation FORCE ROW LEVEL SECURITY;

CREATE POLICY owner_all ON app.walk_observation FOR ALL TO ttc_app
  USING (user_id = app.current_user_id())
  WITH CHECK (user_id = app.current_user_id());

CREATE POLICY worker_all ON app.walk_observation FOR ALL TO ttc_worker
  USING (true) WITH CHECK (true);

GRANT SELECT, INSERT ON app.walk_observation TO ttc_app;
GRANT USAGE ON SEQUENCE app.walk_observation_observation_id_seq TO ttc_app;
GRANT ALL ON app.walk_observation TO ttc_worker;
GRANT ALL ON SEQUENCE app.walk_observation_observation_id_seq TO ttc_worker;

COMMENT ON TABLE app.walk_observation IS
  'Per-user walk timing observations. Used to learn correction_ratio.';

COMMIT;