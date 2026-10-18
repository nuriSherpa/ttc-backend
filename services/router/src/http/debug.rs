use std::sync::atomic::Ordering;

use axum::extract::State;
use axum::http::HeaderMap;
use axum::response::IntoResponse;
use axum::Json;
use serde::Serialize;
use serde_json::{json, Value};
use sqlx::PgPool;

use crate::http::errors::ApiError;
use crate::http::middleware::check_internal_token;
use crate::AppState;

#[derive(Debug, Serialize)]
pub struct TableGroup {
    pub tables: Vec<(String, Option<i64>)>,
    pub total_rows: i64,
}

#[derive(Debug, Serialize)]
pub struct GraphStatusSnapshot {
    pub graph_loaded: bool,
    pub feed_version: Option<String>,
    pub live_vehicles: i64,
    pub active_alerts: i64,
}

#[derive(Debug, Serialize)]
pub struct DataSnapshot {
    pub ref_data: TableGroup,
    pub core: TableGroup,
    pub realtime: TableGroup,
    pub stats: TableGroup,
    pub app: TableGroup,
    pub graph_status: GraphStatusSnapshot,
    pub samples: Value,
}

async fn table_count(pool: &PgPool, schema: &str, table: &str) -> Option<i64> {
    // Table names come from our own compile-time list — no injection risk.
    let sql = format!("SELECT count(*) FROM \"{}\".\"{}\"", schema, table);
    sqlx::query_scalar::<_, i64>(&sql)
        .fetch_one(pool)
        .await
        .ok()
}

async fn group(pool: &PgPool, schema: &str, tables: &[&str]) -> TableGroup {
    let mut result = Vec::with_capacity(tables.len());
    let mut total = 0i64;
    for &t in tables {
        let count = table_count(pool, schema, t).await;
        if let Some(n) = count {
            total += n;
        }
        result.push((format!("{}.{}", schema, t), count));
    }
    TableGroup {
        tables: result,
        total_rows: total,
    }
}

pub async fn data_snapshot(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<impl IntoResponse, ApiError> {
    check_internal_token(&state, &headers)?;
    let snap = build_snapshot(&state).await;
    Ok(Json(snap))
}

pub async fn build_snapshot(state: &AppState) -> DataSnapshot {
    let ref_data = group(
        &state.pg,
        "ref",
        &[
            "stop_points", "trips", "trip_stops", "departures",
            "patterns", "pattern_stops", "station_nodes", "pathway_edges",
            "transfers", "service_days",
        ],
    )
    .await;

    let core = group(
        &state.pg,
        "core",
        &["stops", "routes", "trips", "stop_times", "shapes", "calendar", "agency"],
    )
    .await;

    let realtime = group(
        &state.pg,
        "rt",
        &[
            "vehicle_latest", "vehicle_samples", "trip_status", "stop_eta",
            "alert", "alert_active_period", "alert_informed_entity",
        ],
    )
    .await;

    let stats = group(
        &state.pg,
        "stats",
        &["route_reliability", "stop_reliability", "segment_travel_time"],
    )
    .await;

    let app = group(
        &state.pg,
        "app",
        &[
            "account", "user_preferences", "walk_observation", "user_consent",
            "session", "device", "commitment", "commitment_run",
        ],
    )
    .await;

    let stops_sample: Value = sqlx::query_scalar(
        "SELECT COALESCE(jsonb_agg(row_to_json(t)), '[]'::jsonb) FROM (
            SELECT stop_id, stop_name, stop_lat, stop_lon, wheelchair_boarding
            FROM ref.stop_points ORDER BY stop_id LIMIT 3
         ) t",
    )
    .fetch_one(&state.pg)
    .await
    .unwrap_or(json!([]));

    let routes_sample: Value = sqlx::query_scalar(
        "SELECT COALESCE(jsonb_agg(row_to_json(t)), '[]'::jsonb) FROM (
            SELECT route_id, route_short_name, route_long_name, route_type
            FROM core.routes
            WHERE feed_version = ops.active_version()
            ORDER BY route_short_name NULLS LAST LIMIT 5
         ) t",
    )
    .fetch_one(&state.pg)
    .await
    .unwrap_or(json!([]));

    let vehicles_sample: Value = sqlx::query_scalar(
        "SELECT COALESCE(jsonb_agg(row_to_json(t)), '[]'::jsonb) FROM (
            SELECT vehicle_id, route_id, lat, lon, occupancy, service_state, received_at
            FROM rt.vehicle_latest
            ORDER BY received_at DESC LIMIT 3
         ) t",
    )
    .fetch_one(&state.pg)
    .await
    .unwrap_or(json!([]));

    let alerts_sample: Value = sqlx::query_scalar(
        "SELECT COALESCE(jsonb_agg(row_to_json(t)), '[]'::jsonb) FROM (
            SELECT alert_id, effect, severity_level, header_text, active_from, active_until
            FROM rt.active_alerts LIMIT 3
         ) t",
    )
    .fetch_one(&state.pg)
    .await
    .unwrap_or(json!([]));

    let reliability_sample: Value = sqlx::query_scalar(
        "SELECT COALESCE(jsonb_agg(row_to_json(t)), '[]'::jsonb) FROM (
            SELECT route_id, direction_id, day_type, hour_bucket,
                   round(score, 1) AS score, sample_count
            FROM stats.route_reliability
            ORDER BY route_id, direction_id, hour_bucket LIMIT 5
         ) t",
    )
    .fetch_one(&state.pg)
    .await
    .unwrap_or(json!([]));

    let departures_sample: Value = sqlx::query_scalar(
        "SELECT COALESCE(jsonb_agg(row_to_json(t)), '[]'::jsonb) FROM (
            SELECT service_date, trip_id, stop_id, departs_at, route_id, headsign
            FROM ref.departures
            WHERE departs_at > now()
            ORDER BY departs_at LIMIT 5
         ) t",
    )
    .fetch_one(&state.pg)
    .await
    .unwrap_or(json!([]));

    let feed_version: Option<String> =
        sqlx::query_scalar::<_, Option<String>>("SELECT ops.active_version()")
            .fetch_one(&state.pg)
            .await
            .ok()
            .flatten();

    let live_vehicles: i64 = sqlx::query_scalar(
        "SELECT count(*) FROM rt.vehicle_latest WHERE received_at > now() - interval '5 minutes'",
    )
    .fetch_one(&state.pg)
    .await
    .unwrap_or(0);

    let active_alerts: i64 = sqlx::query_scalar("SELECT count(*) FROM rt.active_alerts")
        .fetch_one(&state.pg)
        .await
        .unwrap_or(0);

    DataSnapshot {
        ref_data,
        core,
        realtime,
        stats,
        app,
        graph_status: GraphStatusSnapshot {
            graph_loaded: state.graph_loaded.load(Ordering::Relaxed),
            feed_version,
            live_vehicles,
            active_alerts,
        },
        samples: json!({
            "stops": stops_sample,
            "routes": routes_sample,
            "vehicles": vehicles_sample,
            "alerts": alerts_sample,
            "reliability": reliability_sample,
            "departures": departures_sample,
        }),
    }
}

pub async fn print_snapshot(state: &AppState) {
    let snap = build_snapshot(state).await;

    println!();
    println!("╔═══════════════════════════════════════════════════════════════╗");
    println!("║  DATA SNAPSHOT — what ttc-router sees                         ║");
    println!("╚═══════════════════════════════════════════════════════════════╝");
    if let Some(v) = &snap.graph_status.feed_version {
        println!("  Feed version: {}", v);
    } else {
        println!("  Feed version: (none active)");
    }
    println!();

    let print_group = |name: &str, g: &TableGroup| {
        println!("  {} — {} total rows", name, g.total_rows);
        for (tbl, count) in &g.tables {
            let c = count.map(|n| n.to_string()).unwrap_or_else(|| "—".into());
            println!("    {:<32} {:>12}", tbl, c);
        }
        println!();
    };

    print_group("REF (derived from active feed)", &snap.ref_data);
    print_group("CORE (raw GTFS)", &snap.core);
    print_group("REALTIME", &snap.realtime);
    print_group("STATS", &snap.stats);
    print_group("APP", &snap.app);

    println!("  Live vehicles (≤5min): {}", snap.graph_status.live_vehicles);
    println!("  Active alerts:         {}", snap.graph_status.active_alerts);
    println!("╔═══════════════════════════════════════════════════════════════╗");
    println!("║  Full dump: GET /debug/data (with X-Internal-Token header)    ║");
    println!("╚═══════════════════════════════════════════════════════════════╝");
    println!();
}