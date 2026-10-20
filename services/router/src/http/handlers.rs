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
    pub arrive_at: Option<DateTime<Utc>>,
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

// ────────────────────────────────────────────────────────────────────────────
// /plan — full pipeline: gates → run_shifted → assemble → score
// ────────────────────────────────────────────────────────────────────────────
pub async fn plan(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(req): Json<PlanRequest>,
) -> Result<impl IntoResponse, ApiError> {
    use crate::raptor::raptor::ShiftPolicy;
    use crate::score::{Preset, ScoreContext, TimeMode};

    check_internal_token(&state, &headers)?;

    // ── Resolve time mode ──
    let (time_mode, anchor) = match (req.depart_at, req.arrive_at) {
        (Some(d), None) => (TimeMode::LeaveAt, d),
        (None, Some(a)) => (TimeMode::ArriveBy, a),
        (None, None) => (TimeMode::LeaveAt, Utc::now()),
        (Some(_), Some(_)) => {
            return Err(ApiError::BadRequest(
                "specify depart_at XOR arrive_at, not both".into(),
            ))
        }
    };

    let ctx = state
        .ctx_loader
        .build(
            req.user_id,
            req.filters,
            req.origin,
            req.destination,
            Some(anchor),
        )
        .await
        .map_err(ApiError::Internal)?;

    let prefs = &ctx.user;
    let preset = Preset::from_opt(ctx.filters.preset.as_deref());

    tracing::info!(
        user_id = ?ctx.user_id,
        preset = preset.as_str(),
        mode = ?time_mode,
        anchor = %anchor,
        "plan request"
    );

    // Weather at origin
    let weather_multiplier = crate::graph::weather::at(
        &state.weather,
        ctx.origin.lat,
        ctx.origin.lon,
        anchor,
    )
    .await
    .map(|w| w.condition.walk_penalty(w.severity))
    .unwrap_or(1.0);

    let graph = state.graph.read().await;
    let live = state.live.read().await;

    // Search radius MUST be at least max_walk_m / detour_factor, otherwise
    // stops that would pass the walk gate are never found. Walk distance is
    // always >= straight distance, so using max_walk_m as the straight-line
    // search bound guarantees every walkable stop is found.
    let walk_margin = (prefs.max_walk_m as f64) / prefs.detour_factor + 50.0;
    let radius = match preset {
        Preset::Fastest => walk_margin.max(1000.0),
        _ => walk_margin.max(400.0),
    };

    let origin_candidates = build_candidates(
        &graph,
        &state.weather,
        prefs,
        ctx.origin.lat,
        ctx.origin.lon,
        radius,
        anchor,
    )
    .await;
    let dest_candidates = build_candidates(
        &graph,
        &state.weather,
        prefs,
        ctx.destination.lat,
        ctx.destination.lon,
        radius,
        anchor,
    )
    .await;

    let mut warnings: Vec<String> = Vec::new();

    if origin_candidates.is_empty() || dest_candidates.is_empty() {
        warnings.push(format!(
            "No stops passed gates (origin={}, dest={}). \
             Try increasing max_walk_m (currently {}m) or expanding search radius.",
            origin_candidates.len(),
            dest_candidates.len(),
            prefs.max_walk_m
        ));
        return Ok(Json(PlanResponse {
            recommended: None,
            alternatives: vec![],
            meta: PlanMeta {
                as_of: Utc::now(),
                data_freshness_s: (Utc::now() - live.loaded_at).num_seconds().max(0) as u64,
                graph_loaded: state.graph_loaded.load(Ordering::Relaxed),
                gates_applied: gates_applied(&preset),
                warnings,
            },
        }));
    }

    // ── Offsets + policy per mode ──
    let (offsets, policy, arrive_deadline) = match time_mode {
        TimeMode::LeaveAt => (
            vec![0, 300, 600, 900],
            ShiftPolicy::EarliestArrival,
            None,
        ),
        TimeMode::ArriveBy => {
            // 2-hour window back from deadline, 5-minute steps
            let offsets: Vec<i64> = (-24..=0).map(|i| i * 300).collect();
            (offsets, ShiftPolicy::LatestDeparture, Some(anchor))
        }
    };

    let mut shifted = crate::raptor::raptor::run_shifted(
        &graph,
        &origin_candidates,
        &dest_candidates,
        anchor,
        prefs,
        weather_multiplier,
        &offsets,
        &live,
        policy,
    );

    // For arrive_by, filter to journeys arriving at or before the deadline.
    if let Some(deadline) = arrive_deadline {
        shifted.retain(|(j, base)| {
            let arrival = *base + chrono::Duration::seconds(j.arrive_s as i64);
            arrival <= deadline
        });
    }

    if shifted.is_empty() {
        let local = anchor.with_timezone(&chrono_tz::America::Toronto);
        warnings.push(match time_mode {
            TimeMode::LeaveAt => format!(
                "No route departing {} Toronto within max_transfers={}, max_walk_m={}m{}",
                local.format("%H:%M"),
                prefs.max_transfers,
                prefs.max_walk_m,
                if prefs.wheelchair_mode || prefs.avoid_stairs {
                    " [accessible]"
                } else {
                    ""
                },
            ),
            TimeMode::ArriveBy => format!(
                "No route arriving before {} Toronto within max_transfers={}, max_walk_m={}m{}",
                local.format("%H:%M"),
                prefs.max_transfers,
                prefs.max_walk_m,
                if prefs.wheelchair_mode || prefs.avoid_stairs {
                    " [accessible]"
                } else {
                    ""
                },
            ),
        });
    }

    // ── Assemble each journey using its OWN base departure ──
    let mut assembled: Vec<crate::journey::types::JourneyResponse> = shifted
        .iter()
        .map(|(j, base)| {
            crate::journey::assemble::assemble(
                &graph,
                j,
                *base,
                &ctx.origin,
                &ctx.destination,
                &origin_candidates,
                &dest_candidates,
            )
        })
        .collect();

    // ── Inject walk-only alternative when origin→dest is walkable ──
    let direct_m = haversine_m(
        ctx.origin.lat,
        ctx.origin.lon,
        ctx.destination.lat,
        ctx.destination.lon,
    );
    let walk_m = direct_m * prefs.detour_factor;
    if walk_m <= prefs.max_walk_m as f64 {
        let walk_ctx = crate::walk::types::WalkContext {
            from_lat: ctx.origin.lat,
            from_lon: ctx.origin.lon,
            to_lat: ctx.destination.lat,
            to_lon: ctx.destination.lon,
            raw_distance_m: direct_m,
            depart_at: anchor,
            user: prefs,
            weather: &state.weather,
        };
        let est = crate::walk::pipeline::estimate(&walk_ctx).await;
        assembled.push(make_walk_only_journey(
            anchor,
            &ctx.origin,
            &ctx.destination,
            est.walk_m,
            est.seconds,
            est.breakdown,
        ));
    }

    // ── Score with reliability cache ──
    let reliability = state.reliability.read().await;
    let score_ctx = ScoreContext {
        requested_depart_at: anchor,
        requested_arrive_at: arrive_deadline,
        mode: time_mode,
        max_walk_m: prefs.max_walk_m,
        hour: ctx.hour_bucket,
        day_type: ctx.service_day.as_str().to_string(),
        reliability: if reliability.scores.is_empty() {
            None
        } else {
            Some(crate::graph::reliability::ReliabilityCache {
                scores: reliability.scores.clone(),
                loaded_at: reliability.loaded_at,
                row_count: reliability.row_count,
            })
        },
    };
    let mut scored = crate::score::score(assembled, preset, &score_ctx);

    // ── Hard filter: journey-level walk cap ──
    let max_walk = prefs.max_walk_m as f64;
    let pre_filter = scored.len();
    scored.retain(|s| s.journey.total_walk_m <= max_walk);
    if scored.is_empty() && pre_filter > 0 {
        warnings.push(format!(
            "All routes exceeded max_walk_m ({}m). Try increasing it.",
            prefs.max_walk_m
        ));
    }

    // ── Slice top 3 ──
    let (recommended, alternatives) = if scored.is_empty() {
        (None, vec![])
    } else {
        let mut iter = scored.into_iter();
        let first = iter.next().map(scored_to_json);
        let rest: Vec<serde_json::Value> = iter.take(2).map(scored_to_json).collect();
        (first, rest)
    };

    Ok(Json(PlanResponse {
        recommended,
        alternatives,
        meta: PlanMeta {
            as_of: Utc::now(),
            data_freshness_s: (Utc::now() - live.loaded_at).num_seconds().max(0) as u64,
            graph_loaded: state.graph_loaded.load(Ordering::Relaxed),
            gates_applied: gates_applied(&preset),
            warnings,
        },
    }))
}

fn gates_applied(preset: &crate::score::Preset) -> Vec<String> {
    let mut v = vec![
        "geo".into(),
        "accessibility".into(),
        "walk".into(),
        "max_walk".into(),
    ];
    if matches!(preset, crate::score::Preset::Accessible) {
        v.push("preset:accessible".into());
    }
    v
}

/// Shape a `ScoredJourney` into the JSON body used by `/plan`.
fn scored_to_json(s: crate::score::ScoredJourney) -> serde_json::Value {
    serde_json::json!({
        "journey": s.journey,
        "score": (s.score * 10.0).round() / 10.0,
        "reasons": s.reasons,
        "departure_slip_s": s.departure_slip_s,
    })
}

/// Synthetic walk-only journey — one WalkLeg from origin to dest.
fn make_walk_only_journey(
    depart_at: DateTime<Utc>,
    origin: &LatLon,
    dest: &LatLon,
    walk_m: f64,
    walk_s: u32,
    breakdown: crate::walk::types::WalkBreakdown,
) -> crate::journey::types::JourneyResponse {
    use crate::journey::types::*;
    let arrive_at = depart_at + chrono::Duration::seconds(walk_s as i64);
    let detour = breakdown.detour_factor.unwrap_or(1.30);
    let straight = if detour > 0.0 { walk_m / detour } else { walk_m };

    JourneyResponse {
        legs: vec![ResponseLeg::Walk(WalkLeg {
            walk_kind: WalkKind::Destination,
            from: Location {
                lat: origin.lat,
                lon: origin.lon,
                label: "Origin".into(),
                stop_id: None,
            },
            to: Location {
                lat: dest.lat,
                lon: dest.lon,
                label: "Destination".into(),
                stop_id: None,
            },
            depart_at,
            arrive_at,
            duration_s: walk_s,
            distance_m: walk_m,
            distance_m_straight: straight,
            detour_factor: detour,
            breakdown: Some(breakdown),
        })],
        depart_at,
        arrive_at,
        total_seconds: walk_s,
        total_transit_seconds: 0,
        total_wait_seconds: 0,
        total_walk_seconds: walk_s,
        total_walk_m: walk_m,
        num_transfers: 0,
        real_transfers: 0,
        waypoint_arrivals: vec![],
    }
}

/// Straight-line distance in meters.
fn haversine_m(lat1: f64, lon1: f64, lat2: f64, lon2: f64) -> f64 {
    const R: f64 = 6_371_000.0;
    let phi1 = lat1.to_radians();
    let phi2 = lat2.to_radians();
    let dphi = (lat2 - lat1).to_radians();
    let dlambda = (lon2 - lon1).to_radians();
    let a = (dphi / 2.0).sin().powi(2)
        + phi1.cos() * phi2.cos() * (dlambda / 2.0).sin().powi(2);
    2.0 * R * a.sqrt().asin()
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

fn default_radius() -> f64 {
    1000.0
}
fn default_limit() -> usize {
    15
}

pub async fn nearest(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(q): Query<NearestQuery>,
) -> Result<impl IntoResponse, ApiError> {
    check_internal_token(&state, &headers)?;

    if q.radius <= 0.0 || q.radius > 10_000.0 {
        return Err(ApiError::BadRequest(format!(
            "radius must be 0 < r <= 10000, got {}",
            q.radius
        )));
    }
    if q.limit == 0 || q.limit > 50 {
        return Err(ApiError::BadRequest(format!(
            "limit must be 1..=50, got {}",
            q.limit
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
            "radius must be 0 < r <= 10000, got {}",
            q.radius
        )));
    }
    if q.limit == 0 || q.limit > 50 {
        return Err(ApiError::BadRequest(format!(
            "limit must be 1..=50, got {}",
            q.limit
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
    use crate::gates::{
        accessibility, max_walk,
        types::{Candidate, GateStats},
    };

    check_internal_token(&state, &headers)?;

    if q.radius <= 0.0 || q.radius > 10_000.0 {
        return Err(ApiError::BadRequest(format!(
            "radius out of range: {}",
            q.radius
        )));
    }
    if q.limit == 0 || q.limit > 50 {
        return Err(ApiError::BadRequest(format!(
            "limit out of range: {}",
            q.limit
        )));
    }

    let prefs = if let Some(uid) = q.user_id {
        state.ctx_loader.load_user_prefs(uid).await.unwrap_or_default()
    } else {
        crate::context::loader::UserPrefs::default()
    };
    let depart_at = q.depart_at.unwrap_or_else(Utc::now);

    let graph = state.graph.read().await;

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

    let (candidates, acc_dropped) = accessibility::apply(candidates, &graph, &prefs);

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

// ────────────────────────────────────────────────────────────────────────────
// /debug/raptor — raw (legacy) or assembled
// ────────────────────────────────────────────────────────────────────────────

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
    #[serde(default)]
    pub raw: bool,
}

async fn build_candidates(
    graph: &crate::graph::Graph,
    weather: &crate::graph::weather::WeatherCache,
    prefs: &crate::context::loader::UserPrefs,
    lat: f64,
    lon: f64,
    radius: f64,
    depart_at: DateTime<Utc>,
) -> Vec<crate::gates::types::Candidate> {
    use crate::gates::{accessibility, max_walk, types::Candidate};

    let raw = graph.geo_index.nearest(lat, lon, radius, 15);
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

    let (candidates, _) = accessibility::apply(candidates, graph, prefs);

    let mut with_walk = Vec::with_capacity(candidates.len());
    for mut c in candidates {
        let stop = &graph.stops[c.stop_idx as usize];
        let ctx = crate::walk::types::WalkContext {
            from_lat: lat,
            from_lon: lon,
            to_lat: stop.lat,
            to_lon: stop.lon,
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

    let weather_multiplier = crate::graph::weather::at(
        &state.weather,
        q.origin_lat,
        q.origin_lon,
        depart_at,
    )
    .await
    .map(|w| w.condition.walk_penalty(w.severity))
    .unwrap_or(1.0);

    let graph = state.graph.read().await;
    let live = state.live.read().await;
    let t0 = std::time::Instant::now();

    let origin_candidates = build_candidates(
        &graph,
        &state.weather,
        &prefs,
        q.origin_lat,
        q.origin_lon,
        q.radius,
        depart_at,
    )
    .await;

    let dest_candidates = build_candidates(
        &graph,
        &state.weather,
        &prefs,
        q.dest_lat,
        q.dest_lon,
        q.radius,
        depart_at,
    )
    .await;

    if origin_candidates.is_empty() || dest_candidates.is_empty() {
        return Ok(Json(serde_json::json!({
            "error": "no_candidates",
            "origin_candidates": origin_candidates.len(),
            "dest_candidates": dest_candidates.len(),
        })));
    }

    let journeys = crate::raptor::raptor::run(
        &graph,
        &origin_candidates,
        &dest_candidates,
        depart_at,
        &prefs,
        weather_multiplier,
        &live,
    );

    let elapsed_us = t0.elapsed().as_micros() as u64;

    let journeys_json: Vec<serde_json::Value> = if q.raw {
        journeys
            .iter()
            .map(|j| {
                let legs_json: Vec<serde_json::Value> = j
                    .legs
                    .iter()
                    .map(|leg| {
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
                    })
                    .collect();

                serde_json::json!({
                    "depart_s": j.depart_s,
                    "arrive_s": j.arrive_s,
                    "total_seconds": j.arrive_s,
                    "num_transfers": j.num_transfers,
                    "total_walk_m": (j.total_walk_m * 10.0).round() / 10.0,
                    "legs": legs_json,
                })
            })
            .collect()
    } else {
        let origin = LatLon {
            lat: q.origin_lat,
            lon: q.origin_lon,
        };
        let destination = LatLon {
            lat: q.dest_lat,
            lon: q.dest_lon,
        };
        journeys
            .iter()
            .map(|j| {
                let resp = crate::journey::assemble::assemble(
                    &graph,
                    j,
                    depart_at,
                    &origin,
                    &destination,
                    &origin_candidates,
                    &dest_candidates,
                );
                serde_json::to_value(resp).expect("JourneyResponse is Serialize")
            })
            .collect()
    };

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
            "raw": q.raw,
        },
        "journeys": journeys_json,
    })))
}