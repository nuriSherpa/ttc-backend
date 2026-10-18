mod config;
mod context;
mod db;
mod gates;
mod graph;
mod http;
mod raptor; 
mod walk; 

use std::collections::HashMap;
use std::sync::Arc;
use std::sync::atomic::AtomicBool;
use std::time::Instant;

use axum::routing::{get, post};
use axum::Router;
use tokio::sync::RwLock;
use tracing::info;

use crate::graph::{
    loader::{load, LoadOptions},
    Graph,
};

#[derive(Clone)]
pub struct AppState {
    pub pg: sqlx::PgPool,
    pub redis: redis::aio::ConnectionManager,
    pub ctx_loader: Arc<context::loader::CtxLoader>,
    pub internal_token: String,
    pub started_at: Instant,
    pub graph: Arc<RwLock<Graph>>,
    pub graph_loaded: Arc<AtomicBool>,
    pub weather: graph::weather::WeatherCache,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    dotenvy::dotenv().ok();

    tracing_subscriber::fmt()
        .json()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("ttc_router=debug")),
        )
        .init();

    let cfg = config::Config::load()?;

    // ──────────────────────────────────────────────────────────────
    // Layer 0 — infrastructure
    // ──────────────────────────────────────────────────────────────
    let pg = db::pg::new_pool(&cfg.pgdsn).await?;
    info!("postgres reachable");

    let redis = db::redis::new_client(&cfg.redis_url).await?;
    info!("redis reachable");

    // ──────────────────────────────────────────────────────────────
    // Layer 1 — graph (synchronous, must succeed)
    // ──────────────────────────────────────────────────────────────
   let graph = load(&pg, LoadOptions { horizon_days: 3 }).await?;
    info!(
        duration_ms = graph.load_duration_ms,
        stops = graph.stops.len(),
        routes = graph.routes.len(),
        trips = graph.trips.len(),
        departures = graph.departures_flat.len(),
        patterns = graph.patterns.len(),
        station_nodes = graph.station_nodes.len(),
        pathway_edges = graph.pathway_edges.len(),
        horizon_days = graph.horizon_days,
        "graph loaded"
    );

    // ──────────────────────────────────────────────────────────────
    // Layer 1d — weather (synchronous, non-fatal)
    // ──────────────────────────────────────────────────────────────
    let weather_cache: graph::weather::WeatherCache = Arc::new(RwLock::new(HashMap::new()));
    match graph::weather::refresh(&pg, &weather_cache).await {
        Ok(n) => info!(count = n, "weather loaded"),
        Err(e) => tracing::warn!(err = %e, "weather load failed (non-fatal)"),
    }

    // ──────────────────────────────────────────────────────────────
    // Build shared state
    // ──────────────────────────────────────────────────────────────
    let ctx_loader = Arc::new(context::loader::CtxLoader::new(pg.clone(), redis.clone()));
    let graph_lock = Arc::new(RwLock::new(graph));
    let graph_loaded = Arc::new(AtomicBool::new(true));

    let state = AppState {
        pg,
        redis,
        ctx_loader,
        internal_token: cfg.internal_token,
        started_at: Instant::now(),
        graph: graph_lock.clone(),
        graph_loaded: graph_loaded.clone(),
        weather: weather_cache.clone(),
    };

    // Print the DB snapshot once at startup (Layer 0 verification aid)
    http::debug::print_snapshot(&state).await;

    // ──────────────────────────────────────────────────────────────
    // Background: graph refresh every 15 minutes
    // ──────────────────────────────────────────────────────────────
    {
        let pg_clone = state.pg.clone();
        let graph_lock_clone = graph_lock.clone();
        tokio::spawn(async move {
            let mut ticker = tokio::time::interval(std::time::Duration::from_secs(900));
            ticker.tick().await; // skip immediate
            loop {
                ticker.tick().await;
                info!("graph refresh starting");
                match load(&pg_clone, LoadOptions::default()).await {
                    Ok(new_graph) => {
                        let duration_ms = new_graph.load_duration_ms;
                        let departures = new_graph.departures_flat.len();
                        *graph_lock_clone.write().await = new_graph;
                        info!(duration_ms, departures, "graph refreshed");
                    }
                    Err(e) => tracing::error!(err = %e, "graph refresh failed"),
                }
            }
        });
    }

    // ──────────────────────────────────────────────────────────────
    // Background: weather refresh every 10 minutes
    // ──────────────────────────────────────────────────────────────
    {
        let pg_clone = state.pg.clone();
        let weather_clone = state.weather.clone();
        tokio::spawn(async move {
            let mut ticker = tokio::time::interval(std::time::Duration::from_secs(600));
            ticker.tick().await; // skip immediate
            loop {
                ticker.tick().await;
                if let Err(e) = graph::weather::refresh(&pg_clone, &weather_clone).await {
                    tracing::error!(err = %e, "weather refresh failed");
                }
            }
        });
    }

    // ──────────────────────────────────────────────────────────────
    // HTTP server
    // ──────────────────────────────────────────────────────────────
    let app = Router::new()
        .route("/health", get(http::handlers::health))
        .route("/graph/status", get(http::handlers::graph_status))
        .route("/debug/data", get(http::debug::data_snapshot))
        .route("/debug/nearest", get(http::handlers::nearest))
        .route("/debug/walk", get(http::handlers::walk))
        .route("/debug/gates", get(http::handlers::gates))
        .route("/plan", post(http::handlers::plan))
        .route("/debug/raptor", get(http::handlers::raptor))
        .with_state(state);

    let addr = format!("0.0.0.0:{}", cfg.port);
    let listener = tokio::net::TcpListener::bind(&addr).await?;
    info!(%addr, "router ready");
    axum::serve(listener, app).await?;
    Ok(())
}