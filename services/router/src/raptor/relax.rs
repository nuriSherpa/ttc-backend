use crate::context::loader::UserPrefs;
use crate::graph::Graph;
use crate::graph::transfer_table::effective_seconds;

pub fn same_station_transfers(
    graph: &Graph,
    stop_idx: u32,
    arrival_s: u32,
    best_arrival: &[u32],
    user: &UserPrefs,
    weather_multiplier: f32,
) -> Vec<(u32, u32)> {
    let entries = &graph.transfer_table.from[stop_idx as usize];
    let mut out = Vec::with_capacity(entries.len());

    for entry in entries {
        let Some(walk_s) = effective_seconds(entry, user, weather_multiplier) else {
            continue;
        };
        let new_arrival = arrival_s + walk_s;
        if new_arrival < best_arrival[entry.to as usize] {
            out.push((entry.to, new_arrival));
        }
    }

    out
}