use tracing::debug;

use super::raptor::Journey;

/// Filter to a diverse set of non-dominated journeys for the score sandwich.
///
/// Two-stage filter:
///   1. Pareto dominance — drop journeys beaten on time+transfers+walking
///   2. Near-duplicate — drop journeys within (300s, same transfers, 300m)
///   3. Cap at max_candidates (default 5)
///
/// The result is *meaningfully different* alternatives that a scoring layer
/// (Layer 8) can rank against user preferences. A journey that's 3 min slower
/// but has 1 fewer transfer survives — the score sandwich decides which to
/// recommend based on the user's "reliability" or "fewer transfers" weight.
pub fn filter(journeys: Vec<Journey>, max_candidates: usize) -> Vec<Journey> {
    if journeys.is_empty() {
        return journeys;
    }

    let before = journeys.len();

    // Sort by arrival so the earliest survives first
    let mut sorted = journeys;
    sorted.sort_by_key(|j| j.arrive_s);

    let mut kept: Vec<Journey> = Vec::with_capacity(max_candidates);

    for j in sorted {
        // ── Stage 1: Pareto dominance ──
        // Drop if any kept journey is (faster OR equal) on all three axes,
        // with at least one strictly better.
        let dominated = kept.iter().any(|p| {
            p.arrive_s <= j.arrive_s
                && p.num_transfers <= j.num_transfers
                && p.total_walk_m <= j.total_walk_m
                && (p.arrive_s < j.arrive_s
                    || p.num_transfers < j.num_transfers
                    || p.total_walk_m < j.total_walk_m)
        });
        if dominated {
            debug!(
                arrive_s = j.arrive_s,
                transfers = j.num_transfers,
                walk_m = j.total_walk_m,
                "pareto: dropped (dominated)"
            );
            continue;
        }

        // ── Stage 2: near-duplicate ──
        // Drop if essentially identical to something we already kept.
        // Loose thresholds (300s / 300m) so a 5-min-slower alternative with
        // fewer transfers survives.
        let too_similar = kept.iter().any(|p| {
            let time_diff = (p.arrive_s as i64 - j.arrive_s as i64).abs();
            let walk_diff = (p.total_walk_m - j.total_walk_m).abs();
            time_diff < 300
                && p.num_transfers == j.num_transfers
                && walk_diff < 300.0
        });
        if too_similar {
            debug!(
                arrive_s = j.arrive_s,
                transfers = j.num_transfers,
                walk_m = j.total_walk_m,
                "pareto: dropped (near-duplicate)"
            );
            continue;
        }

        kept.push(j);
        if kept.len() >= max_candidates {
            break;
        }
    }

    debug!(
        before,
        after = kept.len(),
        max_candidates,
        "pareto: filter complete"
    );

    kept
}