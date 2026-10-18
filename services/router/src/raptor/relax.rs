use std::collections::HashSet;

use crate::graph::Graph;

const TRANSFER_BUFFER_S: u32 = 180;
const PROXIMITY_TRANSFER_M: f64 = 150.0;

pub fn same_station_transfers(
    graph: &Graph,
    stop_idx: u32,
    arrival_s: u32,
    best_arrival: &[u32],
) -> Vec<(u32, u32)> {
    let stop = &graph.stops[stop_idx as usize];
    let candidate_arrival = arrival_s + TRANSFER_BUFFER_S;
    let mut out = Vec::new();
    let mut seen: HashSet<u32> = HashSet::new();

    // Primary: same parent_station
    if let Some(parent) = &stop.parent_station {
        for (other_idx, other) in graph.stops.iter().enumerate() {
            if other_idx as u32 == stop_idx {
                continue;
            }
            if other.parent_station.as_ref() == Some(parent)
                && candidate_arrival < best_arrival[other_idx]
            {
                out.push((other_idx as u32, candidate_arrival));
                seen.insert(other_idx as u32);
            }
        }
    }

    // Fallback: physical proximity — catches bus bay ↔ subway platform when
    // GTFS doesn't link them via parent_station (very common for TTC).
    let nearby = graph.geo_index.nearest(stop.lat, stop.lon, PROXIMITY_TRANSFER_M, 8);
    for (other_idx, _dist) in nearby {
        if other_idx == stop_idx || seen.contains(&other_idx) {
            continue;
        }
        if candidate_arrival < best_arrival[other_idx as usize] {
            out.push((other_idx, candidate_arrival));
        }
    }

    out
}