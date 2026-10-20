use chrono::{DateTime, Utc};
use chrono_tz::America::Toronto;
use serde::Serialize;
use tracing::{debug, trace};

use crate::context::loader::UserPrefs;
use crate::gates::types::Candidate;
use crate::graph::live::LiveDelays;
use crate::graph::Graph;
use super::{pareto, round};

pub const HORIZON_SECONDS: u32 = 4 * 3600;
pub const INF: u32 = u32::MAX;
pub const DEFAULT_INTER_STOP_S: i32 = 60;
pub const MAX_PARETO_CANDIDATES: usize = 5;

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
    pub board_departs_s: u32,
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
    weather_multiplier: f32,
    live: &LiveDelays,
) -> Vec<Journey> {
    let board_cutoff = depart_at + chrono::Duration::seconds(HORIZON_SECONDS as i64);

    let toronto_today = depart_at.with_timezone(&Toronto).date_naive();
    let toronto_yesterday = toronto_today - chrono::Duration::days(1);
    let service_dates = vec![toronto_yesterday, toronto_today];

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

    // Round 0: seed with origin walks
    let mut marked: Vec<u32> = Vec::new();
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
            marked.push(c.stop_idx);
        }
    }

    // Rounds 1..N
    let max_rounds = (prefs.max_transfers as u32) + 1;
    let mut r = 0;
    while r < max_rounds && !marked.is_empty() {
        r += 1;
        trace!(round = r, marked = marked.len(), "raptor round");

        let result = round::expand_round(
            graph,
            &mut best,
            &marked,
            depart_at,
            &service_dates,
            board_cutoff,
            prefs,
            weather_multiplier,
            live,
        );

        if result.is_empty() {
            break;
        }
        marked = result.all_improved();
    }

    // Reconstruct candidate journeys
    let mut journeys: Vec<Journey> = Vec::new();
    for c in dest_candidates {
        let st = best[c.stop_idx as usize];
        if st.arrival_s == INF {
            continue;
        }
        let est = c.walk_estimate.as_ref().unwrap();
        let final_arrival = st.arrival_s + est.seconds;

        if let Some(j) = reconstruct(&best, c, est.seconds, est.walk_m, final_arrival) {
            journeys.push(j);
        }
    }

    debug!(
        before_filter = journeys.len(),
        dest_candidates = dest_candidates.len(),
        "raptor: candidates generated"
    );

    pareto::filter(journeys, MAX_PARETO_CANDIDATES)
}

fn reconstruct(
    best: &[StopState],
    dest_candidate: &Candidate,
    dest_walk_s: u32,
    dest_walk_m: f64,
    final_arrival_s: u32,
) -> Option<Journey> {
    let dest_stop = dest_candidate.stop_idx;
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

    for w in legs.windows(2) {
        if w[1].depart_s < w[0].arrive_s {
            return None;
        }
    }

    Some(Journey {
        legs,
        depart_s: 0,
        arrive_s: final_arrival_s,
        num_transfers,
        total_walk_m: origin_state.walk_m + dest_walk_m,
    })
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ShiftPolicy {
    /// Keep journey with earliest absolute arrival per transit chain.
    /// Used for `leave_at` mode (leave now, arrive as early as possible).
    EarliestArrival,
    /// Keep journey with latest absolute departure per transit chain.
    /// Used for `arrive_by` mode (leave as late as possible).
    LatestDeparture,
}

/// Run RAPTOR at multiple departure offsets and merge results.
///
/// **`offsets_s` may be negative** — this enables `arrive_by` mode, where
/// we search backwards from a deadline. The returned tuple's second element
/// is the **base departure** for that journey (`anchor + offset`), which
/// the caller MUST use when calling `assemble()`.
pub fn run_shifted(
    graph: &Graph,
    origin_candidates: &[Candidate],
    dest_candidates: &[Candidate],
    anchor: DateTime<Utc>,
    prefs: &UserPrefs,
    weather_multiplier: f32,
    offsets_s: &[i64],
    live: &crate::graph::live::LiveDelays,
    policy: ShiftPolicy,
) -> Vec<(Journey, DateTime<Utc>)> {
    use std::collections::HashMap;

    // chain -> (journey, base_depart, absolute_arrival)
    let mut best: HashMap<Vec<(u32, u32, u32)>, (Journey, DateTime<Utc>, DateTime<Utc>)> =
        HashMap::new();

    for &offset in offsets_s {
        let shifted_depart = anchor + chrono::Duration::seconds(offset);

        let journeys = run(
            graph,
            origin_candidates,
            dest_candidates,
            shifted_depart,
            prefs,
            weather_multiplier,
            live,
        );

        for j in journeys {
            let absolute_arrival =
                shifted_depart + chrono::Duration::seconds(j.arrive_s as i64);
            let chain = transit_chain(&j);

            let replace = match best.get(&chain) {
                None => true,
                Some((_, prev_base, prev_arrival)) => match policy {
                    ShiftPolicy::EarliestArrival => absolute_arrival < *prev_arrival,
                    ShiftPolicy::LatestDeparture => shifted_depart > *prev_base,
                },
            };

            if replace {
                best.insert(chain, (j, shifted_depart, absolute_arrival));
            }
        }
    }

    best.into_values().map(|(j, base, _)| (j, base)).collect()
}

fn transit_chain(j: &Journey) -> Vec<(u32, u32, u32)> {
    j.legs
        .iter()
        .filter(|l| l.kind == LegKind::Transit)
        .map(|l| (l.trip_idx.unwrap_or(u32::MAX), l.from_stop, l.to_stop))
        .collect()
}