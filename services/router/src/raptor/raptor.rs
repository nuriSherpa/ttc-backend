use chrono::{DateTime, NaiveDate, Utc};
use serde::Serialize;
use tracing::{debug, trace};

use crate::context::loader::UserPrefs;
use crate::gates::types::Candidate;
use crate::graph::Graph;
use crate::raptor::relax;

const HORIZON_SECONDS: u32 = 4 * 3600;
const INF: u32 = u32::MAX;
const DEFAULT_INTER_STOP_S: i32 = 60;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TripKind {
    Origin,
    Transfer,
    Transit,
}

#[derive(Debug, Clone, Copy)]
pub struct StopState {
    pub arrival_s: u32,
    pub from_stop: u32,
    pub trip_idx: u32,
    pub kind: TripKind,
    /// For Transit: when we boarded (board_departs_s of the leg).
    /// For Transfer: when we arrived at from_stop (start of the walk).
    pub board_departs_s: u32,
    /// For Origin only: walk distance to reach this stop.
    pub walk_m: f64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub enum LegKind {
    OriginWalk,
    Transit,
    TransferWalk,
    DestWalk,
}

#[derive(Debug, Clone, Serialize)]
pub struct JourneyLeg {
    pub kind: LegKind,
    pub from_stop: u32,
    pub to_stop: u32,
    pub depart_s: u32,
    pub arrive_s: u32,
    pub trip_idx: Option<u32>,
    pub walk_m: f64,
}

#[derive(Debug, Clone, Serialize)]
pub struct Journey {
    pub legs: Vec<JourneyLeg>,
    pub depart_s: u32,
    pub arrive_s: u32,
    pub num_transfers: u8,
    pub total_walk_m: f64,
}

pub fn run(
    graph: &Graph,
    origin_candidates: &[Candidate],
    dest_candidates: &[Candidate],
    depart_at: DateTime<Utc>,
    prefs: &UserPrefs,
) -> Vec<Journey> {
    // FIX 3 — the 4h horizon can span two UTC date buckets. The loader
    // keys departures by `departs_at.date_naive()` (UTC), so we must
    // query every bucket the window touches.
    let board_cutoff = depart_at + chrono::Duration::seconds(HORIZON_SECONDS as i64);
    let first_date: NaiveDate = depart_at.date_naive();
    let last_date: NaiveDate = board_cutoff.date_naive();
    let mut service_dates: Vec<NaiveDate> = vec![first_date];
    if last_date != first_date {
        service_dates.push(last_date);
    }

    let mut best: Vec<StopState> = vec![
        StopState {
            arrival_s: INF,
            from_stop: u32::MAX,
            trip_idx: u32::MAX,
            kind: TripKind::Origin,
            board_departs_s: 0,
            walk_m: 0.0,
        };
        graph.stops.len()
    ];

    let mut marked_this_round: Vec<u32> = Vec::new();

    // Round 0 — seed with origin walks
    for c in origin_candidates {
        let est = c.walk_estimate.as_ref().unwrap();
        let idx = c.stop_idx as usize;
        if est.seconds < best[idx].arrival_s {
            best[idx] = StopState {
                arrival_s: est.seconds,
                from_stop: u32::MAX,
                trip_idx: u32::MAX,
                kind: TripKind::Origin,
                board_departs_s: 0,
                walk_m: est.walk_m,
            };
            marked_this_round.push(c.stop_idx);
        }
    }

    let max_rounds = (prefs.max_transfers as u32) + 1;
    let mut round = 0u32;

    while round < max_rounds && !marked_this_round.is_empty() {
        round += 1;
        trace!(round, marked = marked_this_round.len(), "raptor round");

        let mut improved_in_round: Vec<u32> = Vec::new();
        let mut boardable_count = 0usize;
        let mut expanded_count = 0usize;

        // Transit step
        for &from_stop_idx in &marked_this_round {
            let from_arrival = best[from_stop_idx as usize].arrival_s;
            if from_arrival == INF {
                continue;
            }

            let board_after = depart_at + chrono::Duration::seconds(from_arrival as i64);

            for date in &service_dates {
                let Some(departures) = graph.departures_at(from_stop_idx, *date) else {
                    continue;
                };

                for d in departures {
                    if d.departs_at < board_after {
                        continue;
                    }
                    if d.departs_at > board_cutoff {
                        break;
                    }
                    if !d.boardable {
                        continue;
                    }
                    boardable_count += 1;

                    let trip_stops = graph.trip_stops(d.trip_idx);
                    let Some(start_pos) = trip_stops
                        .iter()
                        .position(|ts| ts.stop_sequence == d.stop_sequence)
                    else {
                        continue;
                    };

                    let board_seconds = (d.departs_at - depart_at).num_seconds() as u32;
                    let base_dep_s = trip_stops[start_pos].departure_s.unwrap_or(0);
                    expanded_count += 1;

                    // FIX 1 — terminus stops have departure_s = NULL.
                    // Track the last known departure time and fall back to
                    // last_known + ~60s for untimed stops, so the bus still
                    // "reaches" the terminal (e.g. Warden Station).
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
                            improved_in_round.push(target_idx);
                        }
                    }
                }
            }
        }

        debug!(
            round,
            from_stops = marked_this_round.len(),
            boardable = boardable_count,
            expanded = expanded_count,
            improved = improved_in_round.len(),
            "transit step"
        );

        // Transfer step (same-station)
        let arrival_array: Vec<u32> = best.iter().map(|s| s.arrival_s).collect();
        let mut transfer_marked: Vec<u32> = Vec::new();

        for &stop_idx in &improved_in_round {
            let arrival_at_stop = best[stop_idx as usize].arrival_s;
            for (to_idx, new_arrival_s) in
                relax::same_station_transfers(graph, stop_idx, arrival_at_stop, &arrival_array)
            {
                if new_arrival_s < best[to_idx as usize].arrival_s {
                    best[to_idx as usize] = StopState {
                        arrival_s: new_arrival_s,
                        from_stop: stop_idx,
                        trip_idx: u32::MAX,
                        kind: TripKind::Transfer,
                        board_departs_s: arrival_at_stop,
                        walk_m: 0.0,
                    };
                    transfer_marked.push(to_idx);
                }
            }
        }

        let mut next_marked = improved_in_round;
        next_marked.extend(transfer_marked);
        next_marked.sort_unstable();
        next_marked.dedup();

        if next_marked.is_empty() {
            break;
        }
        marked_this_round = next_marked;
    }

    // Build journeys for each destination candidate
    let mut journeys: Vec<Journey> = Vec::new();
    for c in dest_candidates {
        let st = best[c.stop_idx as usize];
        if st.arrival_s == INF {
            continue;
        }
        let est = c.walk_estimate.as_ref().unwrap();
        let final_arrival_s = st.arrival_s + est.seconds;

        if let Some(j) = reconstruct(graph, &best, c, est.seconds, est.walk_m, final_arrival_s) {
            journeys.push(j);
        }
    }

    debug!(
        journeys = journeys.len(),
        dest_candidates = dest_candidates.len(),
        "raptor complete"
    );

    journeys.sort_by_key(|j| j.arrive_s);
    journeys
}

fn reconstruct(
    _graph: &Graph,
    best: &[StopState],
    dest_candidate: &Candidate,
    dest_walk_s: u32,
    dest_walk_m: f64,
    final_arrival_s: u32,
) -> Option<Journey> {
    let dest_stop = dest_candidate.stop_idx;

    // Build transit/transfer legs by walking backward (dest→origin).
    let mut reversed_legs: Vec<JourneyLeg> = Vec::new();
    let mut num_transfers: u8 = 0;
    let mut cursor = dest_stop;

    while best[cursor as usize].kind != TripKind::Origin {
        let st = best[cursor as usize];
        if st.from_stop == u32::MAX {
            return None;
        }
        match st.kind {
            TripKind::Transit => {
                reversed_legs.push(JourneyLeg {
                    kind: LegKind::Transit,
                    from_stop: st.from_stop,
                    to_stop: cursor,
                    depart_s: st.board_departs_s,
                    arrive_s: st.arrival_s,
                    trip_idx: Some(st.trip_idx),
                    walk_m: 0.0,
                });
                cursor = st.from_stop;
            }
            TripKind::Transfer => {
                num_transfers += 1;
                reversed_legs.push(JourneyLeg {
                    kind: LegKind::TransferWalk,
                    from_stop: st.from_stop,
                    to_stop: cursor,
                    depart_s: st.board_departs_s,
                    arrive_s: st.arrival_s,
                    trip_idx: None,
                    walk_m: 0.0,
                });
                cursor = st.from_stop;
            }
            TripKind::Origin => unreachable!(),
        }
    }

    let origin_stop = cursor;
    let origin_state = best[origin_stop as usize];

    // Correct order: [origin_walk, first_transit, ..., last_transit, dest_walk]
    let mut legs: Vec<JourneyLeg> = Vec::with_capacity(reversed_legs.len() + 2);

    legs.push(JourneyLeg {
        kind: LegKind::OriginWalk,
        from_stop: u32::MAX,
        to_stop: origin_stop,
        depart_s: 0,
        arrive_s: origin_state.arrival_s,
        trip_idx: None,
        walk_m: origin_state.walk_m,
    });

    reversed_legs.reverse();
    legs.extend(reversed_legs);

    legs.push(JourneyLeg {
        kind: LegKind::DestWalk,
        from_stop: dest_stop,
        to_stop: u32::MAX,
        depart_s: final_arrival_s.saturating_sub(dest_walk_s),
        arrive_s: final_arrival_s,
        trip_idx: None,
        walk_m: dest_walk_m,
    });

    // Monotone: each leg's depart_s must be >= previous leg's arrive_s
    for w in legs.windows(2) {
        if w[1].depart_s < w[0].arrive_s {
            debug!(
                prev_kind = ?w[0].kind,
                next_kind = ?w[1].kind,
                prev_arrive = w[0].arrive_s,
                next_depart = w[1].depart_s,
                "reconstruct: monotone violation"
            );
            return None;
        }
    }

    let total_walk_m = origin_state.walk_m + dest_walk_m;

    Some(Journey {
        legs,
        depart_s: 0,
        arrive_s: final_arrival_s,
        num_transfers,
        total_walk_m,
    })
}