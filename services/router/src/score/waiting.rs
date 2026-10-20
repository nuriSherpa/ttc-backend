//! Waiting dimension — minimize time spent standing at stops.
//!
//! Score is 100 when wait is trivial, 0 when half the journey is waiting.
//! Formula: 100 * (1 - wait_pct * 2), clamped to [0, 100].

pub fn score(wait_s: u32, total_s: u32) -> (f64, String) {
    if total_s == 0 {
        return (100.0, "instant".to_string());
    }
    let pct = wait_s as f64 / total_s as f64;
    let s = (100.0 * (1.0 - pct * 2.0)).clamp(0.0, 100.0);
    let reason = if wait_s < 60 {
        "under 1 min waiting".to_string()
    } else {
        format!("{} min waiting of {} min total", wait_s / 60, total_s / 60)
    };
    (s, reason)
}