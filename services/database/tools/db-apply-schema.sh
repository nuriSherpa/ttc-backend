#!/usr/bin/env bash
# ============================================================================
# db-apply-schema.sh — apply all *.sql files in a folder, in sorted order.
# Called by dbtool.sh; can also be run directly.
#
# Usage:
#   db-apply-schema.sh <folder> [--dry-run] [--verbose]
# ============================================================================

set -euo pipefail

FOLDER=""
DRY_RUN=false
VERBOSE=false

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --verbose) VERBOSE=true ;;
    -*) echo "unknown flag: $arg" >&2; exit 1 ;;
    *)  [[ -z "$FOLDER" ]] && FOLDER="$arg" ;;
  esac
done

[[ -z "$FOLDER" ]] && { echo "usage: $0 <folder> [--dry-run] [--verbose]" >&2; exit 1; }
[[ ! -d "$FOLDER" ]] && { echo "folder not found: $FOLDER" >&2; exit 1; }

PGHOST="${PGHOST:-postgres}"
PGUSER="${PGUSER:-ttc_admin}"
PGDATABASE="${PGDATABASE:-ttc}"

mapfile -t FILES < <(find "$FOLDER" -maxdepth 1 -type f -name '*.sql' | sort)
[[ ${#FILES[@]} -eq 0 ]] && { echo "no .sql files in $FOLDER" >&2; exit 1; }

echo "------------------------------------------------------------"
echo " folder:  $FOLDER"
echo " files:   ${#FILES[@]}"
echo " target:  $PGUSER@$PGHOST/$PGDATABASE"
echo " mode:    $([[ $DRY_RUN == true ]] && echo 'DRY RUN' || echo 'APPLY')"
echo "------------------------------------------------------------"

APPLIED=0
for f in "${FILES[@]}"; do
  name=$(basename "$f")
  printf '  %-40s ' "$name"

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "SKIP"
    continue
  fi

  LOG=$(mktemp)
  if psql -h "$PGHOST" -U "$PGUSER" -d "$PGDATABASE" \
         -v ON_ERROR_STOP=1 -q -f "$f" > "$LOG" 2>&1; then
    echo "OK"
    APPLIED=$((APPLIED + 1))
    [[ "$VERBOSE" == "true" ]] && sed 's/^/       /' "$LOG"
  else
    echo "FAILED"
    echo
    echo "---- output from $name ----"
    cat "$LOG"
    echo "---- end ----"
    rm -f "$LOG"
    exit 1
  fi
  rm -f "$LOG"
done

if [[ "$DRY_RUN" == "true" ]]; then
  echo
  echo "dry run: ${#FILES[@]} files listed, nothing applied"
else
  echo
  echo "OK: $APPLIED file(s) applied"
fi