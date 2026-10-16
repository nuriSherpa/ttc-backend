#!/usr/bin/env bash
# ============================================================================
#  load_gtfs.sh — load a GTFS folder into the TTC v1.3 schema and activate it
#
#  Usage:   ./load_gtfs.sh <gtfs_dir> [feed_version]
#  Env:     DATABASE_URL   libpq connection string (default: "dbname=ttc")
#
#  Steps:   1. COPY each .txt into an unlogged text staging table (header-driven,
#              so column order / extra / missing optional columns are fine)
#           2. In ONE transaction: delete this feed_version from core.* and insert
#              typed rows (blank -> NULL, GTFS names mapped to core names)
#           3. Detect units (shapes km vs m) -> ops.units
#           4. ops.activate_feed()  (rebuild ref.* + flip pointer, atomic)
#           5. Mark run ok, GC old feeds, run ops.maintain(), drop staging
#
#  Safe to re-run with the same feed_version (idempotent reload).
# ============================================================================
set -euo pipefail

DIR="${1:?Usage: $0 <gtfs_dir> [feed_version]}"
FEED="${2:-ttc-$(date +%Y%m%d)}"
DSN="${DATABASE_URL:-dbname=ttc}"
DIR="$(cd "$DIR" && pwd)"

psql_() { psql "$DSN" -X -q -v ON_ERROR_STOP=1 "$@"; }

for f in agency stops routes trips stop_times; do
  [[ -f "$DIR/$f.txt" ]] || { echo "missing required file: $DIR/$f.txt" >&2; exit 1; }
done
[[ -f "$DIR/calendar.txt" || -f "$DIR/calendar_dates.txt" ]] \
  || { echo "need calendar.txt or calendar_dates.txt" >&2; exit 1; }

echo "==> feed_version: $FEED"
echo "==> source dir:   $DIR"

# ---------------------------------------------------------------------------
#  Helper functions (idempotent)
# ---------------------------------------------------------------------------
psql_ <<'SQL'
CREATE SCHEMA IF NOT EXISTS stg;

-- Insert stg.<table> into core.<table>, casting by the target column types.
-- p_map renames target -> source column (GTFS name differs from core name).
-- Columns absent from the file are skipped (table default / NULL applies).
CREATE OR REPLACE FUNCTION ops.load_staged(
    p_table text, p_feed text, p_map jsonb DEFAULT '{}'::jsonb
) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
    r    record;
    src  text;
    expr text;
    v_cols text[] := '{}';
    v_sel  text[] := '{}';
    n    bigint;
BEGIN
    FOR r IN
        SELECT c.column_name, c.data_type, c.is_nullable, c.column_default
        FROM information_schema.columns c
        WHERE c.table_schema = 'core' AND c.table_name = p_table
          AND c.column_name <> 'feed_version'
        ORDER BY c.ordinal_position
    LOOP
        src := COALESCE(p_map->>r.column_name, r.column_name);
        IF NOT EXISTS (SELECT 1 FROM information_schema.columns s
                       WHERE s.table_schema = 'stg' AND s.table_name = p_table
                         AND s.column_name = src) THEN
            CONTINUE;
        END IF;
        expr := format('NULLIF(btrim(s.%I), '''')::%s', src, r.data_type);
        IF r.is_nullable = 'NO' AND r.column_default IS NOT NULL THEN
            expr := format('COALESCE(%s, %s)', expr, r.column_default);
        END IF;
        v_cols := v_cols || format('%I', r.column_name);
        v_sel  := v_sel  || expr;
    END LOOP;

    IF cardinality(v_cols) = 0 THEN
        RETURN 0;                      -- optional file absent or empty
    END IF;

    EXECUTE format('INSERT INTO core.%I (feed_version, %s) SELECT %L, %s FROM stg.%I s',
                   p_table, array_to_string(v_cols, ', '), p_feed,
                   array_to_string(v_sel, ', '), p_table);
    GET DIAGNOSTICS n = ROW_COUNT;
    RETURN n;
END;
$$;

-- Detect distance units by comparing shape_dist_traveled with the haversine
-- length of the shape polyline; snap to {1 m, 1000 km, 1609.344 mile}.
CREATE OR REPLACE FUNCTION ops.detect_units(p_feed text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    v_shape_ratio double precision;
    v_stop_ratio  double precision;
    v_shape_scale double precision := 1;
    v_stop_scale  double precision := 1;
    cands constant double precision[] := ARRAY[1, 1000, 1609.344];
BEGIN
    WITH p1 AS (
        SELECT shape_id, shape_dist_traveled AS d, shape_pt_lat AS lat, shape_pt_lon AS lon,
               lag(shape_pt_lat) OVER w AS plat, lag(shape_pt_lon) OVER w AS plon
        FROM core.shapes WHERE feed_version = p_feed
        WINDOW w AS (PARTITION BY shape_id ORDER BY shape_pt_sequence)
    ), p2 AS (
        SELECT shape_id, d,
               CASE WHEN plat IS NULL THEN 0 ELSE
                 2 * 6371000 * asin(LEAST(1, sqrt(
                     power(sin(radians(lat - plat) / 2), 2)
                   + cos(radians(plat)) * cos(radians(lat))
                     * power(sin(radians(lon - plon) / 2), 2)))) END AS hav
        FROM p1
    ), sl AS (
        SELECT shape_id, sum(hav) AS len_m, max(d) AS max_d FROM p2 GROUP BY shape_id
    ), shape_r AS (
        SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY len_m / max_d) AS r
        FROM sl WHERE max_d > 0 AND len_m > 0
    ), trips_s AS (
        SELECT trip_id, shape_id FROM core.trips
        WHERE feed_version = p_feed AND shape_id IS NOT NULL
        ORDER BY trip_id LIMIT 500
    ), tm AS (
        SELECT t.trip_id, max(st.shape_dist_traveled) AS md
        FROM trips_s t
        JOIN core.stop_times st ON st.feed_version = p_feed AND st.trip_id = t.trip_id
        GROUP BY t.trip_id
    ), stop_r AS (
        SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY sl.len_m / tm.md) AS r
        FROM tm JOIN trips_s t USING (trip_id) JOIN sl USING (shape_id)
        WHERE tm.md > 0 AND sl.len_m > 0
    )
    SELECT (SELECT r FROM shape_r), (SELECT r FROM stop_r)
    INTO v_shape_ratio, v_stop_ratio;

    IF v_shape_ratio IS NULL THEN
        RAISE WARNING 'no usable shape_dist_traveled in shapes; shape_scale = 1';
    ELSE
        SELECT c INTO v_shape_scale FROM unnest(cands) c
        ORDER BY abs(ln(v_shape_ratio / c)) LIMIT 1;
        IF abs(ln(v_shape_ratio / v_shape_scale)) > ln(2) THEN
            RAISE WARNING 'shape ratio % matches no standard unit well; using %',
                          v_shape_ratio, v_shape_scale;
        END IF;
    END IF;

    IF v_stop_ratio IS NULL THEN
        RAISE WARNING 'no usable stop_times.shape_dist_traveled; stop_scale = 1';
    ELSE
        SELECT c INTO v_stop_scale FROM unnest(cands) c
        ORDER BY abs(ln(v_stop_ratio / c)) LIMIT 1;
        IF abs(ln(v_stop_ratio / v_stop_scale)) > ln(2) THEN
            RAISE WARNING 'stop ratio % matches no standard unit well; using %',
                          v_stop_ratio, v_stop_scale;
        END IF;
    END IF;

    RAISE NOTICE 'units: shape ratio=% -> scale %, stop ratio=% -> scale %',
                 v_shape_ratio, v_shape_scale, v_stop_ratio, v_stop_scale;

    INSERT INTO ops.units (feed_version, shape_scale, stop_scale, detected_at)
    VALUES (p_feed, v_shape_scale, v_stop_scale, now())
    ON CONFLICT (feed_version) DO UPDATE
        SET shape_scale = EXCLUDED.shape_scale,
            stop_scale  = EXCLUDED.stop_scale,
            detected_at = EXCLUDED.detected_at;
END;
$$;
SQL

RUN_ID="$(psql_ -At -c "INSERT INTO ops.run (source, feed_version) VALUES ('ttc', '$FEED') RETURNING id" | head -n1)"
mark_failed() {
  psql "$DSN" -X -q -v run_id="$RUN_ID" >/dev/null 2>&1 <<'SQL' || true
UPDATE ops.run SET status = 'failed', finished_at = now(),
       error = 'load_gtfs.sh failed (see terminal output)' WHERE id = :run_id;
SQL
}
trap mark_failed ERR

# ---------------------------------------------------------------------------
#  1. Stage every file as text
# ---------------------------------------------------------------------------
stage() {
  local t="$1" f="$DIR/$1.txt" hdr cols
  if [[ ! -f "$f" ]]; then
    psql_ -c "DROP TABLE IF EXISTS stg.$t; CREATE UNLOGGED TABLE stg.$t ()"
    echo "    $t: (absent, skipped)"
    return
  fi
  # header -> "a text, b text, ..."  (strip CR, UTF-8 BOM, spaces, double quotes)
  hdr=$(head -n1 "$f" | tr -d '\r' | LC_ALL=C sed $'s/^\xef\xbb\xbf//' | tr 'A-Z' 'a-z' | tr -d '[:space:]\042')
  cols=$(printf '%s' "$hdr" | sed 's/,/ text, /g; s/$/ text/')
  psql_ -c "DROP TABLE IF EXISTS stg.$t; CREATE UNLOGGED TABLE stg.$t ($cols)"
  psql_ -c "\\copy stg.$t FROM '$f' WITH (FORMAT csv, HEADER true)"
  echo "    $t: $(psql_ -At -c "SELECT count(*) FROM stg.$t") rows staged"
}

echo "==> staging"
for t in agency stops routes trips stop_times shapes calendar calendar_dates \
         levels pathways transfers frequencies feed_info; do
  stage "$t"
done

# Columns the loader references that single-agency / minimal feeds may omit.
psql_ <<'SQL'
ALTER TABLE stg.agency    ADD COLUMN IF NOT EXISTS agency_id text;
UPDATE stg.agency SET agency_id = COALESCE(NULLIF(btrim(agency_id), ''), 'default');
ALTER TABLE stg.feed_info ADD COLUMN IF NOT EXISTS feed_publisher_name text,
                          ADD COLUMN IF NOT EXISTS feed_publisher_url  text,
                          ADD COLUMN IF NOT EXISTS feed_lang           text,
                          ADD COLUMN IF NOT EXISTS feed_start_date     text,
                          ADD COLUMN IF NOT EXISTS feed_end_date       text;
SQL

# ---------------------------------------------------------------------------
#  2. Typed load into core.* — one transaction
# ---------------------------------------------------------------------------
echo "==> loading core.* (single transaction)"
psql_ -v feed="$FEED" <<'SQL'
BEGIN;
DELETE FROM core.feed_info      WHERE feed_version = :'feed';
DELETE FROM core.agency         WHERE feed_version = :'feed';
DELETE FROM core.stops          WHERE feed_version = :'feed';
DELETE FROM core.routes         WHERE feed_version = :'feed';
DELETE FROM core.trips          WHERE feed_version = :'feed';
DELETE FROM core.stop_times     WHERE feed_version = :'feed';
DELETE FROM core.shapes         WHERE feed_version = :'feed';
DELETE FROM core.calendar       WHERE feed_version = :'feed';
DELETE FROM core.calendar_dates WHERE feed_version = :'feed';
DELETE FROM core.levels         WHERE feed_version = :'feed';
DELETE FROM core.pathways       WHERE feed_version = :'feed';
DELETE FROM core.transfers      WHERE feed_version = :'feed';
DELETE FROM core.frequencies    WHERE feed_version = :'feed';

SELECT 'agency'         AS tbl, ops.load_staged('agency', :'feed',
  '{"name":"agency_name","url":"agency_url","timezone":"agency_timezone","lang":"agency_lang","phone":"agency_phone","email":"agency_email","fare_url":"agency_fare_url"}') AS rows
UNION ALL SELECT 'stops',          ops.load_staged('stops', :'feed')
UNION ALL SELECT 'routes',         ops.load_staged('routes', :'feed')
UNION ALL SELECT 'trips',          ops.load_staged('trips', :'feed')
UNION ALL SELECT 'stop_times',     ops.load_staged('stop_times', :'feed')
UNION ALL SELECT 'shapes',         ops.load_staged('shapes', :'feed')
UNION ALL SELECT 'calendar',       ops.load_staged('calendar', :'feed')
UNION ALL SELECT 'calendar_dates', ops.load_staged('calendar_dates', :'feed', '{"service_date":"date"}')
UNION ALL SELECT 'levels',         ops.load_staged('levels', :'feed')
UNION ALL SELECT 'pathways',       ops.load_staged('pathways', :'feed')
UNION ALL SELECT 'transfers',      ops.load_staged('transfers', :'feed')
UNION ALL SELECT 'frequencies',    ops.load_staged('frequencies', :'feed');

-- feed_info: use the file when it has dates, otherwise derive the validity
-- window from calendar + calendar_dates.
INSERT INTO core.feed_info (feed_version, publisher_name, publisher_url, lang, start_date, end_date)
SELECT :'feed',
       (SELECT NULLIF(btrim(feed_publisher_name), '') FROM stg.feed_info LIMIT 1),
       (SELECT NULLIF(btrim(feed_publisher_url),  '') FROM stg.feed_info LIMIT 1),
       (SELECT NULLIF(btrim(feed_lang),           '') FROM stg.feed_info LIMIT 1),
       COALESCE((SELECT NULLIF(btrim(feed_start_date), '')::date FROM stg.feed_info LIMIT 1), d.s),
       COALESCE((SELECT NULLIF(btrim(feed_end_date),   '')::date FROM stg.feed_info LIMIT 1), d.e)
FROM (SELECT min(x) AS s, max(y) AS e FROM (
          SELECT start_date AS x, end_date AS y FROM core.calendar WHERE feed_version = :'feed'
          UNION ALL
          SELECT service_date, service_date FROM core.calendar_dates WHERE feed_version = :'feed'
      ) q) d;
COMMIT;
SQL

# ---------------------------------------------------------------------------
#  3-5. Units, activate, bookkeeping
# ---------------------------------------------------------------------------
echo "==> detecting units"
psql_ -v feed="$FEED" <<'SQL'
SELECT ops.detect_units(:'feed');
SQL

echo "==> activating (rebuild ref.* + flip pointer; this is the slow step)"
psql_ -v feed="$FEED" <<'SQL'
\timing on
SET work_mem = '256MB';
SET maintenance_work_mem = '1GB';
SELECT ops.activate_feed('ttc', :'feed', 14);
SQL

psql_ -v feed="$FEED" -v run_id="$RUN_ID" <<'SQL'
UPDATE ops.run SET status = 'ok', finished_at = now(),
  rows = jsonb_build_object(
    'stops',      (SELECT count(*) FROM core.stops      WHERE feed_version = :'feed'),
    'trips',      (SELECT count(*) FROM core.trips      WHERE feed_version = :'feed'),
    'stop_times', (SELECT count(*) FROM core.stop_times WHERE feed_version = :'feed'),
    'departures', (SELECT count(*) FROM ref.departures))
WHERE id = :run_id;
SELECT ops.gc_old_feeds('ttc', 2) AS core_rows_gced;
SELECT jsonb_pretty(ops.maintain()) AS maintain;
DROP SCHEMA stg CASCADE;
SQL

echo "==> done: $FEED is active"