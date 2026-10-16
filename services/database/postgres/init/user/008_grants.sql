-- ============================================================================
-- 008_grants.sql
-- Column-level grants. ttc_app cannot read secrets.
-- ============================================================================

BEGIN;

-- app.account: no access to recovery credentials from ttc_app.
GRANT SELECT (user_id, recovery_key_updated_at, created_at, updated_at,
              last_active_at, status, deletion_requested_at,
              deletion_scheduled_at, referral_code, referred_by, feature_flags,
              install_count, first_install_at, app_version_at_signup,
              platform_at_signup)
  ON app.account TO ttc_app;
GRANT INSERT (user_id, recovery_key_lookup, recovery_key_hash,
              app_version_at_signup, platform_at_signup, referral_code)
  ON app.account TO ttc_app;
GRANT UPDATE (recovery_key_lookup, recovery_key_hash, recovery_key_updated_at,
              last_active_at, status, deletion_requested_at,
              deletion_scheduled_at, install_count)
  ON app.account TO ttc_app;

-- app.user_contact: no access to encrypted columns.
GRANT SELECT (user_id, email_hash, email_verified_at,
              phone_hash, phone_verified_at, created_at, updated_at)
  ON app.user_contact TO ttc_app;
GRANT INSERT (user_id, email_hash, email_encrypted, email_verified_at,
              phone_hash, phone_encrypted, phone_verified_at)
  ON app.user_contact TO ttc_app;
GRANT UPDATE (email_hash, email_encrypted, email_verified_at,
              phone_hash, phone_encrypted, phone_verified_at)
  ON app.user_contact TO ttc_app;
GRANT DELETE ON app.user_contact TO ttc_app;

GRANT SELECT, INSERT, UPDATE ON app.user_preferences, app.user_consent TO ttc_app;
GRANT SELECT, INSERT ON app.consent_event TO ttc_app;

-- app.session: ttc_app writes the hash but never reads it back.
GRANT SELECT (session_id, user_id, platform, app_version, os_version, model,
              created_at, last_used_at, expires_at, revoked_at, revoked_reason)
  ON app.session TO ttc_app;
GRANT INSERT (session_id, user_id, token_hash, platform, app_version,
              os_version, model, expires_at)
  ON app.session TO ttc_app;
GRANT UPDATE (last_used_at, revoked_at, revoked_reason) ON app.session TO ttc_app;

GRANT SELECT, INSERT, UPDATE, DELETE ON app.device TO ttc_app;
GRANT SELECT ON app.subscription TO ttc_app;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA app TO ttc_app;

-- Auth-function role.
GRANT SELECT ON app.account TO ttc_auth_fn;
GRANT SELECT ON app.session TO ttc_auth_fn;
GRANT UPDATE (last_used_at) ON app.session TO ttc_auth_fn;

-- Worker: full access.
GRANT ALL ON ALL TABLES    IN SCHEMA app TO ttc_worker;
GRANT ALL ON ALL SEQUENCES IN SCHEMA app TO ttc_worker;

COMMIT;