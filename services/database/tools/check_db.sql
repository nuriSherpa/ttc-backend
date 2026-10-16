-- Database health check: one PASS / FAIL / WARN line per check.
--   docker compose exec -T postgres psql -U ttc_admin -d ttc < services/database/tools/check_db.sql
-- FAIL = something is missing or wrong.  WARN = not an error (e.g. realtime not running yet).
\pset footer off
WITH c(area, name, must, ok, detail) AS (
  -- ---------------------------------------------------------------- structure
  SELECT 'structure','schema version is 1.7', true,
         (SELECT max(version) FROM ops.schema_version) = '1.7',
         'latest = ' || (SELECT max(version) FROM ops.schema_version)
  UNION ALL SELECT 'structure','5 schemas (ops core ref rt cur)', true,
         (SELECT count(*) FROM pg_namespace WHERE nspname IN ('ops','core','ref','rt','cur')) = 5, ''
  UNION ALL SELECT 'structure','13 core tables', true,
         (SELECT count(*) FROM pg_tables WHERE schemaname='core') = 13,
         (SELECT count(*) FROM pg_tables WHERE schemaname='core')::text
  UNION ALL SELECT 'structure','13 ref tables', true,
         (SELECT count(*) FROM pg_tables WHERE schemaname='ref') = 13,
         (SELECT count(*) FROM pg_tables WHERE schemaname='ref')::text
  UNION ALL SELECT 'structure','7 rt tables (alerts included)', true,
         (SELECT count(*) FROM pg_tables WHERE schemaname='rt'
            AND tablename IN ('vehicle_latest','vehicle_samples','trip_status','stop_eta',
                              'alert','alert_active_period','alert_informed_entity')) = 7, ''
  UNION ALL SELECT 'structure','13 cur views', true,
         (SELECT count(*) FROM pg_views WHERE schemaname='cur') = 13, ''
  UNION ALL SELECT 'structure','rt views: vehicle_now trip_now active_alerts', true,
         (SELECT count(*) FROM pg_views WHERE schemaname='rt'
            AND viewname IN ('vehicle_now','trip_now','active_alerts')) = 3, ''
  UNION ALL SELECT 'structure','rt.trip_now exposes schedule_relationship', true,
         EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema='rt'
                 AND table_name='trip_now' AND column_name='schedule_relationship'), ''
  UNION ALL SELECT 'structure','8 realtime CHECKs relaxed to 0..99', true,
         (SELECT count(*) FROM pg_constraint WHERE contype='c'
            AND conrelid IN ('rt.alert'::regclass,'rt.vehicle_latest'::regclass,'rt.trip_status'::regclass)
            AND pg_get_constraintdef(oid) LIKE '%<= 99%') = 8,
         (SELECT count(*) FROM pg_constraint WHERE contype='c'
            AND conrelid IN ('rt.alert'::regclass,'rt.vehicle_latest'::regclass,'rt.trip_status'::regclass)
            AND pg_get_constraintdef(oid) LIKE '%<= 99%')::text || ' of 8'
  UNION ALL SELECT 'structure','redundant alert indexes removed', true,
         NOT EXISTS (SELECT 1 FROM pg_indexes WHERE schemaname='rt'
                     AND indexname IN ('alert_active_period_alert_idx','alert_informed_alert_idx')), ''
  UNION ALL SELECT 'structure','alert dedup unique index exists', true,
         to_regclass('rt.alert_informed_unique_idx') IS NOT NULL, ''
  UNION ALL SELECT 'structure','roles ttc_app and ttc_rt exist', true,
         (SELECT count(*) FROM pg_roles WHERE rolname IN ('ttc_app','ttc_rt')) = 2, ''
  UNION ALL SELECT 'structure','today''s rt partition + default exist', true,
         to_regclass('rt.vehicle_samples_' || to_char(ops.today(),'YYYYMMDD')) IS NOT NULL
         AND to_regclass('rt.vehicle_samples_default') IS NOT NULL, ''
  UNION ALL SELECT 'structure','database timezone is America/Toronto', true,
         current_setting('TimeZone') = 'America/Toronto', current_setting('TimeZone')
  UNION ALL SELECT 'structure','extension pg_trgm', true,
         EXISTS (SELECT 1 FROM pg_extension WHERE extname='pg_trgm'), ''
  UNION ALL SELECT 'structure','extension pg_stat_statements', false,
         EXISTS (SELECT 1 FROM pg_extension WHERE extname='pg_stat_statements'), ''
  -- ---------------------------------------------------------------- feed data
  UNION ALL SELECT 'data','a real feed is active (not placeholder)', true,
         ops.active_version() IS NOT NULL AND ops.active_version() <> '__placeholder__',
         COALESCE(ops.active_version(),'none')
  UNION ALL SELECT 'data','ref.state matches the active feed', true,
         (SELECT feed_version FROM ref.state) IS NOT DISTINCT FROM ops.active_version(),
         COALESCE((SELECT feed_version FROM ref.state),'empty')
  UNION ALL SELECT 'data','ops.units row for active feed', true,
         EXISTS (SELECT 1 FROM ops.units WHERE feed_version = ops.active_version()),
         COALESCE((SELECT 'shape x'||shape_scale||', stop x'||stop_scale FROM ops.units
                   WHERE feed_version = ops.active_version()),'missing')
  UNION ALL SELECT 'data','core.stops loaded', true,
         (SELECT count(*) FROM core.stops WHERE feed_version = ops.active_version()) > 1000,
         (SELECT count(*) FROM core.stops WHERE feed_version = ops.active_version())::text
  UNION ALL SELECT 'data','core.trips loaded', true,
         (SELECT count(*) FROM core.trips WHERE feed_version = ops.active_version()) > 1000,
         (SELECT count(*) FROM core.trips WHERE feed_version = ops.active_version())::text
  UNION ALL SELECT 'data','core.stop_times loaded', true,
         (SELECT count(*) FROM core.stop_times WHERE feed_version = ops.active_version()) > 100000,
         (SELECT count(*) FROM core.stop_times WHERE feed_version = ops.active_version())::text
  UNION ALL SELECT 'data','core.shapes loaded', true,
         (SELECT count(*) FROM core.shapes WHERE feed_version = ops.active_version()) > 1000,
         (SELECT count(*) FROM core.shapes WHERE feed_version = ops.active_version())::text
  UNION ALL SELECT 'data','ref.stop_points / patterns built', true,
         (SELECT count(*) FROM ref.stop_points) > 1000 AND (SELECT count(*) FROM ref.patterns) > 100,
         (SELECT count(*) FROM ref.stop_points)::text || ' stops, '
         || (SELECT count(*) FROM ref.patterns)::text || ' patterns'
  UNION ALL SELECT 'data','ref.departures covers today', true,
         EXISTS (SELECT 1 FROM ref.departures WHERE service_date = ops.today()),
         COALESCE((SELECT min(service_date)::text || ' .. ' || max(service_date)::text
                   FROM ref.departures),'empty')
  UNION ALL SELECT 'data','departures reach at least 7 days ahead', true,
         COALESCE((SELECT max(service_date) FROM ref.departures), DATE '1970-01-01') >= ops.today() + 7,
         (SELECT (max(service_date) - ops.today())::text || ' days ahead' FROM ref.departures)
  UNION ALL SELECT 'data','feed valid for 5+ more days', true,
         COALESCE((SELECT end_date FROM core.feed_info WHERE feed_version = ops.active_version()),
                  DATE '1970-01-01') >= ops.today() + 5,
         COALESCE((SELECT (end_date - ops.today())::text || ' days left (ends ' || end_date || ')'
                   FROM core.feed_info WHERE feed_version = ops.active_version()),'unknown')
  UNION ALL SELECT 'data','next departures query returns rows', true,
         EXISTS (SELECT 1 FROM ref.departures WHERE boardable AND departs_at >= now() LIMIT 1), ''
  -- ----------------------------------------------------------------- realtime
  UNION ALL SELECT 'realtime','vehicles updated in last 2 min', false,
         COALESCE((SELECT max(received_at) FROM rt.vehicle_latest) > now() - interval '2 minutes', false),
         COALESCE((SELECT count(*) || ' vehicles, newest ' || round(extract(epoch FROM now() - max(received_at)))::text || 's ago'
                   FROM rt.vehicle_latest),'none')
  UNION ALL SELECT 'realtime','active trips present', false,
         EXISTS (SELECT 1 FROM rt.trip_status WHERE is_active),
         (SELECT count(*) FROM rt.trip_status WHERE is_active)::text || ' active'
  UNION ALL SELECT 'realtime','stop ETAs present', false,
         EXISTS (SELECT 1 FROM rt.stop_eta),
         (SELECT count(*) FROM rt.stop_eta)::text
  UNION ALL SELECT 'realtime','alerts present', false,
         EXISTS (SELECT 1 FROM rt.alert),
         (SELECT count(*) FROM rt.alert)::text || ' stored, '
         || (SELECT count(*) FROM rt.active_alerts)::text || ' active'
  UNION ALL SELECT 'realtime','no rows stuck in default partition', true,
         NOT EXISTS (SELECT 1 FROM rt.vehicle_samples_default),
         (SELECT count(*) FROM rt.vehicle_samples_default)::text || ' rows'
)
SELECT area, name,
       CASE WHEN ok THEN 'PASS' WHEN must THEN 'FAIL' ELSE 'WARN' END AS result,
       detail
FROM c
ORDER BY CASE area WHEN 'structure' THEN 1 WHEN 'data' THEN 2 ELSE 3 END, name;

SELECT 'SUMMARY' AS " ", ops.active_version() AS active_feed, now() AT TIME ZONE 'America/Toronto' AS toronto_time;