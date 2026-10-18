use super::super::types::{WalkContext, WalkEstimate};

pub fn apply(ctx: &WalkContext<'_>, est: &mut WalkEstimate) {
    let speed = ctx.user.walk_speed_mps.clamp(0.3, 3.0);
    let seconds = (est.walk_m / speed).round() as u32;
    est.seconds = seconds;
    est.breakdown.personal_speed_mps = Some(speed);
    est.breakdown.ingredients_applied.push("personal_speed".into());
}