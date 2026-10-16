--
-- PostgreSQL database dump
--

\restrict MWZwxldvGNqHLWhCGuKTaTRQDsaiHYtRoYnfCoRsEZKxW5mZhLcnhPgIs3CwrQZ

-- Dumped from database version 16.15 (Debian 16.15-1.pgdg13+2)
-- Dumped by pg_dump version 16.15 (Debian 16.15-1.pgdg13+2)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: core; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA core;


--
-- Name: SCHEMA core; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON SCHEMA core IS 'Raw GTFS, versioned by feed_version, read-only';


--
-- Name: cur; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA cur;


--
-- Name: SCHEMA cur; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON SCHEMA cur IS 'Convenience views filtered by active_version()';


--
-- Name: ops; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA ops;


--
-- Name: SCHEMA ops; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON SCHEMA ops IS 'Orchestration: active feed, run history, unit scales';


--
-- Name: ref; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA ref;


--
-- Name: SCHEMA ref; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON SCHEMA ref IS 'Derived tables reflecting the active feed';


--
-- Name: rt; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA rt;


--
-- Name: SCHEMA rt; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON SCHEMA rt IS 'Realtime vehicles, trips, ETAs';


--
-- Name: parse_service_second(text); Type: FUNCTION; Schema: core; Owner: -
--

CREATE FUNCTION core.parse_service_second(t text) RETURNS integer
    LANGUAGE sql IMMUTABLE
    AS $$
    SELECT CASE
        WHEN t IS NULL OR btrim(t) = '' THEN NULL
        ELSE split_part(btrim(t),':',1)::int * 3600
           + split_part(btrim(t),':',2)::int * 60
           + split_part(btrim(t),':',3)::int
    END;
$$;


--
-- Name: FUNCTION parse_service_second(t text); Type: COMMENT; Schema: core; Owner: -
--

COMMENT ON FUNCTION core.parse_service_second(t text) IS 'Parse "30:52:41" -> 111161. Handles GTFS times past midnight.';


--
-- Name: resolve_departure(date, integer); Type: FUNCTION; Schema: core; Owner: -
--

CREATE FUNCTION core.resolve_departure(d date, ss integer) RETURNS timestamp with time zone
    LANGUAGE sql STABLE
    AS $$
    SELECT ((d + time '12:00') AT TIME ZONE 'America/Toronto')
           + make_interval(secs => (ss - 43200));
$$;


--
-- Name: FUNCTION resolve_departure(d date, ss integer); Type: COMMENT; Schema: core; Owner: -
--

COMMENT ON FUNCTION core.resolve_departure(d date, ss integer) IS '(service_date, service_second) -> timestamptz using the GTFS "noon minus 12h" anchor. Correct across DST transitions. STABLE (tz rules can change).';


--
-- Name: activate_feed(text, text, integer); Type: FUNCTION; Schema: ops; Owner: -
--

CREATE FUNCTION ops.activate_feed(p_source text, p_feed text, p_horizon_days integer DEFAULT 14) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
    PERFORM ref.rebuild(p_feed, p_horizon_days);
    INSERT INTO ops.feed (source, feed_version, activated_at)
    VALUES (p_source, p_feed, now())
    ON CONFLICT (source) DO UPDATE
        SET feed_version = EXCLUDED.feed_version,
            activated_at = EXCLUDED.activated_at;
END;
$$;


--
-- Name: FUNCTION activate_feed(p_source text, p_feed text, p_horizon_days integer); Type: COMMENT; Schema: ops; Owner: -
--

COMMENT ON FUNCTION ops.activate_feed(p_source text, p_feed text, p_horizon_days integer) IS 'ref.rebuild + ops.feed flip in one transaction. Call as a single statement.';


--
-- Name: active_version(text); Type: FUNCTION; Schema: ops; Owner: -
--

CREATE FUNCTION ops.active_version(p_source text DEFAULT 'ttc'::text) RETURNS text
    LANGUAGE sql STABLE
    AS $$
    SELECT feed_version FROM ops.feed WHERE source = p_source;
$$;


--
-- Name: FUNCTION active_version(p_source text); Type: COMMENT; Schema: ops; Owner: -
--

COMMENT ON FUNCTION ops.active_version(p_source text) IS 'Returns the currently active feed_version. Used by cur.* views.';


--
-- Name: detect_units(text); Type: FUNCTION; Schema: ops; Owner: -
--

CREATE FUNCTION ops.detect_units(p_feed text) RETURNS void
    LANGUAGE plpgsql
    AS $$
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


--
-- Name: gc_old_feeds(text, integer); Type: FUNCTION; Schema: ops; Owner: -
--

CREATE FUNCTION ops.gc_old_feeds(p_source text DEFAULT 'ttc'::text, p_keep integer DEFAULT 2) RETURNS bigint
    LANGUAGE plpgsql
    AS $_$
DECLARE
    v_keep   text[];
    v_active text;
    v_ref    text;
    r        record;
    n        bigint;
    total    bigint := 0;
BEGIN
    PERFORM pg_advisory_xact_lock(hashtext('ttc.ref.refresh'));

    SELECT COALESCE(array_agg(feed_version), '{}'::text[]) INTO v_keep
    FROM (
        SELECT feed_version
        FROM ops.run
        WHERE source = p_source
          AND status = 'ok'
          AND feed_version IS NOT NULL
        GROUP BY feed_version
        ORDER BY max(finished_at) DESC NULLS LAST
        LIMIT p_keep
    ) s;

    v_keep := v_keep || COALESCE((
        SELECT array_agg(DISTINCT feed_version)
        FROM ops.run
        WHERE source = p_source
          AND status = 'running'
          AND feed_version IS NOT NULL
          AND started_at > now() - interval '6 hours'
    ), '{}'::text[]);

    v_active := ops.active_version(p_source);
    IF v_active IS NOT NULL THEN
        v_keep := array_append(v_keep, v_active);
    END IF;

    SELECT feed_version INTO v_ref FROM ref.state;
    IF v_ref IS NOT NULL THEN
        v_keep := array_append(v_keep, v_ref);
    END IF;

    IF cardinality(v_keep) = 0 THEN
        RETURN 0;   -- never delete everything because history is empty
    END IF;

    FOR r IN
        SELECT c.relname
        FROM pg_class c
        JOIN pg_namespace ns ON ns.oid = c.relnamespace
        WHERE ns.nspname = 'core' AND c.relkind IN ('r','p')
    LOOP
        EXECUTE format('DELETE FROM core.%I WHERE feed_version <> ALL($1)',
                       r.relname) USING v_keep;
        GET DIAGNOSTICS n = ROW_COUNT;
        total := total + n;
    END LOOP;

    DELETE FROM ops.units WHERE feed_version <> ALL(v_keep);
    RETURN total;
END;
$_$;


--
-- Name: FUNCTION gc_old_feeds(p_source text, p_keep integer); Type: COMMENT; Schema: ops; Owner: -
--

COMMENT ON FUNCTION ops.gc_old_feeds(p_source text, p_keep integer) IS 'Deletes core.* rows for feed versions that are not among the last p_keep distinct OK versions, the active version, the ref.state version, or a recent running load. Returns rows deleted.';


--
-- Name: load_staged(text, text, jsonb); Type: FUNCTION; Schema: ops; Owner: -
--

CREATE FUNCTION ops.load_staged(p_table text, p_feed text, p_map jsonb DEFAULT '{}'::jsonb) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
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


--
-- Name: maintain(); Type: FUNCTION; Schema: ops; Owner: -
--

CREATE FUNCTION ops.maintain() RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_today   date := ops.today();
    v_dropped int;
    v_swept   jsonb;
    v_rolled  bigint := NULL;
BEGIN
    FOR i IN 0..3 LOOP                       -- three nights of safety margin
        PERFORM rt.ensure_partition(v_today + i);
    END LOOP;
    v_dropped := rt.drop_old_partitions(2);
    v_swept   := rt.sweep_stale();

    IF EXISTS (SELECT 1 FROM ref.state) THEN
        v_rolled := ref.roll_forward();      -- raises if the feed has expired
    END IF;

    RETURN jsonb_build_object(
        'today',               v_today,
        'partitions_dropped',  v_dropped,
        'departures_added',    v_rolled,
        'swept',               v_swept,
        'default_rows',        (SELECT count(*) FROM rt.vehicle_samples_default),
        'feed_days_remaining', (SELECT i.end_date - v_today
                                FROM ref.state s
                                JOIN core.feed_info i USING (feed_version))
    );
END;
$$;


--
-- Name: FUNCTION maintain(); Type: COMMENT; Schema: ops; Owner: -
--

COMMENT ON FUNCTION ops.maintain() IS 'Nightly: ensure partitions, drop old ones, sweep realtime, roll the departures window. Returns a JSON health report.';


--
-- Name: today(); Type: FUNCTION; Schema: ops; Owner: -
--

CREATE FUNCTION ops.today() RETURNS date
    LANGUAGE sql STABLE
    AS $$
    SELECT (now() AT TIME ZONE 'America/Toronto')::date;
$$;


--
-- Name: FUNCTION today(); Type: COMMENT; Schema: ops; Owner: -
--

COMMENT ON FUNCTION ops.today() IS 'Current date in America/Toronto. Use instead of current_date.';


--
-- Name: rebuild(text, integer); Type: FUNCTION; Schema: ref; Owner: -
--

CREATE FUNCTION ref.rebuild(p_feed text, p_horizon_days integer DEFAULT 14) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_stop_scale double precision;
    v_tmp        text;
BEGIN
    PERFORM pg_advisory_xact_lock(hashtext('ttc.ref.refresh'));

    -- Re-entrancy: drop scratch tables from an earlier call in this session.
    FOREACH v_tmp IN ARRAY ARRAY['_ts','_trip_pattern','_pat'] LOOP
        IF to_regclass('pg_temp.' || v_tmp) IS NOT NULL THEN
            EXECUTE format('DROP TABLE pg_temp.%I', v_tmp);
        END IF;
    END LOOP;

    IF NOT EXISTS (SELECT 1 FROM core.feed_info WHERE feed_version = p_feed) THEN
        RAISE EXCEPTION 'feed % not found in core.feed_info', p_feed;
    END IF;

    SELECT stop_scale INTO v_stop_scale
    FROM ops.units WHERE feed_version = p_feed;
    IF v_stop_scale IS NULL THEN
        RAISE EXCEPTION
            'no ops.units row for feed %: detect units before rebuilding '
            '(refusing to guess a scale of 1)', p_feed;
    END IF;

    -- -----------------------------------------------------------------------
    -- 0. Per-trip stop list with normalized ordinal and interpolated times.
    --    Number FIRST (ordinal covers every stop), then fill gaps, so ordinal
    --    always agrees with ref.pattern_stops.
    -- -----------------------------------------------------------------------
    CREATE TEMP TABLE _ts ON COMMIT DROP AS
    WITH raw AS (
        SELECT st.trip_id,
               ROW_NUMBER() OVER (PARTITION BY st.trip_id
                                  ORDER BY st.stop_sequence)::integer AS ordinal,
               COUNT(*)     OVER (PARTITION BY st.trip_id)::integer   AS n_stops,
               st.stop_sequence, st.stop_id, st.stop_headsign,
               st.pickup_type, st.shape_dist_traveled,
               COALESCE(core.parse_service_second(st.departure_time),
                        core.parse_service_second(st.arrival_time)) AS t_s
        FROM core.stop_times st
        WHERE st.feed_version = p_feed
    ), g AS (
        SELECT raw.*,
               COUNT(t_s) OVER (PARTITION BY trip_id ORDER BY ordinal)      AS g_prev,
               COUNT(t_s) OVER (PARTITION BY trip_id ORDER BY ordinal DESC) AS g_next
        FROM raw
    ), m AS (
        SELECT g.*,
               first_value(t_s)     OVER (PARTITION BY trip_id, g_prev ORDER BY ordinal)      AS prev_s,
               first_value(ordinal) OVER (PARTITION BY trip_id, g_prev ORDER BY ordinal)      AS prev_o,
               first_value(t_s)     OVER (PARTITION BY trip_id, g_next ORDER BY ordinal DESC) AS next_s,
               first_value(ordinal) OVER (PARTITION BY trip_id, g_next ORDER BY ordinal DESC) AS next_o
        FROM g
    )
    SELECT trip_id, ordinal, n_stops, stop_sequence, stop_id, stop_headsign,
           pickup_type, shape_dist_traveled,
           CASE
               WHEN t_s IS NOT NULL THEN t_s
               WHEN prev_s IS NOT NULL AND next_s IS NOT NULL
                   THEN round(prev_s + (next_s - prev_s)::numeric
                                       * (ordinal - prev_o) / (next_o - prev_o))::integer
           END AS departure_s,
           (t_s IS NULL AND prev_s IS NOT NULL AND next_s IS NOT NULL) AS interpolated
    FROM m;
    ALTER TABLE pg_temp._ts ADD PRIMARY KEY (trip_id, ordinal);
    ANALYZE pg_temp._ts;

    CREATE TEMP TABLE _trip_pattern ON COMMIT DROP AS
    SELECT x.trip_id,
           md5(x.stops || '|' || t.route_id || '|'
               || COALESCE(t.direction_id::text, '')) AS pattern_id,
           x.n_stops
    FROM (SELECT trip_id,
                 string_agg(stop_id, ',' ORDER BY ordinal) AS stops,
                 max(n_stops) AS n_stops
          FROM pg_temp._ts GROUP BY trip_id) x
    JOIN core.trips t
      ON t.feed_version = p_feed AND t.trip_id = x.trip_id;
    ALTER TABLE pg_temp._trip_pattern ADD PRIMARY KEY (trip_id);

    CREATE TEMP TABLE _pat ON COMMIT DROP AS
    SELECT pattern_id,
           MIN(trip_id)  AS sample_trip_id,
           COUNT(*)::int AS trip_count
    FROM pg_temp._trip_pattern
    GROUP BY pattern_id;

    -- -----------------------------------------------------------------------
    -- Clear derived tables (children first; DELETE keeps readers unblocked)
    -- -----------------------------------------------------------------------
    DELETE FROM ref.departures;
    DELETE FROM ref.service_days;
    DELETE FROM ref.pattern_stops;
    DELETE FROM ref.patterns;
    DELETE FROM ref.stop_routes;
    DELETE FROM ref.stop_points;
    DELETE FROM ref.trip_stops;
    DELETE FROM ref.trips;
    DELETE FROM ref.station_nodes;
    DELETE FROM ref.pathway_edges;
    DELETE FROM ref.transfers;
    DELETE FROM ref.frequency_trips;

    -- -----------------------------------------------------------------------
    -- 1. trips + trip_stops
    -- -----------------------------------------------------------------------
    INSERT INTO ref.trips
        (trip_id, route_id, service_id, direction_id, headsign,
         pattern_id, n_stops)
    SELECT t.trip_id, t.route_id, t.service_id, t.direction_id,
           t.trip_headsign, tp.pattern_id, tp.n_stops
    FROM core.trips t
    JOIN pg_temp._trip_pattern tp ON tp.trip_id = t.trip_id
    WHERE t.feed_version = p_feed;

    INSERT INTO ref.trip_stops
        (trip_id, ordinal, stop_sequence, stop_id, stop_headsign,
         departure_s, interpolated, boardable)
    SELECT ts.trip_id, ts.ordinal, ts.stop_sequence, ts.stop_id,
           ts.stop_headsign, ts.departure_s, ts.interpolated,
           COALESCE(ts.pickup_type, 0) <> 1 AND ts.ordinal < ts.n_stops
    FROM pg_temp._ts ts
    JOIN ref.trips t ON t.trip_id = ts.trip_id;

    -- -----------------------------------------------------------------------
    -- 2. stop_points + stop_routes
    -- -----------------------------------------------------------------------
    INSERT INTO ref.stop_points
        (stop_id, stop_code, stop_name, stop_lat, stop_lon,
         wheelchair_boarding, parent_station, station_name)
    SELECT s.stop_id, s.stop_code, s.stop_name,
           s.stop_lat, s.stop_lon, s.wheelchair_boarding,
           s.parent_station, ps.stop_name
    FROM core.stops s
    LEFT JOIN core.stops ps
      ON ps.feed_version = s.feed_version AND ps.stop_id = s.parent_station
    WHERE s.feed_version = p_feed
      AND s.location_type = 0
      AND s.stop_lat IS NOT NULL
      AND s.stop_lon IS NOT NULL
      AND s.stop_id IN (SELECT stop_id FROM ref.trip_stops);

    INSERT INTO ref.stop_routes (stop_id, route_id)
    SELECT DISTINCT ts.stop_id, t.route_id
    FROM ref.trip_stops ts
    JOIN ref.trips t ON t.trip_id = ts.trip_id
    WHERE ts.stop_id IN (SELECT stop_id FROM ref.stop_points);

    -- -----------------------------------------------------------------------
    -- 3. patterns + pattern_stops (ordinal numbering shared with trip_stops)
    -- -----------------------------------------------------------------------
    INSERT INTO ref.patterns
        (pattern_id, route_id, direction_id, headsign, n_stops, trip_count)
    SELECT p.pattern_id, t.route_id, t.direction_id, t.headsign,
           t.n_stops, p.trip_count
    FROM pg_temp._pat p
    JOIN ref.trips t ON t.trip_id = p.sample_trip_id;

    INSERT INTO ref.pattern_stops (pattern_id, ordinal, stop_id, dist_m)
    SELECT p.pattern_id, ts.ordinal, ts.stop_id,
           ts.shape_dist_traveled * v_stop_scale
    FROM pg_temp._pat p
    JOIN pg_temp._ts ts ON ts.trip_id = p.sample_trip_id;

    -- -----------------------------------------------------------------------
    -- 4. station_nodes
    -- -----------------------------------------------------------------------
    INSERT INTO ref.station_nodes
        (stop_id, stop_name, location_type, station_id, level_id,
         level_index, level_name, wheelchair_boarding, stop_lat, stop_lon)
    SELECT s.stop_id, COALESCE(s.stop_name, s.stop_id), s.location_type,
           COALESCE(s.parent_station,
                    CASE WHEN s.location_type = 1 THEN s.stop_id END),
           s.level_id, l.level_index, l.level_name,
           s.wheelchair_boarding, s.stop_lat, s.stop_lon
    FROM core.stops s
    LEFT JOIN core.levels l
      ON l.feed_version = p_feed AND l.level_id = s.level_id
    WHERE s.feed_version = p_feed
      AND (s.parent_station IS NOT NULL OR s.location_type = 1);

    -- -----------------------------------------------------------------------
    -- 5. pathway_edges (bidirectional expanded)
    -- -----------------------------------------------------------------------
    INSERT INTO ref.pathway_edges
        (pathway_id, from_id, to_id, mode, traversal_s,
         length_m, stair_count, sign)
    SELECT pathway_id, from_stop_id, to_stop_id,
           pathway_mode, traversal_time, length, stair_count, signposted_as
    FROM core.pathways
    WHERE feed_version = p_feed
      AND from_stop_id IS NOT NULL AND to_stop_id IS NOT NULL
    UNION ALL
    SELECT pathway_id, to_stop_id, from_stop_id,
           pathway_mode, traversal_time, length, stair_count,
           reversed_signposted_as
    FROM core.pathways
    WHERE feed_version = p_feed
      AND is_bidirectional = 1
      AND from_stop_id IS NOT NULL AND to_stop_id IS NOT NULL;

    -- -----------------------------------------------------------------------
    -- 6. transfers + frequency_trips (optional, empty for TTC today)
    -- -----------------------------------------------------------------------
    INSERT INTO ref.transfers
        (from_stop_id, to_stop_id, from_route_id, to_route_id,
         from_trip_id, to_trip_id, min_seconds, type)
    SELECT from_stop_id, to_stop_id, from_route_id, to_route_id,
           from_trip_id, to_trip_id,
           COALESCE(min_transfer_time,
                    CASE transfer_type WHEN 1 THEN 0 ELSE 120 END),
           COALESCE(transfer_type, 0)
    FROM core.transfers
    WHERE feed_version = p_feed
      AND COALESCE(transfer_type, 0) <> 3;      -- 3 = transfer impossible

    INSERT INTO ref.frequency_trips
        (trip_id, start_s, end_s, headway_s, exact_times)
    SELECT trip_id,
           core.parse_service_second(start_time),
           core.parse_service_second(end_time),
           headway_secs, exact_times
    FROM core.frequencies
    WHERE feed_version = p_feed;

    -- -----------------------------------------------------------------------
    -- 7. Record the build, then materialize service_days + departures
    -- -----------------------------------------------------------------------
    INSERT INTO ref.state (singleton, feed_version, horizon_days, built_at, rolled_at)
    VALUES (true, p_feed, p_horizon_days, now(), NULL)
    ON CONFLICT (singleton) DO UPDATE
        SET feed_version = EXCLUDED.feed_version,
            horizon_days = EXCLUDED.horizon_days,
            built_at     = EXCLUDED.built_at,
            rolled_at    = NULL;

    PERFORM ref.roll_forward(p_horizon_days);

    ANALYZE ref.trips;
    ANALYZE ref.trip_stops;
    ANALYZE ref.stop_points;
    ANALYZE ref.stop_routes;
    ANALYZE ref.patterns;
    ANALYZE ref.pattern_stops;
    ANALYZE ref.station_nodes;
    ANALYZE ref.pathway_edges;
    ANALYZE ref.transfers;
END;
$$;


--
-- Name: FUNCTION rebuild(p_feed text, p_horizon_days integer); Type: COMMENT; Schema: ref; Owner: -
--

COMMENT ON FUNCTION ref.rebuild(p_feed text, p_horizon_days integer) IS 'Rebuild all ref.* tables from core.* for one feed. Atomic with the caller''s transaction. Raises if ops.units has no row for the feed.';


--
-- Name: roll_forward(integer); Type: FUNCTION; Schema: ref; Owner: -
--

CREATE FUNCTION ref.roll_forward(p_horizon_days integer DEFAULT NULL::integer) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_feed       text;
    v_horizon    integer;
    v_feed_start date;
    v_feed_end   date;
    v_start      date;
    v_end        date;
    v_inserted   bigint;
BEGIN
    PERFORM pg_advisory_xact_lock(hashtext('ttc.ref.refresh'));

    SELECT feed_version, horizon_days INTO v_feed, v_horizon FROM ref.state;
    IF v_feed IS NULL THEN
        RAISE EXCEPTION 'ref.state is empty: run ref.rebuild() first';
    END IF;
    IF p_horizon_days IS NOT NULL THEN
        v_horizon := p_horizon_days;
        UPDATE ref.state SET horizon_days = v_horizon;
    END IF;

    SELECT start_date, end_date INTO v_feed_start, v_feed_end
    FROM core.feed_info WHERE feed_version = v_feed;
    IF v_feed_start IS NULL THEN
        RAISE EXCEPTION 'feed % is missing from core.feed_info', v_feed;
    END IF;

    -- Include yesterday so after-midnight trips of yesterday's service day
    -- (times up to ~31:00:00) are present.
    v_start := GREATEST(v_feed_start, ops.today() - 1);
    v_end   := LEAST(v_feed_end, v_start + v_horizon - 1);
    IF v_end < v_start THEN
        RAISE EXCEPTION
            'feed % has no service in the window (feed ends %, today %): load a newer feed',
            v_feed, v_feed_end, ops.today();
    END IF;

    -- 1. service_days
    DELETE FROM ref.service_days;
    INSERT INTO ref.service_days (service_date, service_id)
    WITH days AS (
        SELECT g::date AS d
        FROM generate_series(v_start::timestamp, v_end::timestamp,
                             interval '1 day') g
    )
    SELECT d.d, c.service_id
    FROM days d
    JOIN core.calendar c
      ON c.feed_version = v_feed
     AND d.d BETWEEN c.start_date AND c.end_date
     AND CASE EXTRACT(DOW FROM d.d)
            WHEN 0 THEN c.sunday
            WHEN 1 THEN c.monday
            WHEN 2 THEN c.tuesday
            WHEN 3 THEN c.wednesday
            WHEN 4 THEN c.thursday
            WHEN 5 THEN c.friday
            WHEN 6 THEN c.saturday
         END
    WHERE NOT EXISTS (
        SELECT 1 FROM core.calendar_dates cd
        WHERE cd.feed_version = v_feed
          AND cd.service_id = c.service_id
          AND cd.service_date = d.d
          AND cd.exception_type = 2
    )
    UNION
    SELECT cd.service_date, cd.service_id
    FROM core.calendar_dates cd
    WHERE cd.feed_version = v_feed
      AND cd.exception_type = 1
      AND cd.service_date BETWEEN v_start AND v_end;

    -- 2. trim dates outside the window
    DELETE FROM ref.departures
    WHERE service_date < v_start OR service_date > v_end;

    -- 3. materialize only the dates that are missing
    INSERT INTO ref.departures
        (service_date, trip_id, ordinal, stop_sequence, stop_id,
         departs_at, departure_s, route_id, headsign, direction_id,
         pattern_id, boardable)
    SELECT sd.service_date,
           ts.trip_id,
           ts.ordinal,
           ts.stop_sequence,
           ts.stop_id,
           core.resolve_departure(sd.service_date, ts.departure_s),
           ts.departure_s,
           t.route_id,
           COALESCE(ts.stop_headsign, t.headsign),
           t.direction_id,
           t.pattern_id,
           ts.boardable
    FROM ref.service_days sd
    JOIN ref.trips t       ON t.service_id = sd.service_id
    JOIN ref.trip_stops ts ON ts.trip_id   = t.trip_id
    WHERE ts.departure_s IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM ref.departures d
                      WHERE d.service_date = sd.service_date);
    GET DIAGNOSTICS v_inserted = ROW_COUNT;

    UPDATE ref.state SET rolled_at = now();
    ANALYZE ref.service_days;
    ANALYZE ref.departures;
    RETURN v_inserted;
END;
$$;


--
-- Name: FUNCTION roll_forward(p_horizon_days integer); Type: COMMENT; Schema: ref; Owner: -
--

COMMENT ON FUNCTION ref.roll_forward(p_horizon_days integer) IS 'Daily window slide. Needs no feed argument (reads ref.state). Raises if the feed has no service left, so the cron job fails loudly.';


--
-- Name: drop_old_partitions(integer); Type: FUNCTION; Schema: rt; Owner: -
--

CREATE FUNCTION rt.drop_old_partitions(p_keep_days integer DEFAULT 2) RETURNS integer
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_cutoff date := ops.today() - p_keep_days;
    v_cut_ts timestamptz := (ops.today() - p_keep_days)::timestamp
                            AT TIME ZONE 'America/Toronto';
    r        record;
    n        int := 0;
BEGIN
    FOR r IN
        SELECT c.relname
        FROM pg_inherits i
        JOIN pg_class c ON c.oid = i.inhrelid
        JOIN pg_class p ON p.oid = i.inhparent
        JOIN pg_namespace nsp ON nsp.oid = p.relnamespace
        WHERE nsp.nspname = 'rt'
          AND p.relname = 'vehicle_samples'
          AND c.relname <> 'vehicle_samples_default'
    LOOP
        IF r.relname < 'vehicle_samples_' || to_char(v_cutoff, 'YYYYMMDD') THEN
            EXECUTE format('DROP TABLE rt.%I', r.relname);
            n := n + 1;
        END IF;
    END LOOP;

    DELETE FROM rt.vehicle_samples_default WHERE received_at < v_cut_ts;
    RETURN n;
END;
$$;


--
-- Name: ensure_partition(date); Type: FUNCTION; Schema: rt; Owner: -
--

CREATE FUNCTION rt.ensure_partition(p_date date) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    part_name  text := 'vehicle_samples_' || to_char(p_date, 'YYYYMMDD');
    stage_name text := 'vehicle_samples_' || to_char(p_date, 'YYYYMMDD') || '_stage';
    v_lo       timestamptz := p_date::timestamp AT TIME ZONE 'America/Toronto';
    v_hi       timestamptz := (p_date + 1)::timestamp AT TIME ZONE 'America/Toronto';
BEGIN
    IF to_regclass(format('rt.%I', part_name)) IS NOT NULL THEN
        RETURN;
    END IF;

    IF EXISTS (SELECT 1 FROM rt.vehicle_samples_default
               WHERE received_at >= v_lo AND received_at < v_hi) THEN
        IF to_regclass(format('rt.%I', stage_name)) IS NOT NULL THEN
            EXECUTE format('DROP TABLE rt.%I', stage_name);   -- leftover of a failed run
        END IF;
        EXECUTE format(
            'CREATE TABLE rt.%I (LIKE rt.vehicle_samples INCLUDING DEFAULTS)',
            stage_name);
        EXECUTE format(
            'WITH moved AS ('
            '  DELETE FROM rt.vehicle_samples_default '
            '  WHERE received_at >= %L AND received_at < %L RETURNING *) '
            'INSERT INTO rt.%I SELECT * FROM moved',
            v_lo, v_hi, stage_name);
        EXECUTE format(
            'ALTER TABLE rt.vehicle_samples ATTACH PARTITION rt.%I '
            'FOR VALUES FROM (%L) TO (%L)', stage_name, v_lo, v_hi);
        EXECUTE format('ALTER TABLE rt.%I RENAME TO %I', stage_name, part_name);
    ELSE
        EXECUTE format(
            'CREATE TABLE rt.%I PARTITION OF rt.vehicle_samples '
            'FOR VALUES FROM (%L) TO (%L)', part_name, v_lo, v_hi);
    END IF;
END;
$$;


--
-- Name: FUNCTION ensure_partition(p_date date); Type: COMMENT; Schema: rt; Owner: -
--

COMMENT ON FUNCTION rt.ensure_partition(p_date date) IS 'Idempotent. Boundaries are America/Toronto midnights (explicit offset), so the session timezone is irrelevant. Drains matching default rows.';


--
-- Name: infer_service_date(text, timestamp with time zone, date); Type: FUNCTION; Schema: rt; Owner: -
--

CREATE FUNCTION rt.infer_service_date(p_trip_id text, p_ts timestamp with time zone, p_start_date date DEFAULT NULL::date) RETURNS date
    LANGUAGE sql STABLE
    AS $$
    SELECT COALESCE(
        p_start_date,
        (
            SELECT d.service_date
            FROM ref.departures d
            WHERE d.trip_id = p_trip_id
              AND d.service_date IN ((p_ts AT TIME ZONE 'America/Toronto')::date,
                                     (p_ts AT TIME ZONE 'America/Toronto')::date - 1)
            GROUP BY d.service_date
            HAVING p_ts BETWEEN min(d.departs_at) - interval '3 hours'
                            AND max(d.departs_at) + interval '3 hours'
            ORDER BY min(abs(extract(epoch FROM (d.departs_at - p_ts))))
            LIMIT 1
        ),
        (p_ts AT TIME ZONE 'America/Toronto')::date
    );
$$;


--
-- Name: FUNCTION infer_service_date(p_trip_id text, p_ts timestamp with time zone, p_start_date date); Type: COMMENT; Schema: rt; Owner: -
--

COMMENT ON FUNCTION rt.infer_service_date(p_trip_id text, p_ts timestamp with time zone, p_start_date date) IS 'Explicit start_date wins; else the scheduled service_date (today or yesterday) whose run of the trip is nearest p_ts; else the local date.';


--
-- Name: sweep_stale(interval); Type: FUNCTION; Schema: rt; Owner: -
--

CREATE FUNCTION rt.sweep_stale(p_max_age interval DEFAULT '00:10:00'::interval) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
    n_veh int; n_dead int; n_old int; n_eta int;
    n_alert int; n_period int; n_entity int;
BEGIN
    DELETE FROM rt.vehicle_latest WHERE received_at < now() - p_max_age;
    GET DIAGNOSTICS n_veh = ROW_COUNT;

    UPDATE rt.trip_status SET is_active = false
    WHERE is_active AND received_at < now() - p_max_age;
    GET DIAGNOSTICS n_dead = ROW_COUNT;

    DELETE FROM rt.trip_status
    WHERE NOT is_active AND received_at < now() - interval '1 day';
    GET DIAGNOSTICS n_old = ROW_COUNT;

    DELETE FROM rt.stop_eta WHERE received_at < now() - p_max_age;
    GET DIAGNOSTICS n_eta = ROW_COUNT;

    WITH doomed AS (
        SELECT alert_id FROM rt.alert
        WHERE (active_until IS NOT NULL AND active_until < now() - interval '1 hour')
           OR received_at < now() - interval '6 hours'
    )
    DELETE FROM rt.alert_informed_entity
    WHERE alert_id IN (SELECT alert_id FROM doomed);
    GET DIAGNOSTICS n_entity = ROW_COUNT;

    WITH doomed AS (
        SELECT alert_id FROM rt.alert
        WHERE (active_until IS NOT NULL AND active_until < now() - interval '1 hour')
           OR received_at < now() - interval '6 hours'
    )
    DELETE FROM rt.alert_active_period
    WHERE alert_id IN (SELECT alert_id FROM doomed);
    GET DIAGNOSTICS n_period = ROW_COUNT;

    DELETE FROM rt.alert
    WHERE (active_until IS NOT NULL AND active_until < now() - interval '1 hour')
       OR received_at < now() - interval '6 hours';
    GET DIAGNOSTICS n_alert = ROW_COUNT;

    RETURN jsonb_build_object(
        'vehicles_deleted',       n_veh,
        'trips_deactivated',      n_dead,
        'trips_deleted',          n_old,
        'etas_deleted',           n_eta,
        'alerts_deleted',         n_alert,
        'alert_periods_deleted',  n_period,
        'alert_entities_deleted', n_entity
    );
END;
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: agency; Type: TABLE; Schema: core; Owner: -
--

CREATE TABLE core.agency (
    feed_version text NOT NULL,
    agency_id text NOT NULL,
    name text,
    url text,
    timezone text,
    lang text,
    phone text,
    email text,
    fare_url text
);


--
-- Name: calendar; Type: TABLE; Schema: core; Owner: -
--

CREATE TABLE core.calendar (
    feed_version text NOT NULL,
    service_id text NOT NULL,
    monday boolean DEFAULT false NOT NULL,
    tuesday boolean DEFAULT false NOT NULL,
    wednesday boolean DEFAULT false NOT NULL,
    thursday boolean DEFAULT false NOT NULL,
    friday boolean DEFAULT false NOT NULL,
    saturday boolean DEFAULT false NOT NULL,
    sunday boolean DEFAULT false NOT NULL,
    start_date date NOT NULL,
    end_date date NOT NULL
);


--
-- Name: calendar_dates; Type: TABLE; Schema: core; Owner: -
--

CREATE TABLE core.calendar_dates (
    feed_version text NOT NULL,
    service_id text NOT NULL,
    service_date date NOT NULL,
    exception_type smallint NOT NULL,
    CONSTRAINT cd_exception_check CHECK ((exception_type = ANY (ARRAY[1, 2])))
);


--
-- Name: TABLE calendar_dates; Type: COMMENT; Schema: core; Owner: -
--

COMMENT ON TABLE core.calendar_dates IS 'GTFS calendar_dates. exception_type: 1 added, 2 removed.';


--
-- Name: feed_info; Type: TABLE; Schema: core; Owner: -
--

CREATE TABLE core.feed_info (
    feed_version text NOT NULL,
    publisher_name text,
    publisher_url text,
    lang text,
    start_date date NOT NULL,
    end_date date NOT NULL
);


--
-- Name: frequencies; Type: TABLE; Schema: core; Owner: -
--

CREATE TABLE core.frequencies (
    feed_version text NOT NULL,
    trip_id text NOT NULL,
    start_time text NOT NULL,
    end_time text NOT NULL,
    headway_secs integer NOT NULL,
    exact_times smallint
);


--
-- Name: TABLE frequencies; Type: COMMENT; Schema: core; Owner: -
--

COMMENT ON TABLE core.frequencies IS 'GTFS frequencies. Empty for current TTC feed.';


--
-- Name: levels; Type: TABLE; Schema: core; Owner: -
--

CREATE TABLE core.levels (
    feed_version text NOT NULL,
    level_id text NOT NULL,
    level_index double precision,
    level_name text
);


--
-- Name: pathways; Type: TABLE; Schema: core; Owner: -
--

CREATE TABLE core.pathways (
    feed_version text NOT NULL,
    pathway_id text NOT NULL,
    from_stop_id text,
    to_stop_id text,
    pathway_mode smallint NOT NULL,
    is_bidirectional smallint,
    length double precision,
    traversal_time integer,
    stair_count integer,
    max_slope double precision,
    min_width double precision,
    signposted_as text,
    reversed_signposted_as text,
    CONSTRAINT pw_mode_check CHECK (((pathway_mode >= 1) AND (pathway_mode <= 7)))
);


--
-- Name: TABLE pathways; Type: COMMENT; Schema: core; Owner: -
--

COMMENT ON TABLE core.pathways IS 'GTFS pathways. mode: 1 walkway, 2 stairs, 3 moving walkway, 4 escalator, 5 elevator, 6 fare gate, 7 exit gate.';


--
-- Name: routes; Type: TABLE; Schema: core; Owner: -
--

CREATE TABLE core.routes (
    feed_version text NOT NULL,
    route_id text NOT NULL,
    agency_id text,
    route_short_name text,
    route_long_name text,
    route_desc text,
    route_type smallint NOT NULL,
    route_url text,
    route_color text,
    route_text_color text,
    route_sort_order integer,
    CONSTRAINT routes_type_check CHECK (((route_type = ANY (ARRAY[0, 1, 2, 3, 4, 5, 6, 7, 11, 12])) OR ((route_type >= 100) AND (route_type <= 1799))))
);


--
-- Name: shapes; Type: TABLE; Schema: core; Owner: -
--

CREATE TABLE core.shapes (
    feed_version text NOT NULL,
    shape_id text NOT NULL,
    shape_pt_sequence integer NOT NULL,
    shape_pt_lat double precision NOT NULL,
    shape_pt_lon double precision NOT NULL,
    shape_dist_traveled double precision
);


--
-- Name: TABLE shapes; Type: COMMENT; Schema: core; Owner: -
--

COMMENT ON TABLE core.shapes IS 'GTFS shapes. ~1M rows. shape_dist_traveled is RAW (TTC: km). Never UPDATE it. cur.shapes multiplies by ops.units.shape_scale -> meters.';


--
-- Name: stop_times; Type: TABLE; Schema: core; Owner: -
--

CREATE TABLE core.stop_times (
    feed_version text NOT NULL,
    trip_id text NOT NULL,
    stop_sequence integer NOT NULL,
    stop_id text NOT NULL,
    arrival_time text,
    departure_time text,
    stop_headsign text,
    pickup_type smallint,
    drop_off_type smallint,
    shape_dist_traveled double precision,
    timepoint smallint,
    CONSTRAINT st_dropoff_check CHECK (((drop_off_type IS NULL) OR (drop_off_type = ANY (ARRAY[0, 1, 2, 3])))),
    CONSTRAINT st_pickup_check CHECK (((pickup_type IS NULL) OR (pickup_type = ANY (ARRAY[0, 1, 2, 3]))))
);


--
-- Name: TABLE stop_times; Type: COMMENT; Schema: core; Owner: -
--

COMMENT ON TABLE core.stop_times IS 'GTFS stop_times. ~4.3M rows. Times are text "HH:MM:SS", may exceed 24:00:00, and may be NULL at interpolated stops (ref.rebuild fills them).';


--
-- Name: stops; Type: TABLE; Schema: core; Owner: -
--

CREATE TABLE core.stops (
    feed_version text NOT NULL,
    stop_id text NOT NULL,
    stop_code text,
    stop_name text,
    stop_desc text,
    stop_lat double precision,
    stop_lon double precision,
    zone_id text,
    stop_url text,
    location_type smallint DEFAULT 0 NOT NULL,
    parent_station text,
    stop_timezone text,
    wheelchair_boarding smallint,
    level_id text,
    platform_code text,
    tts_stop_name text,
    CONSTRAINT stops_location_type_check CHECK ((location_type = ANY (ARRAY[0, 1, 2, 3, 4]))),
    CONSTRAINT stops_wheelchair_check CHECK (((wheelchair_boarding IS NULL) OR (wheelchair_boarding = ANY (ARRAY[0, 1, 2]))))
);


--
-- Name: TABLE stops; Type: COMMENT; Schema: core; Owner: -
--

COMMENT ON TABLE core.stops IS 'GTFS stops. ~12k rows. location_type: 0 platform, 1 station, 2 entrance, 3 generic node, 4 boarding area. Name search runs against ref.stop_points (active feed only), not here.';


--
-- Name: transfers; Type: TABLE; Schema: core; Owner: -
--

CREATE TABLE core.transfers (
    feed_version text NOT NULL,
    from_stop_id text NOT NULL,
    to_stop_id text NOT NULL,
    from_route_id text DEFAULT ''::text NOT NULL,
    to_route_id text DEFAULT ''::text NOT NULL,
    from_trip_id text DEFAULT ''::text NOT NULL,
    to_trip_id text DEFAULT ''::text NOT NULL,
    transfer_type smallint,
    min_transfer_time integer,
    CONSTRAINT transfers_type_check CHECK (((transfer_type IS NULL) OR (transfer_type = ANY (ARRAY[0, 1, 2, 3, 4, 5]))))
);


--
-- Name: TABLE transfers; Type: COMMENT; Schema: core; Owner: -
--

COMMENT ON TABLE core.transfers IS 'GTFS transfers. Empty for current TTC feed. '' in PK columns means "any".';


--
-- Name: trips; Type: TABLE; Schema: core; Owner: -
--

CREATE TABLE core.trips (
    feed_version text NOT NULL,
    trip_id text NOT NULL,
    route_id text NOT NULL,
    service_id text NOT NULL,
    trip_headsign text,
    trip_short_name text,
    direction_id smallint,
    block_id text,
    shape_id text,
    wheelchair_accessible smallint,
    bikes_allowed smallint,
    CONSTRAINT trips_direction_check CHECK (((direction_id IS NULL) OR (direction_id = ANY (ARRAY[0, 1]))))
);


--
-- Name: agency; Type: VIEW; Schema: cur; Owner: -
--

CREATE VIEW cur.agency AS
 SELECT feed_version,
    agency_id,
    name,
    url,
    timezone,
    lang,
    phone,
    email,
    fare_url
   FROM core.agency
  WHERE (feed_version = ops.active_version());


--
-- Name: calendar; Type: VIEW; Schema: cur; Owner: -
--

CREATE VIEW cur.calendar AS
 SELECT feed_version,
    service_id,
    monday,
    tuesday,
    wednesday,
    thursday,
    friday,
    saturday,
    sunday,
    start_date,
    end_date
   FROM core.calendar
  WHERE (feed_version = ops.active_version());


--
-- Name: calendar_dates; Type: VIEW; Schema: cur; Owner: -
--

CREATE VIEW cur.calendar_dates AS
 SELECT feed_version,
    service_id,
    service_date,
    exception_type
   FROM core.calendar_dates
  WHERE (feed_version = ops.active_version());


--
-- Name: feed_info; Type: VIEW; Schema: cur; Owner: -
--

CREATE VIEW cur.feed_info AS
 SELECT feed_version,
    publisher_name,
    publisher_url,
    lang,
    start_date,
    end_date
   FROM core.feed_info
  WHERE (feed_version = ops.active_version());


--
-- Name: frequencies; Type: VIEW; Schema: cur; Owner: -
--

CREATE VIEW cur.frequencies AS
 SELECT feed_version,
    trip_id,
    start_time,
    end_time,
    headway_secs,
    exact_times
   FROM core.frequencies
  WHERE (feed_version = ops.active_version());


--
-- Name: levels; Type: VIEW; Schema: cur; Owner: -
--

CREATE VIEW cur.levels AS
 SELECT feed_version,
    level_id,
    level_index,
    level_name
   FROM core.levels
  WHERE (feed_version = ops.active_version());


--
-- Name: pathways; Type: VIEW; Schema: cur; Owner: -
--

CREATE VIEW cur.pathways AS
 SELECT feed_version,
    pathway_id,
    from_stop_id,
    to_stop_id,
    pathway_mode,
    is_bidirectional,
    length,
    traversal_time,
    stair_count,
    max_slope,
    min_width,
    signposted_as,
    reversed_signposted_as
   FROM core.pathways
  WHERE (feed_version = ops.active_version());


--
-- Name: routes; Type: VIEW; Schema: cur; Owner: -
--

CREATE VIEW cur.routes AS
 SELECT feed_version,
    route_id,
    agency_id,
    route_short_name,
    route_long_name,
    route_desc,
    route_type,
    route_url,
    route_color,
    route_text_color,
    route_sort_order
   FROM core.routes
  WHERE (feed_version = ops.active_version());


--
-- Name: units; Type: TABLE; Schema: ops; Owner: -
--

CREATE TABLE ops.units (
    feed_version text NOT NULL,
    shape_scale double precision DEFAULT 1 NOT NULL,
    stop_scale double precision DEFAULT 1 NOT NULL,
    detected_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT units_positive_check CHECK (((shape_scale > (0)::double precision) AND (stop_scale > (0)::double precision)))
);


--
-- Name: TABLE units; Type: COMMENT; Schema: ops; Owner: -
--

COMMENT ON TABLE ops.units IS 'Detected unit scales (multiply raw value to get meters). TTC: shapes in km (shape_scale 1000), stop_times in m (stop_scale 1). core.* stays raw; cur.shapes / cur.stop_times / ref.pattern_stops apply the scale. A feed with no row here cannot be rebuilt: ref.rebuild() raises.';


--
-- Name: shapes; Type: VIEW; Schema: cur; Owner: -
--

CREATE VIEW cur.shapes AS
 SELECT s.feed_version,
    s.shape_id,
    s.shape_pt_sequence,
    s.shape_pt_lat,
    s.shape_pt_lon,
    (s.shape_dist_traveled * u.shape_scale) AS shape_dist_traveled
   FROM (core.shapes s
     LEFT JOIN ops.units u ON ((u.feed_version = s.feed_version)))
  WHERE (s.feed_version = ops.active_version());


--
-- Name: stop_times; Type: VIEW; Schema: cur; Owner: -
--

CREATE VIEW cur.stop_times AS
 SELECT st.feed_version,
    st.trip_id,
    st.stop_sequence,
    st.stop_id,
    st.arrival_time,
    st.departure_time,
    st.stop_headsign,
    st.pickup_type,
    st.drop_off_type,
    (st.shape_dist_traveled * u.stop_scale) AS shape_dist_traveled,
    st.timepoint
   FROM (core.stop_times st
     LEFT JOIN ops.units u ON ((u.feed_version = st.feed_version)))
  WHERE (st.feed_version = ops.active_version());


--
-- Name: stops; Type: VIEW; Schema: cur; Owner: -
--

CREATE VIEW cur.stops AS
 SELECT feed_version,
    stop_id,
    stop_code,
    stop_name,
    stop_desc,
    stop_lat,
    stop_lon,
    zone_id,
    stop_url,
    location_type,
    parent_station,
    stop_timezone,
    wheelchair_boarding,
    level_id,
    platform_code,
    tts_stop_name
   FROM core.stops
  WHERE (feed_version = ops.active_version());


--
-- Name: transfers; Type: VIEW; Schema: cur; Owner: -
--

CREATE VIEW cur.transfers AS
 SELECT feed_version,
    from_stop_id,
    to_stop_id,
    from_route_id,
    to_route_id,
    from_trip_id,
    to_trip_id,
    transfer_type,
    min_transfer_time
   FROM core.transfers
  WHERE (feed_version = ops.active_version());


--
-- Name: trips; Type: VIEW; Schema: cur; Owner: -
--

CREATE VIEW cur.trips AS
 SELECT feed_version,
    trip_id,
    route_id,
    service_id,
    trip_headsign,
    trip_short_name,
    direction_id,
    block_id,
    shape_id,
    wheelchair_accessible,
    bikes_allowed
   FROM core.trips
  WHERE (feed_version = ops.active_version());


--
-- Name: feed; Type: TABLE; Schema: ops; Owner: -
--

CREATE TABLE ops.feed (
    source text NOT NULL,
    feed_version text NOT NULL,
    activated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: TABLE feed; Type: COMMENT; Schema: ops; Owner: -
--

COMMENT ON TABLE ops.feed IS 'Single source of truth for the active feed_version. Flip it only through ops.activate_feed().';


--
-- Name: run; Type: TABLE; Schema: ops; Owner: -
--

CREATE TABLE ops.run (
    id bigint NOT NULL,
    source text NOT NULL,
    feed_version text,
    status text DEFAULT 'running'::text NOT NULL,
    started_at timestamp with time zone DEFAULT now() NOT NULL,
    finished_at timestamp with time zone,
    rows jsonb DEFAULT '{}'::jsonb NOT NULL,
    error text,
    CONSTRAINT run_status_check CHECK ((status = ANY (ARRAY['running'::text, 'ok'::text, 'failed'::text])))
);


--
-- Name: TABLE run; Type: COMMENT; Schema: ops; Owner: -
--

COMMENT ON TABLE ops.run IS 'Audit trail of every updater invocation.';


--
-- Name: run_id_seq; Type: SEQUENCE; Schema: ops; Owner: -
--

CREATE SEQUENCE ops.run_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: run_id_seq; Type: SEQUENCE OWNED BY; Schema: ops; Owner: -
--

ALTER SEQUENCE ops.run_id_seq OWNED BY ops.run.id;


--
-- Name: schema_version; Type: TABLE; Schema: ops; Owner: -
--

CREATE TABLE ops.schema_version (
    version text NOT NULL,
    applied_at timestamp with time zone DEFAULT now() NOT NULL,
    note text
);


--
-- Name: departures; Type: TABLE; Schema: ref; Owner: -
--

CREATE TABLE ref.departures (
    service_date date NOT NULL,
    trip_id text NOT NULL,
    ordinal integer NOT NULL,
    stop_sequence integer NOT NULL,
    stop_id text NOT NULL,
    departs_at timestamp with time zone NOT NULL,
    departure_s integer NOT NULL,
    route_id text NOT NULL,
    headsign text,
    direction_id smallint,
    pattern_id text,
    boardable boolean NOT NULL
)
WITH (autovacuum_vacuum_scale_factor='0.02', autovacuum_analyze_scale_factor='0.01');


--
-- Name: TABLE departures; Type: COMMENT; Schema: ref; Owner: -
--

COMMENT ON TABLE ref.departures IS '~16M rows for a 14-day horizon. PK includes service_date because a trip runs on many dates. stop_sequence is raw (matches GTFS-RT); ordinal is normalized (matches ref.pattern_stops). Interpolated stops are included.';


--
-- Name: frequency_trips; Type: TABLE; Schema: ref; Owner: -
--

CREATE TABLE ref.frequency_trips (
    trip_id text NOT NULL,
    start_s integer NOT NULL,
    end_s integer NOT NULL,
    headway_s integer NOT NULL,
    exact_times smallint
);


--
-- Name: pathway_edges; Type: TABLE; Schema: ref; Owner: -
--

CREATE TABLE ref.pathway_edges (
    pathway_id text NOT NULL,
    from_id text NOT NULL,
    to_id text NOT NULL,
    mode smallint NOT NULL,
    traversal_s integer,
    length_m double precision,
    stair_count integer,
    sign text
);


--
-- Name: TABLE pathway_edges; Type: COMMENT; Schema: ref; Owner: -
--

COMMENT ON TABLE ref.pathway_edges IS 'Directed edges for in-station Dijkstra. Bidirectional pathways are expanded into two rows.';


--
-- Name: pattern_stops; Type: TABLE; Schema: ref; Owner: -
--

CREATE TABLE ref.pattern_stops (
    pattern_id text NOT NULL,
    ordinal integer NOT NULL,
    stop_id text NOT NULL,
    dist_m double precision
);


--
-- Name: TABLE pattern_stops; Type: COMMENT; Schema: ref; Owner: -
--

COMMENT ON TABLE ref.pattern_stops IS 'Stops of a pattern in order, indexed by ordinal so every trip on the pattern shares one numbering.';


--
-- Name: patterns; Type: TABLE; Schema: ref; Owner: -
--

CREATE TABLE ref.patterns (
    pattern_id text NOT NULL,
    route_id text NOT NULL,
    direction_id smallint,
    headsign text,
    n_stops integer NOT NULL,
    trip_count integer NOT NULL
);


--
-- Name: service_days; Type: TABLE; Schema: ref; Owner: -
--

CREATE TABLE ref.service_days (
    service_date date NOT NULL,
    service_id text NOT NULL
);


--
-- Name: TABLE service_days; Type: COMMENT; Schema: ref; Owner: -
--

COMMENT ON TABLE ref.service_days IS 'Resolved (date, service_id) for the horizon: ops.today()-1 .. +horizon.';


--
-- Name: state; Type: TABLE; Schema: ref; Owner: -
--

CREATE TABLE ref.state (
    singleton boolean DEFAULT true NOT NULL,
    feed_version text NOT NULL,
    horizon_days integer NOT NULL,
    built_at timestamp with time zone DEFAULT now() NOT NULL,
    rolled_at timestamp with time zone,
    CONSTRAINT state_singleton_check CHECK (singleton)
);


--
-- Name: TABLE state; Type: COMMENT; Schema: ref; Owner: -
--

COMMENT ON TABLE ref.state IS 'One row: which feed ref.* was built from and the derive horizon. ref.roll_forward() reads it, so the nightly job needs no arguments.';


--
-- Name: station_nodes; Type: TABLE; Schema: ref; Owner: -
--

CREATE TABLE ref.station_nodes (
    stop_id text NOT NULL,
    stop_name text NOT NULL,
    location_type smallint NOT NULL,
    station_id text,
    level_id text,
    level_index double precision,
    level_name text,
    wheelchair_boarding smallint,
    stop_lat double precision,
    stop_lon double precision
);


--
-- Name: stop_points; Type: TABLE; Schema: ref; Owner: -
--

CREATE TABLE ref.stop_points (
    stop_id text NOT NULL,
    stop_code text,
    stop_name text NOT NULL,
    stop_lat double precision NOT NULL,
    stop_lon double precision NOT NULL,
    wheelchair_boarding smallint,
    parent_station text,
    station_name text
);


--
-- Name: TABLE stop_points; Type: COMMENT; Schema: ref; Owner: -
--

COMMENT ON TABLE ref.stop_points IS 'Boardable stops (location_type=0, coords present, served). ~9.4k rows.';


--
-- Name: stop_routes; Type: TABLE; Schema: ref; Owner: -
--

CREATE TABLE ref.stop_routes (
    stop_id text NOT NULL,
    route_id text NOT NULL
);


--
-- Name: transfers; Type: TABLE; Schema: ref; Owner: -
--

CREATE TABLE ref.transfers (
    from_stop_id text NOT NULL,
    to_stop_id text NOT NULL,
    from_route_id text DEFAULT ''::text NOT NULL,
    to_route_id text DEFAULT ''::text NOT NULL,
    from_trip_id text DEFAULT ''::text NOT NULL,
    to_trip_id text DEFAULT ''::text NOT NULL,
    min_seconds integer NOT NULL,
    type smallint NOT NULL
);


--
-- Name: TABLE transfers; Type: COMMENT; Schema: ref; Owner: -
--

COMMENT ON TABLE ref.transfers IS 'Derived transfers. Empty for current TTC feed. Planner falls back to its default minimum transfer time when a lookup misses.';


--
-- Name: trip_stops; Type: TABLE; Schema: ref; Owner: -
--

CREATE TABLE ref.trip_stops (
    trip_id text NOT NULL,
    ordinal integer NOT NULL,
    stop_sequence integer NOT NULL,
    stop_id text NOT NULL,
    stop_headsign text,
    departure_s integer,
    interpolated boolean NOT NULL,
    boardable boolean NOT NULL
);


--
-- Name: TABLE trip_stops; Type: COMMENT; Schema: ref; Owner: -
--

COMMENT ON TABLE ref.trip_stops IS 'Per-trip stop list, date-independent. Times at untimed stops are linearly interpolated by ordinal between the surrounding timed stops (interpolated = true). The unique index maps a GTFS-RT stop_sequence to an ordinal; roll_forward() cross-joins this with service_days.';


--
-- Name: trips; Type: TABLE; Schema: ref; Owner: -
--

CREATE TABLE ref.trips (
    trip_id text NOT NULL,
    route_id text NOT NULL,
    service_id text NOT NULL,
    direction_id smallint,
    headsign text,
    pattern_id text NOT NULL,
    n_stops integer NOT NULL
);


--
-- Name: TABLE trips; Type: COMMENT; Schema: ref; Owner: -
--

COMMENT ON TABLE ref.trips IS 'Trips that have stop_times, with their pattern. Feeds roll_forward().';


--
-- Name: alert; Type: TABLE; Schema: rt; Owner: -
--

CREATE TABLE rt.alert (
    alert_id text NOT NULL,
    cause smallint,
    effect smallint,
    severity_level smallint,
    header_text text,
    description_text text,
    tts_header_text text,
    tts_description_text text,
    url text,
    active_from timestamp with time zone,
    active_until timestamp with time zone,
    received_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT alert_cause_check CHECK (((cause IS NULL) OR ((cause >= 0) AND (cause <= 99)))),
    CONSTRAINT alert_effect_check CHECK (((effect IS NULL) OR ((effect >= 0) AND (effect <= 99)))),
    CONSTRAINT alert_severity_check CHECK (((severity_level IS NULL) OR ((severity_level >= 0) AND (severity_level <= 99))))
);


--
-- Name: active_alerts; Type: VIEW; Schema: rt; Owner: -
--

CREATE VIEW rt.active_alerts AS
 SELECT alert_id,
    cause,
    effect,
    severity_level,
    header_text,
    description_text,
    tts_header_text,
    tts_description_text,
    url,
    active_from,
    active_until,
    received_at
   FROM rt.alert
  WHERE (((active_from IS NULL) OR (active_from <= now())) AND ((active_until IS NULL) OR (active_until >= now())));


--
-- Name: alert_active_period; Type: TABLE; Schema: rt; Owner: -
--

CREATE TABLE rt.alert_active_period (
    alert_id text NOT NULL,
    ordinal integer NOT NULL,
    start_at timestamp with time zone,
    end_at timestamp with time zone
);


--
-- Name: alert_informed_entity; Type: TABLE; Schema: rt; Owner: -
--

CREATE TABLE rt.alert_informed_entity (
    alert_id text NOT NULL,
    ordinal integer NOT NULL,
    agency_id text,
    route_id text,
    route_type smallint,
    direction_id smallint,
    trip_id text,
    stop_id text
);


--
-- Name: stop_eta; Type: TABLE; Schema: rt; Owner: -
--

CREATE TABLE rt.stop_eta (
    trip_id text NOT NULL,
    service_date date NOT NULL,
    stop_sequence integer NOT NULL,
    stop_id text NOT NULL,
    scheduled_at timestamp with time zone,
    predicted_at timestamp with time zone,
    delay_s integer,
    is_skipped boolean DEFAULT false NOT NULL,
    received_at timestamp with time zone DEFAULT now() NOT NULL
)
WITH (fillfactor='85', autovacuum_vacuum_scale_factor='0.02', autovacuum_analyze_scale_factor='0.01');


--
-- Name: trip_status; Type: TABLE; Schema: rt; Owner: -
--

CREATE TABLE rt.trip_status (
    trip_id text NOT NULL,
    service_date date NOT NULL,
    vehicle_id text,
    route_id text,
    direction_id smallint,
    pattern_id text,
    last_stop_id text,
    last_stop_sequence integer,
    last_status smallint,
    next_stop_id text,
    next_stop_sequence integer,
    scheduled_next_at timestamp with time zone,
    predicted_next_at timestamp with time zone,
    delay_s integer,
    lat double precision,
    lon double precision,
    bearing real,
    speed_mps real,
    received_at timestamp with time zone DEFAULT now() NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    schedule_relationship smallint,
    CONSTRAINT trip_status_last_status_check CHECK (((last_status IS NULL) OR ((last_status >= 0) AND (last_status <= 99)))),
    CONSTRAINT trip_status_sched_check CHECK (((schedule_relationship IS NULL) OR ((schedule_relationship >= 0) AND (schedule_relationship <= 99))))
)
WITH (fillfactor='85', autovacuum_vacuum_scale_factor='0.01', autovacuum_analyze_scale_factor='0.005');


--
-- Name: TABLE trip_status; Type: COMMENT; Schema: rt; Owner: -
--

COMMENT ON TABLE rt.trip_status IS 'One row per active trip. Ride tracker reads by (trip_id, service_date). Derive service_date with rt.infer_service_date() when the feed omits it.';


--
-- Name: COLUMN trip_status.schedule_relationship; Type: COMMENT; Schema: rt; Owner: -
--

COMMENT ON COLUMN rt.trip_status.schedule_relationship IS 'GTFS-RT TripDescriptor.ScheduleRelationship: 0 SCHEDULED, 1 ADDED, 2 UNSCHEDULED, 3 CANCELED, 4 REPLACEMENT, 5 DUPLICATED, 6 DELETED. NEW trips (added service) have value 1.';


--
-- Name: trip_now; Type: VIEW; Schema: rt; Owner: -
--

CREATE VIEW rt.trip_now AS
 SELECT trip_id,
    service_date,
    vehicle_id,
    route_id,
    direction_id,
    pattern_id,
    schedule_relationship,
    last_stop_id,
    last_stop_sequence,
    last_status,
    next_stop_id,
    next_stop_sequence,
    scheduled_next_at,
    predicted_next_at,
    delay_s,
    lat,
    lon,
    bearing,
    speed_mps,
    received_at,
    is_active
   FROM rt.trip_status
  WHERE is_active;


--
-- Name: vehicle_latest; Type: TABLE; Schema: rt; Owner: -
--

CREATE TABLE rt.vehicle_latest (
    vehicle_id text NOT NULL,
    trip_id text,
    route_id text,
    direction_id smallint,
    schedule_relationship smallint,
    lat double precision,
    lon double precision,
    bearing real,
    speed_mps real,
    current_stop_id text,
    current_stop_sequence integer,
    current_status smallint,
    occupancy smallint,
    vehicle_ts timestamp with time zone,
    received_at timestamp with time zone DEFAULT now() NOT NULL,
    current_ordinal integer,
    stops_remaining integer,
    service_state text,
    CONSTRAINT veh_occupancy_check CHECK (((occupancy IS NULL) OR ((occupancy >= 0) AND (occupancy <= 99)))),
    CONSTRAINT veh_sched_check CHECK (((schedule_relationship IS NULL) OR ((schedule_relationship >= 0) AND (schedule_relationship <= 99)))),
    CONSTRAINT veh_status_check CHECK (((current_status IS NULL) OR ((current_status >= 0) AND (current_status <= 99)))),
    CONSTRAINT vehicle_latest_service_state_check CHECK (((service_state IS NULL) OR (service_state = ANY (ARRAY['unknown'::text, 'not_started'::text, 'in_service'::text, 'finished'::text]))))
)
WITH (fillfactor='85', autovacuum_vacuum_scale_factor='0.01', autovacuum_analyze_scale_factor='0.005');


--
-- Name: TABLE vehicle_latest; Type: COMMENT; Schema: rt; Owner: -
--

COMMENT ON TABLE rt.vehicle_latest IS 'One row per active vehicle. Upserted every 30s. ~500 rows steady state.';


--
-- Name: vehicle_now; Type: VIEW; Schema: rt; Owner: -
--

CREATE VIEW rt.vehicle_now AS
 SELECT vehicle_id,
    trip_id,
    route_id,
    direction_id,
    schedule_relationship,
    lat,
    lon,
    bearing,
    speed_mps,
    current_stop_id,
    current_stop_sequence,
    current_status,
    occupancy,
    vehicle_ts,
    received_at
   FROM rt.vehicle_latest
  WHERE (received_at > (now() - '00:05:00'::interval));


--
-- Name: vehicle_samples; Type: TABLE; Schema: rt; Owner: -
--

CREATE TABLE rt.vehicle_samples (
    sample_id bigint NOT NULL,
    vehicle_id text NOT NULL,
    trip_id text,
    route_id text,
    direction_id smallint,
    lat double precision,
    lon double precision,
    bearing real,
    speed_mps real,
    current_stop_id text,
    current_stop_sequence integer,
    current_status smallint,
    occupancy smallint,
    vehicle_ts timestamp with time zone,
    received_at timestamp with time zone DEFAULT now() NOT NULL
)
PARTITION BY RANGE (received_at);


--
-- Name: TABLE vehicle_samples; Type: COMMENT; Schema: rt; Owner: -
--

COMMENT ON TABLE rt.vehicle_samples IS 'Append-only history. Partitioned daily (America/Toronto day boundaries). Retention via DROP TABLE.';


--
-- Name: vehicle_samples_20261011; Type: TABLE; Schema: rt; Owner: -
--

CREATE TABLE rt.vehicle_samples_20261011 (
    sample_id bigint NOT NULL,
    vehicle_id text NOT NULL,
    trip_id text,
    route_id text,
    direction_id smallint,
    lat double precision,
    lon double precision,
    bearing real,
    speed_mps real,
    current_stop_id text,
    current_stop_sequence integer,
    current_status smallint,
    occupancy smallint,
    vehicle_ts timestamp with time zone,
    received_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: vehicle_samples_20261012; Type: TABLE; Schema: rt; Owner: -
--

CREATE TABLE rt.vehicle_samples_20261012 (
    sample_id bigint NOT NULL,
    vehicle_id text NOT NULL,
    trip_id text,
    route_id text,
    direction_id smallint,
    lat double precision,
    lon double precision,
    bearing real,
    speed_mps real,
    current_stop_id text,
    current_stop_sequence integer,
    current_status smallint,
    occupancy smallint,
    vehicle_ts timestamp with time zone,
    received_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: vehicle_samples_20261013; Type: TABLE; Schema: rt; Owner: -
--

CREATE TABLE rt.vehicle_samples_20261013 (
    sample_id bigint NOT NULL,
    vehicle_id text NOT NULL,
    trip_id text,
    route_id text,
    direction_id smallint,
    lat double precision,
    lon double precision,
    bearing real,
    speed_mps real,
    current_stop_id text,
    current_stop_sequence integer,
    current_status smallint,
    occupancy smallint,
    vehicle_ts timestamp with time zone,
    received_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: vehicle_samples_20261014; Type: TABLE; Schema: rt; Owner: -
--

CREATE TABLE rt.vehicle_samples_20261014 (
    sample_id bigint NOT NULL,
    vehicle_id text NOT NULL,
    trip_id text,
    route_id text,
    direction_id smallint,
    lat double precision,
    lon double precision,
    bearing real,
    speed_mps real,
    current_stop_id text,
    current_stop_sequence integer,
    current_status smallint,
    occupancy smallint,
    vehicle_ts timestamp with time zone,
    received_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: vehicle_samples_20261015; Type: TABLE; Schema: rt; Owner: -
--

CREATE TABLE rt.vehicle_samples_20261015 (
    sample_id bigint NOT NULL,
    vehicle_id text NOT NULL,
    trip_id text,
    route_id text,
    direction_id smallint,
    lat double precision,
    lon double precision,
    bearing real,
    speed_mps real,
    current_stop_id text,
    current_stop_sequence integer,
    current_status smallint,
    occupancy smallint,
    vehicle_ts timestamp with time zone,
    received_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: vehicle_samples_20261016; Type: TABLE; Schema: rt; Owner: -
--

CREATE TABLE rt.vehicle_samples_20261016 (
    sample_id bigint NOT NULL,
    vehicle_id text NOT NULL,
    trip_id text,
    route_id text,
    direction_id smallint,
    lat double precision,
    lon double precision,
    bearing real,
    speed_mps real,
    current_stop_id text,
    current_stop_sequence integer,
    current_status smallint,
    occupancy smallint,
    vehicle_ts timestamp with time zone,
    received_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: vehicle_samples_default; Type: TABLE; Schema: rt; Owner: -
--

CREATE TABLE rt.vehicle_samples_default (
    sample_id bigint NOT NULL,
    vehicle_id text NOT NULL,
    trip_id text,
    route_id text,
    direction_id smallint,
    lat double precision,
    lon double precision,
    bearing real,
    speed_mps real,
    current_stop_id text,
    current_stop_sequence integer,
    current_status smallint,
    occupancy smallint,
    vehicle_ts timestamp with time zone,
    received_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: TABLE vehicle_samples_default; Type: COMMENT; Schema: rt; Owner: -
--

COMMENT ON TABLE rt.vehicle_samples_default IS 'Rows here mean a daily partition was missing at insert time. Alert when ops.maintain() reports default_rows > 0.';


--
-- Name: vehicle_samples_sample_id_seq; Type: SEQUENCE; Schema: rt; Owner: -
--

ALTER TABLE rt.vehicle_samples ALTER COLUMN sample_id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME rt.vehicle_samples_sample_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: vehicle_samples_20261011; Type: TABLE ATTACH; Schema: rt; Owner: -
--

ALTER TABLE ONLY rt.vehicle_samples ATTACH PARTITION rt.vehicle_samples_20261011 FOR VALUES FROM ('2026-10-11 00:00:00-04') TO ('2026-10-12 00:00:00-04');


--
-- Name: vehicle_samples_20261012; Type: TABLE ATTACH; Schema: rt; Owner: -
--

ALTER TABLE ONLY rt.vehicle_samples ATTACH PARTITION rt.vehicle_samples_20261012 FOR VALUES FROM ('2026-10-12 00:00:00-04') TO ('2026-10-13 00:00:00-04');


--
-- Name: vehicle_samples_20261013; Type: TABLE ATTACH; Schema: rt; Owner: -
--

ALTER TABLE ONLY rt.vehicle_samples ATTACH PARTITION rt.vehicle_samples_20261013 FOR VALUES FROM ('2026-10-13 00:00:00-04') TO ('2026-10-14 00:00:00-04');


--
-- Name: vehicle_samples_20261014; Type: TABLE ATTACH; Schema: rt; Owner: -
--

ALTER TABLE ONLY rt.vehicle_samples ATTACH PARTITION rt.vehicle_samples_20261014 FOR VALUES FROM ('2026-10-14 00:00:00-04') TO ('2026-10-15 00:00:00-04');


--
-- Name: vehicle_samples_20261015; Type: TABLE ATTACH; Schema: rt; Owner: -
--

ALTER TABLE ONLY rt.vehicle_samples ATTACH PARTITION rt.vehicle_samples_20261015 FOR VALUES FROM ('2026-10-15 00:00:00-04') TO ('2026-10-16 00:00:00-04');


--
-- Name: vehicle_samples_20261016; Type: TABLE ATTACH; Schema: rt; Owner: -
--

ALTER TABLE ONLY rt.vehicle_samples ATTACH PARTITION rt.vehicle_samples_20261016 FOR VALUES FROM ('2026-10-16 00:00:00-04') TO ('2026-10-17 00:00:00-04');


--
-- Name: vehicle_samples_default; Type: TABLE ATTACH; Schema: rt; Owner: -
--

ALTER TABLE ONLY rt.vehicle_samples ATTACH PARTITION rt.vehicle_samples_default DEFAULT;


--
-- Name: run id; Type: DEFAULT; Schema: ops; Owner: -
--

ALTER TABLE ONLY ops.run ALTER COLUMN id SET DEFAULT nextval('ops.run_id_seq'::regclass);


--
-- Name: agency agency_pkey; Type: CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.agency
    ADD CONSTRAINT agency_pkey PRIMARY KEY (feed_version, agency_id);


--
-- Name: calendar_dates calendar_dates_pkey; Type: CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.calendar_dates
    ADD CONSTRAINT calendar_dates_pkey PRIMARY KEY (feed_version, service_id, service_date);


--
-- Name: calendar calendar_pkey; Type: CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.calendar
    ADD CONSTRAINT calendar_pkey PRIMARY KEY (feed_version, service_id);


--
-- Name: feed_info feed_info_pkey; Type: CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.feed_info
    ADD CONSTRAINT feed_info_pkey PRIMARY KEY (feed_version);


--
-- Name: frequencies frequencies_pkey; Type: CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.frequencies
    ADD CONSTRAINT frequencies_pkey PRIMARY KEY (feed_version, trip_id, start_time);


--
-- Name: levels levels_pkey; Type: CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.levels
    ADD CONSTRAINT levels_pkey PRIMARY KEY (feed_version, level_id);


--
-- Name: pathways pathways_pkey; Type: CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.pathways
    ADD CONSTRAINT pathways_pkey PRIMARY KEY (feed_version, pathway_id);


--
-- Name: routes routes_pkey; Type: CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.routes
    ADD CONSTRAINT routes_pkey PRIMARY KEY (feed_version, route_id);


--
-- Name: shapes shapes_pkey; Type: CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.shapes
    ADD CONSTRAINT shapes_pkey PRIMARY KEY (feed_version, shape_id, shape_pt_sequence);


--
-- Name: stop_times stop_times_pkey; Type: CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.stop_times
    ADD CONSTRAINT stop_times_pkey PRIMARY KEY (feed_version, trip_id, stop_sequence);


--
-- Name: stops stops_pkey; Type: CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.stops
    ADD CONSTRAINT stops_pkey PRIMARY KEY (feed_version, stop_id);


--
-- Name: transfers transfers_pkey; Type: CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.transfers
    ADD CONSTRAINT transfers_pkey PRIMARY KEY (feed_version, from_stop_id, to_stop_id, from_route_id, to_route_id, from_trip_id, to_trip_id);


--
-- Name: trips trips_pkey; Type: CONSTRAINT; Schema: core; Owner: -
--

ALTER TABLE ONLY core.trips
    ADD CONSTRAINT trips_pkey PRIMARY KEY (feed_version, trip_id);


--
-- Name: feed feed_pkey; Type: CONSTRAINT; Schema: ops; Owner: -
--

ALTER TABLE ONLY ops.feed
    ADD CONSTRAINT feed_pkey PRIMARY KEY (source);


--
-- Name: run run_pkey; Type: CONSTRAINT; Schema: ops; Owner: -
--

ALTER TABLE ONLY ops.run
    ADD CONSTRAINT run_pkey PRIMARY KEY (id);


--
-- Name: schema_version schema_version_pkey; Type: CONSTRAINT; Schema: ops; Owner: -
--

ALTER TABLE ONLY ops.schema_version
    ADD CONSTRAINT schema_version_pkey PRIMARY KEY (version);


--
-- Name: units units_pkey; Type: CONSTRAINT; Schema: ops; Owner: -
--

ALTER TABLE ONLY ops.units
    ADD CONSTRAINT units_pkey PRIMARY KEY (feed_version);


--
-- Name: departures departures_pkey; Type: CONSTRAINT; Schema: ref; Owner: -
--

ALTER TABLE ONLY ref.departures
    ADD CONSTRAINT departures_pkey PRIMARY KEY (service_date, trip_id, ordinal);


--
-- Name: frequency_trips frequency_trips_pkey; Type: CONSTRAINT; Schema: ref; Owner: -
--

ALTER TABLE ONLY ref.frequency_trips
    ADD CONSTRAINT frequency_trips_pkey PRIMARY KEY (trip_id, start_s);


--
-- Name: pathway_edges pathway_edges_pkey; Type: CONSTRAINT; Schema: ref; Owner: -
--

ALTER TABLE ONLY ref.pathway_edges
    ADD CONSTRAINT pathway_edges_pkey PRIMARY KEY (pathway_id, from_id, to_id);


--
-- Name: pattern_stops pattern_stops_pkey; Type: CONSTRAINT; Schema: ref; Owner: -
--

ALTER TABLE ONLY ref.pattern_stops
    ADD CONSTRAINT pattern_stops_pkey PRIMARY KEY (pattern_id, ordinal);


--
-- Name: patterns patterns_pkey; Type: CONSTRAINT; Schema: ref; Owner: -
--

ALTER TABLE ONLY ref.patterns
    ADD CONSTRAINT patterns_pkey PRIMARY KEY (pattern_id);


--
-- Name: service_days service_days_pkey; Type: CONSTRAINT; Schema: ref; Owner: -
--

ALTER TABLE ONLY ref.service_days
    ADD CONSTRAINT service_days_pkey PRIMARY KEY (service_date, service_id);


--
-- Name: state state_pkey; Type: CONSTRAINT; Schema: ref; Owner: -
--

ALTER TABLE ONLY ref.state
    ADD CONSTRAINT state_pkey PRIMARY KEY (singleton);


--
-- Name: station_nodes station_nodes_pkey; Type: CONSTRAINT; Schema: ref; Owner: -
--

ALTER TABLE ONLY ref.station_nodes
    ADD CONSTRAINT station_nodes_pkey PRIMARY KEY (stop_id);


--
-- Name: stop_points stop_points_pkey; Type: CONSTRAINT; Schema: ref; Owner: -
--

ALTER TABLE ONLY ref.stop_points
    ADD CONSTRAINT stop_points_pkey PRIMARY KEY (stop_id);


--
-- Name: stop_routes stop_routes_pkey; Type: CONSTRAINT; Schema: ref; Owner: -
--

ALTER TABLE ONLY ref.stop_routes
    ADD CONSTRAINT stop_routes_pkey PRIMARY KEY (stop_id, route_id);


--
-- Name: transfers transfers_pkey; Type: CONSTRAINT; Schema: ref; Owner: -
--

ALTER TABLE ONLY ref.transfers
    ADD CONSTRAINT transfers_pkey PRIMARY KEY (from_stop_id, to_stop_id, from_route_id, to_route_id, from_trip_id, to_trip_id);


--
-- Name: trip_stops trip_stops_pkey; Type: CONSTRAINT; Schema: ref; Owner: -
--

ALTER TABLE ONLY ref.trip_stops
    ADD CONSTRAINT trip_stops_pkey PRIMARY KEY (trip_id, ordinal);


--
-- Name: trips trips_pkey; Type: CONSTRAINT; Schema: ref; Owner: -
--

ALTER TABLE ONLY ref.trips
    ADD CONSTRAINT trips_pkey PRIMARY KEY (trip_id);


--
-- Name: alert_active_period alert_active_period_pkey; Type: CONSTRAINT; Schema: rt; Owner: -
--

ALTER TABLE ONLY rt.alert_active_period
    ADD CONSTRAINT alert_active_period_pkey PRIMARY KEY (alert_id, ordinal);


--
-- Name: alert_informed_entity alert_informed_entity_pkey; Type: CONSTRAINT; Schema: rt; Owner: -
--

ALTER TABLE ONLY rt.alert_informed_entity
    ADD CONSTRAINT alert_informed_entity_pkey PRIMARY KEY (alert_id, ordinal);


--
-- Name: alert alert_pkey; Type: CONSTRAINT; Schema: rt; Owner: -
--

ALTER TABLE ONLY rt.alert
    ADD CONSTRAINT alert_pkey PRIMARY KEY (alert_id);


--
-- Name: stop_eta stop_eta_pkey; Type: CONSTRAINT; Schema: rt; Owner: -
--

ALTER TABLE ONLY rt.stop_eta
    ADD CONSTRAINT stop_eta_pkey PRIMARY KEY (trip_id, service_date, stop_sequence);


--
-- Name: trip_status trip_status_pkey; Type: CONSTRAINT; Schema: rt; Owner: -
--

ALTER TABLE ONLY rt.trip_status
    ADD CONSTRAINT trip_status_pkey PRIMARY KEY (trip_id, service_date);


--
-- Name: vehicle_latest vehicle_latest_pkey; Type: CONSTRAINT; Schema: rt; Owner: -
--

ALTER TABLE ONLY rt.vehicle_latest
    ADD CONSTRAINT vehicle_latest_pkey PRIMARY KEY (vehicle_id);


--
-- Name: vehicle_samples vehicle_samples_pkey; Type: CONSTRAINT; Schema: rt; Owner: -
--

ALTER TABLE ONLY rt.vehicle_samples
    ADD CONSTRAINT vehicle_samples_pkey PRIMARY KEY (sample_id, received_at);


--
-- Name: vehicle_samples_20261011 vehicle_samples_20261011_pkey; Type: CONSTRAINT; Schema: rt; Owner: -
--

ALTER TABLE ONLY rt.vehicle_samples_20261011
    ADD CONSTRAINT vehicle_samples_20261011_pkey PRIMARY KEY (sample_id, received_at);


--
-- Name: vehicle_samples_20261012 vehicle_samples_20261012_pkey; Type: CONSTRAINT; Schema: rt; Owner: -
--

ALTER TABLE ONLY rt.vehicle_samples_20261012
    ADD CONSTRAINT vehicle_samples_20261012_pkey PRIMARY KEY (sample_id, received_at);


--
-- Name: vehicle_samples_20261013 vehicle_samples_20261013_pkey; Type: CONSTRAINT; Schema: rt; Owner: -
--

ALTER TABLE ONLY rt.vehicle_samples_20261013
    ADD CONSTRAINT vehicle_samples_20261013_pkey PRIMARY KEY (sample_id, received_at);


--
-- Name: vehicle_samples_20261014 vehicle_samples_20261014_pkey; Type: CONSTRAINT; Schema: rt; Owner: -
--

ALTER TABLE ONLY rt.vehicle_samples_20261014
    ADD CONSTRAINT vehicle_samples_20261014_pkey PRIMARY KEY (sample_id, received_at);


--
-- Name: vehicle_samples_20261015 vehicle_samples_20261015_pkey; Type: CONSTRAINT; Schema: rt; Owner: -
--

ALTER TABLE ONLY rt.vehicle_samples_20261015
    ADD CONSTRAINT vehicle_samples_20261015_pkey PRIMARY KEY (sample_id, received_at);


--
-- Name: vehicle_samples_20261016 vehicle_samples_20261016_pkey; Type: CONSTRAINT; Schema: rt; Owner: -
--

ALTER TABLE ONLY rt.vehicle_samples_20261016
    ADD CONSTRAINT vehicle_samples_20261016_pkey PRIMARY KEY (sample_id, received_at);


--
-- Name: vehicle_samples_default vehicle_samples_default_pkey; Type: CONSTRAINT; Schema: rt; Owner: -
--

ALTER TABLE ONLY rt.vehicle_samples_default
    ADD CONSTRAINT vehicle_samples_default_pkey PRIMARY KEY (sample_id, received_at);


--
-- Name: run_source_started_idx; Type: INDEX; Schema: ops; Owner: -
--

CREATE INDEX run_source_started_idx ON ops.run USING btree (source, started_at DESC);


--
-- Name: dep_stop_time_boardable_idx; Type: INDEX; Schema: ref; Owner: -
--

CREATE INDEX dep_stop_time_boardable_idx ON ref.departures USING btree (stop_id, departs_at) WHERE boardable;


--
-- Name: patterns_route_idx; Type: INDEX; Schema: ref; Owner: -
--

CREATE INDEX patterns_route_idx ON ref.patterns USING btree (route_id, direction_id);


--
-- Name: pe_from_idx; Type: INDEX; Schema: ref; Owner: -
--

CREATE INDEX pe_from_idx ON ref.pathway_edges USING btree (from_id);


--
-- Name: ref_transfers_from_idx; Type: INDEX; Schema: ref; Owner: -
--

CREATE INDEX ref_transfers_from_idx ON ref.transfers USING btree (from_stop_id);


--
-- Name: service_days_service_idx; Type: INDEX; Schema: ref; Owner: -
--

CREATE INDEX service_days_service_idx ON ref.service_days USING btree (service_id);


--
-- Name: station_nodes_station_idx; Type: INDEX; Schema: ref; Owner: -
--

CREATE INDEX station_nodes_station_idx ON ref.station_nodes USING btree (station_id) WHERE (station_id IS NOT NULL);


--
-- Name: stop_points_name_trgm_idx; Type: INDEX; Schema: ref; Owner: -
--

CREATE INDEX stop_points_name_trgm_idx ON ref.stop_points USING gin (stop_name public.gin_trgm_ops);


--
-- Name: stop_points_parent_idx; Type: INDEX; Schema: ref; Owner: -
--

CREATE INDEX stop_points_parent_idx ON ref.stop_points USING btree (parent_station) WHERE (parent_station IS NOT NULL);


--
-- Name: stop_routes_route_idx; Type: INDEX; Schema: ref; Owner: -
--

CREATE INDEX stop_routes_route_idx ON ref.stop_routes USING btree (route_id);


--
-- Name: trip_stops_seq_idx; Type: INDEX; Schema: ref; Owner: -
--

CREATE UNIQUE INDEX trip_stops_seq_idx ON ref.trip_stops USING btree (trip_id, stop_sequence);


--
-- Name: trips_service_idx; Type: INDEX; Schema: ref; Owner: -
--

CREATE INDEX trips_service_idx ON ref.trips USING btree (service_id);


--
-- Name: alert_active_time_idx; Type: INDEX; Schema: rt; Owner: -
--

CREATE INDEX alert_active_time_idx ON rt.alert USING btree (active_from, active_until);


--
-- Name: alert_age_idx; Type: INDEX; Schema: rt; Owner: -
--

CREATE INDEX alert_age_idx ON rt.alert USING btree (received_at);


--
-- Name: alert_effect_idx; Type: INDEX; Schema: rt; Owner: -
--

CREATE INDEX alert_effect_idx ON rt.alert USING btree (effect) WHERE (effect IS NOT NULL);


--
-- Name: alert_informed_route_idx; Type: INDEX; Schema: rt; Owner: -
--

CREATE INDEX alert_informed_route_idx ON rt.alert_informed_entity USING btree (route_id) WHERE (route_id IS NOT NULL);


--
-- Name: alert_informed_stop_idx; Type: INDEX; Schema: rt; Owner: -
--

CREATE INDEX alert_informed_stop_idx ON rt.alert_informed_entity USING btree (stop_id) WHERE (stop_id IS NOT NULL);


--
-- Name: alert_informed_trip_idx; Type: INDEX; Schema: rt; Owner: -
--

CREATE INDEX alert_informed_trip_idx ON rt.alert_informed_entity USING btree (trip_id) WHERE (trip_id IS NOT NULL);


--
-- Name: alert_informed_unique_idx; Type: INDEX; Schema: rt; Owner: -
--

CREATE UNIQUE INDEX alert_informed_unique_idx ON rt.alert_informed_entity USING btree (alert_id, COALESCE(agency_id, ''::text), COALESCE(route_id, ''::text), COALESCE((route_type)::integer, '-1'::integer), COALESCE((direction_id)::integer, '-1'::integer), COALESCE(trip_id, ''::text), COALESCE(stop_id, ''::text));


--
-- Name: INDEX alert_informed_unique_idx; Type: COMMENT; Schema: rt; Owner: -
--

COMMENT ON INDEX rt.alert_informed_unique_idx IS 'Forces dedup. Ingestor inserts with ON CONFLICT DO NOTHING so the TTC feed can repeat the same triple without error.';


--
-- Name: stop_eta_age_idx; Type: INDEX; Schema: rt; Owner: -
--

CREATE INDEX stop_eta_age_idx ON rt.stop_eta USING btree (received_at);


--
-- Name: stop_eta_stop_time_idx; Type: INDEX; Schema: rt; Owner: -
--

CREATE INDEX stop_eta_stop_time_idx ON rt.stop_eta USING btree (stop_id, predicted_at) WHERE (NOT is_skipped);


--
-- Name: trip_status_age_idx; Type: INDEX; Schema: rt; Owner: -
--

CREATE INDEX trip_status_age_idx ON rt.trip_status USING btree (received_at) WHERE is_active;


--
-- Name: trip_status_route_idx; Type: INDEX; Schema: rt; Owner: -
--

CREATE INDEX trip_status_route_idx ON rt.trip_status USING btree (route_id) WHERE is_active;


--
-- Name: trip_status_vehicle_idx; Type: INDEX; Schema: rt; Owner: -
--

CREATE INDEX trip_status_vehicle_idx ON rt.trip_status USING btree (vehicle_id) WHERE (vehicle_id IS NOT NULL);


--
-- Name: veh_latest_age_idx; Type: INDEX; Schema: rt; Owner: -
--

CREATE INDEX veh_latest_age_idx ON rt.vehicle_latest USING btree (received_at);


--
-- Name: veh_latest_route_idx; Type: INDEX; Schema: rt; Owner: -
--

CREATE INDEX veh_latest_route_idx ON rt.vehicle_latest USING btree (route_id, direction_id) WHERE (route_id IS NOT NULL);


--
-- Name: veh_latest_trip_idx; Type: INDEX; Schema: rt; Owner: -
--

CREATE INDEX veh_latest_trip_idx ON rt.vehicle_latest USING btree (trip_id) WHERE (trip_id IS NOT NULL);


--
-- Name: veh_samples_route_ts_idx; Type: INDEX; Schema: rt; Owner: -
--

CREATE INDEX veh_samples_route_ts_idx ON ONLY rt.vehicle_samples USING btree (route_id, received_at DESC) WHERE (route_id IS NOT NULL);


--
-- Name: veh_samples_trip_ts_idx; Type: INDEX; Schema: rt; Owner: -
--

CREATE INDEX veh_samples_trip_ts_idx ON ONLY rt.vehicle_samples USING btree (trip_id, received_at DESC) WHERE (trip_id IS NOT NULL);


--
-- Name: veh_samples_veh_ts_idx; Type: INDEX; Schema: rt; Owner: -
--

CREATE INDEX veh_samples_veh_ts_idx ON ONLY rt.vehicle_samples USING btree (vehicle_id, received_at DESC);


--
-- Name: vehicle_samples_20261011_route_id_received_at_idx; Type: INDEX; Schema: rt; Owner: -
--

CREATE INDEX vehicle_samples_20261011_route_id_received_at_idx ON rt.vehicle_samples_20261011 USING btree (route_id, received_at DESC) WHERE (route_id IS NOT NULL);


--
-- Name: vehicle_samples_20261011_trip_id_received_at_idx; Type: INDEX; Schema: rt; Owner: -
--

CREATE INDEX vehicle_samples_20261011_trip_id_received_at_idx ON rt.vehicle_samples_20261011 USING btree (trip_id, received_at DESC) WHERE (trip_id IS NOT NULL);


--
-- Name: vehicle_samples_20261011_vehicle_id_received_at_idx; Type: INDEX; Schema: rt; Owner: -
--

CREATE INDEX vehicle_samples_20261011_vehicle_id_received_at_idx ON rt.vehicle_samples_20261011 USING btree (vehicle_id, received_at DESC);


--
-- Name: vehicle_samples_20261012_route_id_received_at_idx; Type: INDEX; Schema: rt; Owner: -
--

CREATE INDEX vehicle_samples_20261012_route_id_received_at_idx ON rt.vehicle_samples_20261012 USING btree (route_id, received_at DESC) WHERE (route_id IS NOT NULL);


--
-- Name: vehicle_samples_20261012_trip_id_received_at_idx; Type: INDEX; Schema: rt; Owner: -
--

CREATE INDEX vehicle_samples_20261012_trip_id_received_at_idx ON rt.vehicle_samples_20261012 USING btree (trip_id, received_at DESC) WHERE (trip_id IS NOT NULL);


--
-- Name: vehicle_samples_20261012_vehicle_id_received_at_idx; Type: INDEX; Schema: rt; Owner: -
--

CREATE INDEX vehicle_samples_20261012_vehicle_id_received_at_idx ON rt.vehicle_samples_20261012 USING btree (vehicle_id, received_at DESC);


--
-- Name: vehicle_samples_20261013_route_id_received_at_idx; Type: INDEX; Schema: rt; Owner: -
--

CREATE INDEX vehicle_samples_20261013_route_id_received_at_idx ON rt.vehicle_samples_20261013 USING btree (route_id, received_at DESC) WHERE (route_id IS NOT NULL);


--
-- Name: vehicle_samples_20261013_trip_id_received_at_idx; Type: INDEX; Schema: rt; Owner: -
--

CREATE INDEX vehicle_samples_20261013_trip_id_received_at_idx ON rt.vehicle_samples_20261013 USING btree (trip_id, received_at DESC) WHERE (trip_id IS NOT NULL);


--
-- Name: vehicle_samples_20261013_vehicle_id_received_at_idx; Type: INDEX; Schema: rt; Owner: -
--

CREATE INDEX vehicle_samples_20261013_vehicle_id_received_at_idx ON rt.vehicle_samples_20261013 USING btree (vehicle_id, received_at DESC);


--
-- Name: vehicle_samples_20261014_route_id_received_at_idx; Type: INDEX; Schema: rt; Owner: -
--

CREATE INDEX vehicle_samples_20261014_route_id_received_at_idx ON rt.vehicle_samples_20261014 USING btree (route_id, received_at DESC) WHERE (route_id IS NOT NULL);


--
-- Name: vehicle_samples_20261014_trip_id_received_at_idx; Type: INDEX; Schema: rt; Owner: -
--

CREATE INDEX vehicle_samples_20261014_trip_id_received_at_idx ON rt.vehicle_samples_20261014 USING btree (trip_id, received_at DESC) WHERE (trip_id IS NOT NULL);


--
-- Name: vehicle_samples_20261014_vehicle_id_received_at_idx; Type: INDEX; Schema: rt; Owner: -
--

CREATE INDEX vehicle_samples_20261014_vehicle_id_received_at_idx ON rt.vehicle_samples_20261014 USING btree (vehicle_id, received_at DESC);


--
-- Name: vehicle_samples_20261015_route_id_received_at_idx; Type: INDEX; Schema: rt; Owner: -
--

CREATE INDEX vehicle_samples_20261015_route_id_received_at_idx ON rt.vehicle_samples_20261015 USING btree (route_id, received_at DESC) WHERE (route_id IS NOT NULL);


--
-- Name: vehicle_samples_20261015_trip_id_received_at_idx; Type: INDEX; Schema: rt; Owner: -
--

CREATE INDEX vehicle_samples_20261015_trip_id_received_at_idx ON rt.vehicle_samples_20261015 USING btree (trip_id, received_at DESC) WHERE (trip_id IS NOT NULL);


--
-- Name: vehicle_samples_20261015_vehicle_id_received_at_idx; Type: INDEX; Schema: rt; Owner: -
--

CREATE INDEX vehicle_samples_20261015_vehicle_id_received_at_idx ON rt.vehicle_samples_20261015 USING btree (vehicle_id, received_at DESC);


--
-- Name: vehicle_samples_20261016_route_id_received_at_idx; Type: INDEX; Schema: rt; Owner: -
--

CREATE INDEX vehicle_samples_20261016_route_id_received_at_idx ON rt.vehicle_samples_20261016 USING btree (route_id, received_at DESC) WHERE (route_id IS NOT NULL);


--
-- Name: vehicle_samples_20261016_trip_id_received_at_idx; Type: INDEX; Schema: rt; Owner: -
--

CREATE INDEX vehicle_samples_20261016_trip_id_received_at_idx ON rt.vehicle_samples_20261016 USING btree (trip_id, received_at DESC) WHERE (trip_id IS NOT NULL);


--
-- Name: vehicle_samples_20261016_vehicle_id_received_at_idx; Type: INDEX; Schema: rt; Owner: -
--

CREATE INDEX vehicle_samples_20261016_vehicle_id_received_at_idx ON rt.vehicle_samples_20261016 USING btree (vehicle_id, received_at DESC);


--
-- Name: vehicle_samples_default_route_id_received_at_idx; Type: INDEX; Schema: rt; Owner: -
--

CREATE INDEX vehicle_samples_default_route_id_received_at_idx ON rt.vehicle_samples_default USING btree (route_id, received_at DESC) WHERE (route_id IS NOT NULL);


--
-- Name: vehicle_samples_default_trip_id_received_at_idx; Type: INDEX; Schema: rt; Owner: -
--

CREATE INDEX vehicle_samples_default_trip_id_received_at_idx ON rt.vehicle_samples_default USING btree (trip_id, received_at DESC) WHERE (trip_id IS NOT NULL);


--
-- Name: vehicle_samples_default_vehicle_id_received_at_idx; Type: INDEX; Schema: rt; Owner: -
--

CREATE INDEX vehicle_samples_default_vehicle_id_received_at_idx ON rt.vehicle_samples_default USING btree (vehicle_id, received_at DESC);


--
-- Name: vehicle_samples_20261011_pkey; Type: INDEX ATTACH; Schema: rt; Owner: -
--

ALTER INDEX rt.vehicle_samples_pkey ATTACH PARTITION rt.vehicle_samples_20261011_pkey;


--
-- Name: vehicle_samples_20261011_route_id_received_at_idx; Type: INDEX ATTACH; Schema: rt; Owner: -
--

ALTER INDEX rt.veh_samples_route_ts_idx ATTACH PARTITION rt.vehicle_samples_20261011_route_id_received_at_idx;


--
-- Name: vehicle_samples_20261011_trip_id_received_at_idx; Type: INDEX ATTACH; Schema: rt; Owner: -
--

ALTER INDEX rt.veh_samples_trip_ts_idx ATTACH PARTITION rt.vehicle_samples_20261011_trip_id_received_at_idx;


--
-- Name: vehicle_samples_20261011_vehicle_id_received_at_idx; Type: INDEX ATTACH; Schema: rt; Owner: -
--

ALTER INDEX rt.veh_samples_veh_ts_idx ATTACH PARTITION rt.vehicle_samples_20261011_vehicle_id_received_at_idx;


--
-- Name: vehicle_samples_20261012_pkey; Type: INDEX ATTACH; Schema: rt; Owner: -
--

ALTER INDEX rt.vehicle_samples_pkey ATTACH PARTITION rt.vehicle_samples_20261012_pkey;


--
-- Name: vehicle_samples_20261012_route_id_received_at_idx; Type: INDEX ATTACH; Schema: rt; Owner: -
--

ALTER INDEX rt.veh_samples_route_ts_idx ATTACH PARTITION rt.vehicle_samples_20261012_route_id_received_at_idx;


--
-- Name: vehicle_samples_20261012_trip_id_received_at_idx; Type: INDEX ATTACH; Schema: rt; Owner: -
--

ALTER INDEX rt.veh_samples_trip_ts_idx ATTACH PARTITION rt.vehicle_samples_20261012_trip_id_received_at_idx;


--
-- Name: vehicle_samples_20261012_vehicle_id_received_at_idx; Type: INDEX ATTACH; Schema: rt; Owner: -
--

ALTER INDEX rt.veh_samples_veh_ts_idx ATTACH PARTITION rt.vehicle_samples_20261012_vehicle_id_received_at_idx;


--
-- Name: vehicle_samples_20261013_pkey; Type: INDEX ATTACH; Schema: rt; Owner: -
--

ALTER INDEX rt.vehicle_samples_pkey ATTACH PARTITION rt.vehicle_samples_20261013_pkey;


--
-- Name: vehicle_samples_20261013_route_id_received_at_idx; Type: INDEX ATTACH; Schema: rt; Owner: -
--

ALTER INDEX rt.veh_samples_route_ts_idx ATTACH PARTITION rt.vehicle_samples_20261013_route_id_received_at_idx;


--
-- Name: vehicle_samples_20261013_trip_id_received_at_idx; Type: INDEX ATTACH; Schema: rt; Owner: -
--

ALTER INDEX rt.veh_samples_trip_ts_idx ATTACH PARTITION rt.vehicle_samples_20261013_trip_id_received_at_idx;


--
-- Name: vehicle_samples_20261013_vehicle_id_received_at_idx; Type: INDEX ATTACH; Schema: rt; Owner: -
--

ALTER INDEX rt.veh_samples_veh_ts_idx ATTACH PARTITION rt.vehicle_samples_20261013_vehicle_id_received_at_idx;


--
-- Name: vehicle_samples_20261014_pkey; Type: INDEX ATTACH; Schema: rt; Owner: -
--

ALTER INDEX rt.vehicle_samples_pkey ATTACH PARTITION rt.vehicle_samples_20261014_pkey;


--
-- Name: vehicle_samples_20261014_route_id_received_at_idx; Type: INDEX ATTACH; Schema: rt; Owner: -
--

ALTER INDEX rt.veh_samples_route_ts_idx ATTACH PARTITION rt.vehicle_samples_20261014_route_id_received_at_idx;


--
-- Name: vehicle_samples_20261014_trip_id_received_at_idx; Type: INDEX ATTACH; Schema: rt; Owner: -
--

ALTER INDEX rt.veh_samples_trip_ts_idx ATTACH PARTITION rt.vehicle_samples_20261014_trip_id_received_at_idx;


--
-- Name: vehicle_samples_20261014_vehicle_id_received_at_idx; Type: INDEX ATTACH; Schema: rt; Owner: -
--

ALTER INDEX rt.veh_samples_veh_ts_idx ATTACH PARTITION rt.vehicle_samples_20261014_vehicle_id_received_at_idx;


--
-- Name: vehicle_samples_20261015_pkey; Type: INDEX ATTACH; Schema: rt; Owner: -
--

ALTER INDEX rt.vehicle_samples_pkey ATTACH PARTITION rt.vehicle_samples_20261015_pkey;


--
-- Name: vehicle_samples_20261015_route_id_received_at_idx; Type: INDEX ATTACH; Schema: rt; Owner: -
--

ALTER INDEX rt.veh_samples_route_ts_idx ATTACH PARTITION rt.vehicle_samples_20261015_route_id_received_at_idx;


--
-- Name: vehicle_samples_20261015_trip_id_received_at_idx; Type: INDEX ATTACH; Schema: rt; Owner: -
--

ALTER INDEX rt.veh_samples_trip_ts_idx ATTACH PARTITION rt.vehicle_samples_20261015_trip_id_received_at_idx;


--
-- Name: vehicle_samples_20261015_vehicle_id_received_at_idx; Type: INDEX ATTACH; Schema: rt; Owner: -
--

ALTER INDEX rt.veh_samples_veh_ts_idx ATTACH PARTITION rt.vehicle_samples_20261015_vehicle_id_received_at_idx;


--
-- Name: vehicle_samples_20261016_pkey; Type: INDEX ATTACH; Schema: rt; Owner: -
--

ALTER INDEX rt.vehicle_samples_pkey ATTACH PARTITION rt.vehicle_samples_20261016_pkey;


--
-- Name: vehicle_samples_20261016_route_id_received_at_idx; Type: INDEX ATTACH; Schema: rt; Owner: -
--

ALTER INDEX rt.veh_samples_route_ts_idx ATTACH PARTITION rt.vehicle_samples_20261016_route_id_received_at_idx;


--
-- Name: vehicle_samples_20261016_trip_id_received_at_idx; Type: INDEX ATTACH; Schema: rt; Owner: -
--

ALTER INDEX rt.veh_samples_trip_ts_idx ATTACH PARTITION rt.vehicle_samples_20261016_trip_id_received_at_idx;


--
-- Name: vehicle_samples_20261016_vehicle_id_received_at_idx; Type: INDEX ATTACH; Schema: rt; Owner: -
--

ALTER INDEX rt.veh_samples_veh_ts_idx ATTACH PARTITION rt.vehicle_samples_20261016_vehicle_id_received_at_idx;


--
-- Name: vehicle_samples_default_pkey; Type: INDEX ATTACH; Schema: rt; Owner: -
--

ALTER INDEX rt.vehicle_samples_pkey ATTACH PARTITION rt.vehicle_samples_default_pkey;


--
-- Name: vehicle_samples_default_route_id_received_at_idx; Type: INDEX ATTACH; Schema: rt; Owner: -
--

ALTER INDEX rt.veh_samples_route_ts_idx ATTACH PARTITION rt.vehicle_samples_default_route_id_received_at_idx;


--
-- Name: vehicle_samples_default_trip_id_received_at_idx; Type: INDEX ATTACH; Schema: rt; Owner: -
--

ALTER INDEX rt.veh_samples_trip_ts_idx ATTACH PARTITION rt.vehicle_samples_default_trip_id_received_at_idx;


--
-- Name: vehicle_samples_default_vehicle_id_received_at_idx; Type: INDEX ATTACH; Schema: rt; Owner: -
--

ALTER INDEX rt.veh_samples_veh_ts_idx ATTACH PARTITION rt.vehicle_samples_default_vehicle_id_received_at_idx;


--
-- Name: SCHEMA cur; Type: ACL; Schema: -; Owner: -
--

GRANT USAGE ON SCHEMA cur TO ttc_app;
GRANT USAGE ON SCHEMA cur TO ttc_rt;


--
-- Name: SCHEMA ops; Type: ACL; Schema: -; Owner: -
--

GRANT USAGE ON SCHEMA ops TO ttc_app;
GRANT USAGE ON SCHEMA ops TO ttc_rt;


--
-- Name: SCHEMA ref; Type: ACL; Schema: -; Owner: -
--

GRANT USAGE ON SCHEMA ref TO ttc_app;
GRANT USAGE ON SCHEMA ref TO ttc_rt;


--
-- Name: SCHEMA rt; Type: ACL; Schema: -; Owner: -
--

GRANT USAGE ON SCHEMA rt TO ttc_app;
GRANT USAGE ON SCHEMA rt TO ttc_rt;


--
-- Name: TABLE agency; Type: ACL; Schema: cur; Owner: -
--

GRANT SELECT ON TABLE cur.agency TO ttc_app;


--
-- Name: TABLE calendar; Type: ACL; Schema: cur; Owner: -
--

GRANT SELECT ON TABLE cur.calendar TO ttc_app;


--
-- Name: TABLE calendar_dates; Type: ACL; Schema: cur; Owner: -
--

GRANT SELECT ON TABLE cur.calendar_dates TO ttc_app;


--
-- Name: TABLE feed_info; Type: ACL; Schema: cur; Owner: -
--

GRANT SELECT ON TABLE cur.feed_info TO ttc_app;


--
-- Name: TABLE frequencies; Type: ACL; Schema: cur; Owner: -
--

GRANT SELECT ON TABLE cur.frequencies TO ttc_app;


--
-- Name: TABLE levels; Type: ACL; Schema: cur; Owner: -
--

GRANT SELECT ON TABLE cur.levels TO ttc_app;


--
-- Name: TABLE pathways; Type: ACL; Schema: cur; Owner: -
--

GRANT SELECT ON TABLE cur.pathways TO ttc_app;


--
-- Name: TABLE routes; Type: ACL; Schema: cur; Owner: -
--

GRANT SELECT ON TABLE cur.routes TO ttc_app;


--
-- Name: TABLE shapes; Type: ACL; Schema: cur; Owner: -
--

GRANT SELECT ON TABLE cur.shapes TO ttc_app;


--
-- Name: TABLE stop_times; Type: ACL; Schema: cur; Owner: -
--

GRANT SELECT ON TABLE cur.stop_times TO ttc_app;


--
-- Name: TABLE stops; Type: ACL; Schema: cur; Owner: -
--

GRANT SELECT ON TABLE cur.stops TO ttc_app;


--
-- Name: TABLE transfers; Type: ACL; Schema: cur; Owner: -
--

GRANT SELECT ON TABLE cur.transfers TO ttc_app;


--
-- Name: TABLE trips; Type: ACL; Schema: cur; Owner: -
--

GRANT SELECT ON TABLE cur.trips TO ttc_app;


--
-- Name: TABLE feed; Type: ACL; Schema: ops; Owner: -
--

GRANT SELECT ON TABLE ops.feed TO ttc_app;
GRANT SELECT ON TABLE ops.feed TO ttc_rt;


--
-- Name: TABLE departures; Type: ACL; Schema: ref; Owner: -
--

GRANT SELECT ON TABLE ref.departures TO ttc_app;
GRANT SELECT ON TABLE ref.departures TO ttc_rt;


--
-- Name: TABLE frequency_trips; Type: ACL; Schema: ref; Owner: -
--

GRANT SELECT ON TABLE ref.frequency_trips TO ttc_app;
GRANT SELECT ON TABLE ref.frequency_trips TO ttc_rt;


--
-- Name: TABLE pathway_edges; Type: ACL; Schema: ref; Owner: -
--

GRANT SELECT ON TABLE ref.pathway_edges TO ttc_app;
GRANT SELECT ON TABLE ref.pathway_edges TO ttc_rt;


--
-- Name: TABLE pattern_stops; Type: ACL; Schema: ref; Owner: -
--

GRANT SELECT ON TABLE ref.pattern_stops TO ttc_app;
GRANT SELECT ON TABLE ref.pattern_stops TO ttc_rt;


--
-- Name: TABLE patterns; Type: ACL; Schema: ref; Owner: -
--

GRANT SELECT ON TABLE ref.patterns TO ttc_app;
GRANT SELECT ON TABLE ref.patterns TO ttc_rt;


--
-- Name: TABLE service_days; Type: ACL; Schema: ref; Owner: -
--

GRANT SELECT ON TABLE ref.service_days TO ttc_app;
GRANT SELECT ON TABLE ref.service_days TO ttc_rt;


--
-- Name: TABLE state; Type: ACL; Schema: ref; Owner: -
--

GRANT SELECT ON TABLE ref.state TO ttc_app;
GRANT SELECT ON TABLE ref.state TO ttc_rt;


--
-- Name: TABLE station_nodes; Type: ACL; Schema: ref; Owner: -
--

GRANT SELECT ON TABLE ref.station_nodes TO ttc_app;
GRANT SELECT ON TABLE ref.station_nodes TO ttc_rt;


--
-- Name: TABLE stop_points; Type: ACL; Schema: ref; Owner: -
--

GRANT SELECT ON TABLE ref.stop_points TO ttc_app;
GRANT SELECT ON TABLE ref.stop_points TO ttc_rt;


--
-- Name: TABLE stop_routes; Type: ACL; Schema: ref; Owner: -
--

GRANT SELECT ON TABLE ref.stop_routes TO ttc_app;
GRANT SELECT ON TABLE ref.stop_routes TO ttc_rt;


--
-- Name: TABLE transfers; Type: ACL; Schema: ref; Owner: -
--

GRANT SELECT ON TABLE ref.transfers TO ttc_app;
GRANT SELECT ON TABLE ref.transfers TO ttc_rt;


--
-- Name: TABLE trip_stops; Type: ACL; Schema: ref; Owner: -
--

GRANT SELECT ON TABLE ref.trip_stops TO ttc_app;
GRANT SELECT ON TABLE ref.trip_stops TO ttc_rt;


--
-- Name: TABLE trips; Type: ACL; Schema: ref; Owner: -
--

GRANT SELECT ON TABLE ref.trips TO ttc_app;
GRANT SELECT ON TABLE ref.trips TO ttc_rt;


--
-- Name: TABLE alert; Type: ACL; Schema: rt; Owner: -
--

GRANT SELECT ON TABLE rt.alert TO ttc_app;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE rt.alert TO ttc_rt;


--
-- Name: TABLE active_alerts; Type: ACL; Schema: rt; Owner: -
--

GRANT SELECT ON TABLE rt.active_alerts TO ttc_app;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE rt.active_alerts TO ttc_rt;


--
-- Name: TABLE alert_active_period; Type: ACL; Schema: rt; Owner: -
--

GRANT SELECT ON TABLE rt.alert_active_period TO ttc_app;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE rt.alert_active_period TO ttc_rt;


--
-- Name: TABLE alert_informed_entity; Type: ACL; Schema: rt; Owner: -
--

GRANT SELECT ON TABLE rt.alert_informed_entity TO ttc_app;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE rt.alert_informed_entity TO ttc_rt;


--
-- Name: TABLE stop_eta; Type: ACL; Schema: rt; Owner: -
--

GRANT SELECT ON TABLE rt.stop_eta TO ttc_app;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE rt.stop_eta TO ttc_rt;


--
-- Name: TABLE trip_status; Type: ACL; Schema: rt; Owner: -
--

GRANT SELECT ON TABLE rt.trip_status TO ttc_app;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE rt.trip_status TO ttc_rt;


--
-- Name: TABLE trip_now; Type: ACL; Schema: rt; Owner: -
--

GRANT SELECT ON TABLE rt.trip_now TO ttc_app;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE rt.trip_now TO ttc_rt;


--
-- Name: TABLE vehicle_latest; Type: ACL; Schema: rt; Owner: -
--

GRANT SELECT ON TABLE rt.vehicle_latest TO ttc_app;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE rt.vehicle_latest TO ttc_rt;


--
-- Name: TABLE vehicle_now; Type: ACL; Schema: rt; Owner: -
--

GRANT SELECT ON TABLE rt.vehicle_now TO ttc_app;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE rt.vehicle_now TO ttc_rt;


--
-- Name: TABLE vehicle_samples; Type: ACL; Schema: rt; Owner: -
--

GRANT SELECT ON TABLE rt.vehicle_samples TO ttc_app;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE rt.vehicle_samples TO ttc_rt;


--
-- Name: TABLE vehicle_samples_20261011; Type: ACL; Schema: rt; Owner: -
--

GRANT SELECT ON TABLE rt.vehicle_samples_20261011 TO ttc_app;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE rt.vehicle_samples_20261011 TO ttc_rt;


--
-- Name: TABLE vehicle_samples_20261012; Type: ACL; Schema: rt; Owner: -
--

GRANT SELECT ON TABLE rt.vehicle_samples_20261012 TO ttc_app;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE rt.vehicle_samples_20261012 TO ttc_rt;


--
-- Name: TABLE vehicle_samples_20261013; Type: ACL; Schema: rt; Owner: -
--

GRANT SELECT ON TABLE rt.vehicle_samples_20261013 TO ttc_app;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE rt.vehicle_samples_20261013 TO ttc_rt;


--
-- Name: TABLE vehicle_samples_20261014; Type: ACL; Schema: rt; Owner: -
--

GRANT SELECT ON TABLE rt.vehicle_samples_20261014 TO ttc_app;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE rt.vehicle_samples_20261014 TO ttc_rt;


--
-- Name: TABLE vehicle_samples_20261015; Type: ACL; Schema: rt; Owner: -
--

GRANT SELECT ON TABLE rt.vehicle_samples_20261015 TO ttc_app;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE rt.vehicle_samples_20261015 TO ttc_rt;


--
-- Name: TABLE vehicle_samples_20261016; Type: ACL; Schema: rt; Owner: -
--

GRANT SELECT ON TABLE rt.vehicle_samples_20261016 TO ttc_app;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE rt.vehicle_samples_20261016 TO ttc_rt;


--
-- Name: TABLE vehicle_samples_default; Type: ACL; Schema: rt; Owner: -
--

GRANT SELECT ON TABLE rt.vehicle_samples_default TO ttc_app;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE rt.vehicle_samples_default TO ttc_rt;


--
-- Name: SEQUENCE vehicle_samples_sample_id_seq; Type: ACL; Schema: rt; Owner: -
--

GRANT USAGE ON SEQUENCE rt.vehicle_samples_sample_id_seq TO ttc_rt;


--
-- Name: DEFAULT PRIVILEGES FOR SEQUENCES; Type: DEFAULT ACL; Schema: rt; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE ttc_admin IN SCHEMA rt GRANT USAGE ON SEQUENCES TO ttc_rt;


--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: rt; Owner: -
--

ALTER DEFAULT PRIVILEGES FOR ROLE ttc_admin IN SCHEMA rt GRANT SELECT ON TABLES TO ttc_app;
ALTER DEFAULT PRIVILEGES FOR ROLE ttc_admin IN SCHEMA rt GRANT SELECT,INSERT,DELETE,UPDATE ON TABLES TO ttc_rt;


--
-- PostgreSQL database dump complete
--

\unrestrict MWZwxldvGNqHLWhCGuKTaTRQDsaiHYtRoYnfCoRsEZKxW5mZhLcnhPgIs3CwrQZ

