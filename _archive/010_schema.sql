-- ============================================================================
-- ttc_full_schema.sql  (generated 2026-10-13)
-- Fresh-install file. Contents, in order, each part verbatim:
--   1. GTFS + Realtime schema v1.8   (schemas ops, core, ref, rt, cur)
--   2. 008 user model                (schema app)
--   3. 009 commitments / compass / challenges
--   4. 010 trip history
--   5. 011 anonymous observations    (schema data)
--   6. 012 stats aggregates          (schema stats)
-- Run as a superuser on an EMPTY database. Each part is its own transaction.
-- ============================================================================

-- >>>>>>>>>> BEGIN PART: 001_gtfs_realtime_v1.8.sql <<<<<<<<<<
-- ============================================================================
--  TTC GTFS + Realtime — Complete Database Schema v1.8   (FINAL, fresh install)
-- ============================================================================
--
--  Purpose: power a transit app that shows users when to leave, where to
--  board, when to get off, and how to walk inside stations.
--
--  Consolidated from:
--    v1.3  base schema (ordinal/stop_sequence split, roll_forward, trip_stops)
--    v1.4  service alerts (rt.alert, active_period, informed_entity)
--    v1.5  rt.trip_status.schedule_relationship + alert dedup index
--    v1.6  relaxed schedule_relationship CHECK (0..99)
--    v1.7  realtime hardening: every realtime enum CHECK relaxed to 0..99,
--          redundant alert indexes dropped, atomic alert sweep, doc fixes
--    v1.8  per-vehicle trip progress (current_ordinal, stops_remaining,
--          service_state) derived each ingest cycle
--
--  Running this file on an EMPTY database gives the complete, current schema.
--  (Docker: it runs once, as db/init/010_schema.sql, on first start.)
--  An existing database is upgraded with the numbered migrations instead.
--
--  Design invariants:
--    1. Names are canonical snake_case. Stops use stop_lat/stop_lon; moving
--       things (vehicles) use lat/lon. Raw GTFS names are kept in core.*.
--    2. Every table has an explicit PK. No hidden dependencies.
--    3. Every index is justified by a query. core.* carries PKs only.
--    4. Nullable means "GTFS allows null". The ONLY '' sentinel is in
--       transfers PK columns (Postgres cannot put NULL in a PK).
--    5. Enums are smallint with frozen values. Realtime enums use GTFS-RT
--       protobuf numbering, and their CHECKs are permissive (0..99) so spec
--       growth or a vendor value never aborts an ingest batch.
--    6. Evolution is additive-only.
--    7. Realtime tables are upserted or partitioned. They never bloat.
--    8. Times past midnight are integer seconds, never time.
--    9. All wall-clock is timestamptz. All dates are date.
--   10. Feed versions are immutable. Reload = DELETE WHERE feed_version + COPY.
--       core.* holds RAW values; ref/cur apply unit scales on read/derive.
--   11. FKs exist only where they don't block bulk loads. (None.)
--   12. ref.rebuild() and ref.roll_forward() are the only writers of ref.*.
--       Both take the same advisory lock.
--   13. stop_sequence is ALWAYS the raw GTFS value (what GTFS-RT uses).
--       ordinal is the normalized 1..N position within a trip or pattern.
--   14. "Today" is ops.today() (America/Toronto), never current_date.
--
--  Schemas:
--    ops.*   Orchestration: active feed pointer, run audit, unit scales
--    core.*  Raw GTFS, versioned by feed_version. Read-only.
--    ref.*   Derived from the active feed. Rebuilt per feed, rolled daily.
--    rt.*    Realtime vehicles, trips, ETAs, alerts. Rolling.
--    cur.*   Convenience views filtered by active_version().
--
--  Re-runnable: everything is CREATE ... IF NOT EXISTS / OR REPLACE.
--  (Re-running does NOT alter existing tables; use migrations for that.)
-- ============================================================================

SET client_min_messages TO WARNING;

-- Persistent database timezone (best effort; correctness does not depend on it
-- because every function below uses explicit zones / ops.today()).
DO $$
BEGIN
    EXECUTE format('ALTER DATABASE %I SET timezone TO %L',
                   current_database(), 'America/Toronto');
EXCEPTION WHEN insufficient_privilege THEN
    RAISE WARNING 'not database owner; skipping ALTER DATABASE SET timezone';
END;
$$;
SET timezone TO 'America/Toronto';

-- ---------------------------------------------------------------------------
--  Extensions
-- ---------------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS pg_trgm;
-- pg_stat_statements needs shared_preload_libraries and a restart; enable it
-- in ops tooling, not in this schema file.

-- ---------------------------------------------------------------------------
--  Schemas
-- ---------------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS ops;
CREATE SCHEMA IF NOT EXISTS core;
CREATE SCHEMA IF NOT EXISTS ref;
CREATE SCHEMA IF NOT EXISTS rt;
CREATE SCHEMA IF NOT EXISTS cur;

COMMENT ON SCHEMA ops  IS 'Orchestration: active feed, run history, unit scales';
COMMENT ON SCHEMA core IS 'Raw GTFS, versioned by feed_version, read-only';
COMMENT ON SCHEMA ref  IS 'Derived tables reflecting the active feed';
COMMENT ON SCHEMA rt   IS 'Realtime vehicles, trips, ETAs';
COMMENT ON SCHEMA cur  IS 'Convenience views filtered by active_version()';


-- ============================================================================
--  SECTION 1 — ops.*
-- ============================================================================

CREATE TABLE IF NOT EXISTS ops.schema_version (
    version    text PRIMARY KEY,
    applied_at timestamptz NOT NULL DEFAULT now(),
    note       text
);
INSERT INTO ops.schema_version (version, note) VALUES
    ('1.3', 'ordinal/stop_sequence split, roll_forward, trip_stops'),
    ('1.4', 'rt.alert + active_period + informed_entity'),
    ('1.5', 'rt.trip_status.schedule_relationship + alert_informed dedup index'),
    ('1.6', 'relax schedule_relationship CHECK to 0..99'),
    ('1.7', 'rt hardening: relaxed enum CHECKs, redundant alert indexes dropped, atomic alert sweep'),
    ('1.8', 'per-vehicle trip progress: current_ordinal, stops_remaining, service_state')
ON CONFLICT DO NOTHING;


CREATE TABLE IF NOT EXISTS ops.feed (
    source        text PRIMARY KEY,
    feed_version  text NOT NULL,
    activated_at  timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE ops.feed IS
    'Single source of truth for the active feed_version. '
    'Flip it only through ops.activate_feed().';

INSERT INTO ops.feed (source, feed_version)
VALUES ('ttc', '__placeholder__')
ON CONFLICT DO NOTHING;


CREATE TABLE IF NOT EXISTS ops.run (
    id            bigserial PRIMARY KEY,
    source        text NOT NULL,
    feed_version  text,
    status        text NOT NULL DEFAULT 'running',
    started_at    timestamptz NOT NULL DEFAULT now(),
    finished_at   timestamptz,
    rows          jsonb NOT NULL DEFAULT '{}'::jsonb,
    error         text,
    CONSTRAINT run_status_check CHECK (status IN ('running','ok','failed'))
);
CREATE INDEX IF NOT EXISTS run_source_started_idx
    ON ops.run (source, started_at DESC);
COMMENT ON TABLE ops.run IS 'Audit trail of every updater invocation.';


CREATE TABLE IF NOT EXISTS ops.units (
    feed_version  text PRIMARY KEY,
    shape_scale   double precision NOT NULL DEFAULT 1,
    stop_scale    double precision NOT NULL DEFAULT 1,
    detected_at   timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT units_positive_check CHECK (shape_scale > 0 AND stop_scale > 0)
);
COMMENT ON TABLE ops.units IS
    'Detected unit scales (multiply raw value to get meters). The TTC feed '
    'detected as meters for both (scale 1); a feed in km would get 1000. core.* stays raw; '
    'cur.shapes / cur.stop_times / ref.pattern_stops apply the scale. A feed '
    'with no row here cannot be rebuilt: ref.rebuild() raises.';


CREATE OR REPLACE FUNCTION ops.today()
RETURNS date LANGUAGE sql STABLE AS $$
    SELECT (now() AT TIME ZONE 'America/Toronto')::date;
$$;
COMMENT ON FUNCTION ops.today IS
    'Current date in America/Toronto. Use instead of current_date.';


CREATE OR REPLACE FUNCTION ops.active_version(p_source text DEFAULT 'ttc')
RETURNS text LANGUAGE sql STABLE AS $$
    SELECT feed_version FROM ops.feed WHERE source = p_source;
$$;
COMMENT ON FUNCTION ops.active_version IS
    'Returns the currently active feed_version. Used by cur.* views.';


-- GC: keep the p_keep most recent distinct OK feed versions in core.*, plus
-- the active version, the version ref.* was built from, and any load that
-- started in the last 6 hours and is still running.
CREATE OR REPLACE FUNCTION ops.gc_old_feeds(
    p_source text DEFAULT 'ttc',
    p_keep   int  DEFAULT 2
) RETURNS bigint LANGUAGE plpgsql AS $$
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
$$;
COMMENT ON FUNCTION ops.gc_old_feeds IS
    'Deletes core.* rows for feed versions that are not among the last p_keep '
    'distinct OK versions, the active version, the ref.state version, or a '
    'recent running load. Returns rows deleted.';


-- ============================================================================
--  SECTION 2 — core.*   (raw GTFS; primary keys only)
-- ============================================================================

CREATE TABLE IF NOT EXISTS core.feed_info (
    feed_version   text PRIMARY KEY,
    publisher_name text,
    publisher_url  text,
    lang           text,
    start_date     date NOT NULL,
    end_date       date NOT NULL
);

CREATE TABLE IF NOT EXISTS core.agency (
    feed_version text NOT NULL,
    agency_id    text NOT NULL,
    name         text,
    url          text,
    timezone     text,
    lang         text,
    phone        text,
    email        text,
    fare_url     text,
    PRIMARY KEY (feed_version, agency_id)
);

CREATE TABLE IF NOT EXISTS core.stops (
    feed_version        text NOT NULL,
    stop_id             text NOT NULL,
    stop_code           text,
    stop_name           text,
    stop_desc           text,
    stop_lat            double precision,
    stop_lon            double precision,
    zone_id             text,
    stop_url            text,
    location_type       smallint NOT NULL DEFAULT 0,
    parent_station      text,
    stop_timezone       text,
    wheelchair_boarding smallint,
    level_id            text,
    platform_code       text,
    tts_stop_name       text,
    PRIMARY KEY (feed_version, stop_id),
    CONSTRAINT stops_location_type_check CHECK (location_type IN (0,1,2,3,4)),
    CONSTRAINT stops_wheelchair_check CHECK (
        wheelchair_boarding IS NULL OR wheelchair_boarding IN (0,1,2)
    )
);
COMMENT ON TABLE core.stops IS
    'GTFS stops. ~12k rows. location_type: 0 platform, 1 station, '
    '2 entrance, 3 generic node, 4 boarding area. Name search runs against '
    'ref.stop_points (active feed only), not here.';

CREATE TABLE IF NOT EXISTS core.routes (
    feed_version     text NOT NULL,
    route_id         text NOT NULL,
    agency_id        text,
    route_short_name text,
    route_long_name  text,
    route_desc       text,
    route_type       smallint NOT NULL,
    route_url        text,
    route_color      text,
    route_text_color text,
    route_sort_order integer,
    PRIMARY KEY (feed_version, route_id),
    CONSTRAINT routes_type_check CHECK (
        route_type IN (0,1,2,3,4,5,6,7,11,12)
        OR (route_type BETWEEN 100 AND 1799)
    )
);

CREATE TABLE IF NOT EXISTS core.trips (
    feed_version          text NOT NULL,
    trip_id               text NOT NULL,
    route_id              text NOT NULL,
    service_id            text NOT NULL,
    trip_headsign         text,
    trip_short_name       text,
    direction_id          smallint,
    block_id              text,
    shape_id              text,
    wheelchair_accessible smallint,
    bikes_allowed         smallint,
    PRIMARY KEY (feed_version, trip_id),
    CONSTRAINT trips_direction_check CHECK (
        direction_id IS NULL OR direction_id IN (0,1)
    )
);

CREATE TABLE IF NOT EXISTS core.stop_times (
    feed_version        text NOT NULL,
    trip_id             text NOT NULL,
    stop_sequence       integer NOT NULL,
    stop_id             text NOT NULL,
    arrival_time        text,        -- nullable: GTFS allows empty (interpolated stops)
    departure_time      text,        -- nullable: same
    stop_headsign       text,
    pickup_type         smallint,
    drop_off_type       smallint,
    shape_dist_traveled double precision,   -- RAW feed units (see ops.units.stop_scale)
    timepoint           smallint,
    PRIMARY KEY (feed_version, trip_id, stop_sequence),
    CONSTRAINT st_pickup_check  CHECK (pickup_type   IS NULL
                                       OR pickup_type   IN (0,1,2,3)),
    CONSTRAINT st_dropoff_check CHECK (drop_off_type IS NULL
                                       OR drop_off_type IN (0,1,2,3))
);
COMMENT ON TABLE core.stop_times IS
    'GTFS stop_times. ~4.3M rows. Times are text "HH:MM:SS", may exceed '
    '24:00:00, and may be NULL at interpolated stops (ref.rebuild fills them).';

CREATE TABLE IF NOT EXISTS core.shapes (
    feed_version        text NOT NULL,
    shape_id            text NOT NULL,
    shape_pt_sequence   integer NOT NULL,
    shape_pt_lat        double precision NOT NULL,
    shape_pt_lon        double precision NOT NULL,
    shape_dist_traveled double precision,   -- RAW feed units (TTC: meters)
    PRIMARY KEY (feed_version, shape_id, shape_pt_sequence)
);
COMMENT ON TABLE core.shapes IS
    'GTFS shapes. ~1M rows. shape_dist_traveled is RAW (TTC: meters). Never '
    'UPDATE it. cur.shapes multiplies by ops.units.shape_scale -> meters.';

CREATE TABLE IF NOT EXISTS core.calendar (
    feed_version text NOT NULL,
    service_id   text NOT NULL,
    monday       boolean NOT NULL DEFAULT false,
    tuesday      boolean NOT NULL DEFAULT false,
    wednesday    boolean NOT NULL DEFAULT false,
    thursday     boolean NOT NULL DEFAULT false,
    friday       boolean NOT NULL DEFAULT false,
    saturday     boolean NOT NULL DEFAULT false,
    sunday       boolean NOT NULL DEFAULT false,
    start_date   date NOT NULL,
    end_date     date NOT NULL,
    PRIMARY KEY (feed_version, service_id)
);

CREATE TABLE IF NOT EXISTS core.calendar_dates (
    feed_version   text NOT NULL,
    service_id     text NOT NULL,
    service_date   date NOT NULL,
    exception_type smallint NOT NULL,
    PRIMARY KEY (feed_version, service_id, service_date),
    CONSTRAINT cd_exception_check CHECK (exception_type IN (1,2))
);
COMMENT ON TABLE core.calendar_dates IS
    'GTFS calendar_dates. exception_type: 1 added, 2 removed.';

CREATE TABLE IF NOT EXISTS core.levels (
    feed_version text NOT NULL,
    level_id     text NOT NULL,
    level_index  double precision,
    level_name   text,
    PRIMARY KEY (feed_version, level_id)
);

CREATE TABLE IF NOT EXISTS core.pathways (
    feed_version           text NOT NULL,
    pathway_id             text NOT NULL,
    from_stop_id           text,
    to_stop_id             text,
    pathway_mode           smallint NOT NULL,
    is_bidirectional       smallint,
    length                 double precision,
    traversal_time         integer,
    stair_count            integer,
    max_slope              double precision,
    min_width              double precision,
    signposted_as          text,
    reversed_signposted_as text,
    PRIMARY KEY (feed_version, pathway_id),
    CONSTRAINT pw_mode_check CHECK (pathway_mode BETWEEN 1 AND 7)
);
COMMENT ON TABLE core.pathways IS
    'GTFS pathways. mode: 1 walkway, 2 stairs, 3 moving walkway, '
    '4 escalator, 5 elevator, 6 fare gate, 7 exit gate.';

--  The '' sentinel in the PK columns below means "any". This is the one
--  documented exception to invariant 4.
CREATE TABLE IF NOT EXISTS core.transfers (
    feed_version      text NOT NULL,
    from_stop_id      text NOT NULL,
    to_stop_id        text NOT NULL,
    from_route_id     text NOT NULL DEFAULT '',
    to_route_id       text NOT NULL DEFAULT '',
    from_trip_id      text NOT NULL DEFAULT '',
    to_trip_id        text NOT NULL DEFAULT '',
    transfer_type     smallint,
    min_transfer_time integer,
    PRIMARY KEY (feed_version, from_stop_id, to_stop_id,
                 from_route_id, to_route_id, from_trip_id, to_trip_id),
    CONSTRAINT transfers_type_check CHECK (
        transfer_type IS NULL OR transfer_type IN (0,1,2,3,4,5)
    )
);
COMMENT ON TABLE core.transfers IS
    'GTFS transfers. Empty for current TTC feed. '' in PK columns means "any".';

CREATE TABLE IF NOT EXISTS core.frequencies (
    feed_version text NOT NULL,
    trip_id      text NOT NULL,
    start_time   text NOT NULL,
    end_time     text NOT NULL,
    headway_secs integer NOT NULL,
    exact_times  smallint,
    PRIMARY KEY (feed_version, trip_id, start_time)
);
COMMENT ON TABLE core.frequencies IS
    'GTFS frequencies. Empty for current TTC feed.';


-- ============================================================================
--  SECTION 3 — ref.*   (derived; no FKs, no CASCADE — rebuild deletes
--                       explicitly, children first)
-- ============================================================================

CREATE TABLE IF NOT EXISTS ref.state (
    singleton    boolean PRIMARY KEY DEFAULT true,
    feed_version text NOT NULL,
    horizon_days integer NOT NULL,
    built_at     timestamptz NOT NULL DEFAULT now(),
    rolled_at    timestamptz,
    CONSTRAINT state_singleton_check CHECK (singleton)
);
COMMENT ON TABLE ref.state IS
    'One row: which feed ref.* was built from and the derive horizon. '
    'ref.roll_forward() reads it, so the nightly job needs no arguments.';


CREATE TABLE IF NOT EXISTS ref.service_days (
    service_date date NOT NULL,
    service_id   text NOT NULL,
    PRIMARY KEY (service_date, service_id)
);
CREATE INDEX IF NOT EXISTS service_days_service_idx
    ON ref.service_days (service_id);
COMMENT ON TABLE ref.service_days IS
    'Resolved (date, service_id) for the horizon: ops.today()-1 .. +horizon.';


CREATE TABLE IF NOT EXISTS ref.trips (
    trip_id      text PRIMARY KEY,
    route_id     text NOT NULL,
    service_id   text NOT NULL,
    direction_id smallint,
    headsign     text,
    pattern_id   text NOT NULL,
    n_stops      integer NOT NULL
);
CREATE INDEX IF NOT EXISTS trips_service_idx ON ref.trips (service_id);
COMMENT ON TABLE ref.trips IS
    'Trips that have stop_times, with their pattern. Feeds roll_forward().';


CREATE TABLE IF NOT EXISTS ref.trip_stops (
    trip_id       text NOT NULL,
    ordinal       integer NOT NULL,          -- normalized 1..N
    stop_sequence integer NOT NULL,          -- RAW GTFS / GTFS-RT value
    stop_id       text NOT NULL,
    stop_headsign text,
    departure_s   integer,                   -- NULL only at leading/trailing untimed stops
    interpolated  boolean NOT NULL,
    boardable     boolean NOT NULL,
    PRIMARY KEY (trip_id, ordinal)
);
CREATE UNIQUE INDEX IF NOT EXISTS trip_stops_seq_idx
    ON ref.trip_stops (trip_id, stop_sequence);
COMMENT ON TABLE ref.trip_stops IS
    'Per-trip stop list, date-independent. Times at untimed stops are '
    'linearly interpolated by ordinal between the surrounding timed stops '
    '(interpolated = true). The unique index maps a GTFS-RT stop_sequence to '
    'an ordinal; roll_forward() cross-joins this with service_days.';


CREATE TABLE IF NOT EXISTS ref.stop_points (
    stop_id             text PRIMARY KEY,
    stop_code           text,
    stop_name           text NOT NULL,
    stop_lat            double precision NOT NULL,
    stop_lon            double precision NOT NULL,
    wheelchair_boarding smallint,
    parent_station      text,
    station_name        text
);
CREATE INDEX IF NOT EXISTS stop_points_parent_idx
    ON ref.stop_points (parent_station)
    WHERE parent_station IS NOT NULL;
-- Query: GET /stops/search?q=  (similarity / ILIKE on the active feed).
CREATE INDEX IF NOT EXISTS stop_points_name_trgm_idx
    ON ref.stop_points USING gin (stop_name gin_trgm_ops);
COMMENT ON TABLE ref.stop_points IS
    'Boardable stops (location_type=0, coords present, served). ~9.4k rows.';


CREATE TABLE IF NOT EXISTS ref.stop_routes (
    stop_id  text NOT NULL,
    route_id text NOT NULL,
    PRIMARY KEY (stop_id, route_id)
);
CREATE INDEX IF NOT EXISTS stop_routes_route_idx ON ref.stop_routes (route_id);


CREATE TABLE IF NOT EXISTS ref.patterns (
    pattern_id   text PRIMARY KEY,   -- md5(stop_ids | route_id | direction_id)
    route_id     text NOT NULL,
    direction_id smallint,
    headsign     text,
    n_stops      integer NOT NULL,
    trip_count   integer NOT NULL
);
CREATE INDEX IF NOT EXISTS patterns_route_idx
    ON ref.patterns (route_id, direction_id);


CREATE TABLE IF NOT EXISTS ref.pattern_stops (
    pattern_id text NOT NULL,
    ordinal    integer NOT NULL,     -- normalized 1..N (not raw stop_sequence)
    stop_id    text NOT NULL,
    dist_m     double precision,     -- meters (raw * ops.units.stop_scale)
    PRIMARY KEY (pattern_id, ordinal)
);
COMMENT ON TABLE ref.pattern_stops IS
    'Stops of a pattern in order, indexed by ordinal so every trip on the '
    'pattern shares one numbering.';


--  Hot table. Maintained incrementally: roll_forward() deletes dates that
--  fell out of the window and inserts only dates not yet present, so the
--  daily churn is ~1/14 of the table, not all of it.
CREATE TABLE IF NOT EXISTS ref.departures (
    service_date  date NOT NULL,
    trip_id       text NOT NULL,
    ordinal       integer NOT NULL,
    stop_sequence integer NOT NULL,       -- RAW; join realtime on this
    stop_id       text NOT NULL,
    departs_at    timestamptz NOT NULL,
    departure_s   integer NOT NULL,
    route_id      text NOT NULL,
    headsign      text,
    direction_id  smallint,
    pattern_id    text,
    boardable     boolean NOT NULL,
    PRIMARY KEY (service_date, trip_id, ordinal)
) WITH (
    autovacuum_vacuum_scale_factor  = 0.02,
    autovacuum_analyze_scale_factor = 0.01
);
-- Query: next departures at a stop.
CREATE INDEX IF NOT EXISTS dep_stop_time_boardable_idx
    ON ref.departures (stop_id, departs_at) WHERE boardable;
-- "Rest of this trip" is served by the PK prefix (service_date, trip_id);
-- realtime rows always carry service_date. Map a raw stop_sequence to an
-- ordinal via ref.trip_stops_seq_idx, or filter on departures.stop_sequence
-- within the (service_date, trip_id) range.
COMMENT ON TABLE ref.departures IS
    '~16M rows for a 14-day horizon. PK includes service_date because a trip '
    'runs on many dates. stop_sequence is raw (matches GTFS-RT); ordinal is '
    'normalized (matches ref.pattern_stops). Interpolated stops are included.';


CREATE TABLE IF NOT EXISTS ref.station_nodes (
    stop_id             text PRIMARY KEY,
    stop_name           text NOT NULL,
    location_type       smallint NOT NULL,
    station_id          text,
    level_id            text,
    level_index         double precision,
    level_name          text,
    wheelchair_boarding smallint,
    stop_lat            double precision,
    stop_lon            double precision
);
CREATE INDEX IF NOT EXISTS station_nodes_station_idx
    ON ref.station_nodes (station_id)
    WHERE station_id IS NOT NULL;


CREATE TABLE IF NOT EXISTS ref.pathway_edges (
    pathway_id  text NOT NULL,
    from_id     text NOT NULL,
    to_id       text NOT NULL,
    mode        smallint NOT NULL,
    traversal_s integer,
    length_m    double precision,
    stair_count integer,
    sign        text,
    PRIMARY KEY (pathway_id, from_id, to_id)
);
CREATE INDEX IF NOT EXISTS pe_from_idx ON ref.pathway_edges (from_id);
COMMENT ON TABLE ref.pathway_edges IS
    'Directed edges for in-station Dijkstra. Bidirectional pathways are '
    'expanded into two rows.';


CREATE TABLE IF NOT EXISTS ref.transfers (
    from_stop_id  text NOT NULL,
    to_stop_id    text NOT NULL,
    from_route_id text NOT NULL DEFAULT '',
    to_route_id   text NOT NULL DEFAULT '',
    from_trip_id  text NOT NULL DEFAULT '',
    to_trip_id    text NOT NULL DEFAULT '',
    min_seconds   integer NOT NULL,
    type          smallint NOT NULL,
    PRIMARY KEY (from_stop_id, to_stop_id,
                 from_route_id, to_route_id,
                 from_trip_id, to_trip_id)
);
CREATE INDEX IF NOT EXISTS ref_transfers_from_idx
    ON ref.transfers (from_stop_id);
COMMENT ON TABLE ref.transfers IS
    'Derived transfers. Empty for current TTC feed. Planner falls back to '
    'its default minimum transfer time when a lookup misses.';


CREATE TABLE IF NOT EXISTS ref.frequency_trips (
    trip_id     text NOT NULL,
    start_s     integer NOT NULL,
    end_s       integer NOT NULL,
    headway_s   integer NOT NULL,
    exact_times smallint,
    PRIMARY KEY (trip_id, start_s)
);


-- ============================================================================
--  SECTION 4 — rt.*   (all *_sequence columns are RAW GTFS-RT stop_sequence;
--                      enums use GTFS-RT protobuf numbering)
-- ============================================================================
--   current_status (VehicleStopStatus): 0 INCOMING_AT, 1 STOPPED_AT,
--                                       2 IN_TRANSIT_TO
--   schedule_relationship: 0 SCHEDULED, 1 ADDED, 2 UNSCHEDULED, 3 CANCELED,
--                          4 REPLACEMENT (deprecated), 5 DUPLICATED, 6 DELETED,
--                          7 NEW
--   occupancy (OccupancyStatus): 0 EMPTY, 1 MANY_SEATS_AVAILABLE,
--        2 FEW_SEATS_AVAILABLE, 3 STANDING_ROOM_ONLY, 4 CRUSHED_STANDING_ROOM_ONLY,
--        5 FULL, 6 NOT_ACCEPTING_PASSENGERS, 7 NO_DATA_AVAILABLE, 8 NOT_BOARDABLE
--   alert.cause:           1 UNKNOWN, 2 OTHER, 3 TECHNICAL, 4 STRIKE,
--                          5 DEMONSTRATION, 6 ACCIDENT, 7 HOLIDAY, 8 WEATHER,
--                          9 MAINTENANCE, 10 CONSTRUCTION, 11 POLICE, 12 MEDICAL
--   alert.effect:          1 NO_SERVICE, 2 REDUCED_SERVICE, 3 SIGNIFICANT_DELAYS,
--                          4 DETOUR, 5 ADDITIONAL_SERVICE, 6 MODIFIED_SERVICE,
--                          7 OTHER, 8 UNKNOWN, 9 STOP_MOVED, 10 NO_EFFECT,
--                          11 ACCESSIBILITY_ISSUE
--   alert.severity_level:  1 UNKNOWN, 2 INFO, 3 WARNING, 4 SEVERE
--
--   All realtime enum CHECKs accept 0..99 on purpose (invariant 5).

CREATE TABLE IF NOT EXISTS rt.vehicle_latest (
    vehicle_id            text PRIMARY KEY,
    trip_id               text,
    route_id              text,
    direction_id          smallint,
    schedule_relationship smallint,
    lat                   double precision,
    lon                   double precision,
    bearing               real,
    speed_mps             real,
    current_stop_id       text,
    current_stop_sequence integer,
    current_ordinal       integer,
    stops_remaining       integer,
    service_state         text,
    current_status        smallint,
    occupancy             smallint,
    vehicle_ts            timestamptz,
    received_at           timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT veh_status_check CHECK (
        current_status IS NULL OR current_status BETWEEN 0 AND 99
    ),
    CONSTRAINT veh_sched_check CHECK (
        schedule_relationship IS NULL OR schedule_relationship BETWEEN 0 AND 99
    ),
    CONSTRAINT veh_occupancy_check CHECK (
        occupancy IS NULL OR occupancy BETWEEN 0 AND 99
    ),
    CONSTRAINT vehicle_latest_service_state_check CHECK (
        service_state IS NULL
        OR service_state IN ('unknown','not_started','in_service','finished')
    )
) WITH (
    fillfactor = 85,
    autovacuum_vacuum_scale_factor  = 0.01,
    autovacuum_analyze_scale_factor = 0.005
);
CREATE INDEX IF NOT EXISTS veh_latest_route_idx
    ON rt.vehicle_latest (route_id, direction_id)
    WHERE route_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS veh_latest_trip_idx
    ON rt.vehicle_latest (trip_id)
    WHERE trip_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS veh_latest_age_idx
    ON rt.vehicle_latest (received_at);
COMMENT ON TABLE rt.vehicle_latest IS
    'One row per active vehicle. Upserted every 30s. ~500 rows steady state.';


CREATE TABLE IF NOT EXISTS rt.vehicle_samples (
    sample_id             bigint GENERATED ALWAYS AS IDENTITY,
    vehicle_id            text NOT NULL,
    trip_id               text,
    route_id              text,
    direction_id          smallint,
    lat                   double precision,
    lon                   double precision,
    bearing               real,
    speed_mps             real,
    current_stop_id       text,
    current_stop_sequence integer,
    current_status        smallint,
    occupancy             smallint,
    vehicle_ts            timestamptz,
    received_at           timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (sample_id, received_at)
) PARTITION BY RANGE (received_at);

CREATE INDEX IF NOT EXISTS veh_samples_veh_ts_idx
    ON rt.vehicle_samples (vehicle_id, received_at DESC);
CREATE INDEX IF NOT EXISTS veh_samples_trip_ts_idx
    ON rt.vehicle_samples (trip_id, received_at DESC)
    WHERE trip_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS veh_samples_route_ts_idx
    ON rt.vehicle_samples (route_id, received_at DESC)
    WHERE route_id IS NOT NULL;
COMMENT ON TABLE rt.vehicle_samples IS
    'Append-only history. Partitioned daily (America/Toronto day boundaries). '
    'Retention via DROP TABLE.';

--  Safety net for inserts that arrive before their daily partition exists.
--  rt.ensure_partition() drains it automatically when it creates the matching
--  day, so a missed cron run no longer blocks future partition creation.
CREATE TABLE IF NOT EXISTS rt.vehicle_samples_default
    PARTITION OF rt.vehicle_samples DEFAULT;
COMMENT ON TABLE rt.vehicle_samples_default IS
    'Rows here mean a daily partition was missing at insert time. '
    'Alert when ops.maintain() reports default_rows > 0.';


CREATE TABLE IF NOT EXISTS rt.trip_status (
    trip_id            text NOT NULL,
    service_date       date NOT NULL,
    vehicle_id         text,
    route_id           text,
    direction_id       smallint,
    pattern_id         text,
    schedule_relationship smallint,
    last_stop_id       text,
    last_stop_sequence integer,
    last_status        smallint,
    next_stop_id       text,
    next_stop_sequence integer,
    scheduled_next_at  timestamptz,
    predicted_next_at  timestamptz,
    delay_s            integer,
    lat                double precision,
    lon                double precision,
    bearing            real,
    speed_mps          real,
    received_at        timestamptz NOT NULL DEFAULT now(),
    is_active          boolean NOT NULL DEFAULT true,
    PRIMARY KEY (trip_id, service_date),
    CONSTRAINT trip_status_last_status_check CHECK (
        last_status IS NULL OR last_status BETWEEN 0 AND 99
    ),
    CONSTRAINT trip_status_sched_check CHECK (
        schedule_relationship IS NULL OR schedule_relationship BETWEEN 0 AND 99
    )
) WITH (
    fillfactor = 85,
    autovacuum_vacuum_scale_factor  = 0.01,
    autovacuum_analyze_scale_factor = 0.005
);
CREATE INDEX IF NOT EXISTS trip_status_route_idx
    ON rt.trip_status (route_id) WHERE is_active;
CREATE INDEX IF NOT EXISTS trip_status_vehicle_idx
    ON rt.trip_status (vehicle_id) WHERE vehicle_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS trip_status_age_idx
    ON rt.trip_status (received_at) WHERE is_active;
COMMENT ON TABLE rt.trip_status IS
    'One row per active trip. Ride tracker reads by (trip_id, service_date). '
    'Derive service_date with rt.infer_service_date() when the feed omits it.';
COMMENT ON COLUMN rt.trip_status.schedule_relationship IS
    'GTFS-RT TripDescriptor.ScheduleRelationship: 0 SCHEDULED, 1 ADDED, '
    '2 UNSCHEDULED, 3 CANCELED, 4 REPLACEMENT, 5 DUPLICATED, 6 DELETED, '
    '7 NEW. 1 and 7 both mean live "added service" trips.';


CREATE TABLE IF NOT EXISTS rt.stop_eta (
    trip_id       text NOT NULL,
    service_date  date NOT NULL,
    stop_sequence integer NOT NULL,          -- RAW GTFS-RT value
    stop_id       text NOT NULL,
    scheduled_at  timestamptz,
    predicted_at  timestamptz,
    delay_s       integer,
    is_skipped    boolean NOT NULL DEFAULT false,
    received_at   timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (trip_id, service_date, stop_sequence)
) WITH (
    fillfactor = 85,
    autovacuum_vacuum_scale_factor  = 0.02,
    autovacuum_analyze_scale_factor = 0.01
);
CREATE INDEX IF NOT EXISTS stop_eta_stop_time_idx
    ON rt.stop_eta (stop_id, predicted_at) WHERE NOT is_skipped;
CREATE INDEX IF NOT EXISTS stop_eta_age_idx ON rt.stop_eta (received_at);


-- ---------- Alerts ----------------------------------------------------------

CREATE TABLE IF NOT EXISTS rt.alert (
    alert_id             text PRIMARY KEY,
    cause                smallint,
    effect               smallint,
    severity_level       smallint,
    header_text          text,
    description_text     text,
    tts_header_text      text,
    tts_description_text text,
    url                  text,
    active_from          timestamptz,
    active_until         timestamptz,
    received_at          timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT alert_cause_check    CHECK (cause IS NULL OR cause BETWEEN 0 AND 99),
    CONSTRAINT alert_effect_check   CHECK (effect IS NULL OR effect BETWEEN 0 AND 99),
    CONSTRAINT alert_severity_check CHECK (severity_level IS NULL
                                           OR severity_level BETWEEN 0 AND 99)
);
CREATE INDEX IF NOT EXISTS alert_active_time_idx
    ON rt.alert (active_from, active_until);
CREATE INDEX IF NOT EXISTS alert_effect_idx
    ON rt.alert (effect) WHERE effect IS NOT NULL;
CREATE INDEX IF NOT EXISTS alert_age_idx
    ON rt.alert (received_at);
COMMENT ON TABLE rt.alert IS
    'One row per active GTFS-RT alert. effect 4 = DETOUR; effect IN (1,2,3) = '
    'service disruption. Refreshed each realtime cycle; swept by rt.sweep_stale().';


-- (alert_id) leads each primary key below, so no separate alert_id index.
CREATE TABLE IF NOT EXISTS rt.alert_active_period (
    alert_id text NOT NULL,
    ordinal  integer NOT NULL,
    start_at timestamptz,
    end_at   timestamptz,
    PRIMARY KEY (alert_id, ordinal)
);


CREATE TABLE IF NOT EXISTS rt.alert_informed_entity (
    alert_id     text NOT NULL,
    ordinal      integer NOT NULL,
    agency_id    text,
    route_id     text,
    route_type   smallint,
    direction_id smallint,
    trip_id      text,
    stop_id      text,
    PRIMARY KEY (alert_id, ordinal)
);
CREATE INDEX IF NOT EXISTS alert_informed_route_idx
    ON rt.alert_informed_entity (route_id) WHERE route_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS alert_informed_stop_idx
    ON rt.alert_informed_entity (stop_id) WHERE stop_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS alert_informed_trip_idx
    ON rt.alert_informed_entity (trip_id) WHERE trip_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS alert_informed_unique_idx
    ON rt.alert_informed_entity (
        alert_id,
        COALESCE(agency_id, ''),
        COALESCE(route_id, ''),
        COALESCE(route_type, -1),
        COALESCE(direction_id, -1),
        COALESCE(trip_id, ''),
        COALESCE(stop_id, '')
    );
COMMENT ON INDEX rt.alert_informed_unique_idx IS
    'Forces dedup. The ingester inserts with ON CONFLICT DO NOTHING so the '
    'feed can repeat the same entity without error.';


-- ============================================================================
--  SECTION 5 — Helper functions
-- ============================================================================

-- GTFS service_second parser. Handles "HH:MM:SS" with H possibly > 24.
CREATE OR REPLACE FUNCTION core.parse_service_second(t text)
RETURNS integer LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
        WHEN t IS NULL OR btrim(t) = '' THEN NULL
        ELSE split_part(btrim(t),':',1)::int * 3600
           + split_part(btrim(t),':',2)::int * 60
           + split_part(btrim(t),':',3)::int
    END;
$$;
COMMENT ON FUNCTION core.parse_service_second IS
    'Parse "30:52:41" -> 111161. Handles GTFS times past midnight.';


-- GTFS measures service time from "noon minus 12 hours" of the service day,
-- which differs from midnight on DST-change days.
CREATE OR REPLACE FUNCTION core.resolve_departure(d date, ss integer)
RETURNS timestamptz LANGUAGE sql STABLE AS $$
    SELECT ((d + time '12:00') AT TIME ZONE 'America/Toronto')
           + make_interval(secs => (ss - 43200));
$$;
COMMENT ON FUNCTION core.resolve_departure IS
    '(service_date, service_second) -> timestamptz using the GTFS '
    '"noon minus 12h" anchor. Correct across DST transitions. STABLE (tz '
    'rules can change).';


-- Ensure the daily partition of rt.vehicle_samples exists. If rows for that
-- day already landed in the default partition, they are moved into the new
-- partition (a plain CREATE ... PARTITION OF would fail on the overlap).
CREATE OR REPLACE FUNCTION rt.ensure_partition(p_date date)
RETURNS void LANGUAGE plpgsql AS $$
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
COMMENT ON FUNCTION rt.ensure_partition IS
    'Idempotent. Boundaries are America/Toronto midnights (explicit offset), '
    'so the session timezone is irrelevant. Drains matching default rows.';


-- Drop daily partitions older than p_keep_days (and stale default rows).
CREATE OR REPLACE FUNCTION rt.drop_old_partitions(p_keep_days int DEFAULT 2)
RETURNS integer LANGUAGE plpgsql AS $$
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


-- Sweep stale realtime rows. Call from the realtime loop (cheap).
CREATE OR REPLACE FUNCTION rt.sweep_stale(p_max_age interval DEFAULT interval '10 minutes')
RETURNS jsonb LANGUAGE plpgsql AS $$
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

    -- One statement = one snapshot: an alert refreshed by the ingester during
    -- the sweep is either fully kept or fully removed, never left without its
    -- periods/entities.
    WITH doomed AS (
        DELETE FROM rt.alert
        WHERE (active_until IS NOT NULL AND active_until < now() - interval '1 hour')
           OR received_at < now() - interval '6 hours'
        RETURNING alert_id
    ), p AS (
        DELETE FROM rt.alert_active_period
        WHERE alert_id IN (SELECT alert_id FROM doomed) RETURNING 1
    ), e AS (
        DELETE FROM rt.alert_informed_entity
        WHERE alert_id IN (SELECT alert_id FROM doomed) RETURNING 1
    )
    SELECT (SELECT count(*) FROM doomed), (SELECT count(*) FROM p),
           (SELECT count(*) FROM e)
    INTO n_alert, n_period, n_entity;

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


-- Pick the service_date of a realtime trip. GTFS-RT start_date is optional;
-- when absent, choose the scheduled run of this trip (today or yesterday,
-- the only dates an overnight trip can belong to) closest to p_ts.
CREATE OR REPLACE FUNCTION rt.infer_service_date(
    p_trip_id    text,
    p_ts         timestamptz,
    p_start_date date DEFAULT NULL
) RETURNS date LANGUAGE sql STABLE AS $$
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
COMMENT ON FUNCTION rt.infer_service_date IS
    'Explicit start_date wins; else the scheduled service_date (today or '
    'yesterday) whose run of the trip is nearest p_ts; else the local date.';


-- ============================================================================
--  SECTION 6 — ref.roll_forward()  (daily) and ref.rebuild()  (new feed)
-- ============================================================================

-- Slide the derive window to [ops.today()-1, +horizon-1] without touching the
-- feed: refresh service_days, drop departures outside the window, and insert
-- only the dates that are not materialized yet. Cheap enough to run nightly.
CREATE OR REPLACE FUNCTION ref.roll_forward(p_horizon_days integer DEFAULT NULL)
RETURNS bigint LANGUAGE plpgsql AS $$
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
COMMENT ON FUNCTION ref.roll_forward IS
    'Daily window slide. Needs no feed argument (reads ref.state). Raises if '
    'the feed has no service left, so the cron job fails loudly.';


-- Rebuild everything in ref.* from one feed. Runs in the caller''s
-- transaction; DELETE (not TRUNCATE) keeps readers unblocked and the swap
-- atomic. Call it through ops.activate_feed() so the pointer flips in the
-- same transaction.
CREATE OR REPLACE FUNCTION ref.rebuild(
    p_feed         text,
    p_horizon_days integer DEFAULT 14
) RETURNS void LANGUAGE plpgsql AS $$
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
COMMENT ON FUNCTION ref.rebuild IS
    'Rebuild all ref.* tables from core.* for one feed. Atomic with the '
    'caller''s transaction. Raises if ops.units has no row for the feed.';


-- ============================================================================
--  SECTION 7 — cur.* views (explicit columns; units normalized to meters)
-- ============================================================================

CREATE OR REPLACE VIEW cur.feed_info AS
SELECT feed_version, publisher_name, publisher_url, lang, start_date, end_date
FROM core.feed_info WHERE feed_version = ops.active_version();

CREATE OR REPLACE VIEW cur.agency AS
SELECT feed_version, agency_id, name, url, timezone, lang, phone, email, fare_url
FROM core.agency WHERE feed_version = ops.active_version();

CREATE OR REPLACE VIEW cur.routes AS
SELECT feed_version, route_id, agency_id, route_short_name, route_long_name,
       route_desc, route_type, route_url, route_color, route_text_color,
       route_sort_order
FROM core.routes WHERE feed_version = ops.active_version();

CREATE OR REPLACE VIEW cur.stops AS
SELECT feed_version, stop_id, stop_code, stop_name, stop_desc,
       stop_lat, stop_lon, zone_id, stop_url, location_type, parent_station,
       stop_timezone, wheelchair_boarding, level_id, platform_code,
       tts_stop_name
FROM core.stops WHERE feed_version = ops.active_version();

CREATE OR REPLACE VIEW cur.trips AS
SELECT feed_version, trip_id, route_id, service_id, trip_headsign,
       trip_short_name, direction_id, block_id, shape_id,
       wheelchair_accessible, bikes_allowed
FROM core.trips WHERE feed_version = ops.active_version();

-- shape_dist_traveled here is METERS (raw * stop_scale); NULL if the feed has
-- no ops.units row, never a silently wrong number.
CREATE OR REPLACE VIEW cur.stop_times AS
SELECT st.feed_version, st.trip_id, st.stop_sequence, st.stop_id,
       st.arrival_time, st.departure_time, st.stop_headsign, st.pickup_type,
       st.drop_off_type,
       st.shape_dist_traveled * u.stop_scale AS shape_dist_traveled,
       st.timepoint
FROM core.stop_times st
LEFT JOIN ops.units u ON u.feed_version = st.feed_version
WHERE st.feed_version = ops.active_version();

-- shape_dist_traveled here is METERS (raw * shape_scale); see above.
CREATE OR REPLACE VIEW cur.shapes AS
SELECT s.feed_version, s.shape_id, s.shape_pt_sequence, s.shape_pt_lat,
       s.shape_pt_lon,
       s.shape_dist_traveled * u.shape_scale AS shape_dist_traveled
FROM core.shapes s
LEFT JOIN ops.units u ON u.feed_version = s.feed_version
WHERE s.feed_version = ops.active_version();

CREATE OR REPLACE VIEW cur.calendar AS
SELECT feed_version, service_id, monday, tuesday, wednesday, thursday,
       friday, saturday, sunday, start_date, end_date
FROM core.calendar WHERE feed_version = ops.active_version();

CREATE OR REPLACE VIEW cur.calendar_dates AS
SELECT feed_version, service_id, service_date, exception_type
FROM core.calendar_dates WHERE feed_version = ops.active_version();

CREATE OR REPLACE VIEW cur.levels AS
SELECT feed_version, level_id, level_index, level_name
FROM core.levels WHERE feed_version = ops.active_version();

CREATE OR REPLACE VIEW cur.pathways AS
SELECT feed_version, pathway_id, from_stop_id, to_stop_id, pathway_mode,
       is_bidirectional, length, traversal_time, stair_count, max_slope,
       min_width, signposted_as, reversed_signposted_as
FROM core.pathways WHERE feed_version = ops.active_version();

CREATE OR REPLACE VIEW cur.transfers AS
SELECT feed_version, from_stop_id, to_stop_id,
       from_route_id, to_route_id, from_trip_id, to_trip_id,
       transfer_type, min_transfer_time
FROM core.transfers WHERE feed_version = ops.active_version();

CREATE OR REPLACE VIEW cur.frequencies AS
SELECT feed_version, trip_id, start_time, end_time, headway_secs, exact_times
FROM core.frequencies WHERE feed_version = ops.active_version();

CREATE OR REPLACE VIEW rt.vehicle_now AS
SELECT vehicle_id, trip_id, route_id, direction_id, schedule_relationship,
       lat, lon, bearing, speed_mps, current_stop_id, current_stop_sequence,
       current_status, occupancy, vehicle_ts, received_at
FROM rt.vehicle_latest
WHERE received_at > now() - interval '5 minutes';

CREATE OR REPLACE VIEW rt.trip_now AS
SELECT trip_id, service_date, vehicle_id, route_id, direction_id, pattern_id,
       schedule_relationship, last_stop_id, last_stop_sequence, last_status,
       next_stop_id, next_stop_sequence, scheduled_next_at, predicted_next_at,
       delay_s, lat, lon, bearing, speed_mps, received_at, is_active
FROM rt.trip_status
WHERE is_active;

CREATE OR REPLACE VIEW rt.active_alerts AS
SELECT alert_id, cause, effect, severity_level,
       header_text, description_text, tts_header_text, tts_description_text,
       url, active_from, active_until, received_at
FROM rt.alert
WHERE (active_from IS NULL OR active_from <= now())
  AND (active_until IS NULL OR active_until >= now());
COMMENT ON VIEW rt.active_alerts IS
    'Alerts whose own time window contains now(). Does not check freshness: '
    'an alert with no end time stays listed until rt.sweep_stale() removes it '
    '(6 h after the ingester last refreshed it).';


-- ============================================================================
--  SECTION 8 — Orchestration entry points
-- ============================================================================

-- Rebuild ref.* from a loaded feed AND flip the active pointer. One statement
-- = one transaction: readers see the old feed or the new feed, never a mix.
CREATE OR REPLACE FUNCTION ops.activate_feed(
    p_source       text,
    p_feed         text,
    p_horizon_days integer DEFAULT 14
) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    PERFORM ref.rebuild(p_feed, p_horizon_days);
    INSERT INTO ops.feed (source, feed_version, activated_at)
    VALUES (p_source, p_feed, now())
    ON CONFLICT (source) DO UPDATE
        SET feed_version = EXCLUDED.feed_version,
            activated_at = EXCLUDED.activated_at;
END;
$$;
COMMENT ON FUNCTION ops.activate_feed IS
    'ref.rebuild + ops.feed flip in one transaction. Call as a single statement.';


-- Nightly job. Timezone-independent (uses ops.today()). Run from cron, and
-- alert on a non-zero exit or default_rows > 0.
CREATE OR REPLACE FUNCTION ops.maintain()
RETURNS jsonb LANGUAGE plpgsql AS $$
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
COMMENT ON FUNCTION ops.maintain IS
    'Nightly: ensure partitions, drop old ones, sweep realtime, roll the '
    'departures window. Returns a JSON health report.';


-- ============================================================================
--  SECTION 9 — Initial partitions
-- ============================================================================

SELECT rt.ensure_partition(ops.today());
SELECT rt.ensure_partition(ops.today() + 1);
SELECT rt.ensure_partition(ops.today() + 2);


-- ============================================================================
--  END OF SCHEMA v1.8
-- ============================================================================
--
--  Load sequence (once per new feed; services/database/tools/load_gtfs.sh):
--    1. BEGIN;
--         DELETE FROM core.<table> WHERE feed_version = $new;   -- idempotent
--         COPY core.<table> ...;                                -- RAW values
--       COMMIT;
--    2. Detect units; upsert ops.units (feed_version, shape_scale, stop_scale).
--    3. SELECT ops.activate_feed('ttc', '$new', 14);   -- one transaction
--    4. SELECT ops.gc_old_feeds('ttc', 2);
--
--  Realtime loop (ingester; feed URLs live in its config):
--    UPSERT rt.vehicle_latest / rt.trip_status / rt.stop_eta
--      (service_date := rt.infer_service_date(trip_id, now(), start_date);
--       all *_sequence values are the raw GTFS-RT stop_sequence)
--    INSERT rt.vehicle_samples
--    Alerts: refresh rt.alert / alert_active_period / alert_informed_entity
--      (insert entities with ON CONFLICT DO NOTHING)
--    SELECT rt.sweep_stale();
--
--  Nightly (services/database maintainer container, every 12 h):
--    SELECT ops.maintain();
--
--  Monitoring (from the ops.maintain() result):
--    default_rows > 0           -> a daily partition was missing; rows drained
--    feed_days_remaining < 5    -> TTC feed about to expire; load a new one
--    SELECT max(received_at) FROM rt.vehicle_latest   -- must be < 60s ago
--
-- ============================================================================
-- >>>>>>>>>> END PART: 001_gtfs_realtime_v1.8.sql <<<<<<<<<<

-- >>>>>>>>>> BEGIN PART: 008_user_schema.sql <<<<<<<<<<
-- ============================================================================
-- 008_user_schema.sql
-- User identity, auth, consent, devices, billing.
-- Replaces any earlier 008 (do not apply both). Requires ops.schema_version.
--
-- Roles
--   ttc_app      API role. Subject to RLS; sees only the current user's rows.
--                Cannot read secrets (recovery key, token hash, encrypted PII)
--                and cannot write guarded state (account status, consent).
--   ttc_auth_fn  NOLOGIN. Owns SECURITY DEFINER functions that must run before
--                the user is known (auth lookups) or write guarded columns
--                (consent, account deletion state).
--   ttc_worker   NOLOGIN here (ops: ALTER ROLE ... LOGIN). Background jobs.
--
-- Request contract (API):
--   BEGIN;
--   SELECT set_config('app.user_id', '<uuid>', true);   -- tx-local, always
--   ... queries ...
--   COMMIT;
--
-- The migration role must be a superuser, or a member of ttc_auth_fn and
-- ttc_worker, so ALTER FUNCTION ... OWNER TO works.
-- ============================================================================

BEGIN;

CREATE SCHEMA IF NOT EXISTS app;
COMMENT ON SCHEMA app IS 'Per-user data. RLS-protected. Never joined to data.*.';

-- ----------------------------------------------------------------------------
-- 0. Roles and helpers
-- ----------------------------------------------------------------------------

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

CREATE OR REPLACE FUNCTION app.touch_updated_at() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END $$;

-- ----------------------------------------------------------------------------
-- 1. app.account
-- ----------------------------------------------------------------------------

CREATE TABLE app.account (
  user_id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),

  -- recovery_key_lookup = HMAC-SHA256(server pepper, key): deterministic, indexed.
  -- recovery_key_hash   = Argon2id (salt embedded), used only to verify.
  recovery_key_lookup     bytea NOT NULL UNIQUE,
  recovery_key_hash       text  NOT NULL,
  recovery_key_updated_at timestamptz NOT NULL DEFAULT now(),

  created_at              timestamptz NOT NULL DEFAULT now(),
  updated_at              timestamptz NOT NULL DEFAULT now(),
  last_active_at          timestamptz,

  status                  text NOT NULL DEFAULT 'active'
                          CHECK (status IN
                            ('active','suspended','pending_deletion','deleted')),
  deletion_requested_at   timestamptz,
  deletion_scheduled_at   timestamptz,

  referral_code           text UNIQUE,
  referred_by             uuid REFERENCES app.account(user_id) ON DELETE SET NULL,
  feature_flags           jsonb NOT NULL DEFAULT '{}'::jsonb,

  install_count           integer NOT NULL DEFAULT 1 CHECK (install_count >= 1),
  first_install_at        timestamptz NOT NULL DEFAULT now(),
  app_version_at_signup   text,
  platform_at_signup      text CHECK (platform_at_signup IN ('ios','android')),

  CONSTRAINT account_deletion_chk CHECK (
    status <> 'pending_deletion'
    OR (deletion_requested_at IS NOT NULL AND deletion_scheduled_at IS NOT NULL)),
  CONSTRAINT account_no_self_referral CHECK (referred_by <> user_id)
);

CREATE INDEX app_account_status_active_idx
  ON app.account (status) WHERE status = 'active';
CREATE INDEX app_account_deletion_scheduled_idx
  ON app.account (deletion_scheduled_at) WHERE deletion_scheduled_at IS NOT NULL;
CREATE INDEX app_account_referred_by_idx
  ON app.account (referred_by) WHERE referred_by IS NOT NULL;

CREATE TRIGGER trg_account_touch BEFORE UPDATE ON app.account
  FOR EACH ROW EXECUTE FUNCTION app.touch_updated_at();

-- ----------------------------------------------------------------------------
-- 2. app.user_contact: optional PII (hashes are HMAC with a pepper)
-- ----------------------------------------------------------------------------

CREATE TABLE app.user_contact (
  user_id            uuid PRIMARY KEY REFERENCES app.account(user_id) ON DELETE CASCADE,

  email_hash         text UNIQUE,
  email_encrypted    bytea,
  email_verified_at  timestamptz,

  phone_hash         text UNIQUE,
  phone_encrypted    bytea,
  phone_verified_at  timestamptz,

  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now()
);

CREATE TRIGGER trg_user_contact_touch BEFORE UPDATE ON app.user_contact
  FOR EACH ROW EXECUTE FUNCTION app.touch_updated_at();

-- ----------------------------------------------------------------------------
-- 3. app.user_preferences
-- ----------------------------------------------------------------------------

CREATE TABLE app.user_preferences (
  user_id                uuid PRIMARY KEY REFERENCES app.account(user_id) ON DELETE CASCADE,

  locale                 text    NOT NULL DEFAULT 'en',
  timezone               text    NOT NULL DEFAULT 'America/Toronto',   -- IANA; API validates
  time_format            text    NOT NULL DEFAULT '24h'
                         CHECK (time_format IN ('12h','24h')),
  theme                  text    NOT NULL DEFAULT 'auto'
                         CHECK (theme IN ('light','dark','auto')),
  units                  text    NOT NULL DEFAULT 'metric'
                         CHECK (units IN ('metric','imperial')),

  wheelchair_mode        boolean NOT NULL DEFAULT false,
  avoid_stairs           boolean NOT NULL DEFAULT false,
  reduced_motion         boolean NOT NULL DEFAULT false,
  color_blind_mode       boolean NOT NULL DEFAULT false,
  large_text             boolean NOT NULL DEFAULT false,

  walk_speed_mps         numeric(4,2) NOT NULL DEFAULT 1.40
                         CHECK (walk_speed_mps BETWEEN 0.3 AND 3.0),
  detour_factor          numeric(4,2) NOT NULL DEFAULT 1.30
                         CHECK (detour_factor BETWEEN 1.0 AND 3.0),
  max_walk_m             integer NOT NULL DEFAULT 800
                         CHECK (max_walk_m BETWEEN 50 AND 10000),
  max_transfers          smallint NOT NULL DEFAULT 3
                         CHECK (max_transfers BETWEEN 0 AND 10),
  prefer_less_walking    boolean NOT NULL DEFAULT false,
  prefer_fewer_transfers boolean NOT NULL DEFAULT true,

  notifications_enabled  boolean NOT NULL DEFAULT true,
  notify_leave_now       boolean NOT NULL DEFAULT true,
  notify_service_alerts  boolean NOT NULL DEFAULT true,
  notify_commute         boolean NOT NULL DEFAULT false,
  -- Local hours (0-23) in `timezone`. Both set or both null.
  quiet_hours_start      smallint CHECK (quiet_hours_start BETWEEN 0 AND 23),
  quiet_hours_end        smallint CHECK (quiet_hours_end   BETWEEN 0 AND 23),

  updated_at             timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT quiet_hours_pair_chk CHECK (
    (quiet_hours_start IS NULL) = (quiet_hours_end IS NULL))
);

CREATE TRIGGER trg_user_preferences_touch BEFORE UPDATE ON app.user_preferences
  FOR EACH ROW EXECUTE FUNCTION app.touch_updated_at();

-- ----------------------------------------------------------------------------
-- 4. app.user_consent (current state) + app.consent_event (append-only proof)
--    ttc_app can NOT write consent columns directly; use app.record_consent().
-- ----------------------------------------------------------------------------

CREATE TABLE app.user_consent (
  user_id                     uuid PRIMARY KEY REFERENCES app.account(user_id) ON DELETE CASCADE,

  trip_recording              boolean NOT NULL DEFAULT false,
  trip_contribution           boolean NOT NULL DEFAULT false,
  segment_contribution        boolean NOT NULL DEFAULT false,
  analytics_opt_in            boolean NOT NULL DEFAULT false,
  -- Use location during an active commitment (missed-vehicle + get-off detection).
  live_trip_tracking          boolean NOT NULL DEFAULT false,
  -- Send current location to pick a nearby challenge.
  challenge_location          boolean NOT NULL DEFAULT false,

  location_permission_asked_at   timestamptz,
  location_permission_granted_at timestamptz,

  consented_at                timestamptz,
  revoked_at                  timestamptz,
  updated_at                  timestamptz NOT NULL DEFAULT now()
);

CREATE TRIGGER trg_user_consent_touch BEFORE UPDATE ON app.user_consent
  FOR EACH ROW EXECUTE FUNCTION app.touch_updated_at();

CREATE TABLE app.consent_event (
  event_id        bigserial PRIMARY KEY,
  user_id         uuid NOT NULL REFERENCES app.account(user_id) ON DELETE CASCADE,
  purpose         text NOT NULL CHECK (purpose IN
                    ('trip_recording','trip_contribution',
                     'segment_contribution','analytics_opt_in',
                     'live_trip_tracking','challenge_location')),
  granted         boolean NOT NULL,
  policy_version  text NOT NULL,
  occurred_at     timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX app_consent_event_user_idx
  ON app.consent_event (user_id, occurred_at DESC);

-- ----------------------------------------------------------------------------
-- 5. app.session + app.device
-- ----------------------------------------------------------------------------

CREATE TABLE app.session (
  session_id      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         uuid NOT NULL REFERENCES app.account(user_id) ON DELETE CASCADE,
  token_hash      text NOT NULL UNIQUE,       -- SHA-256 of a 256-bit random token
  platform        text NOT NULL CHECK (platform IN ('ios','android')),
  app_version     text NOT NULL,
  os_version      text,
  model           text,
  created_at      timestamptz NOT NULL DEFAULT now(),
  last_used_at    timestamptz NOT NULL DEFAULT now(),
  expires_at      timestamptz NOT NULL,
  revoked_at      timestamptz,
  revoked_reason  text CHECK (revoked_reason IN
                    ('logout','phrase_reset','admin','expired'))
);

CREATE INDEX app_session_user_active_idx
  ON app.session (user_id) WHERE revoked_at IS NULL;
CREATE INDEX app_session_expires_idx
  ON app.session (expires_at) WHERE revoked_at IS NULL;

CREATE TABLE app.device (
  device_id       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         uuid NOT NULL REFERENCES app.account(user_id) ON DELETE CASCADE,
  session_id      uuid REFERENCES app.session(session_id) ON DELETE SET NULL,

  platform        text NOT NULL CHECK (platform IN ('ios','android')),
  push_provider   text NOT NULL CHECK (push_provider IN ('apns','fcm')),
  push_token      text NOT NULL,
  app_version     text,
  locale          text,

  created_at      timestamptz NOT NULL DEFAULT now(),
  last_seen_at    timestamptz NOT NULL DEFAULT now(),
  invalidated_at  timestamptz,

  UNIQUE (push_provider, push_token),
  -- Target for composite FKs (device-scoped rows in 009 can't cross users).
  UNIQUE (device_id, user_id)
);

CREATE INDEX app_device_user_active_idx
  ON app.device (user_id) WHERE invalidated_at IS NULL;

CREATE OR REPLACE FUNCTION app.prevent_device_reassign() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.user_id <> OLD.user_id THEN
    RAISE EXCEPTION 'device.user_id is immutable';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_device_no_reassign BEFORE UPDATE ON app.device
  FOR EACH ROW EXECUTE FUNCTION app.prevent_device_reassign();

-- ----------------------------------------------------------------------------
-- 6. app.subscription + app.subscription_event
--    Written by ttc_worker (verified webhooks / receipt checks).
--    user_id is SET NULL on deletion: billing records may be retained, but
--    must stop pointing at a person. Keep event payloads free of PII.
-- ----------------------------------------------------------------------------

CREATE TABLE app.subscription (
  subscription_id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id                   uuid REFERENCES app.account(user_id) ON DELETE SET NULL,
  plan                      text NOT NULL,
  status                    text NOT NULL CHECK (status IN
                              ('active','past_due','canceled','expired','trialing')),
  provider                  text NOT NULL CHECK (provider IN
                              ('app_store','play_store','stripe')),
  provider_customer_id      text,
  provider_subscription_id  text,
  current_period_start      timestamptz,
  current_period_end        timestamptz,
  created_at                timestamptz NOT NULL DEFAULT now(),
  updated_at                timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX app_subscription_user_idx   ON app.subscription (user_id);
CREATE INDEX app_subscription_active_idx ON app.subscription (user_id) WHERE status = 'active';
CREATE UNIQUE INDEX app_subscription_provider_sub_uidx
  ON app.subscription (provider, provider_subscription_id)
  WHERE provider_subscription_id IS NOT NULL;

CREATE TRIGGER trg_subscription_touch BEFORE UPDATE ON app.subscription
  FOR EACH ROW EXECUTE FUNCTION app.touch_updated_at();

CREATE TABLE app.subscription_event (
  event_id           bigserial PRIMARY KEY,
  subscription_id    uuid NOT NULL REFERENCES app.subscription(subscription_id) ON DELETE RESTRICT,
  provider           text NOT NULL CHECK (provider IN ('app_store','play_store','stripe')),
  provider_event_id  text NOT NULL,       -- webhook retry idempotency
  event_type         text NOT NULL,
  payload            jsonb NOT NULL,
  occurred_at        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (provider, provider_event_id)
);

CREATE INDEX app_subscription_event_sub_idx
  ON app.subscription_event (subscription_id, occurred_at DESC);

-- ----------------------------------------------------------------------------
-- 7. app.deletion_audit (ops only; no FK, the user is gone)
-- ----------------------------------------------------------------------------

CREATE TABLE app.deletion_audit (
  deletion_id    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id        uuid NOT NULL,
  requested_at   timestamptz NOT NULL,
  executed_at    timestamptz,
  rows_deleted   jsonb,
  notes          text
);

CREATE INDEX app_deletion_audit_user_idx ON app.deletion_audit (user_id);

-- ----------------------------------------------------------------------------
-- 8. Row level security (explicit WITH CHECK; FORCE binds the table owner too)
-- ----------------------------------------------------------------------------

DO $$
DECLARE t text;
BEGIN
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

  -- Read-only for ttc_app; writes go through app.record_consent().
  ALTER TABLE app.consent_event ENABLE ROW LEVEL SECURITY;
  ALTER TABLE app.consent_event FORCE ROW LEVEL SECURITY;
  CREATE POLICY owner_select ON app.consent_event FOR SELECT TO ttc_app
    USING (user_id = app.current_user_id());

  -- Ops-only: RLS on with no ttc_app policy = default deny.
  ALTER TABLE app.subscription_event ENABLE ROW LEVEL SECURITY;
  ALTER TABLE app.subscription_event FORCE ROW LEVEL SECURITY;
  ALTER TABLE app.deletion_audit ENABLE ROW LEVEL SECURITY;
  ALTER TABLE app.deletion_audit FORCE ROW LEVEL SECURITY;

  -- Worker: all rows.
  FOREACH t IN ARRAY ARRAY['account','user_contact','user_preferences',
                           'user_consent','consent_event','session','device',
                           'subscription','subscription_event','deletion_audit']
  LOOP
    EXECUTE format($p$CREATE POLICY worker_all ON app.%I FOR ALL TO ttc_worker
                      USING (true) WITH CHECK (true)$p$, t);
  END LOOP;
END $$;

-- Definer role: auth lookups happen before the user is known.
CREATE POLICY auth_fn_all ON app.account FOR ALL TO ttc_auth_fn
  USING (true) WITH CHECK (true);
CREATE POLICY auth_fn_all ON app.session FOR ALL TO ttc_auth_fn
  USING (true) WITH CHECK (true);
-- Consent functions act on behalf of the current user only.
CREATE POLICY auth_fn_self ON app.user_consent FOR ALL TO ttc_auth_fn
  USING (user_id = app.current_user_id())
  WITH CHECK (user_id = app.current_user_id());
CREATE POLICY auth_fn_self ON app.consent_event FOR ALL TO ttc_auth_fn
  USING (user_id = app.current_user_id())
  WITH CHECK (user_id = app.current_user_id());

-- ----------------------------------------------------------------------------
-- 9. Grants
-- ----------------------------------------------------------------------------

-- account: ttc_app never reads recovery credentials and cannot change status.
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
              last_active_at, install_count)
  ON app.account TO ttc_app;
-- status / deletion_*: only via app.request_deletion() / app.cancel_deletion().

-- user_contact: no access to encrypted columns.
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

GRANT SELECT, INSERT, UPDATE ON app.user_preferences TO ttc_app;

-- consent: read, seed the row, record OS permission timestamps. Nothing else.
GRANT SELECT ON app.user_consent TO ttc_app;
GRANT INSERT (user_id) ON app.user_consent TO ttc_app;
GRANT UPDATE (location_permission_asked_at, location_permission_granted_at)
  ON app.user_consent TO ttc_app;
GRANT SELECT ON app.consent_event TO ttc_app;

-- session: ttc_app never reads token_hash back.
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

-- Definer role.
GRANT SELECT ON app.account TO ttc_auth_fn;
GRANT UPDATE (status, deletion_requested_at, deletion_scheduled_at)
  ON app.account TO ttc_auth_fn;
GRANT SELECT ON app.session TO ttc_auth_fn;
GRANT UPDATE (last_used_at) ON app.session TO ttc_auth_fn;
GRANT SELECT, UPDATE ON app.user_consent TO ttc_auth_fn;
GRANT SELECT, INSERT ON app.consent_event TO ttc_auth_fn;
GRANT USAGE ON SEQUENCE app.consent_event_event_id_seq TO ttc_auth_fn;

-- Worker.
GRANT ALL ON ALL TABLES    IN SCHEMA app TO ttc_worker;
GRANT ALL ON ALL SEQUENCES IN SCHEMA app TO ttc_worker;

-- ----------------------------------------------------------------------------
-- 10. Functions
-- ----------------------------------------------------------------------------

-- Signup. The id is generated here and set tx-locally BEFORE the insert, so
-- the RLS WITH CHECK passes and the seed trigger can write the child rows.
-- Runs as the caller (ttc_app).
CREATE OR REPLACE FUNCTION app.create_account(
  p_recovery_key_lookup bytea,
  p_recovery_key_hash   text,
  p_platform            text,
  p_app_version         text
) RETURNS uuid
LANGUAGE plpgsql AS $$
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

-- 009 redefines this to seed its 1:1 tables too.
CREATE OR REPLACE FUNCTION app.seed_user_defaults()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO app.user_preferences (user_id) VALUES (NEW.user_id) ON CONFLICT DO NOTHING;
  INSERT INTO app.user_consent     (user_id) VALUES (NEW.user_id) ON CONFLICT DO NOTHING;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_seed_user_defaults
  AFTER INSERT ON app.account
  FOR EACH ROW EXECUTE FUNCTION app.seed_user_defaults();

-- Consent: append to the log and update the current-state row together.
CREATE OR REPLACE FUNCTION app.record_consent(
  p_purpose        text,
  p_granted        boolean,
  p_policy_version text
) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog
AS $$
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
    live_trip_tracking   = CASE WHEN p_purpose = 'live_trip_tracking'   THEN p_granted ELSE live_trip_tracking END,
    challenge_location   = CASE WHEN p_purpose = 'challenge_location'   THEN p_granted ELSE challenge_location END,
    consented_at         = CASE WHEN p_granted     THEN now() ELSE consented_at END,
    revoked_at           = CASE WHEN NOT p_granted THEN now() ELSE revoked_at END
  WHERE user_id = v_uid;
END $$;

-- Account deletion: 30-day grace, cancellable. The worker purges after
-- deletion_scheduled_at. Reminder jobs must skip pending_deletion accounts.
CREATE OR REPLACE FUNCTION app.request_deletion() RETURNS timestamptz
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_uid uuid := app.current_user_id();
  v_at  timestamptz := now() + interval '30 days';
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'app.user_id not set';
  END IF;
  UPDATE app.account
     SET status = 'pending_deletion',
         deletion_requested_at = now(),
         deletion_scheduled_at = v_at
   WHERE user_id = v_uid AND status = 'active';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'account is not active';
  END IF;
  RETURN v_at;
END $$;

CREATE OR REPLACE FUNCTION app.cancel_deletion() RETURNS void
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  v_uid uuid := app.current_user_id();
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'app.user_id not set';
  END IF;
  UPDATE app.account
     SET status = 'active',
         deletion_requested_at = NULL,
         deletion_scheduled_at = NULL
   WHERE user_id = v_uid AND status = 'pending_deletion';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'account is not pending deletion';
  END IF;
END $$;

-- Auth lookups run BEFORE app.user_id is known. pending_deletion accounts may
-- still log in (to cancel); suspended/deleted may not.
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

-- Ownership (needs CREATE on the schema temporarily).
GRANT CREATE ON SCHEMA app TO ttc_auth_fn;
ALTER FUNCTION app.auth_session_lookup(text)         OWNER TO ttc_auth_fn;
ALTER FUNCTION app.auth_recovery_lookup(bytea)       OWNER TO ttc_auth_fn;
ALTER FUNCTION app.record_consent(text, boolean, text) OWNER TO ttc_auth_fn;
ALTER FUNCTION app.request_deletion()                OWNER TO ttc_auth_fn;
ALTER FUNCTION app.cancel_deletion()                 OWNER TO ttc_auth_fn;
REVOKE CREATE ON SCHEMA app FROM ttc_auth_fn;

-- EXECUTE: ttc_app only.
REVOKE ALL ON FUNCTION app.auth_session_lookup(text)           FROM PUBLIC;
REVOKE ALL ON FUNCTION app.auth_recovery_lookup(bytea)         FROM PUBLIC;
REVOKE ALL ON FUNCTION app.record_consent(text, boolean, text) FROM PUBLIC;
REVOKE ALL ON FUNCTION app.request_deletion()                  FROM PUBLIC;
REVOKE ALL ON FUNCTION app.cancel_deletion()                   FROM PUBLIC;
REVOKE ALL ON FUNCTION app.create_account(bytea, text, text, text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION app.auth_session_lookup(text)           TO ttc_app;
GRANT EXECUTE ON FUNCTION app.auth_recovery_lookup(bytea)         TO ttc_app;
GRANT EXECUTE ON FUNCTION app.record_consent(text, boolean, text) TO ttc_app;
GRANT EXECUTE ON FUNCTION app.request_deletion()                  TO ttc_app;
GRANT EXECUTE ON FUNCTION app.cancel_deletion()                   TO ttc_app;
GRANT EXECUTE ON FUNCTION app.create_account(bytea, text, text, text) TO ttc_app;

INSERT INTO ops.schema_version (version, note) VALUES ('008', 'user model: account, auth, consent, devices, billing') ON CONFLICT DO NOTHING;

COMMIT;
-- >>>>>>>>>> END PART: 008_user_schema.sql <<<<<<<<<<

-- >>>>>>>>>> BEGIN PART: 009_commute_compass.sql <<<<<<<<<<
-- ============================================================================
-- 009_commute_compass.sql
-- Commitments, reminders, compass calibration, challenges.
-- Builds on 008_user_schema.sql.
--
-- Design rules
--   * Transit ids (route_id, stop_id, poi_id) are plain text, NO FK to data.*.
--   * Places that pin down a person (home, work, destinations) are encrypted.
--   * Location-derived signals (boarded, missed) need consent.live_trip_tracking.
--   * Compass calibration is per DEVICE (each magnetometer differs).
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. app.reminder_preferences (1:1)
-- ----------------------------------------------------------------------------

CREATE TABLE app.reminder_preferences (
  user_id                       uuid PRIMARY KEY REFERENCES app.account(user_id) ON DELETE CASCADE,

  leave_now_lead_min            smallint NOT NULL DEFAULT 5  CHECK (leave_now_lead_min BETWEEN 0 AND 60),
  default_buffer_min            smallint NOT NULL DEFAULT 3  CHECK (default_buffer_min BETWEEN 0 AND 60),

  disruption_briefing_enabled   boolean  NOT NULL DEFAULT true,
  briefing_lead_min             smallint NOT NULL DEFAULT 45 CHECK (briefing_lead_min BETWEEN 5 AND 240),
  disruption_updates_enabled    boolean  NOT NULL DEFAULT true,

  missed_vehicle_alert          boolean  NOT NULL DEFAULT true,

  getoff_alert_enabled          boolean  NOT NULL DEFAULT true,
  getoff_alert_stops_before     smallint NOT NULL DEFAULT 1  CHECK (getoff_alert_stops_before BETWEEN 0 AND 5),
  getoff_alert_style            text     NOT NULL DEFAULT 'both'
                                CHECK (getoff_alert_style IN ('notification','haptic','both')),
  getoff_compass_handoff        boolean  NOT NULL DEFAULT true,

  -- Quiet hours (008) never silence an in-progress trip.
  bypass_quiet_hours_in_trip    boolean  NOT NULL DEFAULT true,

  updated_at                    timestamptz NOT NULL DEFAULT now()
);

CREATE TRIGGER trg_reminder_preferences_touch BEFORE UPDATE ON app.reminder_preferences
  FOR EACH ROW EXECUTE FUNCTION app.touch_updated_at();

-- ----------------------------------------------------------------------------
-- 2. app.compass_preferences (1:1). Units come from user_preferences.units.
-- ----------------------------------------------------------------------------

CREATE TABLE app.compass_preferences (
  user_id            uuid PRIMARY KEY REFERENCES app.account(user_id) ON DELETE CASCADE,

  dial_style         text NOT NULL DEFAULT 'classic'
                     CHECK (dial_style IN ('classic','minimal','arrow')),
  heading_reference  text NOT NULL DEFAULT 'true_north'
                     CHECK (heading_reference IN ('true_north','magnetic_north')),

  haptic_guidance    boolean  NOT NULL DEFAULT true,
  haptic_intensity   smallint NOT NULL DEFAULT 2 CHECK (haptic_intensity BETWEEN 1 AND 3),
  audio_cues         boolean  NOT NULL DEFAULT false,
  show_distance      boolean  NOT NULL DEFAULT true,
  arrival_radius_m   smallint NOT NULL DEFAULT 25 CHECK (arrival_radius_m BETWEEN 10 AND 100),

  updated_at         timestamptz NOT NULL DEFAULT now()
);

CREATE TRIGGER trg_compass_preferences_touch BEFORE UPDATE ON app.compass_preferences
  FOR EACH ROW EXECUTE FUNCTION app.touch_updated_at();

-- ----------------------------------------------------------------------------
-- 3. app.device_calibration + app.calibration_event
--    The phone is the source of truth; this is backup + quality signal.
-- ----------------------------------------------------------------------------

CREATE TABLE app.device_calibration (
  device_id              uuid PRIMARY KEY,
  user_id                uuid NOT NULL,

  algorithm_version      text NOT NULL,
  hard_iron_offset_ut    real[]
                         CHECK (hard_iron_offset_ut IS NULL OR cardinality(hard_iron_offset_ut) = 3),
  soft_iron_matrix       real[]                         -- row-major 3x3
                         CHECK (soft_iron_matrix IS NULL OR cardinality(soft_iron_matrix) = 9),
  declination_override_deg real
                         CHECK (declination_override_deg IS NULL
                                OR declination_override_deg BETWEEN -90 AND 90),

  quality_score          real NOT NULL CHECK (quality_score BETWEEN 0 AND 1),
  sensor_accuracy        text CHECK (sensor_accuracy IN ('unreliable','low','medium','high')),
  sample_count           integer CHECK (sample_count >= 0),
  calibration_count      integer NOT NULL DEFAULT 1 CHECK (calibration_count >= 1),
  needs_recalibration    boolean NOT NULL DEFAULT false,

  calibrated_at          timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),

  FOREIGN KEY (device_id, user_id)
    REFERENCES app.device (device_id, user_id) ON DELETE CASCADE
);

CREATE TRIGGER trg_device_calibration_touch BEFORE UPDATE ON app.device_calibration
  FOR EACH ROW EXECUTE FUNCTION app.touch_updated_at();

-- Append-only. Worker prunes (suggest 180 days).
CREATE TABLE app.calibration_event (
  event_id           bigserial PRIMARY KEY,
  user_id            uuid NOT NULL,
  device_id          uuid NOT NULL,
  event_type         text NOT NULL CHECK (event_type IN
                       ('calibrated','recalibrated','accuracy_dropped',
                        'interference_detected','user_reported_off')),
  quality_score      real CHECK (quality_score BETWEEN 0 AND 1),
  sensor_accuracy    text CHECK (sensor_accuracy IN ('unreliable','low','medium','high')),
  algorithm_version  text,
  reported_error_deg real CHECK (reported_error_deg BETWEEN -180 AND 180),
  occurred_at        timestamptz NOT NULL DEFAULT now(),

  FOREIGN KEY (device_id, user_id)
    REFERENCES app.device (device_id, user_id) ON DELETE CASCADE
);

CREATE INDEX app_calibration_event_device_idx
  ON app.calibration_event (device_id, occurred_at DESC);
CREATE INDEX app_calibration_event_user_idx
  ON app.calibration_event (user_id, occurred_at DESC);

-- ----------------------------------------------------------------------------
-- 4. app.saved_place: label, coordinates and address live in one encrypted blob.
-- ----------------------------------------------------------------------------

CREATE TABLE app.saved_place (
  place_id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id          uuid NOT NULL REFERENCES app.account(user_id) ON DELETE CASCADE,
  kind             text NOT NULL DEFAULT 'custom'
                   CHECK (kind IN ('home','work','school','custom')),
  place_encrypted  bytea NOT NULL,
  key_version      smallint NOT NULL DEFAULT 1,           -- for key rotation
  algorithm        text     NOT NULL DEFAULT 'AES-GCM-256',
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX app_saved_place_one_per_kind_uidx
  ON app.saved_place (user_id, kind) WHERE kind IN ('home','work','school');
CREATE INDEX app_saved_place_user_idx ON app.saved_place (user_id);

CREATE TRIGGER trg_saved_place_touch BEFORE UPDATE ON app.saved_place
  FOR EACH ROW EXECUTE FUNCTION app.touch_updated_at();

-- ----------------------------------------------------------------------------
-- 5. app.commitment: "I need to be somewhere at a time". The core object.
-- ----------------------------------------------------------------------------

CREATE TABLE app.commitment (
  commitment_id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id               uuid NOT NULL REFERENCES app.account(user_id) ON DELETE CASCADE,

  -- Appears in push payloads: keep it generic ("Work").
  label                 text NOT NULL CHECK (char_length(label) BETWEEN 1 AND 60),
  place_id              uuid REFERENCES app.saved_place(place_id) ON DELETE SET NULL,
  destination_encrypted bytea,

  time_mode             text NOT NULL CHECK (time_mode IN ('arrive_by','depart_at')),
  schedule_kind         text NOT NULL CHECK (schedule_kind IN ('one_time','recurring')),
  one_time_at           timestamptz,
  local_time            time,
  weekdays              smallint,              -- Mon=1 Tue=2 Wed=4 Thu=8 Fri=16 Sat=32 Sun=64
  timezone              text NOT NULL DEFAULT 'America/Toronto',
  starts_on             date,
  ends_on               date,

  buffer_min            smallint NOT NULL DEFAULT 0 CHECK (buffer_min BETWEEN 0 AND 60),

  enabled               boolean NOT NULL DEFAULT true,
  snoozed_until         timestamptz,
  archived_at           timestamptz,

  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now(),

  UNIQUE (commitment_id, user_id),

  CONSTRAINT commitment_schedule_chk CHECK (
    (schedule_kind = 'one_time'
       AND one_time_at IS NOT NULL AND local_time IS NULL AND weekdays IS NULL)
    OR
    (schedule_kind = 'recurring'
       AND local_time IS NOT NULL AND weekdays BETWEEN 1 AND 127 AND one_time_at IS NULL)),
  CONSTRAINT commitment_window_chk CHECK (
    starts_on IS NULL OR ends_on IS NULL OR ends_on >= starts_on)
);

CREATE INDEX app_commitment_active_idx
  ON app.commitment (user_id) WHERE enabled AND archived_at IS NULL;

CREATE TRIGGER trg_commitment_touch BEFORE UPDATE ON app.commitment
  FOR EACH ROW EXECUTE FUNCTION app.touch_updated_at();

-- ----------------------------------------------------------------------------
-- 5b. app.commitment_leg: the transit plan (public ids only)
-- ----------------------------------------------------------------------------

CREATE TABLE app.commitment_leg (
  commitment_id   uuid NOT NULL,
  seq             smallint NOT NULL CHECK (seq >= 1),
  user_id         uuid NOT NULL,

  mode            text NOT NULL CHECK (mode IN ('walk','bus','streetcar','subway','rail')),
  route_id        text,
  direction_id    smallint CHECK (direction_id IN (0,1)),
  board_stop_id   text,
  alight_stop_id  text,

  PRIMARY KEY (commitment_id, seq),
  FOREIGN KEY (commitment_id, user_id)
    REFERENCES app.commitment (commitment_id, user_id) ON DELETE CASCADE,
  CONSTRAINT leg_transit_fields_chk CHECK (
    mode = 'walk'
    OR (route_id IS NOT NULL AND board_stop_id IS NOT NULL AND alight_stop_id IS NOT NULL))
);

-- "Which commitments use route X / stop Y" (disruption matching).
CREATE INDEX app_commitment_leg_route_idx
  ON app.commitment_leg (route_id)      WHERE route_id IS NOT NULL;
CREATE INDEX app_commitment_leg_board_idx
  ON app.commitment_leg (board_stop_id) WHERE board_stop_id IS NOT NULL;
CREATE INDEX app_commitment_leg_alight_idx
  ON app.commitment_leg (alight_stop_id) WHERE alight_stop_id IS NOT NULL;

-- ----------------------------------------------------------------------------
-- 6. app.commitment_run: one occurrence; the reminder state machine.
--    Materialized by the worker. Prune completed runs after ~90 days.
-- ----------------------------------------------------------------------------

CREATE TABLE app.commitment_run (
  run_id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  commitment_id          uuid NOT NULL,
  user_id                uuid NOT NULL,

  scheduled_for          timestamptz NOT NULL,   -- the arrive-by / depart-at instant
  status                 text NOT NULL DEFAULT 'scheduled'
                         CHECK (status IN ('scheduled','briefed','leave_now',
                                           'in_transit','completed','missed',
                                           'cancelled_by_user','cancelled_by_system',
                                           'expired')),

  expected_vehicle_at    timestamptz,            -- latest real-time prediction
  -- When the worker next needs to act on this run (briefing, leave-now,
  -- missed check, get-off). Worker keeps it current; polling indexes it.
  next_action_at         timestamptz,

  briefing_sent_at       timestamptz,
  leave_now_sent_at      timestamptz,
  missed_notified_at     timestamptz,
  getoff_alert_sent_at   timestamptz,

  -- Only ever set when consent.live_trip_tracking is true.
  boarded_at             timestamptz,
  completed_at           timestamptz,

  created_at             timestamptz NOT NULL DEFAULT now(),
  updated_at             timestamptz NOT NULL DEFAULT now(),

  UNIQUE (commitment_id, scheduled_for),
  FOREIGN KEY (commitment_id, user_id)
    REFERENCES app.commitment (commitment_id, user_id) ON DELETE CASCADE
);

CREATE INDEX app_commitment_run_due_idx
  ON app.commitment_run (next_action_at)
  WHERE next_action_at IS NOT NULL
    AND status IN ('scheduled','briefed','leave_now','in_transit');
CREATE INDEX app_commitment_run_user_idx
  ON app.commitment_run (user_id, scheduled_for DESC);

CREATE TRIGGER trg_commitment_run_touch BEFORE UPDATE ON app.commitment_run
  FOR EACH ROW EXECUTE FUNCTION app.touch_updated_at();

-- When a commitment's schedule changes (or it is disabled/archived), cancel its
-- upcoming runs. SECURITY DEFINER (owned by ttc_worker): ttc_app is only
-- allowed to set 'cancelled_by_user', so the caller's own role can't do this.
CREATE OR REPLACE FUNCTION app.cancel_stale_commitment_runs()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog
AS $$
BEGIN
  IF (OLD.local_time   IS DISTINCT FROM NEW.local_time)
     OR (OLD.one_time_at IS DISTINCT FROM NEW.one_time_at)
     OR (OLD.weekdays    IS DISTINCT FROM NEW.weekdays)
     OR (OLD.timezone    IS DISTINCT FROM NEW.timezone)
     OR (OLD.time_mode   IS DISTINCT FROM NEW.time_mode)
     OR (OLD.enabled AND NOT NEW.enabled)
     OR (OLD.archived_at IS NULL AND NEW.archived_at IS NOT NULL) THEN
    UPDATE app.commitment_run
       SET status = 'cancelled_by_system',
           next_action_at = NULL
     WHERE commitment_id = NEW.commitment_id
       AND status IN ('scheduled','briefed')
       AND scheduled_for > now();
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_commitment_cancel_stale_runs
  AFTER UPDATE ON app.commitment
  FOR EACH ROW EXECUTE FUNCTION app.cancel_stale_commitment_runs();

-- ----------------------------------------------------------------------------
-- 7. app.challenge_preferences (1:1, opt-in) + app.challenge
-- ----------------------------------------------------------------------------

CREATE TABLE app.challenge_preferences (
  user_id             uuid PRIMARY KEY REFERENCES app.account(user_id) ON DELETE CASCADE,

  enabled             boolean NOT NULL DEFAULT false,
  kinds               text[]  NOT NULL DEFAULT ARRAY['nature','cafe','landmark']
                      CHECK (kinds <@ ARRAY['nature','cafe','landmark','surprise']::text[]),

  min_distance_m      integer NOT NULL DEFAULT 300  CHECK (min_distance_m >= 50),
  max_distance_m      integer NOT NULL DEFAULT 2000 CHECK (max_distance_m <= 10000),
  -- Safety window in the user's local time.
  earliest_local_hour smallint NOT NULL DEFAULT 8  CHECK (earliest_local_hour BETWEEN 0 AND 23),
  latest_local_hour   smallint NOT NULL DEFAULT 20 CHECK (latest_local_hour   BETWEEN 0 AND 23),
  daily_limit         smallint NOT NULL DEFAULT 3  CHECK (daily_limit BETWEEN 1 AND 20),

  reveal_mode         text NOT NULL DEFAULT 'on_arrival'
                      CHECK (reveal_mode IN ('on_arrival','after_hint')),

  updated_at          timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT challenge_distance_chk CHECK (min_distance_m <= max_distance_m)
);

CREATE TRIGGER trg_challenge_preferences_touch BEFORE UPDATE ON app.challenge_preferences
  FOR EACH ROW EXECUTE FUNCTION app.touch_updated_at();

-- The API withholds the place's identity until revealed_at is set.
CREATE TABLE app.challenge (
  challenge_id   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id        uuid NOT NULL REFERENCES app.account(user_id) ON DELETE CASCADE,

  kind           text NOT NULL CHECK (kind IN ('nature','cafe','landmark','surprise')),
  status         text NOT NULL DEFAULT 'offered'
                 CHECK (status IN ('offered','active','completed','abandoned','expired')),
  target_poi_id  text NOT NULL,
  distance_m     integer NOT NULL CHECK (distance_m > 0),
  difficulty     smallint CHECK (difficulty BETWEEN 1 AND 5),

  offered_at     timestamptz NOT NULL DEFAULT now(),
  started_at     timestamptz,
  revealed_at    timestamptz,
  completed_at   timestamptz,
  expires_at     timestamptz NOT NULL
);

CREATE INDEX app_challenge_user_idx ON app.challenge (user_id, offered_at DESC);
CREATE INDEX app_challenge_open_idx ON app.challenge (user_id)
  WHERE status IN ('offered','active');

-- ----------------------------------------------------------------------------
-- 8. Seed all 1:1 rows on signup (replaces the 008 trigger function)
--    Existing accounts, if any, need a one-off backfill by a superuser/worker.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION app.seed_user_defaults()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO app.user_preferences      (user_id) VALUES (NEW.user_id) ON CONFLICT DO NOTHING;
  INSERT INTO app.user_consent          (user_id) VALUES (NEW.user_id) ON CONFLICT DO NOTHING;
  INSERT INTO app.reminder_preferences  (user_id) VALUES (NEW.user_id) ON CONFLICT DO NOTHING;
  INSERT INTO app.compass_preferences   (user_id) VALUES (NEW.user_id) ON CONFLICT DO NOTHING;
  INSERT INTO app.challenge_preferences (user_id) VALUES (NEW.user_id) ON CONFLICT DO NOTHING;
  RETURN NEW;
END $$;

-- ----------------------------------------------------------------------------
-- 9. Row level security
-- ----------------------------------------------------------------------------

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['reminder_preferences','compass_preferences',
                           'challenge_preferences','device_calibration',
                           'saved_place','commitment','commitment_leg','challenge']
  LOOP
    EXECUTE format('ALTER TABLE app.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('ALTER TABLE app.%I FORCE ROW LEVEL SECURITY', t);
    EXECUTE format($p$CREATE POLICY owner_all ON app.%I FOR ALL TO ttc_app
                      USING (user_id = app.current_user_id())
                      WITH CHECK (user_id = app.current_user_id())$p$, t);
  END LOOP;

  -- Append-only for ttc_app.
  ALTER TABLE app.calibration_event ENABLE ROW LEVEL SECURITY;
  ALTER TABLE app.calibration_event FORCE ROW LEVEL SECURITY;
  CREATE POLICY owner_select ON app.calibration_event FOR SELECT TO ttc_app
    USING (user_id = app.current_user_id());
  CREATE POLICY owner_insert ON app.calibration_event FOR INSERT TO ttc_app
    WITH CHECK (user_id = app.current_user_id());

  -- Runs: owner reads, and may only move an upcoming run to 'cancelled_by_user'.
  ALTER TABLE app.commitment_run ENABLE ROW LEVEL SECURITY;
  ALTER TABLE app.commitment_run FORCE ROW LEVEL SECURITY;
  CREATE POLICY owner_select ON app.commitment_run FOR SELECT TO ttc_app
    USING (user_id = app.current_user_id());
  CREATE POLICY owner_cancel ON app.commitment_run FOR UPDATE TO ttc_app
    USING (user_id = app.current_user_id() AND status IN ('scheduled','briefed'))
    WITH CHECK (user_id = app.current_user_id() AND status = 'cancelled_by_user');

  FOREACH t IN ARRAY ARRAY['reminder_preferences','compass_preferences',
                           'challenge_preferences','device_calibration',
                           'calibration_event','saved_place','commitment',
                           'commitment_leg','commitment_run','challenge']
  LOOP
    EXECUTE format($p$CREATE POLICY worker_all ON app.%I FOR ALL TO ttc_worker
                      USING (true) WITH CHECK (true)$p$, t);
  END LOOP;
END $$;

-- ----------------------------------------------------------------------------
-- 10. Grants
-- ----------------------------------------------------------------------------

GRANT SELECT, INSERT, UPDATE
  ON app.reminder_preferences, app.compass_preferences, app.challenge_preferences,
     app.challenge
  TO ttc_app;

GRANT SELECT, INSERT, UPDATE, DELETE
  ON app.device_calibration, app.saved_place, app.commitment, app.commitment_leg
  TO ttc_app;

GRANT SELECT, INSERT ON app.calibration_event TO ttc_app;
GRANT SELECT ON app.commitment_run TO ttc_app;
GRANT UPDATE (status) ON app.commitment_run TO ttc_app;

GRANT USAGE ON ALL SEQUENCES IN SCHEMA app TO ttc_app;

GRANT ALL ON ALL TABLES    IN SCHEMA app TO ttc_worker;
GRANT ALL ON ALL SEQUENCES IN SCHEMA app TO ttc_worker;

-- Trigger function runs as ttc_worker (has worker_all on commitment_run).
GRANT CREATE ON SCHEMA app TO ttc_worker;
ALTER FUNCTION app.cancel_stale_commitment_runs() OWNER TO ttc_worker;
REVOKE CREATE ON SCHEMA app FROM ttc_worker;

INSERT INTO ops.schema_version (version, note) VALUES ('009', 'commitments, reminders, compass calibration, challenges') ON CONFLICT DO NOTHING;

COMMIT;
-- >>>>>>>>>> END PART: 009_commute_compass.sql <<<<<<<<<<

-- >>>>>>>>>> BEGIN PART: 010_trip_history.sql <<<<<<<<<<
-- ============================================================================
-- 010_trip_history.sql
-- Completed rides: a user's personal history. Snapshots + soft references to
-- transit data (names are copied, so history survives GTFS changes).
--
-- Privacy note: board/alight stops are stored in plaintext. Frequent stops
-- reveal home and work. That is a deliberate trade-off for server-side stats;
-- no GPS tracks or raw coordinates of the user are ever stored here.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1. app.trip (partitioned monthly by boarded_at)
-- ----------------------------------------------------------------------------

CREATE TABLE app.trip (
  trip_id                 uuid NOT NULL DEFAULT gen_random_uuid(),
  user_id                 uuid NOT NULL REFERENCES app.account(user_id) ON DELETE CASCADE,
  journey_id              uuid,

  route_id                text NOT NULL,
  route_short_name        text,
  route_long_name         text,
  route_color             text,
  route_type              smallint,

  direction_id            smallint NOT NULL,
  headsign                text,

  vehicle_id              text,
  vehicle_label           text,

  board_stop_id           text NOT NULL,
  board_stop_name         text NOT NULL,
  board_stop_lat          numeric(9,6),
  board_stop_lon          numeric(9,6),
  boarded_at              timestamptz NOT NULL,
  scheduled_board_at      timestamptz,
  delay_seconds           integer,

  alight_stop_id          text NOT NULL,
  alight_stop_name        text NOT NULL,
  alight_stop_lat         numeric(9,6),
  alight_stop_lon         numeric(9,6),
  alighted_at             timestamptz NOT NULL,

  walk_to_board_seconds    integer,
  walk_from_alight_seconds integer,

  ride_seconds            integer NOT NULL,
  num_stops               smallint NOT NULL,
  num_intermediate_stops  smallint NOT NULL DEFAULT 0,

  detection_method        text NOT NULL CHECK (detection_method IN ('auto','manual')),
  detected_via            text NOT NULL CHECK (detected_via IN ('ttc_feed','gps','manual')),

  created_at              timestamptz NOT NULL DEFAULT now(),

  PRIMARY KEY (trip_id, boarded_at),
  -- Lets trip_stop reference (trip, user) so a stop row can't cross users.
  UNIQUE (trip_id, boarded_at, user_id)
) PARTITION BY RANGE (boarded_at);

CREATE INDEX app_trip_user_time_idx       ON app.trip (user_id, boarded_at DESC);
CREATE INDEX app_trip_user_route_idx      ON app.trip (user_id, route_id);
CREATE INDEX app_trip_user_board_stop_idx ON app.trip (user_id, board_stop_id);
CREATE INDEX app_trip_journey_idx         ON app.trip (journey_id) WHERE journey_id IS NOT NULL;

-- Catch-all so a missed partition-maintenance run never makes inserts fail.
-- Rows landing here should be moved into a real partition by the maintainer.
CREATE TABLE app.trip_default PARTITION OF app.trip DEFAULT;

-- Creates the monthly partition for p_date. SECURITY DEFINER (owned by the
-- migration role, which owns app.trip) so ttc_worker can run it.
CREATE OR REPLACE FUNCTION app.ensure_trip_partition(p_date date)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  start_date date := date_trunc('month', p_date)::date;
  end_date   date := (date_trunc('month', p_date) + interval '1 month')::date;
  part_name  text := 'trip_' || to_char(start_date, 'YYYY_MM');
BEGIN
  EXECUTE format(
    'CREATE TABLE IF NOT EXISTS app.%I PARTITION OF app.trip
       FOR VALUES FROM (%L) TO (%L)',
    part_name, start_date, end_date);
END $$;

REVOKE ALL ON FUNCTION app.ensure_trip_partition(date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.ensure_trip_partition(date) TO ttc_worker;

SELECT app.ensure_trip_partition(current_date);
SELECT app.ensure_trip_partition((current_date + interval '1 month')::date);
SELECT app.ensure_trip_partition((current_date + interval '2 months')::date);

ALTER TABLE app.trip ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.trip FORCE ROW LEVEL SECURITY;
CREATE POLICY owner_all ON app.trip FOR ALL TO ttc_app
  USING (user_id = app.current_user_id())
  WITH CHECK (user_id = app.current_user_id());
CREATE POLICY worker_all ON app.trip FOR ALL TO ttc_worker
  USING (true) WITH CHECK (true);

-- ----------------------------------------------------------------------------
-- 2. app.trip_stop: per-stop timeline of a trip. user_id is denormalized so RLS
--    is a plain column check, and deleting an account cascades to it.
-- ----------------------------------------------------------------------------

CREATE TABLE app.trip_stop (
  trip_id               uuid NOT NULL,
  boarded_at            timestamptz NOT NULL,
  user_id               uuid NOT NULL REFERENCES app.account(user_id) ON DELETE CASCADE,
  ordinal               smallint NOT NULL,

  stop_id               text NOT NULL,
  stop_name             text NOT NULL,
  stop_lat              numeric(9,6),
  stop_lon              numeric(9,6),

  is_board              boolean NOT NULL DEFAULT false,
  is_alight             boolean NOT NULL DEFAULT false,

  scheduled_arrival_at  timestamptz,
  observed_arrival_at   timestamptz,
  observed_departure_at timestamptz,
  dwell_seconds         integer,

  PRIMARY KEY (trip_id, ordinal),
  FOREIGN KEY (trip_id, boarded_at, user_id)
    REFERENCES app.trip (trip_id, boarded_at, user_id) ON DELETE CASCADE
);

CREATE INDEX app_trip_stop_stop_idx ON app.trip_stop (stop_id);
CREATE INDEX app_trip_stop_user_idx ON app.trip_stop (user_id);

ALTER TABLE app.trip_stop ENABLE ROW LEVEL SECURITY;
ALTER TABLE app.trip_stop FORCE ROW LEVEL SECURITY;
CREATE POLICY owner_all ON app.trip_stop FOR ALL TO ttc_app
  USING (user_id = app.current_user_id())
  WITH CHECK (user_id = app.current_user_id());
CREATE POLICY worker_all ON app.trip_stop FOR ALL TO ttc_worker
  USING (true) WITH CHECK (true);

-- ----------------------------------------------------------------------------
-- 3. Per-user aggregates (cheap "most used" lookups)
-- ----------------------------------------------------------------------------

CREATE TABLE app.user_route_stat (
  user_id         uuid     NOT NULL REFERENCES app.account(user_id) ON DELETE CASCADE,
  route_id        text     NOT NULL,
  ride_count      integer  NOT NULL DEFAULT 0,
  last_ridden_on  date,
  PRIMARY KEY (user_id, route_id)
);

CREATE INDEX app_user_route_stat_rank_idx
  ON app.user_route_stat (user_id, ride_count DESC);

CREATE TABLE app.user_stop_stat (
  user_id         uuid     NOT NULL REFERENCES app.account(user_id) ON DELETE CASCADE,
  stop_id         text     NOT NULL,
  board_count     integer  NOT NULL DEFAULT 0,
  alight_count    integer  NOT NULL DEFAULT 0,
  last_used_on    date,
  PRIMARY KEY (user_id, stop_id)
);

CREATE INDEX app_user_stop_stat_board_rank_idx
  ON app.user_stop_stat (user_id, board_count DESC);

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['user_route_stat','user_stop_stat']
  LOOP
    EXECUTE format('ALTER TABLE app.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('ALTER TABLE app.%I FORCE ROW LEVEL SECURITY', t);
    EXECUTE format($p$CREATE POLICY owner_all ON app.%I FOR ALL TO ttc_app
                      USING (user_id = app.current_user_id())
                      WITH CHECK (user_id = app.current_user_id())$p$, t);
    EXECUTE format($p$CREATE POLICY worker_all ON app.%I FOR ALL TO ttc_worker
                      USING (true) WITH CHECK (true)$p$, t);
  END LOOP;
END $$;

-- Recompute aggregates from trips. p_user_id NULL = everyone (worker, nightly).
-- Under RLS, ttc_app calling it with NULL only touches its own user.
CREATE OR REPLACE FUNCTION app.refresh_user_stats(p_user_id uuid DEFAULT NULL)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO app.user_route_stat (user_id, route_id, ride_count, last_ridden_on)
  SELECT user_id, route_id, count(*)::int, max(boarded_at)::date
    FROM app.trip
   WHERE (p_user_id IS NULL OR user_id = p_user_id)
   GROUP BY user_id, route_id
  ON CONFLICT (user_id, route_id) DO UPDATE SET
    ride_count     = EXCLUDED.ride_count,
    last_ridden_on = EXCLUDED.last_ridden_on;

  DELETE FROM app.user_route_stat s
   WHERE (p_user_id IS NULL OR s.user_id = p_user_id)
     AND NOT EXISTS (SELECT 1 FROM app.trip t
                      WHERE t.user_id = s.user_id AND t.route_id = s.route_id);

  INSERT INTO app.user_stop_stat (user_id, stop_id, board_count, alight_count, last_used_on)
  WITH b AS (
    SELECT user_id, board_stop_id AS stop_id, count(*)::int AS c, max(boarded_at)::date AS d
      FROM app.trip WHERE (p_user_id IS NULL OR user_id = p_user_id)
     GROUP BY user_id, board_stop_id
  ), a AS (
    SELECT user_id, alight_stop_id AS stop_id, count(*)::int AS c, max(alighted_at)::date AS d
      FROM app.trip WHERE (p_user_id IS NULL OR user_id = p_user_id)
     GROUP BY user_id, alight_stop_id
  )
  SELECT coalesce(b.user_id, a.user_id),
         coalesce(b.stop_id,  a.stop_id),
         coalesce(b.c, 0), coalesce(a.c, 0),
         greatest(coalesce(b.d, '1970-01-01'::date), coalesce(a.d, '1970-01-01'::date))
    FROM b FULL OUTER JOIN a
      ON b.user_id = a.user_id AND b.stop_id = a.stop_id
  ON CONFLICT (user_id, stop_id) DO UPDATE SET
    board_count  = EXCLUDED.board_count,
    alight_count = EXCLUDED.alight_count,
    last_used_on = EXCLUDED.last_used_on;

  DELETE FROM app.user_stop_stat s
   WHERE (p_user_id IS NULL OR s.user_id = p_user_id)
     AND NOT EXISTS (SELECT 1 FROM app.trip t
                      WHERE t.user_id = s.user_id
                        AND (t.board_stop_id = s.stop_id OR t.alight_stop_id = s.stop_id));
END $$;

REVOKE ALL ON FUNCTION app.refresh_user_stats(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION app.refresh_user_stats(uuid) TO ttc_app, ttc_worker;

-- ----------------------------------------------------------------------------
-- 4. Grants
-- ----------------------------------------------------------------------------

GRANT SELECT, INSERT, UPDATE, DELETE
  ON app.trip, app.trip_stop, app.user_route_stat, app.user_stop_stat
  TO ttc_app;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA app TO ttc_app;
GRANT ALL ON ALL TABLES IN SCHEMA app TO ttc_worker;

INSERT INTO ops.schema_version (version, note) VALUES ('010', 'trip history + per-user stats') ON CONFLICT DO NOTHING;

COMMIT;
-- >>>>>>>>>> END PART: 010_trip_history.sql <<<<<<<<<<

-- >>>>>>>>>> BEGIN PART: 011_data_observations.sql <<<<<<<<<<
-- ============================================================================
-- 011_data_observations.sql
-- Anonymous contributions. No user_id anywhere. Never joined to app.*.
--
-- Pipeline: API inserts into *_staging  ->  data.promote_staging() moves a
-- group to the final tables only once it has >= k DISTINCT contributors.
--
-- contributor_key (staging only) = HMAC(daily-rotating server key, user_id),
-- computed by the API. It lets the database count distinct people without ever
-- seeing a user id, and it cannot be linked across days. It is deleted with the
-- staging row and never copied to the final tables.
--
-- Conventions: observed_date / hour_bucket are in America/Toronto local time;
-- day_of_week follows EXTRACT(dow): 0 = Sunday ... 6 = Saturday.
-- ============================================================================

BEGIN;

CREATE SCHEMA IF NOT EXISTS data;
COMMENT ON SCHEMA data IS 'Anonymous observations. No user_id, ever.';

-- ----------------------------------------------------------------------------
-- 1. Final tables (partitioned monthly by observed_date)
-- ----------------------------------------------------------------------------

CREATE TABLE data.trip_observation (
  observation_id  bigserial,
  observed_date   date NOT NULL,
  hour_bucket     smallint NOT NULL CHECK (hour_bucket BETWEEN 0 AND 23),
  day_of_week     smallint NOT NULL CHECK (day_of_week BETWEEN 0 AND 6),
  route_id        text NOT NULL,
  direction_id    smallint NOT NULL,
  board_stop_id   text NOT NULL,
  alight_stop_id  text NOT NULL,
  ride_seconds    integer NOT NULL CHECK (ride_seconds > 0),
  delay_seconds   integer,
  k_group         text NOT NULL,

  PRIMARY KEY (observation_id, observed_date)
) PARTITION BY RANGE (observed_date);

CREATE INDEX data_trip_obs_agg_idx
  ON data.trip_observation (route_id, board_stop_id, alight_stop_id, hour_bucket, day_of_week);
CREATE TABLE data.trip_observation_default PARTITION OF data.trip_observation DEFAULT;

CREATE TABLE data.segment_observation (
  observation_id  bigserial,
  observed_date   date NOT NULL,
  hour_bucket     smallint NOT NULL CHECK (hour_bucket BETWEEN 0 AND 23),
  day_of_week     smallint NOT NULL CHECK (day_of_week BETWEEN 0 AND 6),
  route_id        text NOT NULL,
  direction_id    smallint NOT NULL,
  from_stop_id    text NOT NULL,
  to_stop_id      text NOT NULL,
  travel_seconds  integer NOT NULL CHECK (travel_seconds >= 0),
  dwell_seconds   integer,
  sample_source   text NOT NULL CHECK (sample_source IN ('ttc_feed','user_gps')),
  k_group         text NOT NULL,

  PRIMARY KEY (observation_id, observed_date)
) PARTITION BY RANGE (observed_date);

CREATE INDEX data_seg_obs_agg_idx
  ON data.segment_observation (route_id, from_stop_id, to_stop_id, hour_bucket, day_of_week);
CREATE INDEX data_seg_obs_source_idx
  ON data.segment_observation (sample_source, observed_date);
CREATE TABLE data.segment_observation_default PARTITION OF data.segment_observation DEFAULT;

-- ----------------------------------------------------------------------------
-- 2. Staging tables. Same checks as the finals so bad rows fail at insert time,
--    not at promotion. inserted_at is truncated to the hour to blunt timing
--    correlation with API logs.
-- ----------------------------------------------------------------------------

CREATE TABLE data.trip_observation_staging (
  observation_id   bigserial PRIMARY KEY,
  observed_date    date NOT NULL,
  hour_bucket      smallint NOT NULL CHECK (hour_bucket BETWEEN 0 AND 23),
  day_of_week      smallint NOT NULL CHECK (day_of_week BETWEEN 0 AND 6),
  route_id         text NOT NULL,
  direction_id     smallint NOT NULL,
  board_stop_id    text NOT NULL,
  alight_stop_id   text NOT NULL,
  ride_seconds     integer NOT NULL CHECK (ride_seconds > 0),
  delay_seconds    integer,
  k_group          text NOT NULL,
  contributor_key  bytea NOT NULL,
  inserted_at      timestamptz NOT NULL DEFAULT date_trunc('hour', now())
);
CREATE INDEX data_trip_obs_staging_kgroup_idx ON data.trip_observation_staging (k_group);
CREATE INDEX data_trip_obs_staging_age_idx    ON data.trip_observation_staging (inserted_at);

CREATE TABLE data.segment_observation_staging (
  observation_id   bigserial PRIMARY KEY,
  observed_date    date NOT NULL,
  hour_bucket      smallint NOT NULL CHECK (hour_bucket BETWEEN 0 AND 23),
  day_of_week      smallint NOT NULL CHECK (day_of_week BETWEEN 0 AND 6),
  route_id         text NOT NULL,
  direction_id     smallint NOT NULL,
  from_stop_id     text NOT NULL,
  to_stop_id       text NOT NULL,
  travel_seconds   integer NOT NULL CHECK (travel_seconds >= 0),
  dwell_seconds    integer,
  sample_source    text NOT NULL CHECK (sample_source IN ('ttc_feed','user_gps')),
  k_group          text NOT NULL,
  contributor_key  bytea NOT NULL,
  inserted_at      timestamptz NOT NULL DEFAULT date_trunc('hour', now())
);
CREATE INDEX data_seg_obs_staging_kgroup_idx ON data.segment_observation_staging (k_group);
CREATE INDEX data_seg_obs_staging_age_idx    ON data.segment_observation_staging (inserted_at);

-- ----------------------------------------------------------------------------
-- 3. Partition management (SECURITY DEFINER, owned by the migration role,
--    which owns the parents)
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION data.ensure_partition(p_date date)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog
AS $$
DECLARE
  start_date date := date_trunc('month', p_date)::date;
  end_date   date := (date_trunc('month', p_date) + interval '1 month')::date;
  trip_part  text := 'trip_obs_' || to_char(start_date, 'YYYY_MM');
  seg_part   text := 'seg_obs_'  || to_char(start_date, 'YYYY_MM');
BEGIN
  EXECUTE format(
    'CREATE TABLE IF NOT EXISTS data.%I PARTITION OF data.trip_observation
       FOR VALUES FROM (%L) TO (%L)',
    trip_part, start_date, end_date);
  EXECUTE format(
    'CREATE TABLE IF NOT EXISTS data.%I PARTITION OF data.segment_observation
       FOR VALUES FROM (%L) TO (%L)',
    seg_part, start_date, end_date);
END $$;

REVOKE ALL ON FUNCTION data.ensure_partition(date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION data.ensure_partition(date) TO ttc_worker;

SELECT data.ensure_partition(current_date);
SELECT data.ensure_partition((current_date + interval '1 month')::date);
SELECT data.ensure_partition((current_date + interval '2 months')::date);

-- ----------------------------------------------------------------------------
-- 4. k-anonymity gate. Each table is handled in ONE statement
--    (DELETE ... RETURNING feeding the INSERT), so rows arriving mid-run can
--    never be deleted without being promoted. Promoted rows are shuffled so
--    the sequence ids carry no arrival order.
-- ----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION data.promote_staging(
  p_k       integer  DEFAULT 10,
  p_max_age interval DEFAULT '24 hours'
) RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  WITH ready AS (
    SELECT k_group FROM data.trip_observation_staging
     GROUP BY k_group HAVING count(DISTINCT contributor_key) >= p_k
  ), moved AS (
    DELETE FROM data.trip_observation_staging s
     USING ready r
     WHERE s.k_group = r.k_group
    RETURNING s.observed_date, s.hour_bucket, s.day_of_week, s.route_id,
              s.direction_id, s.board_stop_id, s.alight_stop_id,
              s.ride_seconds, s.delay_seconds, s.k_group
  )
  INSERT INTO data.trip_observation
    (observed_date, hour_bucket, day_of_week, route_id, direction_id,
     board_stop_id, alight_stop_id, ride_seconds, delay_seconds, k_group)
  SELECT observed_date, hour_bucket, day_of_week, route_id, direction_id,
         board_stop_id, alight_stop_id, ride_seconds, delay_seconds, k_group
    FROM moved
   ORDER BY random();

  DELETE FROM data.trip_observation_staging
   WHERE inserted_at < now() - p_max_age;

  WITH ready AS (
    SELECT k_group FROM data.segment_observation_staging
     GROUP BY k_group HAVING count(DISTINCT contributor_key) >= p_k
  ), moved AS (
    DELETE FROM data.segment_observation_staging s
     USING ready r
     WHERE s.k_group = r.k_group
    RETURNING s.observed_date, s.hour_bucket, s.day_of_week, s.route_id,
              s.direction_id, s.from_stop_id, s.to_stop_id, s.travel_seconds,
              s.dwell_seconds, s.sample_source, s.k_group
  )
  INSERT INTO data.segment_observation
    (observed_date, hour_bucket, day_of_week, route_id, direction_id,
     from_stop_id, to_stop_id, travel_seconds, dwell_seconds, sample_source, k_group)
  SELECT observed_date, hour_bucket, day_of_week, route_id, direction_id,
         from_stop_id, to_stop_id, travel_seconds, dwell_seconds, sample_source, k_group
    FROM moved
   ORDER BY random();

  DELETE FROM data.segment_observation_staging
   WHERE inserted_at < now() - p_max_age;
END $$;

-- ----------------------------------------------------------------------------
-- 5. Grants: ttc_app may only INSERT into staging. It cannot read any data.*.
-- ----------------------------------------------------------------------------

GRANT USAGE ON SCHEMA data TO ttc_app, ttc_worker;
GRANT INSERT ON data.trip_observation_staging,
                data.segment_observation_staging
  TO ttc_app;
GRANT USAGE ON SEQUENCE data.trip_observation_staging_observation_id_seq,
                        data.segment_observation_staging_observation_id_seq
  TO ttc_app;
GRANT ALL ON ALL TABLES    IN SCHEMA data TO ttc_worker;
GRANT ALL ON ALL SEQUENCES IN SCHEMA data TO ttc_worker;

INSERT INTO ops.schema_version (version, note) VALUES ('011', 'anonymous observations + k-anonymity gate') ON CONFLICT DO NOTHING;

COMMIT;
-- >>>>>>>>>> END PART: 011_data_observations.sql <<<<<<<<<<

-- >>>>>>>>>> BEGIN PART: 012_stats_aggregates.sql <<<<<<<<<<
-- ============================================================================
-- 012_stats_aggregates.sql
-- Pre-computed reliability. Read-only for the API. Refreshed nightly by the
-- worker via stats.refresh_all().
--
-- day_type mapping assumes data.*.day_of_week = EXTRACT(dow):
--   1..5 = weekday, 6 = sat, 0 = sun.
-- ============================================================================

BEGIN;

CREATE SCHEMA IF NOT EXISTS stats;
COMMENT ON SCHEMA stats IS 'Pre-computed aggregates. Read-only for the API.';

CREATE TABLE stats.route_reliability (
  route_id           text NOT NULL,
  direction_id       smallint NOT NULL,
  day_type           text NOT NULL CHECK (day_type IN ('weekday','sat','sun')),
  hour_bucket        smallint NOT NULL CHECK (hour_bucket BETWEEN 0 AND 23),
  sample_count       integer NOT NULL,
  mean_delay_s       integer,
  p50_delay_s        integer,
  p90_delay_s        integer,
  on_time_pct        numeric(5,2),
  computed_at        timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (route_id, direction_id, day_type, hour_bucket)
);

-- Delay at the boarding stop.
CREATE TABLE stats.stop_reliability (
  route_id           text NOT NULL,
  direction_id       smallint NOT NULL,
  stop_id            text NOT NULL,
  day_type           text NOT NULL CHECK (day_type IN ('weekday','sat','sun')),
  hour_bucket        smallint NOT NULL CHECK (hour_bucket BETWEEN 0 AND 23),
  sample_count       integer NOT NULL,
  mean_delay_s       integer,
  p50_delay_s        integer,
  p90_delay_s        integer,
  on_time_pct        numeric(5,2),
  computed_at        timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (route_id, direction_id, stop_id, day_type, hour_bucket)
);

CREATE TABLE stats.segment_travel_time (
  route_id           text NOT NULL,
  direction_id       smallint NOT NULL,
  from_stop_id       text NOT NULL,
  to_stop_id         text NOT NULL,
  day_type           text NOT NULL CHECK (day_type IN ('weekday','sat','sun')),
  hour_bucket        smallint NOT NULL CHECK (hour_bucket BETWEEN 0 AND 23),
  sample_count       integer NOT NULL,
  mean_travel_s      integer,
  p50_travel_s       integer,
  p90_travel_s       integer,
  mean_dwell_s       integer,
  computed_at        timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (route_id, direction_id, from_stop_id, to_stop_id, day_type, hour_bucket)
);

-- Rebuilds all three tables from the last p_window of observations.
-- Groups below p_min_samples are not published. Groups that no longer qualify
-- (aged out of the window or below the minimum) are deleted: every row written
-- this run has computed_at = now(), so anything older is stale.
CREATE OR REPLACE FUNCTION stats.refresh_all(
  p_window       interval DEFAULT '90 days',
  p_min_samples  integer  DEFAULT 10
) RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  v_cutoff date := (now() - p_window)::date;
BEGIN
  -- Route-level
  INSERT INTO stats.route_reliability
    (route_id, direction_id, day_type, hour_bucket, sample_count,
     mean_delay_s, p50_delay_s, p90_delay_s, on_time_pct, computed_at)
  WITH base AS (
    SELECT route_id, direction_id, hour_bucket, delay_seconds,
           CASE WHEN day_of_week BETWEEN 1 AND 5 THEN 'weekday'
                WHEN day_of_week = 6 THEN 'sat' ELSE 'sun' END AS day_type
      FROM data.trip_observation
     WHERE observed_date >= v_cutoff AND delay_seconds IS NOT NULL
  )
  SELECT route_id, direction_id, day_type, hour_bucket,
         count(*)::int,
         avg(delay_seconds)::int,
         percentile_disc(0.50) WITHIN GROUP (ORDER BY delay_seconds),
         percentile_disc(0.90) WITHIN GROUP (ORDER BY delay_seconds),
         round(100.0 * count(*) FILTER (WHERE delay_seconds BETWEEN -60 AND 300)
               / count(*), 2),
         now()
    FROM base
   GROUP BY route_id, direction_id, day_type, hour_bucket
  HAVING count(*) >= p_min_samples
  ON CONFLICT (route_id, direction_id, day_type, hour_bucket) DO UPDATE SET
    sample_count = EXCLUDED.sample_count,
    mean_delay_s = EXCLUDED.mean_delay_s,
    p50_delay_s  = EXCLUDED.p50_delay_s,
    p90_delay_s  = EXCLUDED.p90_delay_s,
    on_time_pct  = EXCLUDED.on_time_pct,
    computed_at  = EXCLUDED.computed_at;
  DELETE FROM stats.route_reliability WHERE computed_at < now();

  -- Stop-level (delay at the boarding stop)
  INSERT INTO stats.stop_reliability
    (route_id, direction_id, stop_id, day_type, hour_bucket, sample_count,
     mean_delay_s, p50_delay_s, p90_delay_s, on_time_pct, computed_at)
  WITH base AS (
    SELECT route_id, direction_id, board_stop_id AS stop_id, hour_bucket, delay_seconds,
           CASE WHEN day_of_week BETWEEN 1 AND 5 THEN 'weekday'
                WHEN day_of_week = 6 THEN 'sat' ELSE 'sun' END AS day_type
      FROM data.trip_observation
     WHERE observed_date >= v_cutoff AND delay_seconds IS NOT NULL
  )
  SELECT route_id, direction_id, stop_id, day_type, hour_bucket,
         count(*)::int,
         avg(delay_seconds)::int,
         percentile_disc(0.50) WITHIN GROUP (ORDER BY delay_seconds),
         percentile_disc(0.90) WITHIN GROUP (ORDER BY delay_seconds),
         round(100.0 * count(*) FILTER (WHERE delay_seconds BETWEEN -60 AND 300)
               / count(*), 2),
         now()
    FROM base
   GROUP BY route_id, direction_id, stop_id, day_type, hour_bucket
  HAVING count(*) >= p_min_samples
  ON CONFLICT (route_id, direction_id, stop_id, day_type, hour_bucket) DO UPDATE SET
    sample_count = EXCLUDED.sample_count,
    mean_delay_s = EXCLUDED.mean_delay_s,
    p50_delay_s  = EXCLUDED.p50_delay_s,
    p90_delay_s  = EXCLUDED.p90_delay_s,
    on_time_pct  = EXCLUDED.on_time_pct,
    computed_at  = EXCLUDED.computed_at;
  DELETE FROM stats.stop_reliability WHERE computed_at < now();

  -- Segment travel time
  INSERT INTO stats.segment_travel_time
    (route_id, direction_id, from_stop_id, to_stop_id, day_type, hour_bucket,
     sample_count, mean_travel_s, p50_travel_s, p90_travel_s, mean_dwell_s, computed_at)
  WITH base AS (
    SELECT route_id, direction_id, from_stop_id, to_stop_id, hour_bucket,
           travel_seconds, dwell_seconds,
           CASE WHEN day_of_week BETWEEN 1 AND 5 THEN 'weekday'
                WHEN day_of_week = 6 THEN 'sat' ELSE 'sun' END AS day_type
      FROM data.segment_observation
     WHERE observed_date >= v_cutoff
  )
  SELECT route_id, direction_id, from_stop_id, to_stop_id, day_type, hour_bucket,
         count(*)::int,
         avg(travel_seconds)::int,
         percentile_disc(0.50) WITHIN GROUP (ORDER BY travel_seconds),
         percentile_disc(0.90) WITHIN GROUP (ORDER BY travel_seconds),
         avg(dwell_seconds)::int,
         now()
    FROM base
   GROUP BY route_id, direction_id, from_stop_id, to_stop_id, day_type, hour_bucket
  HAVING count(*) >= p_min_samples
  ON CONFLICT (route_id, direction_id, from_stop_id, to_stop_id, day_type, hour_bucket)
  DO UPDATE SET
    sample_count  = EXCLUDED.sample_count,
    mean_travel_s = EXCLUDED.mean_travel_s,
    p50_travel_s  = EXCLUDED.p50_travel_s,
    p90_travel_s  = EXCLUDED.p90_travel_s,
    mean_dwell_s  = EXCLUDED.mean_dwell_s,
    computed_at   = EXCLUDED.computed_at;
  DELETE FROM stats.segment_travel_time WHERE computed_at < now();
END $$;

REVOKE ALL ON FUNCTION stats.refresh_all(interval, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION stats.refresh_all(interval, integer) TO ttc_worker;

GRANT USAGE ON SCHEMA stats TO ttc_app, ttc_worker;
GRANT SELECT ON ALL TABLES IN SCHEMA stats TO ttc_app;
GRANT ALL    ON ALL TABLES IN SCHEMA stats TO ttc_worker;

INSERT INTO ops.schema_version (version, note) VALUES ('012', 'stats aggregates') ON CONFLICT DO NOTHING;

COMMIT;
-- >>>>>>>>>> END PART: 012_stats_aggregates.sql <<<<<<<<<<