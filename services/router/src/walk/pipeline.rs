use super::ingredients::{
    base_distance, personal_correction, personal_speed, terrain, time_of_day, weather,
};
use super::types::{WalkContext, WalkEstimate};

pub async fn estimate(ctx: &WalkContext<'_>) -> WalkEstimate {
    let mut est = WalkEstimate {
        seconds: 0,
        walk_m: 0.0,
        confidence: 1.0,
        breakdown: Default::default(),
    };

    base_distance::apply(ctx, &mut est);
    personal_speed::apply(ctx, &mut est);
    terrain::apply(ctx, &mut est);
    weather::apply(ctx, &mut est).await;
    time_of_day::apply(ctx, &mut est);
    personal_correction::apply(ctx, &mut est);

    est
}