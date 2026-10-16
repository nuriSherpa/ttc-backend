export interface ParsedVehicle {
  vehicle_id: string;
  trip_id: string | null;
  route_id: string | null;
  direction_id: 0 | 1 | null;
  schedule_relationship: number | null;
  lat: number | null;
  lon: number | null;
  bearing: number | null;
  speed_mps: number | null;
  current_stop_id: string | null;
  current_stop_sequence: number | null;
  current_status: number | null;
  occupancy: number | null;
  vehicle_ts: Date | null;
}

export interface ParsedTripStop {
  stop_sequence: number;
  stop_id: string;
  arrival_time: Date | null;
  departure_time: Date | null;
  is_skipped: boolean;
}

export interface ParsedTrip {
  trip_id: string;
  route_id: string | null;
  direction_id: 0 | 1 | null;
  schedule_relationship: number | null;
  start_date: string | null; // YYYYMMDD from GTFS-RT
  vehicle_id: string | null;
  timestamp: Date | null;
  stops: ParsedTripStop[];
}

export interface ParsedAlert {
  alert_id: string;
  cause: number | null;
  effect: number | null;
  severity_level: number | null;
  header_text: string | null;
  description_text: string | null;
  tts_header_text: string | null;
  tts_description_text: string | null;
  url: string | null;
  active_periods: Array<{ start_at: Date | null; end_at: Date | null }>;
  informed_entities: Array<{
    agency_id: string | null;
    route_id: string | null;
    route_type: number | null;
    direction_id: number | null;
    trip_id: string | null;
    stop_id: string | null;
  }>;
}

export interface DecodedFeed {
  kind: 'vehicles' | 'trips' | 'alerts';
  entities: ParsedVehicle[] | ParsedTrip[] | ParsedAlert[];
}
