use super::super::types::{WalkContext, WalkEstimate};

pub fn apply(_ctx: &WalkContext<'_>, est: &mut WalkEstimate) {
    // No elevation data yet. Skipped silently per design principle.
    est.breakdown.ingredients_skipped.push("terrain".into());
}