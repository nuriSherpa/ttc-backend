//! Transfers dimension — fewer real transfers is better.
//!
//! Uses `real_transfers` (transit_legs - 1), not RAPTOR's `num_transfers`,
//! to avoid penalizing journeys whose final "transfer" was actually a walk
//! to a stop near the destination (Test 6 Warden→Roper case).
//!
//! Score: 100 for 0 transfers, minus 20 per transfer, floored at 0.

pub fn score(real_transfers: u8) -> (f64, String) {
    let penalty = real_transfers as f64 * 20.0;
    let s = (100.0 - penalty).max(0.0);
    let reason = if real_transfers == 0 {
        "no transfers".to_string()
    } else {
        format!(
            "{} transfer{}",
            real_transfers,
            if real_transfers == 1 { "" } else { "s" }
        )
    };
    (s, reason)
}