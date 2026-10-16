-- ============================================================================
-- 000_roles.sql
-- Roles, schema, and helper functions for the user model.
-- ============================================================================

BEGIN;

CREATE SCHEMA IF NOT EXISTS app;
COMMENT ON SCHEMA app IS 'Per-user data. RLS-protected. Never joined to data.*.';

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ttc_app') THEN
    CREATE ROLE ttc_app LOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ttc_auth_fn') THEN
    CREATE ROLE ttc_auth_fn NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ttc_worker') THEN
    CREATE ROLE ttc_worker NOLOGIN;
  END IF;
END $$;

GRANT USAGE ON SCHEMA app TO ttc_app, ttc_auth_fn, ttc_worker;

CREATE OR REPLACE FUNCTION app.current_user_id() RETURNS uuid
LANGUAGE sql STABLE AS $$
  SELECT nullif(current_setting('app.user_id', true), '')::uuid
$$;

COMMENT ON FUNCTION app.current_user_id() IS
  'Set via SET LOCAL app.user_id = ''...'' at the start of every API request.';

CREATE OR REPLACE FUNCTION app.touch_updated_at() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END $$;

COMMIT;