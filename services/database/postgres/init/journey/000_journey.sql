-- ============================================================================
-- 000_journey.sql
-- app.journey — a commitment to a specific planned route.
--
-- Written only on "Start". Previews are cached in Redis, never here.
-- The plan itself is JSONB; live state lives in Redis, not here.
-- Never holds user location coordinates (the plan's legs are self-contained).
-- ============================================================================

BEGIN;

CREATE TABLE app.journey (
  journey_id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id              uuid NOT NULL REFERENCES app.account(user_id) ON DELETE CASCADE,

  -- What produced this plan
  source               text NOT NULL CHECK (source IN
                         ('commitment','ad_hoc','friend','challenge')),
  commitment_id        uuid,                     -- soft FK to app.commitment
  commitment_run_id    uuid,                     -- soft FK to app.commitment_run

  -- Idempotency for the preview→start handoff
  preview_id           text,                     -- content-addressed cache key
  option_idx           smallint CHECK (option_idx BETWEEN 0 AND 9),

  -- When the journey applies
  journey_date         date NOT NULL,
  timezone             text NOT NULL DEFAULT 'America/Toronto',

  -- The plan itself
  plan                 jsonb NOT NULL,
  plan_version         smallint NOT NULL DEFAULT 1,

  -- Summary for display (extracted from the plan, denormalized)
  origin_label         text,                     -- "Home" (nullable, optional)
  destination_label    text,                     -- "Work" (nullable, optional)
  depart_at            timestamptz,
  arrive_by            timestamptz,
  predicted_arrival_at timestamptz,
  total_walk_m         integer,
  num_transfers        smallint,
  num_legs             smallint,

  -- Lifecycle
  status               text NOT NULL DEFAULT 'in_progress'
                       CHECK (status IN
                         ('planned','in_progress','completed',
                          'missed','abandoned','expired')),
  started_at           timestamptz NOT NULL DEFAULT now(),
  completed_at         timestamptz,
  actual_arrival_at    timestamptz,
  abandoned_at         timestamptz,

  -- Auto-cleanup
  expires_at           timestamptz NOT NULL DEFAULT (now() + interval '24 hours'),

  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX app_journey_user_date_idx
  ON app.journey (user_id, journey_date DESC);
CREATE INDEX app_journey_active_idx
  ON app.journey (user_id)
  WHERE status IN ('planned','in_progress');
CREATE INDEX app_journey_expires_idx
  ON app.journey (expires_at);
CREATE INDEX app_journey_commitment_idx
  ON app.journey (commitment_run_id)
  WHERE commitment_run_id IS NOT NULL;

-- Idempotency: (user_id, preview_id) is unique among active journeys.
-- If Start retries, it finds the existing journey and returns the same id.
CREATE UNIQUE INDEX app_journey_active_preview_uidx
  ON app.journey (user_id, preview_id)
  WHERE preview_id IS NOT NULL
    AND status IN ('planned','in_progress');

CREATE TRIGGER trg_journey_touch BEFORE UPDATE ON app.journey
  FOR EACH ROW EXECUTE FUNCTION app.touch_updated_at();

COMMENT ON TABLE app.journey IS
  'A user commitment to a specific route. Written on Start. '
  'Live state lives in Redis. Plan stored as JSONB. No coordinates.';

COMMENT ON COLUMN app.journey.preview_id IS
  'Content-addressed cache key from the preview call. Enables idempotent Start.';

COMMIT;