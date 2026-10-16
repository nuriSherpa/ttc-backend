-- ============================================================================
-- 002_preferences.sql
-- app.user_preferences and app.user_contact.
-- ============================================================================

BEGIN;

CREATE TABLE app.user_preferences (
  user_id                uuid PRIMARY KEY REFERENCES app.account(user_id) ON DELETE CASCADE,

  locale                 text    NOT NULL DEFAULT 'en',
  timezone               text    NOT NULL DEFAULT 'America/Toronto',
  time_format            text    NOT NULL DEFAULT '24h'
                         CHECK (time_format IN ('12h','24h')),
  theme                  text    NOT NULL DEFAULT 'auto'
                         CHECK (theme IN ('light','dark','auto')),
  units                  text    NOT NULL DEFAULT 'metric'
                         CHECK (units IN ('metric','imperial')),

  wheelchair_mode        boolean NOT NULL DEFAULT false,
  avoid_stairs           boolean NOT NULL DEFAULT false,
  reduced_motion         boolean NOT NULL DEFAULT false,
  color_blind_mode       boolean NOT NULL DEFAULT false,
  large_text             boolean NOT NULL DEFAULT false,

  walk_speed_mps         numeric(4,2) NOT NULL DEFAULT 1.40
                         CHECK (walk_speed_mps BETWEEN 0.3 AND 3.0),
  detour_factor          numeric(4,2) NOT NULL DEFAULT 1.30
                         CHECK (detour_factor BETWEEN 1.0 AND 3.0),
  max_walk_m             integer NOT NULL DEFAULT 800
                         CHECK (max_walk_m BETWEEN 50 AND 10000),
  max_transfers          smallint NOT NULL DEFAULT 3
                         CHECK (max_transfers BETWEEN 0 AND 10),
  prefer_less_walking    boolean NOT NULL DEFAULT false,
  prefer_fewer_transfers boolean NOT NULL DEFAULT true,

  notifications_enabled  boolean NOT NULL DEFAULT true,
  notify_leave_now       boolean NOT NULL DEFAULT true,
  notify_service_alerts  boolean NOT NULL DEFAULT true,
  notify_commute         boolean NOT NULL DEFAULT false,
  quiet_hours_start      smallint CHECK (quiet_hours_start BETWEEN 0 AND 23),
  quiet_hours_end        smallint CHECK (quiet_hours_end   BETWEEN 0 AND 23),

  updated_at             timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT quiet_hours_pair_chk CHECK (
    (quiet_hours_start IS NULL) = (quiet_hours_end IS NULL))
);

CREATE TRIGGER trg_user_preferences_touch BEFORE UPDATE ON app.user_preferences
  FOR EACH ROW EXECUTE FUNCTION app.touch_updated_at();

CREATE TABLE app.user_contact (
  user_id            uuid PRIMARY KEY REFERENCES app.account(user_id) ON DELETE CASCADE,

  email_hash         text UNIQUE,
  email_encrypted    bytea,
  email_verified_at  timestamptz,

  phone_hash         text UNIQUE,
  phone_encrypted    bytea,
  phone_verified_at  timestamptz,

  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now()
);

CREATE TRIGGER trg_user_contact_touch BEFORE UPDATE ON app.user_contact
  FOR EACH ROW EXECUTE FUNCTION app.touch_updated_at();

COMMIT;