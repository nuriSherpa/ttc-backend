-- ============================================================================
-- 001_functions.sql
-- RLS, grants, and the journey lifecycle functions.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- RLS
-- ----------------------------------------------------------------------------

ALTER TABLE app.journey ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.journey FORCE ROW LEVEL SECURITY;

CREATE POLICY owner_all ON app.journey FOR ALL TO ttc_app
  USING (user_id = app.current_user_id())
  WITH CHECK (user_id = app.current_user_id());

CREATE POLICY worker_all ON app.journey FOR ALL TO ttc_worker
  USING (true) WITH CHECK (true);

-- ----------------------------------------------------------------------------
-- Grants
-- ----------------------------------------------------------------------------

GRANT SELECT, INSERT, UPDATE, DELETE ON app.journey TO ttc_app;
GRANT ALL ON app.journey TO ttc_worker;

-- ----------------------------------------------------------------------------
-- app.start_journey — idempotent on (user_id, preview_id) among active rows.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION app.start_journey(
  p_user_id            uuid,
  p_preview_id         text,
  p_option_idx         smallint,
  p_plan               jsonb,
  p_source             text DEFAULT 'ad_hoc',
  p_commitment_id      uuid DEFAULT NULL,
  p_commitment_run_id  uuid DEFAULT NULL,
  p_origin_label       text DEFAULT NULL,
  p_destination_label  text DEFAULT NULL,
  p_ttl_hours          integer DEFAULT 24
) RETURNS uuid
LANGUAGE plpgsql AS $$
DECLARE
  v_id  uuid;
  v_arr timestamptz;
BEGIN
  -- Idempotency check
  IF p_preview_id IS NOT NULL THEN
    SELECT journey_id INTO v_id
    FROM app.journey
    WHERE user_id = p_user_id
      AND preview_id = p_preview_id
      AND status IN ('planned','in_progress')
    LIMIT 1;
    IF v_id IS NOT NULL THEN
      RETURN v_id;
    END IF;
  END IF;

  v_arr := (p_plan->>'predicted_arrival')::timestamptz;

  INSERT INTO app.journey (
    user_id, source, commitment_id, commitment_run_id,
    preview_id, option_idx,
    journey_date, timezone,
    plan, plan_version,
    origin_label, destination_label,
    depart_at, arrive_by, predicted_arrival_at,
    total_walk_m, num_transfers, num_legs,
    status, started_at, expires_at
  ) VALUES (
    p_user_id, p_source, p_commitment_id, p_commitment_run_id,
    p_preview_id, p_option_idx,
    current_date,
    COALESCE(p_plan->>'timezone', 'America/Toronto'),
    p_plan,
    COALESCE((p_plan->>'version')::smallint, 1),
    p_origin_label, p_destination_label,
    (p_plan->>'depart_at')::timestamptz,
    (p_plan->>'arrive_by')::timestamptz,
    v_arr,
    (p_plan->>'total_walk_m')::integer,
    (p_plan->>'num_transfers')::smallint,
    COALESCE((p_plan->>'num_legs')::smallint, jsonb_array_length(p_plan->'legs')),
    'in_progress', now(), now() + make_interval(hours => p_ttl_hours)
  )
  RETURNING journey_id INTO v_id;

  RETURN v_id;
END $$;

COMMENT ON FUNCTION app.start_journey(uuid, text, smallint, jsonb, text, uuid, uuid, text, text, integer) IS
  'Create a journey from a chosen preview option. Idempotent on (user_id, preview_id).';

-- ----------------------------------------------------------------------------
-- app.complete_journey
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION app.complete_journey(
  p_journey_id        uuid,
  p_actual_arrival_at timestamptz DEFAULT now()
) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  UPDATE app.journey
  SET status = 'completed',
      completed_at = now(),
      actual_arrival_at = p_actual_arrival_at
  WHERE journey_id = p_journey_id
    AND status IN ('planned','in_progress');
END $$;

-- ----------------------------------------------------------------------------
-- app.abandon_journey
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION app.abandon_journey(
  p_journey_id uuid
) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  UPDATE app.journey
  SET status = 'abandoned',
      abandoned_at = now()
  WHERE journey_id = p_journey_id
    AND status IN ('planned','in_progress');
END $$;

-- ----------------------------------------------------------------------------
-- app.mark_journey_missed — for the "you didn't board" case
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION app.mark_journey_missed(
  p_journey_id uuid
) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  UPDATE app.journey
  SET status = 'missed'
  WHERE journey_id = p_journey_id
    AND status IN ('planned','in_progress');
END $$;

-- ----------------------------------------------------------------------------
-- Schema version
-- ----------------------------------------------------------------------------

INSERT INTO ops.schema_version (version) VALUES (13) ON CONFLICT DO NOTHING;

COMMIT;