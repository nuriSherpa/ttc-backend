-- ============================================================================
-- 007_rls.sql
-- Row Level Security for every app table.
-- Depends on: 001–006 (all tables must exist).
-- ============================================================================

BEGIN;

DO $$
DECLARE t text;
BEGIN
  -- Per-user tables: ttc_app sees only its own rows.
  FOREACH t IN ARRAY ARRAY['account','user_contact','user_preferences',
                           'user_consent','session','device']
  LOOP
    EXECUTE format('ALTER TABLE app.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('ALTER TABLE app.%I FORCE ROW LEVEL SECURITY', t);
    EXECUTE format($p$CREATE POLICY owner_all ON app.%I FOR ALL TO ttc_app
                      USING (user_id = app.current_user_id())
                      WITH CHECK (user_id = app.current_user_id())$p$, t);
  END LOOP;

  -- Read-only for ttc_app.
  ALTER TABLE app.subscription ENABLE ROW LEVEL SECURITY;
  ALTER TABLE app.subscription FORCE ROW LEVEL SECURITY;
  CREATE POLICY owner_select ON app.subscription FOR SELECT TO ttc_app
    USING (user_id = app.current_user_id());

  -- Append-only for ttc_app.
  ALTER TABLE app.consent_event ENABLE ROW LEVEL SECURITY;
  ALTER TABLE app.consent_event FORCE ROW LEVEL SECURITY;
  CREATE POLICY owner_select ON app.consent_event FOR SELECT TO ttc_app
    USING (user_id = app.current_user_id());
  CREATE POLICY owner_insert ON app.consent_event FOR INSERT TO ttc_app
    WITH CHECK (user_id = app.current_user_id());

  -- Ops-only tables: RLS on, no ttc_app policy = default deny.
  ALTER TABLE app.subscription_event ENABLE ROW LEVEL SECURITY;
  ALTER TABLE app.subscription_event FORCE ROW LEVEL SECURITY;
  ALTER TABLE app.deletion_audit ENABLE ROW LEVEL SECURITY;
  ALTER TABLE app.deletion_audit FORCE ROW LEVEL SECURITY;

  -- Background worker: all rows, all tables.
  FOREACH t IN ARRAY ARRAY['account','user_contact','user_preferences',
                           'user_consent','consent_event','session','device',
                           'subscription','subscription_event','deletion_audit']
  LOOP
    EXECUTE format($p$CREATE POLICY worker_all ON app.%I FOR ALL TO ttc_worker
                      USING (true) WITH CHECK (true)$p$, t);
  END LOOP;
END $$;

-- Auth-function role: only the two tables it needs (RLS + policy).
ALTER TABLE app.account ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.account FORCE ROW LEVEL SECURITY;
ALTER TABLE app.session ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.session FORCE ROW LEVEL SECURITY;

CREATE POLICY auth_fn_all ON app.account FOR ALL TO ttc_auth_fn
  USING (true) WITH CHECK (true);
CREATE POLICY auth_fn_all ON app.session FOR ALL TO ttc_auth_fn
  USING (true) WITH CHECK (true);

COMMIT;