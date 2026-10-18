use crate::context::loader::UserPrefs;
use super::types::Candidate;

/// Drop candidates whose estimated walk distance exceeds the user's limit.
pub fn apply(candidates: Vec<Candidate>, prefs: &UserPrefs) -> (Vec<Candidate>, usize) {
    let max = prefs.max_walk_m as f64;
    let before = candidates.len();
    let filtered: Vec<Candidate> = candidates
        .into_iter()
        .filter(|c| {
            c.walk_estimate
                .as_ref()
                .map(|e| e.walk_m <= max)
                .unwrap_or(false)
        })
        .collect();
    let dropped = before - filtered.len();
    (filtered, dropped)
}