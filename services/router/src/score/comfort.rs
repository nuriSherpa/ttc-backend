//! Comfort dimension — STUB until Layer 7 wires occupancy from
//! rt.vehicle_latest (packed vs. empty, seat availability).
//!
//! When real data is available, return `Some((score, reason))` based on
//! vehicle occupancy on transit legs and shelter quality on wait legs.
//! For now, return `None`.

use crate::journey::types::JourneyResponse;

pub fn score(_j: &JourneyResponse) -> Option<(f64, String)> {
    None
}