use std::sync::atomic::Ordering;

use axum::extract::State;
use axum::http::{HeaderMap, StatusCode};
use axum::response::IntoResponse;
use axum::Json;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::context::loader::{LatLon, PlanFilters};
use crate::http::errors::ApiError;
use crate::http::middleware::check_internal_token;
use crate::AppState;

use axum::extract::Query;

#[derive(Deserialize)]
pub struct PlanRequest {
    pub user_id: Option<Uuid>,
    pub origin: LatLon,
    pub destination: LatLon,
    pub depart_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub filters: PlanFilters,
}

#[derive(Serialize)]
pub struct PlanResponse {
    pub recommended: Option<serde_json::Value>,
    pub alternatives: Vec<serde_json::Value>,
    pub meta: PlanMeta,
}

#[derive(Serialize)]
pub struct PlanMeta {
    pub as_of: DateTime<Utc>,
    pub data_freshness_s: u64,
    pub graph_loaded: bool,
    pub gates_applied: Vec<String>,
    pub warnings: Vec<String>,
}

pub async fn health(State(state): State<AppState>) -> impl IntoResponse {
    let pg_ok = sqlx::query("SELECT 1").fetch_one(&state.pg).await.is_ok();

let mut r = state.redis.clone();
let pong: String = redis::cmd("PING")
    .query_async(&mut r)
    .await
    .unwrap_or_default();
let redis_ok = pong == "PONG";

    let graph_loaded = state.graph_loaded.load(Ordering::Relaxed);
    let ok = pg_ok && redis_ok && graph_loaded;
    let status = if ok {
        StatusCode::OK
    } else {
        StatusCode::SERVICE_UNAVAILABLE
    };

    let body = Json(serde_json::json!({
        "ok": ok,
        "pg": pg_ok,
        "redis": redis_ok,
        "graph_loaded": graph_loaded,
        "uptime_s": state.started_at.elapsed().as_secs(),
        "version": "0.1.0",
    }));
    (status, body)
}

pub async fn graph_status(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<impl IntoResponse, ApiError> {
    check_internal_token(&state, &headers)?;
    let graph = state.graph.read().await;
    Ok(Json(serde_json::json!({
        "feed_version":       graph.feed_version,
        "loaded_at":          graph.loaded_at,
        "load_duration_ms":   graph.load_duration_ms,
        "horizon_days":       graph.horizon_days,
        "stops":              graph.stops.len(),
        "routes":             graph.routes.len(),
        "trips":              graph.trips.len(),
        "trip_stops":         graph.trip_stops_flat.len(),
        "departures":         graph.departures_flat.len(),
        "patterns":           graph.patterns.len(),
        "pattern_stops":      graph.pattern_stops_flat.len(),
        "station_nodes":      graph.station_nodes.len(),
        "pathway_edges":      graph.pathway_edges.len(),
    })))
}

pub async fn plan(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(req): Json<PlanRequest>,
) -> Result<impl IntoResponse, ApiError> {
    check_internal_token(&state, &headers)?;

    let ctx = state
        .ctx_loader
        .build(req.user_id, req.filters, req.origin, req.destination, req.depart_at)
        .await
        .map_err(ApiError::Internal)?;

    tracing::info!(
        user_id = ?ctx.user_id,
        wheelchair = ctx.user.wheelchair_mode,
        hour = ctx.hour_bucket,
        service_day = ctx.service_day.as_str(),
        "plan request"
    );

    Ok(Json(PlanResponse {
        recommended: None,
        alternatives: vec![],
        meta: PlanMeta {
            as_of: Utc::now(),
            data_freshness_s: 0,
            graph_loaded: state.graph_loaded.load(Ordering::Relaxed),
            gates_applied: vec![],
            warnings: vec!["routing pipeline not yet implemented (Layer 0 only)".into()],
        },
    }))
}

#[derive(serde::Deserialize)]
pub struct NearestQuery {
    pub lat: f64,
    pub lon: f64,
    #[serde(default = "default_radius")]
    pub radius: f64,
    #[serde(default = "default_limit")]
    pub limit: usize,
}

fn default_radius() -> f64 { 1000.0 }
fn default_limit() -> usize { 15 }

pub async fn nearest(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(q): Query<NearestQuery>,
) -> Result<impl IntoResponse, ApiError> {
    check_internal_token(&state, &headers)?;

    if q.radius <= 0.0 || q.radius > 10_000.0 {
        return Err(ApiError::BadRequest(format!(
            "radius must be 0 < r <= 10000, got {}", q.radius
        )));
    }
    if q.limit == 0 || q.limit > 50 {
        return Err(ApiError::BadRequest(format!(
            "limit must be 1..=50, got {}", q.limit
        )));
    }

    let t0 = std::time::Instant::now();
    let graph = state.graph.read().await;
    let results = graph.geo_index.nearest(q.lat, q.lon, q.radius, q.limit);
    let elapsed_us = t0.elapsed().as_micros() as u64;

    let stops: Vec<serde_json::Value> = results
        .iter()
        .map(|(idx, dist)| {
            let s = &graph.stops[*idx as usize];
            serde_json::json!({
                "stop_idx":          idx,
                "stop_id":           s.stop_id,
                "stop_name":         s.name,
                "distance_m":        (*dist * 10.0).round() / 10.0,
                "lat":               s.lat,
                "lon":               s.lon,
                "wheelchair_boarding": s.wheelchair_boarding,
                "parent_station":    s.parent_station,
            })
        })
        .collect();

    Ok(Json(serde_json::json!({
        "query": {
            "lat": q.lat,
            "lon": q.lon,
            "radius_m": q.radius,
            "limit": q.limit
        },
        "count": stops.len(),
        "elapsed_us": elapsed_us,
        "results": stops,
    })))
}



#[derive(Deserialize)]
pub struct WalkQuery {
    pub lat: f64,
    pub lon: f64,
    #[serde(default = "default_radius")]
    pub radius: f64,
    #[serde(default = "default_limit")]
    pub limit: usize,
    pub user_id: Option<Uuid>,
    pub depart_at: Option<DateTime<Utc>>,
}

pub async fn walk(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(q): Query<WalkQuery>,
) -> Result<impl IntoResponse, ApiError> {
    check_internal_token(&state, &headers)?;

    if q.radius <= 0.0 || q.radius > 10_000.0 {
        return Err(ApiError::BadRequest(format!(
            "radius must be 0 < r <= 10000, got {}", q.radius
        )));
    }
    if q.limit == 0 || q.limit > 50 {
        return Err(ApiError::BadRequest(format!(
            "limit must be 1..=50, got {}", q.limit
        )));
    }

    let prefs = if let Some(uid) = q.user_id {
        state.ctx_loader.load_user_prefs(uid).await.unwrap_or_default()
    } else {
        crate::context::loader::UserPrefs::default()
    };

    let depart_at = q.depart_at.unwrap_or_else(Utc::now);
    let t0 = std::time::Instant::now();
    let graph = state.graph.read().await;
    let candidates = graph.geo_index.nearest(q.lat, q.lon, q.radius, q.limit);

    let mut results = Vec::with_capacity(candidates.len());
    for (stop_idx, distance_m) in candidates {
        let stop = &graph.stops[stop_idx as usize];
        let ctx = crate::walk::types::WalkContext {
            from_lat: q.lat,
            from_lon: q.lon,
            to_lat: stop.lat,
            to_lon: stop.lon,
            raw_distance_m: distance_m,
            depart_at,
            user: &prefs,
            weather: &state.weather,
        };
        let est = crate::walk::pipeline::estimate(&ctx).await;
        results.push(serde_json::json!({
            "stop_id": stop.stop_id,
            "stop_name": stop.name,
            "stop_idx": stop_idx,
            "raw_distance_m": (distance_m * 10.0).round() / 10.0,
            "walk_seconds": est.seconds,
            "walk_m": (est.walk_m * 10.0).round() / 10.0,
            "confidence": (est.confidence * 100.0).round() / 100.0,
            "breakdown": est.breakdown,
        }));
    }
    drop(graph);
    let elapsed_us = t0.elapsed().as_micros() as u64;

    Ok(Json(serde_json::json!({
        "query": {
            "lat": q.lat, "lon": q.lon, "radius_m": q.radius,
            "limit": q.limit, "depart_at": depart_at,
        },
        "user": {
            "user_id": q.user_id,
            "correction_ratio": prefs.correction_ratio,
            "walk_speed_mps": prefs.walk_speed_mps,
            "detour_factor": prefs.detour_factor,
        },
        "count": results.len(),
        "elapsed_us": elapsed_us,
        "results": results,
    })))
}


#[derive(Deserialize)]
pub struct GatesQuery {
    pub lat: f64,
    pub lon: f64,
    #[serde(default = "default_radius")]
    pub radius: f64,
    #[serde(default = "default_limit")]
    pub limit: usize,
    pub user_id: Option<Uuid>,
    pub depart_at: Option<DateTime<Utc>>,
}

pub async fn gates(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(q): Query<GatesQuery>,
) -> Result<impl IntoResponse, ApiError> {
    use crate::gates::{accessibility, max_walk, types::{Candidate, GateStats}};

    check_internal_token(&state, &headers)?;

    if q.radius <= 0.0 || q.radius > 10_000.0 {
        return Err(ApiError::BadRequest(format!("radius out of range: {}", q.radius)));
    }
    if q.limit == 0 || q.limit > 50 {
        return Err(ApiError::BadRequest(format!("limit out of range: {}", q.limit)));
    }

    let prefs = if let Some(uid) = q.user_id {
        state.ctx_loader.load_user_prefs(uid).await.unwrap_or_default()
    } else {
        crate::context::loader::UserPrefs::default()
    };
    let depart_at = q.depart_at.unwrap_or_else(Utc::now);

    let graph = state.graph.read().await;

    // Step 1 — geo candidates
    let raw = graph.geo_index.nearest(q.lat, q.lon, q.radius, q.limit);
    let input_count = raw.len();
    let candidates: Vec<Candidate> = raw
        .into_iter()
        .map(|(stop_idx, raw_distance_m)| Candidate {
            stop_idx,
            raw_distance_m,
            walk_estimate: None,
            gates_passed: vec!["geo"],
            gate_failed: None,
        })
        .collect();

    // Step 2 — accessibility gate (before walk — cheaper)
    let (candidates, acc_dropped) = accessibility::apply(candidates, &graph, &prefs);

    // Step 3 — walk pipeline for survivors
    let mut candidates_with_walk = Vec::with_capacity(candidates.len());
    for mut c in candidates {
        let stop = &graph.stops[c.stop_idx as usize];
        let ctx = crate::walk::types::WalkContext {
            from_lat: q.lat,
            from_lon: q.lon,
            to_lat: stop.lat,
            to_lon: stop.lon,
            raw_distance_m: c.raw_distance_m,
            depart_at,
            user: &prefs,
            weather: &state.weather,
        };
        c.walk_estimate = Some(crate::walk::pipeline::estimate(&ctx).await);
        c.gates_passed.push("walk");
        candidates_with_walk.push(c);
    }

    // Step 4 — max walk gate
    let before_mw = candidates_with_walk.len();
    let (mut final_candidates, mw_dropped) = max_walk::apply(candidates_with_walk, &prefs);
    for c in &mut final_candidates {
        c.gates_passed.push("max_walk");
    }

    let output_count = final_candidates.len();
    let stats = GateStats {
        input: input_count,
        accessibility_dropped: acc_dropped,
        max_walk_dropped: mw_dropped,
        output: output_count,
    };
    let _ = before_mw;

    // Reshape for response
    let results: Vec<serde_json::Value> = final_candidates
        .iter()
        .map(|c| {
            let stop = &graph.stops[c.stop_idx as usize];
            let est = c.walk_estimate.as_ref().unwrap();
            serde_json::json!({
                "stop_id": stop.stop_id,
                "stop_name": stop.name,
                "wheelchair_boarding": stop.wheelchair_boarding,
                "raw_distance_m": (c.raw_distance_m * 10.0).round() / 10.0,
                "walk_m": (est.walk_m * 10.0).round() / 10.0,
                "walk_seconds": est.seconds,
                "gates_passed": c.gates_passed,
            })
        })
        .collect();

    Ok(Json(serde_json::json!({
        "query": {
            "lat": q.lat, "lon": q.lon,
            "radius_m": q.radius, "limit": q.limit,
            "depart_at": depart_at,
        },
        "user": {
            "user_id": q.user_id,
            "wheelchair_mode": prefs.wheelchair_mode,
            "avoid_stairs": prefs.avoid_stairs,
            "max_walk_m": prefs.max_walk_m,
            "correction_ratio": prefs.correction_ratio,
        },
        "stats": stats,
        "results": results,
    })))
}



#[derive(Deserialize)]
pub struct RaptorQuery {
    pub origin_lat: f64,
    pub origin_lon: f64,
    pub dest_lat: f64,
    pub dest_lon: f64,
    #[serde(default = "default_radius")]
    pub radius: f64,
    pub user_id: Option<Uuid>,
    pub depart_at: Option<DateTime<Utc>>,
}

async fn build_candidates(
    graph: &crate::graph::Graph,
    weather: &crate::graph::weather::WeatherCache,
    prefs: &crate::context::loader::UserPrefs,
    lat: f64, lon: f64, radius: f64,
    depart_at: DateTime<Utc>,
) -> Vec<crate::gates::types::Candidate> {
    use crate::gates::{accessibility, max_walk, types::Candidate};

    let raw = graph.geo_index.nearest(lat, lon, radius, 15);
    let candidates: Vec<Candidate> = raw
        .into_iter()
        .map(|(stop_idx, raw_distance_m)| Candidate {
            stop_idx, raw_distance_m,
            walk_estimate: None,
            gates_passed: vec!["geo"],
            gate_failed: None,
        })
        .collect();

    let (candidates, _) = accessibility::apply(candidates, graph, prefs);

    let mut with_walk = Vec::with_capacity(candidates.len());
    for mut c in candidates {
        let stop = &graph.stops[c.stop_idx as usize];
        let ctx = crate::walk::types::WalkContext {
            from_lat: lat, from_lon: lon,
            to_lat: stop.lat, to_lon: stop.lon,
            raw_distance_m: c.raw_distance_m,
            depart_at,
            user: prefs,
            weather,
        };
        c.walk_estimate = Some(crate::walk::pipeline::estimate(&ctx).await);
        c.gates_passed.push("walk");
        with_walk.push(c);
    }

    let (candidates, _) = max_walk::apply(with_walk, prefs);
    candidates
}

pub async fn raptor(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(q): Query<RaptorQuery>,
) -> Result<impl IntoResponse, ApiError> {
    check_internal_token(&state, &headers)?;

    let prefs = if let Some(uid) = q.user_id {
        state.ctx_loader.load_user_prefs(uid).await.unwrap_or_default()
    } else {
        crate::context::loader::UserPrefs::default()
    };
    let depart_at = q.depart_at.unwrap_or_else(Utc::now);

    let graph = state.graph.read().await;
    let t0 = std::time::Instant::now();

    let origin_candidates = build_candidates(
        &graph, &state.weather, &prefs,
        q.origin_lat, q.origin_lon, q.radius, depart_at,
    ).await;

    let dest_candidates = build_candidates(
        &graph, &state.weather, &prefs,
        q.dest_lat, q.dest_lon, q.radius, depart_at,
    ).await;

    if origin_candidates.is_empty() || dest_candidates.is_empty() {
        return Ok(Json(serde_json::json!({
            "error": "no_candidates",
            "origin_candidates": origin_candidates.len(),
            "dest_candidates": dest_candidates.len(),
        })));
    }

    let journeys = crate::raptor::raptor::run(
        &graph, &origin_candidates, &dest_candidates, depart_at, &prefs,
    );

    let elapsed_us = t0.elapsed().as_micros() as u64;

    let journeys_json: Vec<serde_json::Value> = journeys
        .iter()
        .map(|j| {
            let legs_json: Vec<serde_json::Value> = j.legs.iter().map(|leg| {
                use crate::raptor::raptor::LegKind;
                let from_name = if leg.from_stop == u32::MAX {
                    "origin".to_string()
                } else {
                    graph.stops[leg.from_stop as usize].name.clone()
                };
                let to_name = if leg.to_stop == u32::MAX {
                    "destination".to_string()
                } else {
                    graph.stops[leg.to_stop as usize].name.clone()
                };
                let route_info = leg.trip_idx.map(|tidx| {
                    let trip = &graph.trips[tidx as usize];
                    let route = &graph.routes[trip.route_idx as usize];
                    serde_json::json!({
                        "route_id": route.route_id,
                        "short_name": route.short_name,
                        "headsign": trip.headsign,
                    })
                });
                serde_json::json!({
                    "kind": match leg.kind {
                        LegKind::OriginWalk => "origin_walk",
                        LegKind::Transit => "transit",
                        LegKind::TransferWalk => "transfer_walk",
                        LegKind::DestWalk => "dest_walk",
                    },
                    "from": from_name,
                    "to": to_name,
                    "depart_s": leg.depart_s,
                    "arrive_s": leg.arrive_s,
                    "duration_s": leg.arrive_s.saturating_sub(leg.depart_s),
                    "walk_m": (leg.walk_m * 10.0).round() / 10.0,
                    "trip": route_info,
                })
            }).collect();

            serde_json::json!({
                "depart_s": j.depart_s,
                "arrive_s": j.arrive_s,
                "total_seconds": j.arrive_s,
                "num_transfers": j.num_transfers,
                "total_walk_m": (j.total_walk_m * 10.0).round() / 10.0,
                "legs": legs_json,
            })
        })
        .collect();

    Ok(Json(serde_json::json!({
        "query": {
            "origin": {"lat": q.origin_lat, "lon": q.origin_lon},
            "destination": {"lat": q.dest_lat, "lon": q.dest_lon},
            "depart_at": depart_at,
            "radius_m": q.radius,
        },
        "user": {
            "user_id": q.user_id,
            "wheelchair_mode": prefs.wheelchair_mode,
            "max_transfers": prefs.max_transfers,
            "correction_ratio": prefs.correction_ratio,
        },
        "stats": {
            "origin_candidates": origin_candidates.len(),
            "dest_candidates": dest_candidates.len(),
            "journeys_found": journeys.len(),
            "elapsed_us": elapsed_us,
        },
        "journeys": journeys_json,
    })))
}