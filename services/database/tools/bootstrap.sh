#!/usr/bin/env bash
# ============================================================================
# bootstrap.sh — schema setup, idempotent.
#
# Runs on every `docker compose up`. First run applies user/, trip/, journey/.
# Later runs detect existing schemas and exit in under a second.
# Never drops anything.
#
# Env:
#   TARGET    apply only this phase (user | trip | journey). Empty = all.
# ============================================================================

set -euo pipefail

PGHOST="${PGHOST:-postgres}"
PGUSER="${PGUSER:-ttc_admin}"
PGDATABASE="${PGDATABASE:-ttc}"
SCHEMA_ROOT="${SCHEMA_ROOT:-/schema}"

psql_r()   { psql -h "$PGHOST" -U "$PGUSER" -d "$PGDATABASE" -tAc "$@"; }
psql_run() { psql -h "$PGHOST" -U "$PGUSER" -d "$PGDATABASE" -v ON_ERROR_STOP=1 -q "$@"; }

# ---------------------------------------------------------------------------
# Wait for Postgres to answer
# ---------------------------------------------------------------------------
printf 'bootstrap: waiting for postgres'
for _ in $(seq 1 60); do
  if psql -h "$PGHOST" -U "$PGUSER" -d "$PGDATABASE" -c 'SELECT 1' >/dev/null 2>&1; then
    echo ' ready.'
    break
  fi
  printf '.'
  sleep 1
done

# ---------------------------------------------------------------------------
# Wait for Postgres to finish its own init scripts (010_ttc_schema.sql).
# Prevents bootstrap running while schema is still being created.
# ---------------------------------------------------------------------------
printf 'bootstrap: waiting for init scripts'
for _ in $(seq 1 120); do
  ok=$(psql_r "SELECT count(*) FROM pg_class c
               JOIN pg_namespace n ON n.oid = c.relnamespace
               WHERE n.nspname='ops' AND c.relname='schema_version'")
  if [[ "$ok" == "1" ]]; then
    echo ' complete.'
    break
  fi
  printf '.'
  sleep 1
done

# ---------------------------------------------------------------------------
# Marker table
# ---------------------------------------------------------------------------
psql_run <<'SQL'
CREATE SCHEMA IF NOT EXISTS bootstrap;
CREATE TABLE IF NOT EXISTS bootstrap.applied_file (
  phase      text NOT NULL,
  filename   text NOT NULL,
  applied_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (phase, filename)
);
SQL

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

file_applied()  { [[ "$(psql_r "SELECT count(*) FROM bootstrap.applied_file
                              WHERE phase='$1' AND filename='$2'")" == "1" ]]; }
mark_applied()  { psql_run -c "INSERT INTO bootstrap.applied_file (phase, filename)
                               VALUES ('$1', '$2') ON CONFLICT DO NOTHING"; }
role_exists()   { [[ "$(psql_r "SELECT count(*) FROM pg_roles WHERE rolname='$1'")" == "1" ]]; }
ext_exists()    { [[ "$(psql_r "SELECT count(*) FROM pg_extension WHERE extname='$1'")" == "1" ]]; }
table_exists()  {
  local ns="${1%%.*}" rel="${1#*.}"
  [[ "$(psql_r "SELECT count(*) FROM pg_class c
                JOIN pg_namespace n ON n.oid=c.relnamespace
                WHERE n.nspname='$ns' AND c.relname='$rel'")" == "1" ]]
}

apply_sql() {
  local phase="$1" file="$2" fname log
  fname=$(basename "$file")
  file_applied "$phase" "$fname" && return 0
  printf '    [%s] %-40s ' "$phase" "$fname"
  log=$(mktemp)
  if psql_run -f "$file" >"$log" 2>&1; then
    echo OK
    mark_applied "$phase" "$fname"
  else
    echo FAILED
    echo "---- error from $fname ----"
    cat "$log"
    echo "---------------------------"
    rm -f "$log"
    exit 1
  fi
  rm -f "$log"
}

apply_folder() {
  local phase="$1" folder="$2" sentinel="$3"
  [[ ! -d "$folder" ]] && return 0

  # Pre-seed markers if the sentinel table already exists (fresh-install path
  # where Postgres ran the top-level files but the folder was already applied
  # in a previous life of this volume).
  if [[ -n "$sentinel" ]] \
     && [[ "$(psql_r "SELECT count(*) FROM bootstrap.applied_file WHERE phase='$phase'")" == "0" ]] \
     && table_exists "$sentinel"; then
    echo "  [$phase] detected pre-existing (via $sentinel) — marking as applied"
    while IFS= read -r f; do
      mark_applied "$phase" "$(basename "$f")"
    done < <(find "$folder" -maxdepth 1 -type f -name '*.sql' | sort)
    return 0
  fi

  echo "  [$phase]"
  while IFS= read -r f; do
    apply_sql "$phase" "$f"
  done < <(find "$folder" -maxdepth 1 -type f -name '*.sql' | sort)
}

# ---------------------------------------------------------------------------
# Phases applied by Postgres itself: detect and mark, don't re-run
# ---------------------------------------------------------------------------

echo
echo '============================================================'
echo ' bootstrap'
echo '============================================================'

if ! file_applied extensions 005_extensions.sql; then
  if ext_exists pg_trgm && ext_exists pg_stat_statements; then
    echo '  [extensions] detected pre-existing'
    mark_applied extensions 005_extensions.sql
  else
    apply_sql extensions "$SCHEMA_ROOT/005_extensions.sql"
  fi
fi

if ! file_applied transit 010_ttc_schema.sql; then
  if table_exists ops.schema_version; then
    echo '  [transit] detected pre-existing'
    mark_applied transit 010_ttc_schema.sql
  else
    apply_sql transit "$SCHEMA_ROOT/010_ttc_schema.sql"
  fi
fi

if ! file_applied roles 020_roles.sh; then
  if role_exists ttc_rt; then
    echo '  [roles] detected pre-existing'
    mark_applied roles 020_roles.sh
  else
    printf '    [roles] %-40s ' '020_roles.sh'
    if APP_DB_PASSWORD="${APP_DB_PASSWORD:-}" RT_DB_PASSWORD="${RT_DB_PASSWORD:-}" \
       bash "$SCHEMA_ROOT/020_roles.sh" >/dev/null 2>&1; then
      echo OK
      mark_applied roles 020_roles.sh
    else
      echo FAILED
      echo '  020_roles.sh requires APP_DB_PASSWORD and RT_DB_PASSWORD.'
      exit 1
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Subfolder schemas — applied by bootstrap.
# TARGET env var scopes to one phase; empty = apply all.
# ---------------------------------------------------------------------------

target() {
  local phase="$1" folder="$2" sentinel="$3"
  if [[ -z "${TARGET:-}" || "${TARGET}" == "$phase" ]]; then
    apply_folder "$phase" "$folder" "$sentinel"
  fi
}

target weather "$SCHEMA_ROOT/weather" ref.weather_grid

target user    "$SCHEMA_ROOT/user"    app.account
target trip    "$SCHEMA_ROOT/trip"    app.trip
target journey "$SCHEMA_ROOT/journey" app.journey
target walk    "$SCHEMA_ROOT/walk"    app.walk_observation
target data    "$SCHEMA_ROOT/data"    data.trip_observation
target stats   "$SCHEMA_ROOT/stats"   stats.route_reliability

echo
echo 'bootstrap: done'