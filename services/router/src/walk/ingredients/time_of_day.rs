use super::super::types::{WalkContext, WalkEstimate};

pub fn apply(_ctx: &WalkContext<'_>, est: &mut WalkEstimate) {
    // Neutral for now — no lighting/darkness data source. Placeholder
    // keeps the ingredient in the pipeline so Layer 3+ can extend it.
    let multiplier = 1.0;
    est.seconds = ((est.seconds as f64) * multiplier).round() as u32;
    est.breakdown.time_of_day_multiplier = Some(multiplier);
    est.breakdown.ingredients_applied.push("time_of_day".into());
}