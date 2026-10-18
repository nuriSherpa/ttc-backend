use super::super::types::{WalkContext, WalkEstimate};

pub fn apply(ctx: &WalkContext<'_>, est: &mut WalkEstimate) {
    if let Some(ratio) = ctx.user.correction_ratio {
        est.seconds = ((est.seconds as f64) * ratio).round() as u32;
        est.breakdown.personal_correction = Some(ratio);
        est.confidence *= 0.90;
        est.breakdown.ingredients_applied.push("personal_correction".into());
    } else {
        est.breakdown.ingredients_skipped.push("personal_correction".into());
    }
}