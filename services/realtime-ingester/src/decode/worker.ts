import { parentPort } from 'node:worker_threads';
import GtfsRealtimeBindings from 'gtfs-realtime-bindings';
import type {
  ParsedVehicle,
  ParsedTrip,
  ParsedAlert,
  ParsedTripStop,
  DecodedFeed,
} from './types.js';

const { transit_realtime } = GtfsRealtimeBindings as unknown as {
  transit_realtime: typeof import('gtfs-realtime-bindings').transit_realtime;
};

type Input = { kind: 'vehicles' | 'trips' | 'alerts'; bytes: Uint8Array };

function toDate(seconds: number | Long | null | undefined): Date | null {
  if (seconds == null) return null;
  const n = typeof seconds === 'number' ? seconds : Number(seconds);
  if (!Number.isFinite(n) || n <= 0) return null;
  return new Date(n * 1000);
}

function pickTranslation(t: any): string | null {
  if (!t?.translation?.length) return null;
  const en = t.translation.find((x: any) => x.language === 'en' || !x.language);
  const chosen = en ?? t.translation[0];
  return chosen?.text ?? null;
}

function decodeVehicles(feed: any): ParsedVehicle[] {
  const out: ParsedVehicle[] = [];
  for (const entity of feed.entity ?? []) {
    const v = entity.vehicle;
    if (!v) continue;
    out.push({
      vehicle_id: v.vehicle?.id ?? entity.id,
      trip_id: v.trip?.tripId ?? null,
      route_id: v.trip?.routeId ?? null,
      direction_id:
        v.trip?.directionId === 0 || v.trip?.directionId === 1 ? v.trip.directionId : null,
      schedule_relationship: v.trip?.scheduleRelationship ?? null,
      lat: v.position?.latitude ?? null,
      lon: v.position?.longitude ?? null,
      bearing: v.position?.bearing ?? null,
      speed_mps: v.position?.speed ?? null,
      current_stop_id: v.stopId ?? null,
      current_stop_sequence: v.currentStopSequence ?? null,
      current_status: v.currentStatus ?? null,
      occupancy: v.occupancyStatus ?? null,
      vehicle_ts: toDate(v.timestamp),
    });
  }
  return out;
}

function decodeTrips(feed: any): ParsedTrip[] {
  // TTC can emit multiple entities with the same trip_id (SCHEDULED + NEW).
  // Keep only the best one per trip_id.
  const byTripId = new Map<string, ParsedTrip>();

  for (const entity of feed.entity ?? []) {
    const tu = entity.tripUpdate;
    if (!tu?.trip?.tripId) continue;

    const stops: ParsedTripStop[] = [];
    for (const stu of tu.stopTimeUpdate ?? []) {
      if (stu.stopSequence == null || !stu.stopId) continue;
      stops.push({
        stop_sequence: stu.stopSequence,
        stop_id: stu.stopId,
        arrival_time: toDate(stu.arrival?.time),
        departure_time: toDate(stu.departure?.time),
        is_skipped: stu.scheduleRelationship === 1,
      });
    }

    const candidate: ParsedTrip = {
      trip_id: tu.trip.tripId,
      route_id: tu.trip.routeId ?? null,
      direction_id:
        tu.trip.directionId === 0 || tu.trip.directionId === 1 ? tu.trip.directionId : null,
      schedule_relationship: tu.trip.scheduleRelationship ?? null,
      start_date: tu.trip.startDate ?? null,
      vehicle_id: tu.vehicle?.id ?? null,
      timestamp: toDate(tu.timestamp),
      stops,
    };

    const existing = byTripId.get(candidate.trip_id);
    if (!existing) {
      byTripId.set(candidate.trip_id, candidate);
      continue;
    }

    // Prefer SCHEDULED (0) over NEW/ADDED (1, 7).
    // If both are the same, prefer the one with more stops.
    const isScheduled = (r: number | null) => r === 0;
    if (
      isScheduled(candidate.schedule_relationship) &&
      !isScheduled(existing.schedule_relationship)
    ) {
      byTripId.set(candidate.trip_id, candidate);
    } else if (
      isScheduled(existing.schedule_relationship) &&
      !isScheduled(candidate.schedule_relationship)
    ) {
      // keep existing
    } else if (candidate.stops.length > existing.stops.length) {
      byTripId.set(candidate.trip_id, candidate);
    }
  }

  return Array.from(byTripId.values());
}

function decodeAlerts(feed: any): ParsedAlert[] {
  const out: ParsedAlert[] = [];
  for (const entity of feed.entity ?? []) {
    const a = entity.alert;
    if (!a) continue;

    // Deduplicate informed_entity by composite key
    const seen = new Set<string>();
    const entities: ParsedAlert['informed_entities'] = [];
    for (const ie of a.informedEntity ?? []) {
      const key = [
        ie.agencyId ?? '',
        ie.routeId ?? '',
        ie.routeType ?? '',
        ie.directionId ?? '',
        ie.trip?.tripId ?? '',
        ie.stopId ?? '',
      ].join('|');
      if (seen.has(key)) continue;
      seen.add(key);
      entities.push({
        agency_id: ie.agencyId ?? null,
        route_id: ie.routeId ?? null,
        route_type: ie.routeType ?? null,
        direction_id: ie.directionId ?? null,
        trip_id: ie.trip?.tripId ?? null,
        stop_id: ie.stopId ?? null,
      });
    }

    const periods: ParsedAlert['active_periods'] = (a.activePeriod ?? []).map((p: any) => ({
      start_at: toDate(p.start),
      end_at: toDate(p.end),
    }));

    out.push({
      alert_id: entity.id,
      cause: a.cause ?? null,
      effect: a.effect ?? null,
      severity_level: a.severityLevel ?? null,
      header_text: pickTranslation(a.headerText),
      description_text: pickTranslation(a.descriptionText),
      tts_header_text: pickTranslation(a.ttsHeaderText),
      tts_description_text: pickTranslation(a.ttsDescriptionText),
      url: pickTranslation(a.url),
      active_periods: periods,
      informed_entities: entities,
    });
  }
  return out;
}

parentPort?.on('message', (input: Input) => {
  try {
    const feed = transit_realtime.FeedMessage.decode(input.bytes);
    let entities: DecodedFeed['entities'];
    switch (input.kind) {
      case 'vehicles':
        entities = decodeVehicles(feed);
        break;
      case 'trips':
        entities = decodeTrips(feed);
        break;
      case 'alerts':
        entities = decodeAlerts(feed);
        break;
    }
    parentPort!.postMessage({ ok: true, kind: input.kind, entities });
  } catch (err) {
    parentPort!.postMessage({ ok: false, error: String((err as Error).message) });
  }
});
