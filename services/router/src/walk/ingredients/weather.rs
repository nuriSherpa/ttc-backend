use super::super::types::{WalkContext, WalkEstimate};
use crate::graph::weather;

pub async fn apply(ctx: &WalkContext<'_>, est: &mut WalkEstimate) {
    let w = weather::at(ctx.weather, ctx.from_lat, ctx.from_lon, ctx.depart_at).await;

    if let Some(w) = w {
        let penalty = w.condition.walk_penalty(w.severity);
        est.seconds = ((est.seconds as f32) * penalty).round() as u32;
        est.breakdown.weather_penalty = Some(penalty);
        est.breakdown.weather_condition = Some(format!("{:?}", w.condition).to_lowercase());
        est.confidence *= 0.95;
        est.breakdown.ingredients_applied.push("weather".into());
    } else {
        est.breakdown.ingredients_skipped.push("weather".into());
    }
}