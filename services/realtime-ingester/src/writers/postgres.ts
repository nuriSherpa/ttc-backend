import type { Pool, PoolClient } from 'pg';
import type { ParsedVehicle, ParsedTrip, ParsedAlert } from '../decode/types.js';

export async function writeAll(
  pg: Pool,
  vehicles: ParsedVehicle[],
  trips: ParsedTrip[],
  alerts: ParsedAlert[],
): Promise<void> {
  const client = await pg.connect();
  try {
    await client.query('BEGIN');
    await client.query('SET LOCAL synchronous_commit = off');

    await writeVehicleLatest(client, vehicles);
    await writeVehicleProgress(client);
    await writeVehicleSamples(client, vehicles);
    await writeTripStatus(client, trips);
    await writeStopEta(client, trips);
    await writeAlerts(client, alerts);

    await client.query('COMMIT');
  } catch (err) {
    await client.query('ROLLBACK');
    throw err;
  } finally {
    client.release();
  }
}

async function writeVehicleLatest(client: PoolClient, rows: ParsedVehicle[]) {
  if (rows.length === 0) return;

  await client.query(
    `
    INSERT INTO rt.vehicle_latest (
      vehicle_id, trip_id, route_id, direction_id, schedule_relationship,
      lat, lon, bearing, speed_mps,
      current_stop_id, current_stop_sequence, current_status, occupancy,
      vehicle_ts, received_at
    )
    SELECT
      t.vehicle_id, t.trip_id, t.route_id, t.direction_id, t.schedule_relationship,
      t.lat, t.lon, t.bearing, t.speed_mps,
      t.current_stop_id, t.current_stop_sequence, t.current_status, t.occupancy,
      t.vehicle_ts, now()
    FROM UNNEST(
      $1::text[], $2::text[], $3::text[], $4::smallint[], $5::smallint[],
      $6::double precision[], $7::double precision[], $8::real[], $9::real[],
      $10::text[], $11::integer[], $12::smallint[], $13::smallint[],
      $14::timestamptz[]
    ) AS t(
      vehicle_id, trip_id, route_id, direction_id, schedule_relationship,
      lat, lon, bearing, speed_mps,
      current_stop_id, current_stop_sequence, current_status, occupancy,
      vehicle_ts
    )
    ON CONFLICT (vehicle_id) DO UPDATE SET
      trip_id               = EXCLUDED.trip_id,
      route_id              = EXCLUDED.route_id,
      direction_id          = EXCLUDED.direction_id,
      schedule_relationship = EXCLUDED.schedule_relationship,
      lat                   = EXCLUDED.lat,
      lon                   = EXCLUDED.lon,
      bearing               = EXCLUDED.bearing,
      speed_mps             = EXCLUDED.speed_mps,
      current_stop_id       = EXCLUDED.current_stop_id,
      current_stop_sequence = EXCLUDED.current_stop_sequence,
      current_status        = EXCLUDED.current_status,
      occupancy             = EXCLUDED.occupancy,
      vehicle_ts            = EXCLUDED.vehicle_ts,
      received_at           = now()
  `,
    [
      rows.map((r) => r.vehicle_id),
      rows.map((r) => r.trip_id),
      rows.map((r) => r.route_id),
      rows.map((r) => r.direction_id),
      rows.map((r) => r.schedule_relationship),
      rows.map((r) => r.lat),
      rows.map((r) => r.lon),
      rows.map((r) => r.bearing),
      rows.map((r) => r.speed_mps),
      rows.map((r) => r.current_stop_id),
      rows.map((r) => r.current_stop_sequence),
      rows.map((r) => r.current_status),
      rows.map((r) => r.occupancy),
      rows.map((r) => r.vehicle_ts),
    ],
  );
}

/**
 * Derives trip progress for the vehicle_latest rows upserted this cycle.
 * Runs in the same transaction, so now() equals the received_at just written.
 * Every row is rewritten each cycle (including 'unknown'), so a bus that
 * switches trips never keeps stale progress values.
 *
 * stops_remaining = stops AFTER the current ordinal (max_ordinal - current_ordinal).
 */
async function writeVehicleProgress(client: PoolClient) {
  await client.query(
    `
    WITH cur AS (
      SELECT
        v.vehicle_id,
        v.current_status,
        c.ordinal AS cur_ord,
        (SELECT max(ts.ordinal) FROM ref.trip_stops ts WHERE ts.trip_id = v.trip_id) AS max_ord
      FROM rt.vehicle_latest v
      LEFT JOIN ref.trip_stops c
        ON c.trip_id = v.trip_id
       AND c.stop_sequence = v.current_stop_sequence
      WHERE v.received_at = now()
    )
    UPDATE rt.vehicle_latest v
    SET current_ordinal = cur.cur_ord,
        stops_remaining = cur.max_ord - cur.cur_ord,
        service_state = CASE
          WHEN cur.cur_ord IS NULL THEN 'unknown'
          WHEN cur.cur_ord = 1 THEN 'not_started'
          WHEN cur.cur_ord >= cur.max_ord AND cur.current_status = 1 THEN 'finished'
          ELSE 'in_service'
        END
    FROM cur
    WHERE v.vehicle_id = cur.vehicle_id
  `,
  );
}

async function writeVehicleSamples(client: PoolClient, rows: ParsedVehicle[]) {
  if (rows.length === 0) return;

  await client.query(
    `
    INSERT INTO rt.vehicle_samples (
      vehicle_id, trip_id, route_id, direction_id,
      lat, lon, bearing, speed_mps,
      current_stop_id, current_stop_sequence, current_status, occupancy,
      vehicle_ts
    )
    SELECT
      t.vehicle_id, t.trip_id, t.route_id, t.direction_id,
      t.lat, t.lon, t.bearing, t.speed_mps,
      t.current_stop_id, t.current_stop_sequence, t.current_status, t.occupancy,
      t.vehicle_ts
    FROM UNNEST(
      $1::text[], $2::text[], $3::text[], $4::smallint[],
      $5::double precision[], $6::double precision[], $7::real[], $8::real[],
      $9::text[], $10::integer[], $11::smallint[], $12::smallint[],
      $13::timestamptz[]
    ) AS t(
      vehicle_id, trip_id, route_id, direction_id,
      lat, lon, bearing, speed_mps,
      current_stop_id, current_stop_sequence, current_status, occupancy,
      vehicle_ts
    )
  `,
    [
      rows.map((r) => r.vehicle_id),
      rows.map((r) => r.trip_id),
      rows.map((r) => r.route_id),
      rows.map((r) => r.direction_id),
      rows.map((r) => r.lat),
      rows.map((r) => r.lon),
      rows.map((r) => r.bearing),
      rows.map((r) => r.speed_mps),
      rows.map((r) => r.current_stop_id),
      rows.map((r) => r.current_stop_sequence),
      rows.map((r) => r.current_status),
      rows.map((r) => r.occupancy),
      rows.map((r) => r.vehicle_ts),
    ],
  );
}

async function writeTripStatus(client: PoolClient, rows: ParsedTrip[]) {
  if (rows.length === 0) return;

  const torontoToday = new Intl.DateTimeFormat('en-CA', {
    timeZone: 'America/Toronto',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).format(new Date());

  const final = rows.map((r) => ({
    trip_id: r.trip_id,
    service_date:
      r.start_date && /^\d{8}$/.test(r.start_date)
        ? `${r.start_date.slice(0, 4)}-${r.start_date.slice(4, 6)}-${r.start_date.slice(6, 8)}`
        : torontoToday,
    route_id: r.route_id,
    direction_id: r.direction_id,
    vehicle_id: r.vehicle_id,
    schedule_relationship: r.schedule_relationship,
  }));

  await client.query(
    `
    INSERT INTO rt.trip_status (
      trip_id, service_date, route_id, direction_id, vehicle_id,
      schedule_relationship,
      received_at, is_active
    )
    SELECT
      t.trip_id, t.service_date::date, t.route_id, t.direction_id, t.vehicle_id,
      t.schedule_relationship,
      now(), true
    FROM UNNEST(
      $1::text[], $2::text[], $3::text[], $4::smallint[], $5::text[],
      $6::smallint[]
    ) AS t(
      trip_id, service_date, route_id, direction_id, vehicle_id,
      schedule_relationship
    )
    ON CONFLICT (trip_id, service_date) DO UPDATE SET
      route_id              = EXCLUDED.route_id,
      direction_id          = EXCLUDED.direction_id,
      vehicle_id            = EXCLUDED.vehicle_id,
      schedule_relationship = EXCLUDED.schedule_relationship,
      received_at           = now(),
      is_active             = true
  `,
    [
      final.map((f) => f.trip_id),
      final.map((f) => f.service_date),
      final.map((f) => f.route_id),
      final.map((f) => f.direction_id),
      final.map((f) => f.vehicle_id),
      final.map((f) => f.schedule_relationship),
    ],
  );
}

async function writeStopEta(client: PoolClient, trips: ParsedTrip[]) {
  // Sweep expired ETAs and stale rows from previous cycles.
  await client.query(`DELETE FROM rt.stop_eta WHERE predicted_at < now() - interval '1 minute'`);
  await client.query(`DELETE FROM rt.stop_eta WHERE received_at < now() - interval '2 minutes'`);

  const withStops = trips.filter((t) => t.stops.length > 0);
  if (withStops.length === 0) return;
  const tripIds = withStops.map((t) => t.trip_id);

  // 1. Service date per trip, plus vehicle position when it is fresh and on the same trip.
  const { rows: vehRows } = await client.query<{
    trip_id: string;
    service_date: string;
    current_stop_sequence: number | null;
    current_status: number | null;
  }>(
    `
    SELECT ts.trip_id, ts.service_date::text,
           v.current_stop_sequence, v.current_status
    FROM rt.trip_status ts
    LEFT JOIN rt.vehicle_latest v
      ON v.vehicle_id = ts.vehicle_id
     AND v.trip_id = ts.trip_id
     AND v.current_stop_sequence IS NOT NULL
     AND v.received_at > now() - interval '3 minutes'
    WHERE ts.trip_id = ANY($1::text[])
  `,
    [tripIds],
  );
  const vehMap = new Map(vehRows.map((r) => [r.trip_id, r]));

  // 2. Full ordered stop list per trip
  const { rows: stopRows } = await client.query<{
    trip_id: string;
    ordinal: number;
    stop_sequence: number;
    stop_id: string;
  }>(
    `SELECT trip_id, ordinal, stop_sequence, stop_id
     FROM ref.trip_stops WHERE trip_id = ANY($1::text[])
     ORDER BY trip_id, ordinal`,
    [tripIds],
  );
  type Stop = { ordinal: number; stop_sequence: number; stop_id: string };
  const stopsByTrip = new Map<string, Stop[]>();
  for (const r of stopRows) {
    let arr = stopsByTrip.get(r.trip_id);
    if (!arr) stopsByTrip.set(r.trip_id, (arr = []));
    arr.push({ ordinal: r.ordinal, stop_sequence: r.stop_sequence, stop_id: r.stop_id });
  }

  // 3. Map TTC updates onto our stops
  const flat: Array<{
    trip_id: string;
    service_date: string;
    stop_sequence: number;
    stop_id: string;
    predicted_at: Date;
    is_skipped: boolean;
  }> = [];

  const GRACE_MS = 30_000;
  const cutoff = Date.now() - GRACE_MS;
  const timeOf = (s: ParsedTrip['stops'][number]) => s.arrival_time ?? s.departure_time ?? null;
  const stats = { by_seq: 0, by_pos: 0, seq_rejected: 0, no_anchor: 0, past_dropped: 0 };

  for (const t of withStops) {
    const veh = vehMap.get(t.trip_id);
    const schedule = stopsByTrip.get(t.trip_id);
    if (!veh || !schedule) continue;

    const service_date = veh.service_date;
    const curOrd =
      veh.current_stop_sequence != null
        ? schedule.find((s) => s.stop_sequence === veh.current_stop_sequence)?.ordinal
        : undefined;

    // Drop updates whose time has already passed (TTC includes stops the bus left).
    const live = t.stops.filter((s) => {
      const p = timeOf(s);
      if (!p || p.getTime() < cutoff) {
        stats.past_dropped++;
        return false;
      }
      return true;
    });
    if (live.length === 0) continue;

    // Method A: match on TTC's own stop_sequence.
    const bySeq = new Map(schedule.map((s) => [s.stop_sequence, s]));
    const matched = live.filter((s) => bySeq.has(s.stop_sequence));
    let useSeq = matched.length > 0 && matched.length >= Math.ceil(live.length * 0.9);

    // Sanity check against the vehicle feed: the first live entry should be at or
    // near the bus's current stop. If not, the sequences likely mean something else.
    if (useSeq && curOrd != null) {
      const firstOrd = bySeq.get(matched[0]!.stop_sequence)!.ordinal;
      if (Math.abs(firstOrd - curOrd) > 3) {
        useSeq = false;
        stats.seq_rejected++;
      }
    }

    if (useSeq) {
      stats.by_seq++;
      for (const u of matched) {
        const ours = bySeq.get(u.stop_sequence)!;
        flat.push({
          trip_id: t.trip_id,
          service_date,
          stop_sequence: ours.stop_sequence,
          stop_id: ours.stop_id,
          predicted_at: timeOf(u)!,
          is_skipped: u.is_skipped,
        });
      }
      continue;
    }

    // Method B: position anchor. After dropping past entries, live[0] is the bus's
    // next stop: its current stop if INCOMING_AT/IN_TRANSIT_TO, the following one
    // if STOPPED_AT.
    if (curOrd == null) {
      stats.no_anchor++;
      continue;
    }
    const stoppedAt = veh.current_status === 1;
    const rest =
      stoppedAt && live[0]!.stop_sequence === veh.current_stop_sequence ? live.slice(1) : live;
    const upcoming = schedule.filter((s) => s.ordinal >= (stoppedAt ? curOrd + 1 : curOrd));
    const limit = Math.min(rest.length, upcoming.length);
    stats.by_pos++;
    for (let i = 0; i < limit; i++) {
      const u = rest[i]!;
      const ours = upcoming[i]!;
      flat.push({
        trip_id: t.trip_id,
        service_date,
        stop_sequence: ours.stop_sequence,
        stop_id: ours.stop_id,
        predicted_at: timeOf(u)!,
        is_skipped: u.is_skipped,
      });
    }
  }

  console.log(
    JSON.stringify({
      level: 'info',
      msg: 'eta mapping',
      trips: withStops.length,
      rows: flat.length,
      ...stats,
    }),
  );

  // 4. Replace ETAs for these trips (also clears stale rows when nothing maps)
  await client.query(`DELETE FROM rt.stop_eta WHERE trip_id = ANY($1::text[])`, [tripIds]);
  if (flat.length === 0) return;

  await client.query(
    `
    INSERT INTO rt.stop_eta (
      trip_id, service_date, stop_sequence, stop_id,
      predicted_at, is_skipped, received_at
    )
    SELECT
      t.trip_id, t.service_date::date, t.stop_sequence, t.stop_id,
      t.predicted_at, t.is_skipped, now()
    FROM UNNEST(
      $1::text[], $2::text[], $3::integer[], $4::text[],
      $5::timestamptz[], $6::boolean[]
    ) AS t(trip_id, service_date, stop_sequence, stop_id, predicted_at, is_skipped)
    ON CONFLICT (trip_id, service_date, stop_sequence) DO UPDATE SET
      stop_id      = EXCLUDED.stop_id,
      predicted_at = EXCLUDED.predicted_at,
      is_skipped   = EXCLUDED.is_skipped,
      received_at  = now()
  `,
    [
      flat.map((r) => r.trip_id),
      flat.map((r) => r.service_date),
      flat.map((r) => r.stop_sequence),
      flat.map((r) => r.stop_id),
      flat.map((r) => r.predicted_at),
      flat.map((r) => r.is_skipped),
    ],
  );
}

async function writeAlerts(client: PoolClient, rows: ParsedAlert[]) {
  const currentIds = rows.map((r) => r.alert_id);
  const idArray = currentIds.length > 0 ? currentIds : ['__none__'];

  await client.query(
    `DELETE FROM rt.alert_informed_entity WHERE alert_id NOT IN (SELECT unnest($1::text[]))`,
    [idArray],
  );
  await client.query(
    `DELETE FROM rt.alert_active_period WHERE alert_id NOT IN (SELECT unnest($1::text[]))`,
    [idArray],
  );
  await client.query(`DELETE FROM rt.alert WHERE alert_id NOT IN (SELECT unnest($1::text[]))`, [
    idArray,
  ]);

  if (rows.length === 0) return;

  const activeFrom = rows.map((r) =>
    r.active_periods.length > 0
      ? (r.active_periods
          .map((p) => p.start_at)
          .filter((d): d is Date => !!d)
          .sort((a, b) => a.getTime() - b.getTime())[0] ?? null)
      : null,
  );
  const activeUntil = rows.map((r) =>
    r.active_periods.length > 0
      ? (r.active_periods
          .map((p) => p.end_at)
          .filter((d): d is Date => !!d)
          .sort((a, b) => b.getTime() - a.getTime())[0] ?? null)
      : null,
  );

  await client.query(
    `
    INSERT INTO rt.alert (
      alert_id, cause, effect, severity_level,
      header_text, description_text, tts_header_text, tts_description_text,
      url, active_from, active_until, received_at
    )
    SELECT
      t.alert_id, t.cause, t.effect, t.severity_level,
      t.header_text, t.description_text, t.tts_header_text, t.tts_description_text,
      t.url, t.active_from, t.active_until, now()
    FROM UNNEST(
      $1::text[], $2::smallint[], $3::smallint[], $4::smallint[],
      $5::text[], $6::text[], $7::text[], $8::text[],
      $9::text[], $10::timestamptz[], $11::timestamptz[]
    ) AS t(
      alert_id, cause, effect, severity_level,
      header_text, description_text, tts_header_text, tts_description_text,
      url, active_from, active_until
    )
    ON CONFLICT (alert_id) DO UPDATE SET
      cause = EXCLUDED.cause,
      effect = EXCLUDED.effect,
      severity_level = EXCLUDED.severity_level,
      header_text = EXCLUDED.header_text,
      description_text = EXCLUDED.description_text,
      tts_header_text = EXCLUDED.tts_header_text,
      tts_description_text = EXCLUDED.tts_description_text,
      url = EXCLUDED.url,
      active_from = EXCLUDED.active_from,
      active_until = EXCLUDED.active_until,
      received_at = now()
  `,
    [
      rows.map((r) => r.alert_id),
      rows.map((r) => r.cause),
      rows.map((r) => r.effect),
      rows.map((r) => r.severity_level),
      rows.map((r) => r.header_text),
      rows.map((r) => r.description_text),
      rows.map((r) => r.tts_header_text),
      rows.map((r) => r.tts_description_text),
      rows.map((r) => r.url),
      activeFrom,
      activeUntil,
    ],
  );

  await client.query(`DELETE FROM rt.alert_active_period WHERE alert_id = ANY($1::text[])`, [
    currentIds,
  ]);
  const periods: Array<{
    alert_id: string;
    ordinal: number;
    start_at: Date | null;
    end_at: Date | null;
  }> = [];
  for (const r of rows) {
    r.active_periods.forEach((p, i) => {
      periods.push({ alert_id: r.alert_id, ordinal: i, start_at: p.start_at, end_at: p.end_at });
    });
  }
  if (periods.length > 0) {
    await client.query(
      `
      INSERT INTO rt.alert_active_period (alert_id, ordinal, start_at, end_at)
      SELECT * FROM UNNEST($1::text[], $2::integer[], $3::timestamptz[], $4::timestamptz[])
    `,
      [
        periods.map((p) => p.alert_id),
        periods.map((p) => p.ordinal),
        periods.map((p) => p.start_at),
        periods.map((p) => p.end_at),
      ],
    );
  }

  await client.query(`DELETE FROM rt.alert_informed_entity WHERE alert_id = ANY($1::text[])`, [
    currentIds,
  ]);
  const entities: Array<{
    alert_id: string;
    ordinal: number;
    agency_id: string | null;
    route_id: string | null;
    route_type: number | null;
    direction_id: number | null;
    trip_id: string | null;
    stop_id: string | null;
  }> = [];
  for (const r of rows) {
    r.informed_entities.forEach((e, i) => {
      entities.push({ alert_id: r.alert_id, ordinal: i, ...e });
    });
  }
  if (entities.length > 0) {
    await client.query(
      `
      INSERT INTO rt.alert_informed_entity (
        alert_id, ordinal, agency_id, route_id, route_type,
        direction_id, trip_id, stop_id
      )
      SELECT * FROM UNNEST(
        $1::text[], $2::integer[], $3::text[], $4::text[], $5::smallint[],
        $6::smallint[], $7::text[], $8::text[]
      )
      ON CONFLICT DO NOTHING
    `,
      [
        entities.map((e) => e.alert_id),
        entities.map((e) => e.ordinal),
        entities.map((e) => e.agency_id),
        entities.map((e) => e.route_id),
        entities.map((e) => e.route_type),
        entities.map((e) => e.direction_id),
        entities.map((e) => e.trip_id),
        entities.map((e) => e.stop_id),
      ],
    );
  }
}
