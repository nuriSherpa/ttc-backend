-- ============================================================================
-- 005_extensions.sql
-- Extensions used by the schema. Runs first on fresh install.
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
