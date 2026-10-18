use super::super::types::{WalkContext, WalkEstimate};

pub fn apply(ctx: &WalkContext<'_>, est: &mut WalkEstimate) {
    let detour = ctx.user.detour_factor.max(1.0);
    let walk_m = ctx.raw_distance_m * detour;
    est.walk_m = walk_m;
    est.breakdown.base_distance_m = Some(walk_m);
    est.breakdown.detour_factor = Some(detour);
    est.breakdown.ingredients_applied.push("base_distance".into());
}