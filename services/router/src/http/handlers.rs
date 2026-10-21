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
// Internal pipeline helper — standalone async fn so it can be called in
// the tier ladder without closure lifetime headaches.
// ────────────────────────────────────────────────────────────────────────────
#[allow(clippy::too_many_arguments)]
async fn run_plan_pipeline(
    graph: &crate::graph::Graph,
    weather: &crate::graph::weather::WeatherCache,
    reliability: &crate::graph::reliability::ReliabilityCache,
    origin: &LatLon,
    destination: &LatLon,
    anchor: DateTime<Utc>,
    time_mode: crate::score::TimeMode,
    preset: crate::score::Preset,
    effective_prefs: &crate::context::loader::UserPrefs,
    service_day: crate::context::loader::ServiceDay,
    hour_bucket: u8,
    live: &crate::graph::live::LiveDelays,
    weather_multiplier: f32,
    apply_walk_only: bool,
    warnings: &mut Vec<String>,
) -> Vec<crate::score::ScoredJourney> {
    use crate::raptor::raptor::ShiftPolicy;
    use crate::score::ScoreContext;

    let walk_margin =
        (effective_prefs.max_walk_m as f64) / effective_prefs.detour_factor.max(1.0) + 50.0;
    let radius = match preset {
        crate::score::Preset::Fastest => walk_margin.max(1000.0),
        _ => walk_margin.max(400.0),
    };

    let origin_candidates = build_candidates(
        graph,
        weather,
        effective_prefs,
        origin.lat,
        origin.lon,
        radius,
        anchor,
    )
    .await;
    let dest_candidates = build_candidates(
        graph,
        weather,
        effective_prefs,
        destination.lat,
        destination.lon,
        radius,
        anchor,
    )
    .await;

    if origin_candidates.is_empty() || dest_candidates.is_empty() {
        let nearest = graph
            .geo_index
            .nearest(destination.lat, destination.lon, radius * 2.0, 1);
        let hint = nearest
            .first()
            .map(|(_, m)| format!("nearest stop {:.0}m from destination", m))
            .unwrap_or_else(|| "no stops within expanded radius".to_string());
        warnings.push(format!(
            "No stops reachable at destination within {}m walk. {}.",
            effective_prefs.max_walk_m, hint
        ));
        return Vec::new();
    }

    let (offsets, policy, arrive_deadline) = match time_mode {
        crate::score::TimeMode::LeaveAt => (
            vec![0, 300, 600, 900],
            ShiftPolicy::EarliestArrival,
            None,
        ),
        crate::score::TimeMode::ArriveBy => {
            let offsets: Vec<i64> = (-24..=0).map(|i| i * 300).collect();
            (offsets, ShiftPolicy::LatestDeparture, Some(anchor))
        }
    };

    let mut shifted = crate::raptor::raptor::run_shifted(
        graph,
        &origin_candidates,
        &dest_candidates,
        anchor,
        effective_prefs,
        weather_multiplier,
        &offsets,
        live,
        policy,
    );

    if let Some(deadline) = arrive_deadline {
        shifted.retain(|(j, base)| {
            let arrival = *base + chrono::Duration::seconds(j.arrive_s as i64);
            arrival <= deadline
        });
    }

    if shifted.is_empty() {
        warnings.push(format!(
            "No route found departing at this hour within transfer limit ({}).",
            effective_prefs.max_transfers
        ));
        return Vec::new();
    }

    let mut assembled: Vec<crate::journey::types::JourneyResponse> = shifted
        .iter()
        .map(|(j, base)| {
            crate::journey::assemble::assemble(
                graph,
                j,
                *base,
                origin,
                destination,
                &origin_candidates,
                &dest_candidates,
            )
        })
        .collect();

    if apply_walk_only {
        let direct_m = haversine_m(origin.lat, origin.lon, destination.lat, destination.lon);
        let walk_m = direct_m * effective_prefs.detour_factor;
        let walk_only_cap = (effective_prefs.max_walk_m as f64).max(2500.0);
        if walk_m <= walk_only_cap {
            let walk_ctx = crate::walk::types::WalkContext {
                from_lat: origin.lat,
                from_lon: origin.lon,
                to_lat: destination.lat,
                to_lon: destination.lon,
                raw_distance_m: direct_m,
                depart_at: anchor,
                user: effective_prefs,
                weather,
            };
            let est = crate::walk::pipeline::estimate(&walk_ctx).await;
            assembled.push(make_walk_only_journey(
                anchor,
                origin,
                destination,
                est.walk_m,
                est.seconds,
                est.breakdown,
            ));
        }
    }

    let score_ctx = ScoreContext {
        requested_depart_at: anchor,
        requested_arrive_at: arrive_deadline,
        mode: time_mode,
        max_walk_m: effective_prefs.max_walk_m,
        hour: hour_bucket,
        day_type: service_day.as_str().to_string(),
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
    crate::score::score(assembled, preset, &score_ctx)
}

// ────────────────────────────────────────────────────────────────────────────
// /plan — 4-tier fallback: user prefs → 2× → 4× → nearest running service
// ────────────────────────────────────────────────────────────────────────────
pub async fn plan(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(req): Json<PlanRequest>,
) -> Result<impl IntoResponse, ApiError> {
    use crate::score::{Preset, TimeMode};

    check_internal_token(&state, &headers)?;

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
        max_walk = prefs.max_walk_m,
        "plan request"
    );

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
    let reliability = state.reliability.read().await;

    let mut warnings: Vec<String> = Vec::new();
    let hard_cap = prefs.max_walk_m as f64;

    // ── Tier 1: user's max_walk_m ──
    let scored = run_plan_pipeline(
        &graph,
        &state.weather,
        &reliability,
        &ctx.origin,
        &ctx.destination,
        anchor,
        time_mode,
        preset,
        prefs,
        ctx.service_day,
        ctx.hour_bucket,
        &live,
        weather_multiplier,
        true,
        &mut warnings,
    )
    .await;

    let mut final_journeys: Vec<crate::score::ScoredJourney> = scored
        .into_iter()
        .filter(|s| s.journey.total_walk_m <= hard_cap)
        .collect();

    // ── Tier 2: 2× expansion ──
    if final_journeys.is_empty() {
        let tier2_walk = (prefs.max_walk_m * 2).min(5000) as i32;
        if tier2_walk > prefs.max_walk_m {
            let mut p2 = prefs.clone();
            p2.max_walk_m = tier2_walk;

            let mut w2: Vec<String> = Vec::new();
            let s2 = run_plan_pipeline(
                &graph,
                &state.weather,
                &reliability,
                &ctx.origin,
                &ctx.destination,
                anchor,
                time_mode,
                preset,
                &p2,
                ctx.service_day,
                ctx.hour_bucket,
                &live,
                weather_multiplier,
                true,
                &mut w2,
            )
            .await;

            let mut f2: Vec<crate::score::ScoredJourney> = s2
                .into_iter()
                .filter(|s| s.journey.total_walk_m <= tier2_walk as f64)
                .collect();
            f2.sort_by(|a, b| {
                b.score
                    .partial_cmp(&a.score)
                    .unwrap_or(std::cmp::Ordering::Equal)
            });

            if !f2.is_empty() {
                let min_walk = f2
                    .iter()
                    .map(|s| s.journey.total_walk_m)
                    .fold(f64::INFINITY, f64::min);
                warnings.clear();
                warnings.push(format!(
                    "No journey within max_walk_m={}m. Found a route at {}m walk expansion needing {:.0}m total walk. \
                     Accept it, or raise max_walk_m to at least {:.0}m.",
                    prefs.max_walk_m,
                    tier2_walk,
                    min_walk,
                    min_walk.ceil()
                ));
                final_journeys = f2;
            }
        }
    }

    // ── Tier 3: 4× expansion (deep reach) ──
    if final_journeys.is_empty() {
        let tier3_walk = (prefs.max_walk_m * 4).min(5000) as i32;
        if tier3_walk > prefs.max_walk_m * 2 {
            let mut p3 = prefs.clone();
            p3.max_walk_m = tier3_walk;

            let mut w3: Vec<String> = Vec::new();
            let s3 = run_plan_pipeline(
                &graph,
                &state.weather,
                &reliability,
                &ctx.origin,
                &ctx.destination,
                anchor,
                time_mode,
                preset,
                &p3,
                ctx.service_day,
                ctx.hour_bucket,
                &live,
                weather_multiplier,
                true,
                &mut w3,
            )
            .await;

            let mut f3: Vec<crate::score::ScoredJourney> = s3
                .into_iter()
                .filter(|s| s.journey.total_walk_m <= tier3_walk as f64)
                .collect();
            f3.sort_by(|a, b| {
                b.score
                    .partial_cmp(&a.score)
                    .unwrap_or(std::cmp::Ordering::Equal)
            });

            if !f3.is_empty() {
                let min_walk = f3
                    .iter()
                    .map(|s| s.journey.total_walk_m)
                    .fold(f64::INFINITY, f64::min);
                warnings.clear();
                warnings.push(format!(
                    "No journey within max_walk_m={}m. Deep-search to {}m found a route needing {:.0}m total walk. \
                     Accept it, or raise max_walk_m to at least {:.0}m.",
                    prefs.max_walk_m,
                    tier3_walk,
                    min_walk,
                    min_walk.ceil()
                ));
                final_journeys = f3;
            }
        }
    }

    // ── Tier 4: nearest running service advisory ──
    if final_journeys.is_empty() {
        warnings.clear();
        let advisory = query_nearest_running_service(
            &state.pg,
            ctx.destination.lat,
            ctx.destination.lon,
            anchor,
        )
        .await;

        match advisory {
            Some(adv) => {
                warnings.push(format!(
                    "No transit route available at this hour. \
                     Nearest stop with running service: {} (route {}, {:.0}m away, next departure in {} min). \
                     Walk there, or try again at a different time.",
                    adv.stop_name, adv.route_short_name, adv.dist_m, adv.next_dep_min
                ));
            }
            None => {
                warnings.push(
                    "No transit route available. \
                     No running service within 5km of the destination at this hour. \
                     This location may require walking or a different mode of transport."
                        .to_string(),
                );
            }
        }
    }

    // ── Slice top 3 ──
    let (recommended, alternatives) = if final_journeys.is_empty() {
        (None, vec![])
    } else {
        let mut iter = final_journeys.into_iter();
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

// ────────────────────────────────────────────────────────────────────────────
// Nearest running service advisory (tier 4)
// ────────────────────────────────────────────────────────────────────────────

#[derive(Debug)]
struct Advisory {
    stop_name: String,
    dist_m: f64,
    route_short_name: String,
    next_dep_min: i64,
}

/// Find the nearest stop within 5km that has a departure in the next 3 hours.
/// Returns None if no running service within that window or radius.
async fn query_nearest_running_service(
    pg: &sqlx::PgPool,
    lat: f64,
    lon: f64,
    after: DateTime<Utc>,
) -> Option<Advisory> {
    let row: Option<(String, f64, String, i32)> = sqlx::query_as(
        r#"
        WITH candidate AS (
            SELECT
                s.stop_id,
                s.stop_name,
                (6371000 * acos(
                    cos(radians($1::float8)) * cos(radians(s.stop_lat)) *
                    cos(radians(s.stop_lon) - radians($2::float8)) +
                    sin(radians($1::float8)) * sin(radians(s.stop_lat))
                ))::float8 AS dist_m
            FROM ref.stop_points s
            WHERE s.stop_lat BETWEEN $1::float8 - 0.05 AND $1::float8 + 0.05
              AND s.stop_lon BETWEEN $2::float8 - 0.07 AND $2::float8 + 0.07
        ),
        route_next AS (
            SELECT
                d.stop_id,
                r.route_short_name,
                MIN(d.departs_at) AS next_at
            FROM ref.departures d
            JOIN core.routes r ON d.route_id = r.route_id
            WHERE d.departs_at > $3::timestamptz
              AND d.departs_at < $3::timestamptz + interval '3 hours'
              AND d.boardable = true
              AND d.stop_id IN (SELECT stop_id FROM candidate)
            GROUP BY d.stop_id, r.route_short_name
        ),
        ranked AS (
            SELECT
                stop_id,
                route_short_name,
                next_at,
                ROW_NUMBER() OVER (PARTITION BY stop_id ORDER BY next_at) AS rn
            FROM route_next
        )
        SELECT
            c.stop_name,
            c.dist_m,
            r.route_short_name,
            GREATEST(1, EXTRACT(EPOCH FROM (r.next_at - $3::timestamptz))::int / 60) AS next_dep_min
        FROM candidate c
        JOIN ranked r ON r.stop_id = c.stop_id AND r.rn = 1
        WHERE c.dist_m < 5000
        ORDER BY c.dist_m
        LIMIT 1
        "#,
    )
    .bind(lat)
    .bind(lon)
    .bind(after)
    .fetch_optional(pg)
    .await
    .ok()
    .flatten();

    row.map(|(stop_name, dist_m, route_short_name, next_dep_min)| Advisory {
        stop_name,
        dist_m,
        route_short_name,
        next_dep_min: next_dep_min as i64,
    })
}

// ────────────────────────────────────────────────────────────────────────────
// Helpers
// ────────────────────────────────────────────────────────────────────────────

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

fn scored_to_json(s: crate::score::ScoredJourney) -> serde_json::Value {
    serde_json::json!({
        "journey": s.journey,
        "score": (s.score * 10.0).round() / 10.0,
        "reasons": s.reasons,
        "departure_slip_s": s.departure_slip_s,
    })
}

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