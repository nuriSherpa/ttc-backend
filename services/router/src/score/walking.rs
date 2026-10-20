//! Walking dimension — less walking is better.
//!
//! Score is 100 for zero walk, 0 for walk >= max_walk_m.
//! Formula: 100 × (1 - walk_m/max_walk_m), clamped to [0, 100].

pub fn score(walk_m: f64, max_walk_m: f64) -> (f64, String) {
    let max = max_walk_m.max(1.0);
    let ratio = (walk_m / max).clamp(0.0, 1.0);
    let s = 100.0 * (1.0 - ratio);
    let reason = if walk_m < 50.0 {
        "minimal walking".to_string()
    } else {
        format!("walk {}m of max {}m", walk_m.round() as i64, max.round() as i64)
    };
    (s, reason)
}