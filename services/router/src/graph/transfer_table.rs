use std::cmp::Reverse;
use std::collections::{BinaryHeap, HashMap, HashSet};

use crate::graph::geo::GeoIndex;
use crate::graph::types::{PathwayEdge, StationNode, Stop};
use crate::context::loader::UserPrefs;

/// Build-time maximum proximity radius. Anything beyond this is not
/// considered a transfer, even if the user has unlimited walking.
const PROXIMITY_BUILD_MAX_M: f64 = 500.0;

/// Fixed overhead for street-level transfers (finding the stop, crossing).
/// Not data-driven — it's the "friction" of an unfamiliar bus stop.
const PROXIMITY_BUFFER_S: u32 = 60;

#[derive(Debug, Clone)]
pub struct TransferEntry {
    pub to: u32,
    /// Pre-computed at generic 1.40 m/s, no weather.
    /// For station transfers: pathway-graph Dijkstra traversal time.
    /// For proximity transfers: base_m / 1.40 + buffer.
    pub base_seconds: u32,
    /// Actual walking meters. Zero for station transfers (pathway graph
    /// captures real stairs/elevators, not straight-line distance).
    pub base_m: f32,
    /// True = pathway-graph-derived (in-station). False = street proximity.
    pub is_station: bool,
}

#[derive(Debug, Default)]
pub struct TransferTable {
    /// Indexed by from_stop_idx. Each entry is one transfer edge.
    pub from: Vec<Vec<TransferEntry>>,
}

impl TransferTable {
    pub fn total_edges(&self) -> usize {
        self.from.iter().map(|v| v.len()).sum()
    }
}

pub fn build(
    stops: &[Stop],
    stop_idx_by_id: &HashMap<String, u32>,
    station_nodes: &[StationNode],
    station_idx_by_id: &HashMap<String, u32>,
    pathway_edges: &[PathwayEdge],
    geo_index: &GeoIndex,
) -> TransferTable {
    let n_stops = stops.len();
    let mut from: Vec<Vec<TransferEntry>> = vec![Vec::new(); n_stops];

    // ──────────────────────────────────────────────────────────────
    // Step 1 — map station_node_idx → stop_idx where they overlap
    // ──────────────────────────────────────────────────────────────
    let mut node_to_stop: HashMap<u32, u32> = HashMap::new();
    for sn in station_nodes {
        if let Some(&stop_idx) = stop_idx_by_id.get(&sn.stop_id) {
            node_to_stop.insert(sn.id, stop_idx);
        }
    }

    // ──────────────────────────────────────────────────────────────
    // Step 2 — build adjacency in station_node space
    // ──────────────────────────────────────────────────────────────
    let mut adjacency: HashMap<u32, Vec<(u32, u32)>> = HashMap::new();
    for e in pathway_edges {
        let traversal_s = e.traversal_s.unwrap_or(60).max(1) as u32;
        adjacency
            .entry(e.from_idx)
            .or_default()
            .push((e.to_idx, traversal_s));
    }

    // ──────────────────────────────────────────────────────────────
    // Step 3 — group stops by parent_station
    // ──────────────────────────────────────────────────────────────
    let mut by_station: HashMap<String, Vec<u32>> = HashMap::new();
    for (stop_idx, stop) in stops.iter().enumerate() {
        if let Some(parent) = &stop.parent_station {
            by_station
                .entry(parent.clone())
                .or_default()
                .push(stop_idx as u32);
        }
    }

    // ──────────────────────────────────────────────────────────────
    // Step 4 — in-station Dijkstra per (from_stop, to_stop) pair
    // ──────────────────────────────────────────────────────────────
    let mut station_pairs: HashSet<(u32, u32)> = HashSet::new();

    for (_parent, stop_indices) in &by_station {
        if stop_indices.len() < 2 {
            continue;
        }

        let node_ids: Vec<Option<u32>> = stop_indices
            .iter()
            .map(|&sidx| {
                let stop_id = &stops[sidx as usize].stop_id;
                station_idx_by_id.get(stop_id).copied()
            })
            .collect();

        for (i, &from_stop_idx) in stop_indices.iter().enumerate() {
            let Some(from_node) = node_ids[i] else { continue };

            // Dijkstra from from_node over the pathway graph
            let mut dist: HashMap<u32, u32> = HashMap::new();
            let mut heap: BinaryHeap<Reverse<(u32, u32)>> = BinaryHeap::new();
            dist.insert(from_node, 0);
            heap.push(Reverse((0, from_node)));

            while let Some(Reverse((d, node))) = heap.pop() {
                if let Some(&existing) = dist.get(&node) {
                    if d > existing {
                        continue;
                    }
                }
                if let Some(neighbors) = adjacency.get(&node) {
                    for &(next, w) in neighbors {
                        let nd = d + w;
                        if dist.get(&next).map_or(true, |&x| nd < x) {
                            dist.insert(next, nd);
                            heap.push(Reverse((nd, next)));
                        }
                    }
                }
            }

            // Store distances to every other stop in this station
            for (j, &to_stop_idx) in stop_indices.iter().enumerate() {
                if i == j {
                    continue;
                }
                let Some(to_node) = node_ids[j] else { continue };
                if let Some(&seconds) = dist.get(&to_node) {
                    from[from_stop_idx as usize].push(TransferEntry {
                        to: to_stop_idx,
                        base_seconds: seconds,
                        base_m: 0.0,
                        is_station: true,
                    });
                    station_pairs.insert((from_stop_idx, to_stop_idx));
                }
            }
        }
    }

    // ──────────────────────────────────────────────────────────────
    // Step 5 — proximity fallback for anything station-Dijkstra missed
    // ──────────────────────────────────────────────────────────────
    for (from_stop_idx, stop) in stops.iter().enumerate() {
        let from_idx = from_stop_idx as u32;
        let nearby = geo_index.nearest(stop.lat, stop.lon, PROXIMITY_BUILD_MAX_M, 15);

        for (to_idx, dist_m) in nearby {
            if to_idx == from_idx {
                continue;
            }
            if station_pairs.contains(&(from_idx, to_idx)) {
                continue; // station Dijkstra wins
            }

            let base_s = (dist_m / 1.40).ceil() as u32 + PROXIMITY_BUFFER_S;
            from[from_idx as usize].push(TransferEntry {
                to: to_idx,
                base_seconds: base_s,
                base_m: dist_m as f32,
                is_station: false,
            });
        }
    }

    TransferTable { from }
}

/// Called from relax.rs at query time. Applies the user's walk speed,
/// personal correction ratio, max_walk_m limit, and current weather.
pub fn effective_seconds(entry: &TransferEntry, user: &UserPrefs, weather_multiplier: f32) -> Option<u32> {
    let correction = user.correction_ratio.unwrap_or(1.0);
    let speed = user.walk_speed_mps.clamp(0.3, 3.0);

    if entry.is_station {
        // Station transfer: base is a real pathway-graph traversal time.
        // Scale by user speed ratio + correction + weather.
        let speed_ratio = 1.40 / speed;
        let seconds = entry.base_seconds as f64
            * speed_ratio
            * correction
            * (weather_multiplier as f64);
        Some(seconds.round() as u32)
    } else {
        // Proximity: enforce user's max_walk_m, then walk at their actual pace
        if entry.base_m > user.max_walk_m as f32 {
            return None;
        }
        let effective_speed = speed / correction;
        let seconds = (entry.base_m as f64 / effective_speed
            * (weather_multiplier as f64))
            .round() as u32
            + PROXIMITY_BUFFER_S;
        Some(seconds)
    }
}