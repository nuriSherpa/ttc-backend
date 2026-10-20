//! Layer 6 — assemble raw `Journey` (u32 offsets + stop_idx) into
//! `JourneyResponse` (ISO timestamps + resolved stops + explicit Wait legs).
//!
//! Wait legs are inserted wherever `next_leg.depart_s > prev_leg.arrive_s`.
//! In the current RAPTOR output this only happens for:
//!   * OriginWalk → Transit
//!   * TransferWalk → Transit
//! Transit → TransferWalk and Transit → DestWalk are back-to-back by
//! construction (transfer walk starts at transit arrival; dest walk starts
//! at final arrival minus its duration). The generic gap check covers all
//! cases defensively.

use chrono::{DateTime, Duration, Utc};
use chrono_tz::America::Toronto;

use crate::context::loader::LatLon;
use crate::gates::types::Candidate;
use crate::graph::Graph;
use crate::raptor::raptor::{Journey, JourneyLeg, LegKind};

use super::types::*;

/// Assemble one raw journey into production JSON.
///
/// The origin/dest candidates are used to recover the walk `breakdown`
/// (the RAPTOR `Journey` doesn't preserve it).
pub fn assemble(
    graph: &Graph,
    journey: &Journey,
    depart_at: DateTime<Utc>,
    origin: &LatLon,
    destination: &LatLon,
    origin_candidates: &[Candidate],
    dest_candidates: &[Candidate],
) -> JourneyResponse {
    let origin_stop_idx = journey.legs.first().map(|l| l.to_stop).unwrap_or(u32::MAX);
    let dest_stop_idx = journey.legs.last().map(|l| l.from_stop).unwrap_or(u32::MAX);
    let origin_candidate = origin_candidates.iter().find(|c| c.stop_idx == origin_stop_idx);
    let dest_candidate = dest_candidates.iter().find(|c| c.stop_idx == dest_stop_idx);

    let mut out_legs: Vec<ResponseLeg> = Vec::with_capacity(journey.legs.len() + 2);
    let mut totals = Totals::default();

    for i in 0..journey.legs.len() {
        let leg = &journey.legs[i];

        // Emit current leg.
        let response_leg = convert_leg(
            graph,
            leg,
            depart_at,
            origin,
            destination,
            origin_candidate,
            dest_candidate,
        );
        accumulate(&mut totals, &response_leg);
        out_legs.push(response_leg);

        // If there is a gap before the next leg, insert a Wait at this leg's
        // arrival stop (which equals the boarding stop for the next leg).
        if i + 1 < journey.legs.len() {
            let next = &journey.legs[i + 1];
            let gap = next.depart_s.saturating_sub(leg.arrive_s);
            if gap > 0 {
                let wait = build_wait(graph, leg.to_stop, leg.arrive_s, next, depart_at);
                totals.total_wait_seconds += wait.duration_s;
                out_legs.push(ResponseLeg::Wait(wait));
            }
        }
    }

    // Real transfers = (number of Transit legs) - 1. Independent of how
    // RAPTOR structures transfer walks. See `JourneyResponse::real_transfers`.
    let real_transfers = journey
        .legs
        .iter()
        .filter(|l| l.kind == LegKind::Transit)
        .count()
        .saturating_sub(1) as u8;

     // Report this journey's actual first-leg departure (may be later than
    // the requested depart_at for shifted-time alternatives).
    let actual_depart_at = journey
        .legs
        .first()
        .map(|l| depart_at + Duration::seconds(l.depart_s as i64))
        .unwrap_or(depart_at);

    JourneyResponse {
        legs: out_legs,
        depart_at: actual_depart_at,
        arrive_at: depart_at + Duration::seconds(journey.arrive_s as i64),
        total_seconds: journey.arrive_s,
        total_transit_seconds: totals.total_transit_seconds,
        total_wait_seconds: totals.total_wait_seconds,
        total_walk_seconds: totals.total_walk_seconds,
        total_walk_m: totals.total_walk_m,
        num_transfers: journey.num_transfers,
        real_transfers,
        waypoint_arrivals: vec![],
    }
}

// ───────────────────────────── helpers ─────────────────────────────

#[derive(Default)]
struct Totals {
    total_transit_seconds: u32,
    total_wait_seconds: u32,
    total_walk_seconds: u32,
    total_walk_m: f64,
}

fn accumulate(totals: &mut Totals, leg: &ResponseLeg) {
    match leg {
        ResponseLeg::Walk(w) => {
            totals.total_walk_seconds += w.duration_s;
            totals.total_walk_m += w.distance_m;
        }
        ResponseLeg::Transit(t) => {
            totals.total_transit_seconds += t.duration_s;
        }
        ResponseLeg::Wait(w) => {
            totals.total_wait_seconds += w.duration_s;
        }
        ResponseLeg::Dwell(_) => {}
    }
}

fn convert_leg(
    graph: &Graph,
    leg: &JourneyLeg,
    depart_at: DateTime<Utc>,
    origin: &LatLon,
    destination: &LatLon,
    origin_candidate: Option<&Candidate>,
    dest_candidate: Option<&Candidate>,
) -> ResponseLeg {
    match leg.kind {
        LegKind::OriginWalk => {
            let (walk_m, straight_m, detour, breakdown) =
                walk_facts(origin_candidate, 0.0);
            let to_stop = &graph.stops[leg.to_stop as usize];

            ResponseLeg::Walk(WalkLeg {
                walk_kind: WalkKind::Origin,
                from: Location {
                    lat: origin.lat,
                    lon: origin.lon,
                    label: "Origin".into(),
                    stop_id: None,
                },
                to: Location {
                    lat: to_stop.lat,
                    lon: to_stop.lon,
                    label: to_stop.name.clone(),
                    stop_id: Some(to_stop.stop_id.clone()),
                },
                depart_at: depart_at + Duration::seconds(leg.depart_s as i64),
                arrive_at: depart_at + Duration::seconds(leg.arrive_s as i64),
                duration_s: leg.arrive_s.saturating_sub(leg.depart_s),
                distance_m: walk_m,
                distance_m_straight: straight_m,
                detour_factor: detour,
                breakdown,
            })
        }

        LegKind::DestWalk => {
            let (walk_m, straight_m, detour, breakdown) =
                walk_facts(dest_candidate, 0.0);
            let from_stop = &graph.stops[leg.from_stop as usize];

            ResponseLeg::Walk(WalkLeg {
                walk_kind: WalkKind::Destination,
                from: Location {
                    lat: from_stop.lat,
                    lon: from_stop.lon,
                    label: from_stop.name.clone(),
                    stop_id: Some(from_stop.stop_id.clone()),
                },
                to: Location {
                    lat: destination.lat,
                    lon: destination.lon,
                    label: "Destination".into(),
                    stop_id: None,
                },
                depart_at: depart_at + Duration::seconds(leg.depart_s as i64),
                arrive_at: depart_at + Duration::seconds(leg.arrive_s as i64),
                duration_s: leg.arrive_s.saturating_sub(leg.depart_s),
                distance_m: walk_m,
                distance_m_straight: straight_m,
                detour_factor: detour,
                breakdown,
            })
        }

        LegKind::TransferWalk => {
            let from_stop = &graph.stops[leg.from_stop as usize];
            let to_stop = &graph.stops[leg.to_stop as usize];
            let straight_m = haversine_m(from_stop.lat, from_stop.lon, to_stop.lat, to_stop.lon);
            let walk_m = lookup_transfer_m(graph, leg.from_stop, leg.to_stop)
                .unwrap_or(straight_m * 1.30);
            let detour = if straight_m > 0.0 { walk_m / straight_m } else { 1.0 };

            ResponseLeg::Walk(WalkLeg {
                walk_kind: WalkKind::Transfer,
                from: Location {
                    lat: from_stop.lat,
                    lon: from_stop.lon,
                    label: from_stop.name.clone(),
                    stop_id: Some(from_stop.stop_id.clone()),
                },
                to: Location {
                    lat: to_stop.lat,
                    lon: to_stop.lon,
                    label: to_stop.name.clone(),
                    stop_id: Some(to_stop.stop_id.clone()),
                },
                depart_at: depart_at + Duration::seconds(leg.depart_s as i64),
                arrive_at: depart_at + Duration::seconds(leg.arrive_s as i64),
                duration_s: leg.arrive_s.saturating_sub(leg.depart_s),
                distance_m: walk_m,
                distance_m_straight: straight_m,
                detour_factor: detour,
                breakdown: None,
            })
        }

        LegKind::Transit => {
            let trip_idx = leg
                .trip_idx
                .expect("Transit leg must have trip_idx (invariant of reconstruct)");
            let trip = &graph.trips[trip_idx as usize];
            let route = &graph.routes[trip.route_idx as usize];
            let from_stop = &graph.stops[leg.from_stop as usize];
            let to_stop = &graph.stops[leg.to_stop as usize];

            let headsign = trip
                .headsign
                .clone()
                .or_else(|| route.long_name.clone())
                .or_else(|| route.short_name.clone())
                .unwrap_or_else(|| route.route_id.clone());

            let intermediate = compute_intermediate_stops(graph, trip_idx, leg, depart_at);

            ResponseLeg::Transit(TransitLeg {
                route: RouteInfo {
                    route_id: route.route_id.clone(),
                    short_name: route.short_name.clone().unwrap_or_default(),
                    long_name: route.long_name.clone().unwrap_or_default(),
                    color: route.color.clone().unwrap_or_else(|| "#000000".into()),
                    text_color: route.text_color.clone().unwrap_or_else(|| "#ffffff".into()),
                    route_type: route.route_type,
                },
                headsign,
                from_stop: stop_to_info(from_stop),
                to_stop: stop_to_info(to_stop),
                depart_at: depart_at + Duration::seconds(leg.depart_s as i64),
                arrive_at: depart_at + Duration::seconds(leg.arrive_s as i64),
                duration_s: leg.arrive_s.saturating_sub(leg.depart_s),
                intermediate_stops: intermediate,
            })
        }
    }
}

/// Extract (walk_m, straight_m, detour, breakdown) from a candidate,
/// falling back to sensible zeros / defaults when no candidate is available.
fn walk_facts(
    candidate: Option<&Candidate>,
    fallback_straight: f64,
) -> (f64, f64, f64, Option<crate::walk::types::WalkBreakdown>) {
    if let Some(c) = candidate {
        if let Some(est) = c.walk_estimate.as_ref() {
            let detour = est.breakdown.detour_factor.unwrap_or(1.30);
            return (est.walk_m, c.raw_distance_m, detour, Some(est.breakdown.clone()));
        }
        return (0.0, c.raw_distance_m, 1.30, None);
    }
    (0.0, fallback_straight, 1.30, None)
}

fn build_wait(
    graph: &Graph,
    at_stop_idx: u32,
    prev_arrive_s: u32,
    next: &JourneyLeg,
    depart_at: DateTime<Utc>,
) -> WaitLeg {
    let stop = &graph.stops[at_stop_idx as usize];
    let wait_start = depart_at + Duration::seconds(prev_arrive_s as i64);
    let wait_end = depart_at + Duration::seconds(next.depart_s as i64);

    let reason = if next.kind == LegKind::Transit {
        if let Some(tidx) = next.trip_idx {
            let trip = &graph.trips[tidx as usize];
            let route = &graph.routes[trip.route_idx as usize];
            let short = route.short_name.as_deref().unwrap_or(&route.route_id);
            let headsign = trip.headsign.as_deref().unwrap_or("");
            let local = wait_end.with_timezone(&Toronto);
            if headsign.is_empty() {
                format!("Next {} departs at {}", short, local.format("%H:%M"))
            } else {
                format!(
                    "Next {} {} departs at {}",
                    short,
                    headsign,
                    local.format("%H:%M")
                )
            }
        } else {
            "Wait for connection".into()
        }
    } else {
        "Wait".into()
    };

    WaitLeg {
        at: stop_to_info(stop),
        depart_at: wait_start,
        arrive_at: wait_end,
        duration_s: next.depart_s.saturating_sub(prev_arrive_s),
        reason,
    }
}

fn compute_intermediate_stops(
    graph: &Graph,
    trip_idx: u32,
    leg: &JourneyLeg,
    depart_at: DateTime<Utc>,
) -> Vec<IntermediateStop> {
    let trip_stops = graph.trip_stops(trip_idx);

    let from_pos = trip_stops.iter().position(|ts| ts.stop_idx == leg.from_stop);
    let to_pos = trip_stops.iter().position(|ts| ts.stop_idx == leg.to_stop);

    let (Some(from_pos), Some(to_pos)) = (from_pos, to_pos) else {
        return Vec::new();
    };
    if from_pos >= to_pos {
        return Vec::new();
    }

    let base_dep_s = trip_stops[from_pos].departure_s.unwrap_or(0);

    let mut out = Vec::with_capacity(to_pos - from_pos - 1);
    for ts in &trip_stops[from_pos + 1..to_pos] {
        let stop = &graph.stops[ts.stop_idx as usize];
        let stop_dep_s = ts.departure_s.unwrap_or(base_dep_s);
        let delta = stop_dep_s.saturating_sub(base_dep_s).max(0) as u32;
        let offset_s = leg.depart_s + delta;
        let t = depart_at + Duration::seconds(offset_s as i64);

        out.push(IntermediateStop {
            stop_id: stop.stop_id.clone(),
            name: stop.name.clone(),
            arrive_at: t,
            depart_at: t,
            stop_sequence: ts.stop_sequence,
        });
    }
    out
}

fn stop_to_info(s: &crate::graph::types::Stop) -> StopInfo {
    StopInfo {
        stop_id: s.stop_id.clone(),
        name: s.name.clone(),
        lat: s.lat,
        lon: s.lon,
        wheelchair_boarding: s.wheelchair_boarding,
        parent_station: s.parent_station.clone(),
    }
}

fn lookup_transfer_m(graph: &Graph, from_stop: u32, to_stop: u32) -> Option<f64> {
    let entries = graph.transfer_table.from.get(from_stop as usize)?;
    entries
        .iter()
        .find(|e| e.to == to_stop)
        .map(|e| e.base_m as f64)
}

fn haversine_m(lat1: f64, lon1: f64, lat2: f64, lon2: f64) -> f64 {
    const R: f64 = 6_371_000.0;
    let phi1 = lat1.to_radians();
    let phi2 = lat2.to_radians();
    let dphi = (lat2 - lat1).to_radians();
    let dlambda = (lon2 - lon1).to_radians();
    let a = (dphi / 2.0).sin().powi(2)
        + phi1.cos() * phi2.cos() * (dlambda / 2.0).sin().powi(2);
    2.0 * R * a.sqrt().asin()
}