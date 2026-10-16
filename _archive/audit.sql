CREATE OR REPLACE VIEW feed_info      AS SELECT * FROM read_csv('feed_info.txt', all_varchar=true);
CREATE OR REPLACE VIEW agency         AS SELECT * FROM read_csv('agency.txt', all_varchar=true);
CREATE OR REPLACE VIEW stops          AS SELECT * FROM read_csv('stops.txt', all_varchar=true);
CREATE OR REPLACE VIEW routes         AS SELECT * FROM read_csv('routes.txt', all_varchar=true);
CREATE OR REPLACE VIEW trips          AS SELECT * FROM read_csv('trips.txt', all_varchar=true);
CREATE OR REPLACE VIEW stop_times     AS SELECT * FROM read_csv('stop_times.txt', all_varchar=true);
CREATE OR REPLACE VIEW shapes         AS SELECT * FROM read_csv('shapes.txt', all_varchar=true);
CREATE OR REPLACE VIEW calendar       AS SELECT * FROM read_csv('calendar.txt', all_varchar=true);
CREATE OR REPLACE VIEW calendar_dates AS SELECT * FROM read_csv('calendar_dates.txt', all_varchar=true);
CREATE OR REPLACE VIEW levels         AS SELECT * FROM read_csv('levels.txt', all_varchar=true);
CREATE OR REPLACE VIEW pathways       AS SELECT * FROM read_csv('pathways.txt', all_varchar=true);

CREATE OR REPLACE MACRO secs(t) AS
  CASE WHEN t IS NULL OR trim(t) = '' THEN NULL
       ELSE split_part(trim(t),':',1)::INT*3600 + split_part(trim(t),':',2)::INT*60 + split_part(trim(t),':',3)::INT END;

SELECT '=== 1. FEED / AGENCY ===' AS section;
SELECT * FROM feed_info;
SELECT * FROM agency;

SELECT '=== 2. CALENDAR + EXCEPTIONS ===' AS section;
SELECT * FROM calendar ORDER BY service_id;
SELECT * FROM calendar_dates ORDER BY date;
SELECT service_id, count(*) AS trips FROM trips GROUP BY 1 ORDER BY 2 DESC;

SELECT '=== 3. COLUMN PROFILE (null %, min, max, distinct) ===' AS section;
SELECT 'stops' AS file; SUMMARIZE SELECT * FROM stops;
SELECT 'routes' AS file; SUMMARIZE SELECT * FROM routes;
SELECT 'trips' AS file; SUMMARIZE SELECT * FROM trips;
SELECT 'stop_times' AS file; SUMMARIZE SELECT * FROM stop_times;
SELECT 'shapes' AS file; SUMMARIZE SELECT * FROM shapes;

SELECT '=== 4. ROUTES ===' AS section;
SELECT route_type, count(*) AS routes FROM routes GROUP BY 1 ORDER BY 1;
SELECT * FROM routes ORDER BY route_type, route_short_name LIMIT 15;
SELECT * FROM routes WHERE route_type <> '3' ORDER BY route_type, route_short_name;

SELECT '=== 5. STOPS ===' AS section;
SELECT location_type, count(*) AS n FROM stops GROUP BY 1 ORDER BY 1;
SELECT wheelchair_boarding, count(*) AS n FROM stops GROUP BY 1 ORDER BY 1;
SELECT count(*) FILTER (WHERE parent_station IS NOT NULL) AS with_parent,
       count(*) FILTER (WHERE stop_code IS NULL) AS no_stop_code,
       count(*) FILTER (WHERE stop_timezone IS NOT NULL) AS with_tz,
       min(stop_lat::DOUBLE) AS min_lat, max(stop_lat::DOUBLE) AS max_lat,
       min(stop_lon::DOUBLE) AS min_lon, max(stop_lon::DOUBLE) AS max_lon
FROM stops;
SELECT stop_code, count(*) AS dup FROM stops WHERE stop_code IS NOT NULL GROUP BY 1 HAVING count(*) > 1 LIMIT 10;
SELECT * FROM stops WHERE location_type = '0' LIMIT 5;
SELECT * FROM stops WHERE location_type = '1' LIMIT 5;
SELECT * FROM stops WHERE location_type = '2' LIMIT 3;

SELECT '=== 6. TRIPS ===' AS section;
SELECT direction_id, count(*) AS n FROM trips GROUP BY 1 ORDER BY 1;
SELECT wheelchair_accessible, count(*) AS n FROM trips GROUP BY 1 ORDER BY 1;
SELECT count(*) FILTER (WHERE trip_headsign IS NULL) AS no_headsign,
       count(*) FILTER (WHERE block_id IS NULL) AS no_block,
       count(*) FILTER (WHERE shape_id IS NULL) AS no_shape,
       count(DISTINCT block_id) AS blocks, count(DISTINCT shape_id) AS shapes_used,
       count(DISTINCT trip_headsign) AS headsigns
FROM trips;
SELECT r.route_type, count(*) AS trips FROM trips t JOIN routes r USING (route_id) GROUP BY 1 ORDER BY 1;
SELECT * FROM trips LIMIT 5;

SELECT '=== 7. STOP_TIMES ===' AS section;
SELECT * FROM stop_times LIMIT 8;
SELECT timepoint, count(*) AS n FROM stop_times GROUP BY 1 ORDER BY 1;
SELECT pickup_type, drop_off_type, count(*) AS n FROM stop_times GROUP BY 1, 2 ORDER BY 1, 2;
SELECT count(*) FILTER (WHERE arrival_time IS NULL) AS blank_arrival,
       count(*) FILTER (WHERE departure_time IS NULL) AS blank_departure,
       count(*) FILTER (WHERE shape_dist_traveled IS NULL) AS no_dist,
       count(*) FILTER (WHERE stop_headsign IS NOT NULL) AS with_stop_headsign,
       count(*) FILTER (WHERE secs(arrival_time) >= 86400) AS after_midnight,
       max(secs(departure_time)) AS max_secs
FROM stop_times;
SELECT count(*) AS arrival_after_departure FROM stop_times WHERE secs(arrival_time) > secs(departure_time);
WITH x AS (
  SELECT trip_id, stop_sequence::INT AS seq, secs(arrival_time) AS a, secs(departure_time) AS d FROM stop_times),
y AS (SELECT *, lag(d) OVER (PARTITION BY trip_id ORDER BY seq) AS prev_d FROM x)
SELECT count(*) AS time_goes_backwards FROM y WHERE a < prev_d;
SELECT count(*) AS trips_with_under_2_stops FROM (SELECT trip_id FROM stop_times GROUP BY 1 HAVING count(*) < 2);
SELECT count(*) AS duplicate_trip_seq FROM (SELECT trip_id, stop_sequence FROM stop_times GROUP BY 1,2 HAVING count(*) > 1);
SELECT min(n) AS min_stops, round(avg(n),1) AS avg_stops, max(n) AS max_stops FROM (SELECT count(*) AS n FROM stop_times GROUP BY trip_id);

SELECT '=== 8. SHAPES ===' AS section;
SELECT count(DISTINCT shape_id) AS shapes, count(*) AS points,
       count(*) FILTER (WHERE shape_dist_traveled IS NULL) AS no_dist FROM shapes;
SELECT * FROM shapes ORDER BY shape_id, shape_pt_sequence::INT LIMIT 5;

SELECT '=== 9. REFERENTIAL INTEGRITY (all should be 0) ===' AS section;
SELECT count(*) AS trips_without_route FROM trips t LEFT JOIN routes r USING (route_id) WHERE r.route_id IS NULL;
SELECT count(*) AS trips_without_service FROM trips t LEFT JOIN calendar c USING (service_id) WHERE c.service_id IS NULL;
SELECT count(*) AS trips_without_shape FROM trips t LEFT JOIN (SELECT DISTINCT shape_id FROM shapes) s USING (shape_id) WHERE t.shape_id IS NOT NULL AND s.shape_id IS NULL;
SELECT count(*) AS times_without_trip FROM stop_times st LEFT JOIN trips t USING (trip_id) WHERE t.trip_id IS NULL;
SELECT count(*) AS times_without_stop FROM stop_times st LEFT JOIN stops s USING (stop_id) WHERE s.stop_id IS NULL;
SELECT count(*) AS trips_without_stop_times FROM trips t LEFT JOIN (SELECT DISTINCT trip_id FROM stop_times) st USING (trip_id) WHERE st.trip_id IS NULL;
SELECT count(*) AS stops_never_served FROM stops s LEFT JOIN (SELECT DISTINCT stop_id FROM stop_times) st USING (stop_id) WHERE st.stop_id IS NULL AND s.location_type = '0';
SELECT count(*) AS orphan_parent FROM stops s LEFT JOIN stops p ON s.parent_station = p.stop_id WHERE s.parent_station IS NOT NULL AND p.stop_id IS NULL;

SELECT '=== 10. PATTERNS + BLOCKS ===' AS section;
WITH p AS (SELECT t.route_id, t.direction_id, t.shape_id, string_agg(st.stop_id, ',' ORDER BY st.stop_sequence::INT) AS stops
           FROM trips t JOIN stop_times st USING (trip_id) GROUP BY t.trip_id, t.route_id, t.direction_id, t.shape_id)
SELECT count(DISTINCT (route_id, direction_id, stops)) AS distinct_patterns FROM p;
SELECT round(avg(n),1) AS avg_trips_per_block, max(n) AS max_trips_per_block FROM (SELECT count(*) AS n FROM trips WHERE block_id IS NOT NULL GROUP BY block_id);

SELECT '=== 11. STATION DATA (skip for MVP) ===' AS section;
SELECT * FROM pathways LIMIT 3;
SELECT * FROM levels LIMIT 3;
