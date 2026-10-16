#!/usr/bin/env bash
# ============================================================================
# dbtool.sh — one-shot database task dispatcher.
#
# Usage (from Project_T/):
#   docker compose run --rm dbtool <command> [args...]
#
# Commands:
#   apply-schema <folder|all>   Apply .sql files in /schema/<folder> (sorted)
#   list                        List available schema folders
#   reset --confirm             Drop app, data, stats schemas (DESTRUCTIVE)
#   psql [args...]              Open interactive psql (dev convenience)
#   version                     Print schema_version table
#   help                        Show this help
# ============================================================================

set -euo pipefail

SCHEMA_ROOT="${SCHEMA_ROOT:-/schema}"
PGHOST="${PGHOST:-postgres}"
PGUSER="${PGUSER:-ttc_admin}"
PGDATABASE="${PGDATABASE:-ttc}"

psql_q() {
  psql -h "$PGHOST" -U "$PGUSER" -d "$PGDATABASE" -v ON_ERROR_STOP=1 "$@"
}

show_help() {
  sed -n '2,20p' "$0" | sed 's/^# \?//'
}

cmd_apply_schema() {
  local target="${1:-}"
  [[ -z "$target" ]] && { echo "usage: apply-schema <folder|all>" >&2; exit 1; }
  shift || true

  if [[ "$target" == "all" ]]; then
    mapfile -t folders < <(find "$SCHEMA_ROOT" -mindepth 1 -maxdepth 1 -type d | sort)
    if [[ ${#folders[@]} -eq 0 ]]; then
      echo "no schema folders found in $SCHEMA_ROOT" >&2
      exit 1
    fi
    for f in "${folders[@]}"; do
      echo "==> $(basename "$f")"
      /tools/db-apply-schema.sh "$f" "$@"
      echo
    done
  else
    local folder="$SCHEMA_ROOT/$target"
    [[ ! -d "$folder" ]] && { echo "folder not found: $folder" >&2; exit 1; }
    /tools/db-apply-schema.sh "$folder" "$@"
  fi
}

cmd_list() {
  echo "schema folders in $SCHEMA_ROOT:"
  find "$SCHEMA_ROOT" -mindepth 1 -maxdepth 1 -type d | sort \
    | while read -r f; do
        n=$(find "$f" -maxdepth 1 -type f -name '*.sql' | wc -l | tr -d ' ')
        printf '  %-20s (%s files)\n' "$(basename "$f")" "$n"
      done
}

cmd_reset() {
  if [[ "${1:-}" != "--confirm" ]]; then
    echo "reset is destructive. Pass --confirm to proceed." >&2
    echo "This will DROP schemas: app, data, stats CASCADE." >&2
    exit 1
  fi
  echo ">> dropping app, data, stats"
  psql_q <<'SQL'
DROP SCHEMA IF EXISTS app   CASCADE;
DROP SCHEMA IF EXISTS data  CASCADE;
DROP SCHEMA IF EXISTS stats CASCADE;
SQL
  echo "   done"
}

cmd_version() {
  psql_q -c "SELECT version FROM ops.schema_version ORDER BY version;"
}

cmd_psql() {
  exec psql -h "$PGHOST" -U "$PGUSER" -d "$PGDATABASE" "$@"
}

main() {
  local cmd="${1:-help}"
  shift || true
  case "$cmd" in
    apply-schema) cmd_apply_schema "$@" ;;
    list)         cmd_list ;;
    reset)        cmd_reset "$@" ;;
    version)      cmd_version ;;
    psql)         cmd_psql "$@" ;;
    help|*)       show_help ;;
  esac
}

main "$@"