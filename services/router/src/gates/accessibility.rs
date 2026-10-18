use crate::context::loader::UserPrefs;
use crate::graph::Graph;
use super::types::Candidate;

/// Drop candidates whose stop is marked `wheelchair_boarding = 2` (not accessible)
/// when the user needs wheelchair routing. A no-op otherwise.
pub fn apply(
    candidates: Vec<Candidate>,
    graph: &Graph,
    prefs: &UserPrefs,
) -> (Vec<Candidate>, usize) {
    if !prefs.wheelchair_mode && !prefs.avoid_stairs {
        return (candidates, 0);
    }

    let before = candidates.len();
    let filtered: Vec<Candidate> = candidates
        .into_iter()
        .filter(|c| {
            let stop = &graph.stops[c.stop_idx as usize];
            stop.wheelchair_boarding != Some(2)
        })
        .collect();

    let dropped = before - filtered.len();
    (filtered, dropped)
}