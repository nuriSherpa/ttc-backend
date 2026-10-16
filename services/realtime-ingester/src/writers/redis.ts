import type { Redis } from 'ioredis';
import type { Pool } from 'pg';

const LIVE_TTL_S = 45;
const MAX_PER_STOP = 8;
const SEG_TTL_S = 3600;
const SEG_MAX_SAMPLES = 20;
const ALERTS_TTL_S = 120;

const VEHICLES_SQL = `
SELECT vehicle_id, trip_id, route_id, direction_id, lat, lon, bearing, speed_mps,
       current_stop_id, current_stop_sequence,
       current_status, occupancy, current_ordinal, stops_remaining, service_state,
       extract(epoch FROM vehicle_ts)::bigint AS vehicle_ts
FROM rt.vehicle_latest
WHERE received_at > now() - interval '2 minutes'
`;

// One row per (stop, trip) in the next hour, with LIVE / EST / sched resolved.
const ARRIVALS_SQL = `
WITH win AS (
  SELECT d.stop_id, d.trip_id, d.service_date, d.ordinal, d.stop_sequence, d.departs_at,
         t.route_id, t.headsign
  FROM ref.departures d
  JOIN ref.trips t ON t.trip_id = d.trip_id
  WHERE d.boardable
    AND d.service_date BETWEEN ops.today() - 1 AND ops.today()
    AND d.departs_at BETWEEN now() - interval '5 minutes' AND now() + interval '60 minutes'
),
carry AS (
  SELECT DISTINCT ON (e.trip_id, e.service_date)
         e.trip_id, e.service_date, e.stop_sequence AS live_seq,
         e.predicted_at - d.departs_at AS delay
  FROM rt.stop_eta e
  JOIN ref.departures d
    ON d.trip_id = e.trip_id AND d.service_date = e.service_date
   AND d.stop_sequence = e.stop_sequence
  WHERE e.predicted_at > now() - interval '60 seconds'
  ORDER BY e.trip_id, e.service_date, e.stop_sequence DESC
),
joined AS (
  SELECT w.*, e.predicted_at, c.delay,
         v.vehicle_id, v.service_state, v.current_ordinal,
         d1.departs_at AS trip_start
  FROM win w
  LEFT JOIN rt.stop_eta e
    ON e.trip_id = w.trip_id AND e.service_date = w.service_date
   AND e.stop_sequence = w.stop_sequence
   AND e.predicted_at > now() - interval '60 seconds'
  LEFT JOIN carry c
    ON c.trip_id = w.trip_id AND c.service_date = w.service_date
   AND c.live_seq < w.stop_sequence
  LEFT JOIN rt.vehicle_latest v
    ON v.trip_id = w.trip_id AND v.received_at > now() - interval '2 minutes'
  LEFT JOIN ref.departures d1
    ON d1.service_date = w.service_date AND d1.trip_id = w.trip_id AND d1.ordinal = 1
  WHERE NOT (COALESCE(v.service_state,'') = 'in_service'
             AND COALESCE(v.current_ordinal,0) > w.ordinal)
    AND COALESCE(v.service_state,'') <> 'finished'
    AND NOT (COALESCE(v.service_state,'') = 'not_started'
             AND d1.departs_at < now() - interval '10 minutes')
),
final AS (
  SELECT stop_id, route_id, headsign, vehicle_id,
         CASE WHEN predicted_at IS NOT NULL THEN 'LIVE'
              WHEN service_state = 'in_service' AND delay IS NOT NULL THEN 'EST'
              ELSE 'sched' END AS src,
         CASE WHEN predicted_at IS NOT NULL THEN predicted_at
              WHEN service_state = 'in_service' AND delay IS NOT NULL THEN departs_at + delay
              ELSE departs_at END AS best_at,
         ordinal - current_ordinal AS stops_away
  FROM joined
)
SELECT stop_id, route_id, headsign, vehicle_id, src, stops_away,
       extract(epoch FROM best_at)::bigint AS at
FROM final
WHERE best_at > now() - interval '60 seconds'
ORDER BY stop_id, best_at
`;

// Currently active alerts + their informed entities (routes/stops affected).
const ALERTS_SQL = `
  SELECT a.alert_id, a.cause, a.effect, a.severity_level, a.header_text,
         extract(epoch FROM a.active_from)::bigint  AS active_from_s,
         extract(epoch FROM a.active_until)::bigint AS active_until_s,
         e.route_id, e.stop_id, e.direction_id
  FROM rt.alert a
  LEFT JOIN rt.alert_informed_entity e ON e.alert_id = a.alert_id
  WHERE (a.active_from IS NULL OR a.active_from <= now() + interval '10 minutes')
    AND (a.active_until IS NULL OR a.active_until >= now() - interval '5 minutes')
  ORDER BY a.alert_id, e.ordinal
`;

export interface PublishStats {
  vehicles: number;
  stops: number;
  segments: number;
  alerts: number;
  errors: number;
  ms: number;
}

// ---------------------------------------------------------------------------
// Module-level state for segment observation tracking.
// Persists across cycles while the process lives.
// ---------------------------------------------------------------------------

interface VehicleSnapshot {
  trip_id: string | null;
  route_id: string | null;
  stop_id: string;
  ordinal: number | null; // last known ordinal for stop_id (may arrive a cycle late)
  since: number; // vehicle_ts when this vehicle was FIRST seen at stop_id
  seen: number; // vehicle_ts of the latest observation (for pruning)
}

const lastVehicle = new Map<string, VehicleSnapshot>();
const segSamples = new Map<string, number[]>(); // key → rolling samples

export async function writeRedis(redis: Redis, pg: Pool): Promise<PublishStats> {
  const t0 = Date.now();

  const [veh, arr, alerts] = await Promise.all([
    pg.query(VEHICLES_SQL),
    pg.query(ARRIVALS_SQL),
    pg.query(ALERTS_SQL),
  ]);

  const nowS = Math.floor(Date.now() / 1000);
  const p = redis.pipeline();

  // --- vehicles: one JSON per vehicle + atomically swapped geo index ---
  const geoArgs: (string | number)[] = [];
  for (const v of veh.rows) {
    p.set(
      `veh:${v.vehicle_id}`,
      JSON.stringify({ v: 1, ...v, vehicle_ts: Number(v.vehicle_ts) }),
      'EX',
      LIVE_TTL_S,
    );
    if (v.lat != null && v.lon != null) geoArgs.push(v.lon, v.lat, v.vehicle_id);
  }
  if (geoArgs.length > 0) {
    p.del('geo:vehicles:tmp');
    p.geoadd('geo:vehicles:tmp', ...geoArgs);
    p.rename('geo:vehicles:tmp', 'geo:vehicles');
  } else {
    p.del('geo:vehicles');
  }

  // --- segment tracking (feeds the router's Layer 2) ---
  // Segment time = first sighting at stop A -> first sighting at the next stop B,
  // on the same trip. `since` only moves when the stop changes, so a vehicle that
  // sits at A for several cycles is timed from when it first showed up at A.
  for (const v of veh.rows) {
    const id: string = v.vehicle_id;
    const stopId: string | null = v.current_stop_id ?? null;
    const tripId: string | null = v.trip_id ?? null;
    const routeId: string | null = v.route_id ?? null;
    const ordinal: number | null = v.current_ordinal ?? null;
    const ts = Number(v.vehicle_ts);

    // No usable position this cycle: leave the stored state untouched.
    if (stopId == null || tripId == null || !Number.isFinite(ts)) continue;

    const prev = lastVehicle.get(id);

    // First sighting, or a new trip: start fresh (a new trip is a new stop sequence).
    if (!prev || prev.trip_id !== tripId) {
      lastVehicle.set(id, {
        trip_id: tripId,
        route_id: routeId,
        stop_id: stopId,
        ordinal,
        since: ts,
        seen: ts,
      });
      continue;
    }

    // Same stop as before: keep `since`; pick up an ordinal that arrived late.
    if (stopId === prev.stop_id) {
      prev.seen = ts;
      if (ordinal != null) prev.ordinal = ordinal;
      continue;
    }

    // Stop changed on the same trip. Only record adjacent stops (ordinal + 1);
    // a jump over several stops would store a multi-stop time as one segment.
    if (
      prev.route_id != null &&
      prev.ordinal != null &&
      ordinal != null &&
      ordinal === prev.ordinal + 1 &&
      ts > prev.since
    ) {
      const travel_s = ts - prev.since;
      if (travel_s > 0 && travel_s < 3600) {
        const hour = Number(
          new Intl.DateTimeFormat('en-CA', {
            hour: '2-digit',
            hourCycle: 'h23', // hour12:false can yield "24" at midnight on some ICU builds
            timeZone: 'America/Toronto',
          }).format(new Date(prev.since * 1000)),
        );
        const key = `${prev.route_id}:${prev.stop_id}:${stopId}:${hour}`;
        const samples = segSamples.get(key) ?? [];
        samples.push(travel_s);
        if (samples.length > SEG_MAX_SAMPLES) samples.shift();
        segSamples.set(key, samples);
      }
    }

    lastVehicle.set(id, {
      trip_id: tripId,
      route_id: routeId,
      stop_id: stopId,
      ordinal,
      since: ts,
      seen: ts,
    });
  }

  // Forget vehicles not seen for 15 minutes, so the map doesn't grow forever.
  for (const [id, s] of lastVehicle) {
    if (nowS - s.seen > 900) lastVehicle.delete(id);
  }

  // Write running medians + p90 for each segment. Skip segments with <3 samples.
  let segments = 0;
  for (const [key, samples] of segSamples) {
    if (samples.length < 3) continue;
    const sorted = [...samples].sort((a, b) => a - b);
    const med = sorted[Math.floor(sorted.length / 2)]!;
    const p90 = sorted[Math.floor(sorted.length * 0.9)]!;
    p.set(`seg:${key}`, JSON.stringify({ med, p90, n: samples.length }), 'EX', SEG_TTL_S);
    segments++;
  }

  // --- arrivals: one self-contained blob per stop ---
  let stops = 0;
  let curStop: string | null = null;
  let list: unknown[] = [];
  const flush = () => {
    if (curStop && list.length > 0) {
      p.set(
        `arr:${curStop}`,
        JSON.stringify({ v: 1, stop: curStop, at: nowS, arr: list }),
        'EX',
        LIVE_TTL_S,
      );
      stops++;
    }
  };
  for (const r of arr.rows) {
    if (r.stop_id !== curStop) {
      flush();
      curStop = r.stop_id;
      list = [];
    }
    if (list.length < MAX_PER_STOP) {
      list.push({
        route: r.route_id,
        headsign: r.headsign,
        at: Number(r.at),
        src: r.src,
        vehicle: r.vehicle_id,
        stops_away: r.stops_away,
      });
    }
  }
  flush();

  // --- alerts (feeds the router's Layer 3) ---
  const alertMap = new Map<
    string,
    {
      alert_id: string;
      cause: number | null;
      effect: number | null;
      severity: number | null;
      header: string | null;
      active_from: number | null;
      active_until: number | null;
      entities: Array<{
        route_id: string | null;
        stop_id: string | null;
        direction_id: number | null;
      }>;
    }
  >();

  for (const r of alerts.rows) {
    let a = alertMap.get(r.alert_id);
    if (!a) {
      a = {
        alert_id: r.alert_id,
        cause: r.cause,
        effect: r.effect,
        severity: r.severity_level,
        header: r.header_text,
        active_from: r.active_from_s != null ? Number(r.active_from_s) : null,
        active_until: r.active_until_s != null ? Number(r.active_until_s) : null,
        entities: [],
      };
      alertMap.set(r.alert_id, a);
    }
    if (r.route_id || r.stop_id || r.direction_id != null) {
      a.entities.push({
        route_id: r.route_id,
        stop_id: r.stop_id,
        direction_id: r.direction_id,
      });
    }
  }

  const alertList = [...alertMap.values()];
  p.set('alerts:active', JSON.stringify(alertList), 'EX', ALERTS_TTL_S);

  // --- heartbeat ---
  p.set(
    'meta:live',
    JSON.stringify({
      at: nowS,
      vehicles: veh.rowCount,
      stops,
      segments,
      alerts: alertList.length,
    }),
    'EX',
    60,
  );

  const res = await p.exec();
  const errors = (res ?? []).filter(([err]) => err).length;

  return {
    vehicles: veh.rowCount ?? 0,
    stops,
    segments,
    alerts: alertList.length,
    errors,
    ms: Date.now() - t0,
  };
}
