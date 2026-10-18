use std::collections::HashMap;
use std::sync::OnceLock;

use chrono::{DateTime, NaiveDate, Utc};

#[derive(Debug, Clone)]
pub struct Stop {
    pub id: u32,
    pub stop_id: String,
    pub name: String,
    pub lat: f64,
    pub lon: f64,
    pub wheelchair_boarding: Option<i16>,
    pub parent_station: Option<String>,
}

#[derive(Debug, Clone)]
pub struct Route {
    pub id: u32,
    pub route_id: String,
    pub short_name: Option<String>,
    pub long_name: Option<String>,
    pub route_type: i16,
    pub color: Option<String>,
    pub text_color: Option<String>,
}

#[derive(Debug, Clone)]
pub struct Trip {
    pub id: u32,
    pub trip_id: String,
    pub route_idx: u32,
    pub direction_id: Option<i16>,
    pub headsign: Option<String>,
    pub pattern_idx: u32,
    pub n_stops: u32,
}

#[derive(Debug, Clone, Copy)]
pub struct TripStop {
    pub stop_idx: u32,
    pub stop_sequence: i32,
    pub departure_s: Option<i32>,
    pub boardable: bool,
}

#[derive(Debug, Clone, Copy)]
pub struct Departure {
    pub trip_idx: u32,
    pub ordinal: i32,
    pub stop_sequence: i32,
    pub stop_idx: u32,
    pub departs_at: DateTime<Utc>,
    pub route_idx: u32,
    pub pattern_idx: u32,
    pub boardable: bool,
}

#[derive(Debug, Clone)]
pub struct Pattern {
    pub id: u32,
    pub pattern_id: String,
    pub route_idx: u32,
    pub direction_id: Option<i16>,
    pub headsign: Option<String>,
    pub n_stops: u32,
}

#[derive(Debug, Clone, Copy)]
pub struct PatternStop {
    pub stop_idx: u32,
    pub dist_m: Option<f64>,
}

#[derive(Debug, Clone)]
pub struct StationNode {
    pub id: u32,
    pub stop_id: String,
    pub station_id: Option<String>,
    pub name: String,
    pub location_type: i16,
    pub lat: Option<f64>,
    pub lon: Option<f64>,
    pub wheelchair_boarding: Option<i16>,
}

#[derive(Debug, Clone, Copy)]
pub struct PathwayEdge {
    pub from_idx: u32,
    pub to_idx: u32,
    pub mode: i16,
    pub traversal_s: Option<i32>,
    pub length_m: Option<f64>,
    pub stair_count: Option<i32>,
}

pub struct Graph {
    pub stops: Vec<Stop>,
    pub stop_idx_by_id: HashMap<String, u32>,

    pub routes: Vec<Route>,
    pub route_idx_by_id: HashMap<String, u32>,

    pub trips: Vec<Trip>,
    pub trip_idx_by_id: HashMap<String, u32>,

    pub trip_stops_flat: Vec<TripStop>,
    pub trip_stops_range: Vec<(u32, u32)>,

    pub departures_flat: Vec<Departure>,
    pub departures_range: HashMap<(u32, i32), (u32, u32)>,

    pub patterns: Vec<Pattern>,
    pub pattern_idx_by_id: HashMap<String, u32>,
    pub pattern_stops_flat: Vec<PatternStop>,
    pub pattern_stops_range: Vec<(u32, u32)>,

    pub station_nodes: Vec<StationNode>,
    pub station_idx_by_id: HashMap<String, u32>,

    pub pathway_edges: Vec<PathwayEdge>,
    pub pathway_edges_by_from: HashMap<u32, Vec<u32>>,

    pub feed_version: String,
    pub loaded_at: DateTime<Utc>,
    pub load_duration_ms: u64,
    pub horizon_days: i32,

    pub geo_index: super::geo::GeoIndex,
}

impl Graph {
    pub fn trip_stops(&self, trip_idx: u32) -> &[TripStop] {
        let (start, len) = self.trip_stops_range[trip_idx as usize];
        &self.trip_stops_flat[start as usize..(start + len) as usize]
    }

    pub fn departures_at(&self, stop_idx: u32, service_date: NaiveDate) -> Option<&[Departure]> {
        let key = (stop_idx, days_from_epoch(service_date));
        let (start, len) = *self.departures_range.get(&key)?;
        Some(&self.departures_flat[start as usize..(start + len) as usize])
    }
}

fn epoch() -> NaiveDate {
    static EPOCH: OnceLock<NaiveDate> = OnceLock::new();
    *EPOCH.get_or_init(|| NaiveDate::from_ymd_opt(1970, 1, 1).unwrap())
}

pub fn days_from_epoch(d: NaiveDate) -> i32 {
    d.signed_duration_since(epoch()).num_days() as i32
}