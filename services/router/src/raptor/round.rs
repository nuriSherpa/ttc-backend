use chrono::{DateTime, NaiveDate, Utc};
use tracing::debug;

use crate::context::loader::UserPrefs;
use crate::graph::live::{LiveDelays, MAX_LIVE_DELTA_S, MAX_LIVE_STALENESS_S};
use crate::graph::types::days_from_epoch;
use crate::graph::Graph;
use super::raptor::{StopState, TripKind, INF, DEFAULT_INTER_STOP_S};
use super::relax;

#[derive(Debug, Default)]
pub struct RoundResult {
    pub transit_improved: Vec<u32>,
    pub transfer_improved: Vec<u32>,
    pub boardable_count: usize,
    pub expanded_count: usize,
}

impl RoundResult {
    pub fn all_improved(&self) -> Vec<u32> {
        let mut all = self.transit_improved.clone();
        all.extend(self.transfer_improved.iter().copied());
        all.sort_unstable();
        all.dedup();
        all
    }

    pub fn is_empty(&self) -> bool {
        self.transit_improved.is_empty() && self.transfer_improved.is_empty()
    }
}

/// Resolve the effective departure time for a trip-at-stop.
///
/// Uses live prediction if it's available, fresh, and within sane bounds.
/// Falls back to `scheduled` otherwise.
fn effective_departs(
    scheduled: DateTime<Utc>,
    live: Option<DateTime<Utc>>,
    depart_at: DateTime<Utc>,
) -> DateTime<Utc> {
    match live {
        Some(pred) => {
            let delta_s = (pred - scheduled).num_seconds().abs();
            let stale = pred < depart_at - chrono::Duration::seconds(MAX_LIVE_STALENESS_S);
            if delta_s > MAX_LIVE_DELTA_S || stale {
                scheduled
            } else {
                pred
            }
        }
        None => scheduled,
    }
}

pub fn expand_round(
    graph: &Graph,
    best: &mut [StopState],
    marked: &[u32],
    depart_at: DateTime<Utc>,
    service_dates: &[NaiveDate],
    board_cutoff: DateTime<Utc>,
    prefs: &UserPrefs,
    weather_multiplier: f32,
    live: &LiveDelays,
) -> RoundResult {
    let mut result = RoundResult::default();
    let live_ok = !live.feed_version.is_empty() && live.feed_version == graph.feed_version;

    for &from_stop_idx in marked {
        let from_arrival = best[from_stop_idx as usize].arrival_s;
        if from_arrival == INF {
            continue;
        }

        let board_after = depart_at + chrono::Duration::seconds(from_arrival as i64);

        // Boarding safety margin — only applies when a walk precedes
        // boarding (from_arrival > 0). If the user is already at the stop
        // (from_arrival == 0), they board immediately with no buffer.
        //
        // Without this, the router happily plans 5-15s connections that
        // users physically cannot make (walking from stop entrance to
        // actual boarding point, finding the vehicle, stepping on).
        let boarding_margin = if from_arrival == 0 {
            chrono::Duration::zero()
        } else {
            chrono::Duration::seconds(prefs.min_connection_s.max(0))
        };
        let board_after_with_margin = board_after + boarding_margin;

        for date in service_dates {
            let epoch_day = days_from_epoch(*date);
            let Some(departures) = graph.departures_at(from_stop_idx, *date) else {
                continue;
            };

            for d in departures {
                let live_pred = if live_ok {
                    live.get(d.trip_idx, epoch_day, d.stop_sequence)
                } else {
                    None
                };
                let effective = effective_departs(d.departs_at, live_pred, depart_at);

                // Must depart strictly after walk-arrival + safety margin.
                if effective < board_after_with_margin {
                    continue;
                }
                if effective > board_cutoff {
                    break;
                }
                if !d.boardable {
                    continue;
                }
                result.boardable_count += 1;

                let trip_stops = graph.trip_stops(d.trip_idx);
                let Some(start_pos) = trip_stops
                    .iter()
                    .position(|ts| ts.stop_sequence == d.stop_sequence)
                else {
                    continue;
                };

                let board_seconds = (effective - depart_at).num_seconds() as u32;
                let base_dep_s = trip_stops[start_pos].departure_s.unwrap_or(0);
                result.expanded_count += 1;

                let mut last_known_s: i32 = base_dep_s;

                for ts in &trip_stops[start_pos + 1..] {
                    let stop_time = ts
                        .departure_s
                        .unwrap_or(last_known_s + DEFAULT_INTER_STOP_S);
                    last_known_s = stop_time;

                    let delta_s = stop_time.saturating_sub(base_dep_s).max(0) as u32;
                    let arrival_s = board_seconds + delta_s;

                    let target_idx = ts.stop_idx;
                    if arrival_s < best[target_idx as usize].arrival_s {
                        best[target_idx as usize] = StopState {
                            arrival_s,
                            from_stop: from_stop_idx,
                            trip_idx: d.trip_idx,
                            kind: TripKind::Transit,
                            board_departs_s: board_seconds,
                            walk_m: 0.0,
                        };
                        result.transit_improved.push(target_idx);
                    }
                }
            }
        }
    }

    debug!(
        from_stops = marked.len(),
        boardable = result.boardable_count,
        expanded = result.expanded_count,
        transit_improved = result.transit_improved.len(),
        live_ok,
        margin_s = prefs.min_connection_s,
        "transit step"
    );

    // Transfer relaxation — unchanged.
    let arrival_array: Vec<u32> = best.iter().map(|s| s.arrival_s).collect();

    for &stop_idx in &result.transit_improved {
        let arrival_at_stop = best[stop_idx as usize].arrival_s;
        for (to_idx, new_arrival) in relax::same_station_transfers(
            graph,
            stop_idx,
            arrival_at_stop,
            &arrival_array,
            prefs,
            weather_multiplier,
        ) {
            if new_arrival < best[to_idx as usize].arrival_s {
                best[to_idx as usize] = StopState {
                    arrival_s: new_arrival,
                    from_stop: stop_idx,
                    trip_idx: u32::MAX,
                    kind: TripKind::Transfer,
                    board_departs_s: arrival_at_stop,
                    walk_m: 0.0,
                };
                result.transfer_improved.push(to_idx);
            }
        }
    }

    result
}