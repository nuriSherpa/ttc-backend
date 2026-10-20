//! Layer 10 — live delay cache from `rt.stop_eta`.
//!
//! Loads predicted arrival times into a `HashMap` refreshed every 30s from
//! `AppState`. RAPTOR consumes it at board-decision time to reflect real
//! arrival times instead of schedule.
//!
//! `predicted_at` is authoritative — `delay_s` and `scheduled_at` are NULL
//! in the current ingestor, so we compare `predicted_at` directly against
//! the scheduled departure from `ref.departures`.

use std::collections::HashMap;

use anyhow::Context;
use chrono::{DateTime, NaiveDate, Utc};
use sqlx::PgPool;
use tracing::info;

use super::types::days_from_epoch;
use super::Graph;

/// Ignore live predictions whose delta from schedule exceeds 1 hour —
/// almost certainly bad data (wrong service_date, feed glitch, overnight).
pub const MAX_LIVE_DELTA_S: i64 = 3600;

/// Ignore live predictions whose absolute time is more than 5 min in the
/// past — stale row that the 2-hour `received_at` filter didn't catch.
pub const MAX_LIVE_STALENESS_S: i64 = 300;

#[derive(Debug)]
pub struct LiveDelays {
    /// Feed version this cache was built against. If it doesn't match
    /// `graph.feed_version`, treat cache as empty — `trip_idx` values
    /// are only stable within one feed version.
    pub feed_version: String,
    /// `(trip_idx, epoch_day, stop_sequence) -> predicted_at`
    pub map: HashMap<(u32, i32, i32), DateTime<Utc>>,
    pub loaded_at: DateTime<Utc>,
    pub row_count: usize,
}

impl LiveDelays {
    pub fn empty() -> Self {
        Self {
            feed_version: String::new(),
            map: HashMap::new(),
            loaded_at: Utc::now(),
            row_count: 0,
        }
    }

    pub fn get(
        &self,
        trip_idx: u32,
        epoch_day: i32,
        stop_sequence: i32,
    ) -> Option<DateTime<Utc>> {
        self.map.get(&(trip_idx, epoch_day, stop_sequence)).copied()
    }
}

pub async fn load(pg: &PgPool, graph: &Graph) -> anyhow::Result<LiveDelays> {
    let rows: Vec<(String, NaiveDate, i32, DateTime<Utc>)> = sqlx::query_as(
        r#"
        SELECT trip_id, service_date, stop_sequence, predicted_at
        FROM rt.stop_eta
        WHERE received_at > now() - interval '2 hours'
          AND is_skipped = false
          AND predicted_at IS NOT NULL
        "#,
    )
    .fetch_all(pg)
    .await
    .context("loading rt.stop_eta")?;

    let mut map = HashMap::with_capacity(rows.len());
    let mut unresolved = 0usize;
    for (trip_id, service_date, stop_sequence, predicted_at) in &rows {
        if let Some(&trip_idx) = graph.trip_idx_by_id.get(trip_id) {
            map.insert(
                (trip_idx, days_from_epoch(*service_date), *stop_sequence),
                *predicted_at,
            );
        } else {
            unresolved += 1;
        }
    }

    info!(
        rows = rows.len(),
        resolved = map.len(),
        unresolved,
        "live delays loaded"
    );

    Ok(LiveDelays {
        feed_version: graph.feed_version.clone(),
        row_count: map.len(),
        map,
        loaded_at: Utc::now(),
    })
}