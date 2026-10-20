//! Layer 8 — score sandwich.

pub mod comfort;
pub mod reliability;
pub mod time;
pub mod transfers;
pub mod types;
pub mod waiting;
pub mod walking;
pub mod weather;

pub use types::{Preset, ScoreReason, ScoredJourney, Weights};

use chrono::{DateTime, Utc};
use crate::graph::reliability::ReliabilityCache;
use crate::journey::types::{JourneyResponse, ResponseLeg};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TimeMode {
    LeaveAt,
    ArriveBy,
}

pub struct ScoreContext {
    pub requested_depart_at: DateTime<Utc>,
    pub requested_arrive_at: Option<DateTime<Utc>>,
    pub mode: TimeMode,
    pub max_walk_m: i32,
    pub hour: u8,
    pub day_type: String,
    pub reliability: Option<ReliabilityCache>,
}

pub fn score(
    journeys: Vec<JourneyResponse>,
    preset: Preset,
    ctx: &ScoreContext,
) -> Vec<ScoredJourney> {
    if journeys.is_empty() {
        return Vec::new();
    }

    // Precompute reference times based on mode.
    let (fastest_arrival_s, window_s) = match ctx.mode {
        TimeMode::LeaveAt => {
            let fastest = journeys
                .iter()
                .map(|j| (j.arrive_at - ctx.requested_depart_at).num_seconds().max(1))
                .min()
                .unwrap_or(1)
                .max(1);
            (fastest as f64, 3600)
        }
        TimeMode::ArriveBy => {
            let deadline = ctx.requested_arrive_at.unwrap_or(ctx.requested_depart_at);
            // Window = how far back we searched (2 hours).
            (1.0, (deadline - ctx.requested_depart_at).num_seconds().max(3600))
        }
    };

    let weights = preset.weights();

    let mut scored: Vec<ScoredJourney> = journeys
        .into_iter()
        .map(|j| {
            let mut reasons = Vec::new();

            // ── time ──
            let (t_score, t_reason) = match ctx.mode {
                TimeMode::LeaveAt => {
                    let arrival_s = (j.arrive_at - ctx.requested_depart_at)
                        .num_seconds()
                        .max(1) as f64;
                    time::score(arrival_s, fastest_arrival_s)
                }
                TimeMode::ArriveBy => {
                    let deadline = ctx.requested_arrive_at.unwrap_or(ctx.requested_depart_at);
                    let slack_s = (deadline - j.arrive_at).num_seconds();
                    time::score_arrive_by(slack_s, window_s)
                }
            };
            reasons.push(ScoreReason {
                dimension: "time",
                score: t_score,
                weight: weights.time,
                reason: t_reason,
            });

            // ── walking ──
            let (w_score, w_reason) =
                walking::score(j.total_walk_m, ctx.max_walk_m.max(1) as f64);
            reasons.push(ScoreReason {
                dimension: "walking",
                score: w_score,
                weight: weights.walking,
                reason: w_reason,
            });

            // ── transfers ──
            let (tr_score, tr_reason) = transfers::score(j.real_transfers);
            reasons.push(ScoreReason {
                dimension: "transfers",
                score: tr_score,
                weight: weights.transfers,
                reason: tr_reason,
            });

            // ── waiting ──
            let (wa_score, wa_reason) =
                waiting::score(j.total_wait_seconds, j.total_seconds);
            reasons.push(ScoreReason {
                dimension: "waiting",
                score: wa_score,
                weight: weights.waiting,
                reason: wa_reason,
            });

            // ── weather ──
            if let Some((s, r)) = weather::score(&j) {
                reasons.push(ScoreReason {
                    dimension: "weather",
                    score: s,
                    weight: weights.weather,
                    reason: r,
                });
            }

            // ── reliability (real, needs cache) ──
            if let Some(cache) = ctx.reliability.as_ref() {
                if let Some((s, r)) = reliability::score(&j, cache, ctx.hour, &ctx.day_type) {
                    reasons.push(ScoreReason {
                        dimension: "reliability",
                        score: s,
                        weight: weights.reliability,
                        reason: r,
                    });
                }
            }

            // ── comfort (stub) ──
            if let Some((s, r)) = comfort::score(&j) {
                reasons.push(ScoreReason {
                    dimension: "comfort",
                    score: s,
                    weight: weights.comfort,
                    reason: r,
                });
            }

            let total_weight: f64 = reasons.iter().map(|r| r.weight).sum();
            let total_score = if total_weight > 0.0 {
                reasons.iter().map(|r| r.score * r.weight).sum::<f64>() / total_weight
            } else {
                0.0
            };

            let slip_s = match ctx.mode {
                TimeMode::LeaveAt => first_departure(&j)
                    .map(|d| (d - ctx.requested_depart_at).num_seconds())
                    .unwrap_or(0),
                TimeMode::ArriveBy => first_departure(&j)
                    .map(|d| (ctx.requested_arrive_at.unwrap_or(ctx.requested_depart_at) - d).num_seconds())
                    .unwrap_or(0),
            };

            ScoredJourney {
                journey: j,
                score: total_score,
                reasons,
                departure_slip_s: slip_s,
            }
        })
        .collect();

    scored.sort_by(|a, b| {
        b.score
            .partial_cmp(&a.score)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| a.departure_slip_s.cmp(&b.departure_slip_s))
    });
    scored
}

fn first_departure(j: &JourneyResponse) -> Option<DateTime<Utc>> {
    match j.legs.first()? {
        ResponseLeg::Walk(w) => Some(w.depart_at),
        ResponseLeg::Transit(t) => Some(t.depart_at),
        ResponseLeg::Wait(w) => Some(w.depart_at),
        ResponseLeg::Dwell(d) => Some(d.arrive_at),
    }
}