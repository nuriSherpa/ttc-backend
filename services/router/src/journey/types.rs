//! Layer 6 — production JSON shapes for journey assembly.
//!
//! These types are the API-facing response format, distinct from the raw
//! `raptor::raptor::Journey` (which uses `depart_s: u32` offsets and
//! `stop_idx: u32`). Assembly converts one into the other.

use chrono::{DateTime, Utc};
use serde::Serialize;

use crate::walk::types::WalkBreakdown;

/// Top-level response for a single journey.
///
/// `total_seconds == total_transit_seconds + total_wait_seconds
///                  + total_walk_seconds` (plus any dwells, empty for Layer 6).
#[derive(Debug, Clone, Serialize)]
pub struct JourneyResponse {
    pub legs: Vec<ResponseLeg>,

    pub depart_at: DateTime<Utc>,
    pub arrive_at: DateTime<Utc>,
    pub total_seconds: u32,

    // Category totals — always sum to total_seconds (Layer 6: no dwells).
    pub total_transit_seconds: u32,
    pub total_wait_seconds: u32,
    pub total_walk_seconds: u32,

    pub total_walk_m: f64,

    /// RAPTOR's count of transfer-relaxation steps. Includes long
    /// "walks-to-destination-stop" that RAPTOR treats as transfers
    /// (e.g. Test 6's Warden→Roper walk before DestWalk). Use for
    /// diagnostics only — prefer `real_transfers` for scoring/display.
    pub num_transfers: u8,

    /// Real transfers = (number of Transit legs) - 1.
    ///
    /// Definitionally correct: every Transit leg after the first
    /// required a transfer to reach. Independent of how RAPTOR
    /// structures the intermediate walk legs, so it survives any
    /// change to transfer-table behavior. This is what scoring uses.
    pub real_transfers: u8,

    /// Empty until Layer 6.5 (waypoints).
    pub waypoint_arrivals: Vec<WaypointArrival>,
}

/// One leg of the journey, tagged with `"kind"` in JSON.
#[derive(Debug, Clone, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum ResponseLeg {
    Walk(WalkLeg),
    Transit(TransitLeg),
    Wait(WaitLeg),
    #[allow(dead_code)] // Layer 6.5 (waypoints)
    Dwell(DwellLeg),
}

/// Which role this walk plays in the journey.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum WalkKind {
    Origin,
    Transfer,
    Destination,
}

#[derive(Debug, Clone, Serialize)]
pub struct WalkLeg {
    pub walk_kind: WalkKind,
    pub from: Location,
    pub to: Location,
    pub depart_at: DateTime<Utc>,
    pub arrive_at: DateTime<Utc>,
    pub duration_s: u32,
    pub distance_m: f64,
    pub distance_m_straight: f64,
    pub detour_factor: f64,

    /// Full ingredient audit trail when available (origin/dest walks).
    /// Transfer walks are derived from `transfer_table` and carry `None`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub breakdown: Option<WalkBreakdown>,
}

#[derive(Debug, Clone, Serialize)]
pub struct TransitLeg {
    pub route: RouteInfo,
    pub headsign: String,
    pub from_stop: StopInfo,
    pub to_stop: StopInfo,
    pub depart_at: DateTime<Utc>,
    pub arrive_at: DateTime<Utc>,
    pub duration_s: u32,
    /// Stops passed through strictly between `from_stop` and `to_stop`.
    pub intermediate_stops: Vec<IntermediateStop>,
}

/// A wait at a stop between two legs.
///
/// Field names match `WalkLeg`/`TransitLeg` for uniform client handling:
/// `depart_at` is when the wait begins (previous leg's arrival),
/// `arrive_at` is when the wait ends (next leg's departure).
#[derive(Debug, Clone, Serialize)]
pub struct WaitLeg {
    pub at: StopInfo,
    pub depart_at: DateTime<Utc>,
    pub arrive_at: DateTime<Utc>,
    pub duration_s: u32,
    /// Human-readable reason, e.g. "Next 68 Warden Station departs at 00:07".
    pub reason: String,
}

/// A dwell at a user waypoint (Layer 6.5). Not emitted yet.
#[derive(Debug, Clone, Serialize)]
pub struct DwellLeg {
    pub at: Location,
    pub label: String,
    pub arrive_at: DateTime<Utc>,
    pub depart_at: DateTime<Utc>,
    pub duration_s: u32,
}

#[derive(Debug, Clone, Serialize)]
pub struct Location {
    pub lat: f64,
    pub lon: f64,
    pub label: String,
    pub stop_id: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct StopInfo {
    pub stop_id: String,
    pub name: String,
    pub lat: f64,
    pub lon: f64,
    pub wheelchair_boarding: Option<i16>,
    pub parent_station: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct RouteInfo {
    pub route_id: String,
    pub short_name: String,
    pub long_name: String,
    pub color: String,
    pub text_color: String,
    pub route_type: i16,
}

#[derive(Debug, Clone, Serialize)]
pub struct IntermediateStop {
    pub stop_id: String,
    pub name: String,
    /// Arrival and departure coincide in the current schema (only
    /// `TripStop.departure_s` is loaded); they can diverge later if
    /// `arrival_s` is added.
    pub arrive_at: DateTime<Utc>,
    pub depart_at: DateTime<Utc>,
    pub stop_sequence: i32,
}

#[derive(Debug, Clone, Serialize)]
pub struct WaypointArrival {
    pub label: String,
    pub arrive_at: DateTime<Utc>,
    pub depart_at: DateTime<Utc>,
    pub dwell_s: u32,
}