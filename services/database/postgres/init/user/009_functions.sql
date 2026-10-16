-- ============================================================================
-- 009_functions.sql
-- Signup, seeding, consent recording, auth lookups.
-- Depends on: 001–006.
-- ============================================================================

BEGIN;

-- Signup. Generates the user_id, sets app.user_id tx-locally (so RLS passes
-- on the insert and on the seed trigger), creates the account row.
CREATE OR REPLACE FUNCTION app.create_account(
  p_recovery_key_lookup bytea,
  p_recovery_key_hash   text,
  p_platform            text,
  p_app_version         text
) RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, app
AS $$
DECLARE
  v_id uuid := gen_random_uuid();
BEGIN
  PERFORM set_config('app.user_id', v_id::text, true);

  INSERT INTO app.account (user_id, recovery_key_lookup, recovery_key_hash,
                           platform_at_signup, app_version_at_signup)
  VALUES (v_id, p_recovery_key_lookup, p_recovery_key_hash,
          p_platform, p_app_version);

  RETURN v_id;
END $$;

REVOKE ALL ON FUNCTION app.create_account(bytea, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.create_account(bytea, text, text, text) TO ttc_app;

-- Seed 1:1 rows when a new account is created.
CREATE OR REPLACE FUNCTION app.seed_user_defaults()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO app.user_preferences (user_id) VALUES (NEW.user_id)
    ON CONFLICT DO NOTHING;
  INSERT INTO app.user_consent     (user_id) VALUES (NEW.user_id)
    ON CONFLICT DO NOTHING;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_seed_user_defaults
  AFTER INSERT ON app.account
  FOR EACH ROW EXECUTE FUNCTION app.seed_user_defaults();

-- Consent: append event + update the current-state cache.
CREATE OR REPLACE FUNCTION app.record_consent(
  p_purpose        text,
  p_granted        boolean,
  p_policy_version text
) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  v_uid uuid := app.current_user_id();
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'app.user_id not set';
  END IF;

  INSERT INTO app.consent_event (user_id, purpose, granted, policy_version)
  VALUES (v_uid, p_purpose, p_granted, p_policy_version);

  UPDATE app.user_consent SET
    trip_recording       = CASE WHEN p_purpose = 'trip_recording'       THEN p_granted ELSE trip_recording END,
    trip_contribution    = CASE WHEN p_purpose = 'trip_contribution'    THEN p_granted ELSE trip_contribution END,
    segment_contribution = CASE WHEN p_purpose = 'segment_contribution' THEN p_granted ELSE segment_contribution END,
    analytics_opt_in     = CASE WHEN p_purpose = 'analytics_opt_in'     THEN p_granted ELSE analytics_opt_in END,
    consented_at         = CASE WHEN p_granted     THEN now() ELSE consented_at END,
    revoked_at           = CASE WHEN NOT p_granted THEN now() ELSE revoked_at END
  WHERE user_id = v_uid;
END $$;

REVOKE ALL ON FUNCTION app.record_consent(text, boolean, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.record_consent(text, boolean, text) TO ttc_app;

-- Auth: bearer token -> session. Atomic UPDATE...RETURNING touches last_used_at.
CREATE OR REPLACE FUNCTION app.auth_session_lookup(p_token_hash text)
RETURNS TABLE (session_id uuid, user_id uuid, expires_at timestamptz)
LANGUAGE sql SECURITY DEFINER
SET search_path = pg_catalog
AS $$
  UPDATE app.session s
     SET last_used_at = now()
    FROM app.account a
   WHERE s.token_hash = p_token_hash
     AND s.revoked_at IS NULL
     AND s.expires_at > now()
     AND a.user_id = s.user_id
     AND a.status IN ('active','pending_deletion')
  RETURNING s.session_id, s.user_id, s.expires_at;
$$;

-- Auth: recovery key lookup. Returns the Argon2 hash for the API to verify.
CREATE OR REPLACE FUNCTION app.auth_recovery_lookup(p_recovery_key_lookup bytea)
RETURNS TABLE (user_id uuid, recovery_key_hash text)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog
AS $$
  SELECT a.user_id, a.recovery_key_hash
    FROM app.account a
   WHERE a.recovery_key_lookup = p_recovery_key_lookup
     AND a.status IN ('active','pending_deletion');
$$;

GRANT CREATE ON SCHEMA app TO ttc_auth_fn;
ALTER FUNCTION app.auth_session_lookup(text)   OWNER TO ttc_auth_fn;
ALTER FUNCTION app.auth_recovery_lookup(bytea) OWNER TO ttc_auth_fn;
REVOKE CREATE ON SCHEMA app FROM ttc_auth_fn;

REVOKE ALL ON FUNCTION app.auth_session_lookup(text)   FROM PUBLIC;
REVOKE ALL ON FUNCTION app.auth_recovery_lookup(bytea) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.auth_session_lookup(text)   TO ttc_app;
GRANT EXECUTE ON FUNCTION app.auth_recovery_lookup(bytea) TO ttc_app;

-- Schema version bump.
INSERT INTO ops.schema_version (version) VALUES (8) ON CONFLICT DO NOTHING;

COMMIT;