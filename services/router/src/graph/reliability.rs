//! Per-route × hour × day_type reliability scores from `stats.route_reliability`.

use std::collections::HashMap;

use anyhow::Context;
use chrono::{DateTime, Utc};
use sqlx::PgPool;
use tracing::info;

#[derive(Debug, Clone)]
pub struct ReliabilityCache {
    /// (route_id, day_type, hour_of_day) -> averaged on-time score 0-100
    pub scores: HashMap<(String, String, u8), f32>,
    pub loaded_at: DateTime<Utc>,
    pub row_count: usize,
}

impl ReliabilityCache {
    pub fn empty() -> Self {
        Self {
            scores: HashMap::new(),
            loaded_at: Utc::now(),
            row_count: 0,
        }
    }
}

pub async fn load(pg: &PgPool) -> anyhow::Result<ReliabilityCache> {
    let rows: Vec<(String, String, i32, f32)> = sqlx::query_as(
        "SELECT route_id,
                day_type,
                hour_bucket::int AS hour_bucket,
                AVG(score::float4)::float4 AS score
         FROM stats.route_reliability
         WHERE score IS NOT NULL
         GROUP BY route_id, day_type, hour_bucket",
    )
    .fetch_all(pg)
    .await
    .context("loading stats.route_reliability")?;

    let mut scores = HashMap::with_capacity(rows.len());
    for (rid, day_type, hour, score) in &rows {
        let h = (*hour).clamp(0, 23) as u8;
        scores.insert((rid.clone(), day_type.clone(), h), *score);
    }

    let row_count = scores.len();
    info!(rows = rows.len(), keys = row_count, "reliability scores loaded");

    Ok(ReliabilityCache {
        scores,
        loaded_at: Utc::now(),
        row_count,
    })
}
