//! Reliability dimension — uses real route × hour × day_type scores.
//!
//! Lookup is fuzzy: exact (route, day, hour) first, then ±1h, ±2h,
//! then any hour for that (route, day) combo. This handles sparse
//! tables where only certain hours are populated.

use crate::graph::reliability::ReliabilityCache;
use crate::journey::types::{JourneyResponse, ResponseLeg};

fn lookup(cache: &ReliabilityCache, route_id: &str, day_type: &str, hour: u8) -> Option<f32> {
    // 1. Exact match
    if let Some(&s) = cache.scores.get(&(route_id.to_string(), day_type.to_string(), hour)) {
        return Some(s);
    }
    // 2. ±1 hour
    for delta in [1u8, 2u8] {
        if hour >= delta {
            if let Some(&s) = cache.scores.get(&(route_id.to_string(), day_type.to_string(), hour - delta)) {
                return Some(s);
            }
        }
        if hour + delta <= 23 {
            if let Some(&s) = cache.scores.get(&(route_id.to_string(), day_type.to_string(), hour + delta)) {
                return Some(s);
            }
        }
    }
    // 3. Any hour for this (route, day) — fallback to whatever is there
    for h in 0u8..24 {
        if let Some(&s) = cache.scores.get(&(route_id.to_string(), day_type.to_string(), h)) {
            return Some(s);
        }
    }
    None
}

pub fn score(
    j: &JourneyResponse,
    cache: &ReliabilityCache,
    hour: u8,
    day_type: &str,
) -> Option<(f64, String)> {
    if cache.scores.is_empty() {
        return None;
    }

    let mut scores = Vec::new();
    let mut routes_seen = Vec::new();
    for leg in &j.legs {
        if let ResponseLeg::Transit(t) = leg {
            let rid = t.route.route_id.clone();
            if let Some(s) = lookup(cache, &rid, day_type, hour) {
                scores.push(s as f64);
                routes_seen.push(rid);
            }
        }
    }

    if scores.is_empty() {
        return None;
    }

    let avg = scores.iter().sum::<f64>() / scores.len() as f64;
    let reason = format!(
        "avg on-time {:.0}% across {} leg{} ({})",
        avg,
        scores.len(),
        if scores.len() == 1 { "" } else { "s" },
        routes_seen.join(", ")
    );
    Some((avg, reason))
}