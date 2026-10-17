import type { Pool } from 'pg';
import type { Logger } from '../logger.js';

interface LastState {
  trip_id: string | null;
  ordinal: number | null;
  stop_id: string | null;
  seen: number;
}

interface Transition {
  vehicle_id: string;
  trip_id: string;
  route_id: string;
  direction_id: number;
  current_ordinal: number;
  vehicle_ts: Date;
}

const lastState = new Map<string, LastState>();
const PRUNE_SECONDS = 900;

// TTC's RT feed uses ghost stop_ids that don't exist in their static GTFS.
// Match by (route_id, direction_id, ordinal) instead of (trip_id, stop_id) —
// the same position-based approach used for ETA mapping.
//
// ORDER BY priority (important for high-frequency routes):
//   1. Exact trip_id match — if TTC's RT trip_id is in ref.departures, use it
//   2. Past departures before future — a late bus should match its own
//      (past) scheduled departure, not the next trip's on-time departure
//   3. Closest in absolute time — the tiebreaker
//
// Without #2, a bus running 10 min late on a 5-min-headway route matches the
// next trip's on-time departure, producing a phantom "on-time" record and
// leaving the actual late trip unrecorded. This was causing 14-min spreads
// within a single trip_id.
const BATCH_INSERT_SQL = `
  WITH input AS (
    SELECT * FROM unnest(
      $1::text[], $2::text[], $3::text[], $4::int[], $5::int[], $6::timestamptz[]
    ) AS t(vehicle_id, trip_id, route_id, direction_id, current_ordinal, vehicle_ts)
  ),
  matched AS (
    SELECT
      i.vehicle_id,
      i.trip_id,
      i.vehicle_ts,
      d.departs_at,
      d.route_id,
      d.direction_id,
      d.stop_id
    FROM input i
    JOIN LATERAL (
      SELECT d.departs_at, d.route_id, d.direction_id, d.stop_id
      FROM ref.departures d
      WHERE d.route_id     = i.route_id
        AND d.direction_id = i.direction_id
        AND d.ordinal      = i.current_ordinal - 1
        AND d.service_date BETWEEN ops.today() - 1 AND ops.today()
        AND d.departs_at BETWEEN i.vehicle_ts - interval '15 minutes'
                             AND i.vehicle_ts + interval '2 minutes'
      ORDER BY
        (d.trip_id = i.trip_id) DESC,
        CASE WHEN d.departs_at <= i.vehicle_ts THEN 0 ELSE 1 END,
        abs(EXTRACT(EPOCH FROM (d.departs_at - i.vehicle_ts)))
      LIMIT 1
    ) d ON true
  )
  INSERT INTO data.delay_observation (
    observed_date, hour_bucket, day_of_week,
    route_id, direction_id, trip_id, stop_id,
    scheduled_at, observed_at, delay_seconds,
    vehicle_id, sample_source
  )
  SELECT
    (m.vehicle_ts AT TIME ZONE 'America/Toronto')::date,
    EXTRACT(HOUR FROM m.vehicle_ts AT TIME ZONE 'America/Toronto')::smallint,
    EXTRACT(DOW  FROM m.vehicle_ts AT TIME ZONE 'America/Toronto')::smallint,
    m.route_id, m.direction_id, m.trip_id, m.stop_id,
    m.departs_at,
    m.vehicle_ts,
    EXTRACT(EPOCH FROM (m.vehicle_ts - m.departs_at))::int,
    m.vehicle_id,
    'ttc_feed'
  FROM matched m
  ON CONFLICT (trip_id, stop_id, observed_date) DO NOTHING
  RETURNING observation_id
`;

export interface DelayStats {
  transitions: number;
  written: number;
  errors: number;
  ms: number;
}

export async function writeDelays(pg: Pool, log: Logger): Promise<DelayStats> {
  const t0 = Date.now();
  let written = 0;
  let errors = 0;

  const { rows } = await pg.query<{
    vehicle_id: string;
    trip_id: string | null;
    route_id: string | null;
    direction_id: number | null;
    current_ordinal: number | null;
    current_stop_id: string | null;
    vehicle_ts: Date | null;
  }>(`
    SELECT vehicle_id, trip_id, route_id, direction_id,
           current_ordinal, current_stop_id, vehicle_ts
      FROM rt.vehicle_latest
     WHERE received_at > now() - interval '2 minutes'
  `);

  const nowSec = Math.floor(Date.now() / 1000);
  const transitions: Transition[] = [];

  for (const v of rows) {
    const prev = lastState.get(v.vehicle_id);

    const curr: LastState = {
      trip_id: v.trip_id,
      ordinal: v.current_ordinal,
      stop_id: v.current_stop_id,
      seen: nowSec,
    };

    // Detect transition: same trip, ordinal increased, valid timestamp + route
    if (
      prev &&
      prev.trip_id != null &&
      curr.trip_id != null &&
      prev.trip_id === curr.trip_id &&
      prev.ordinal != null &&
      curr.ordinal != null &&
      curr.ordinal > prev.ordinal &&
      v.route_id != null &&
      v.direction_id != null &&
      v.vehicle_ts != null
    ) {
      transitions.push({
        vehicle_id: v.vehicle_id,
        trip_id: curr.trip_id,
        route_id: v.route_id,
        direction_id: v.direction_id,
        current_ordinal: curr.ordinal,
        vehicle_ts: v.vehicle_ts,
      });
    }

    lastState.set(v.vehicle_id, curr);
  }

  // One query for all transitions
  if (transitions.length > 0) {
    try {
      const res = await pg.query(BATCH_INSERT_SQL, [
        transitions.map((t) => t.vehicle_id),
        transitions.map((t) => t.trip_id),
        transitions.map((t) => t.route_id),
        transitions.map((t) => t.direction_id),
        transitions.map((t) => t.current_ordinal),
        transitions.map((t) => t.vehicle_ts),
      ]);
      written = res.rowCount ?? 0;
    } catch (err) {
      errors = 1;
      log.error({ err: String(err), count: transitions.length }, 'batch delay insert failed');
    }
  }

  // Prune stale vehicles
  for (const [id, s] of lastState) {
    if (nowSec - s.seen > PRUNE_SECONDS) lastState.delete(id);
  }

  return { transitions: transitions.length, written, errors, ms: Date.now() - t0 };
}
