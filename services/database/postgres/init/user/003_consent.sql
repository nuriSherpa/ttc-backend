-- ============================================================================
-- 003_consent.sql
-- app.user_consent (cache) and app.consent_event (append-only proof).
-- ============================================================================

BEGIN;

CREATE TABLE app.user_consent (
  user_id                     uuid PRIMARY KEY REFERENCES app.account(user_id) ON DELETE CASCADE,

  trip_recording              boolean NOT NULL DEFAULT false,
  trip_contribution           boolean NOT NULL DEFAULT false,
  segment_contribution        boolean NOT NULL DEFAULT false,
  analytics_opt_in            boolean NOT NULL DEFAULT false,

  location_permission_asked_at   timestamptz,
  location_permission_granted_at timestamptz,

  consented_at                timestamptz,
  revoked_at                  timestamptz,
  updated_at                  timestamptz NOT NULL DEFAULT now()
);

CREATE TRIGGER trg_user_consent_touch BEFORE UPDATE ON app.user_consent
  FOR EACH ROW EXECUTE FUNCTION app.touch_updated_at();

CREATE TABLE app.consent_event (
  event_id        bigserial PRIMARY KEY,
  user_id         uuid NOT NULL REFERENCES app.account(user_id) ON DELETE CASCADE,
  purpose         text NOT NULL CHECK (purpose IN
                    ('trip_recording','trip_contribution',
                     'segment_contribution','analytics_opt_in',
                     'live_trip_tracking','challenge_location')),
  granted         boolean NOT NULL,
  policy_version  text NOT NULL,
  occurred_at     timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX app_consent_event_user_idx
  ON app.consent_event (user_id, occurred_at DESC);

COMMIT;