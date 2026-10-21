use std::collections::HashMap;
use std::time::Instant;

use anyhow::Context;
use chrono::{DateTime, Utc};
use futures::TryStreamExt;
use sqlx::{PgPool, Row};
use tracing::info;

use super::types::*;

pub struct LoadOptions {
    pub horizon_days: i32,
}

impl Default for LoadOptions {
    fn default() -> Self {
        Self { horizon_days: 7 }
    }
}

pub async fn load(pg: &PgPool, opts: LoadOptions) -> anyhow::Result<Graph> {
    let started = Instant::now();
    info!(horizon_days = opts.horizon_days, "graph load starting");

    // 1. Feed version
    let feed_version: Option<String> = sqlx::query_scalar("SELECT ops.active_version()")
        .fetch_one(pg)
        .await
        .context("fetching active feed version")?;
    let feed_version = feed_version.context("no active feed version")?;

    // 2. Stops
    let rows = sqlx::query(
        "SELECT stop_id, stop_name, stop_lat, stop_lon, wheelchair_boarding, parent_station \
         FROM ref.stop_points ORDER BY stop_id",
    )
    .fetch_all(pg)
    .await
    .context("loading ref.stop_points")?;

    let mut stops = Vec::with_capacity(rows.len());
    let mut stop_idx_by_id: HashMap<String, u32> = HashMap::with_capacity(rows.len());
    for (idx, row) in rows.iter().enumerate() {
        let stop_id: String = row.get("stop_id");
        stop_idx_by_id.insert(stop_id.clone(), idx as u32);
        stops.push(Stop {
            id: idx as u32,
            stop_id,
            name: row.get("stop_name"),
            lat: row.get("stop_lat"),
            lon: row.get("stop_lon"),
            wheelchair_boarding: row.get("wheelchair_boarding"),
            parent_station: row.get("parent_station"),
        });
    }
    info!(count = stops.len(), "loaded stops");

    // 3. Routes
    let rows = sqlx::query(
        "SELECT route_id, route_short_name, route_long_name, route_type, \
                route_color, route_text_color \
         FROM core.routes WHERE feed_version = $1 ORDER BY route_id",
    )
    .bind(&feed_version)
    .fetch_all(pg)
    .await
    .context("loading core.routes")?;

    let mut routes = Vec::with_capacity(rows.len());
    let mut route_idx_by_id: HashMap<String, u32> = HashMap::with_capacity(rows.len());
    for (idx, row) in rows.iter().enumerate() {
        let route_id: String = row.get("route_id");
        route_idx_by_id.insert(route_id.clone(), idx as u32);
        routes.push(Route {
            id: idx as u32,
            route_id,
            short_name: row.get("route_short_name"),
            long_name: row.get("route_long_name"),
            route_type: row.get("route_type"),
            color: row.get("route_color"),
            text_color: row.get("route_text_color"),
        });
    }
    info!(count = routes.len(), "loaded routes");

    // 4. Patterns
    let rows = sqlx::query(
        "SELECT pattern_id, route_id, direction_id, headsign, n_stops \
         FROM ref.patterns ORDER BY pattern_id",
    )
    .fetch_all(pg)
    .await
    .context("loading ref.patterns")?;

    let mut patterns = Vec::with_capacity(rows.len());
    let mut pattern_idx_by_id: HashMap<String, u32> = HashMap::with_capacity(rows.len());
    for (idx, row) in rows.iter().enumerate() {
        let pattern_id: String = row.get("pattern_id");
        let route_id: String = row.get("route_id");
        let route_idx = *route_idx_by_id
            .get(&route_id)
            .with_context(|| format!("pattern {} references unknown route {}", pattern_id, route_id))?;
        pattern_idx_by_id.insert(pattern_id.clone(), idx as u32);
        patterns.push(Pattern {
            id: idx as u32,
            pattern_id,
            route_idx,
            direction_id: row.get("direction_id"),
            headsign: row.get("headsign"),
            n_stops: row.get::<i32, _>("n_stops") as u32,
        });
    }
    info!(count = patterns.len(), "loaded patterns");

    // 5. Trips
    let rows = sqlx::query(
        "SELECT trip_id, route_id, direction_id, headsign, pattern_id, n_stops \
         FROM ref.trips ORDER BY trip_id",
    )
    .fetch_all(pg)
    .await
    .context("loading ref.trips")?;

    let mut trips = Vec::with_capacity(rows.len());
    let mut trip_idx_by_id: HashMap<String, u32> = HashMap::with_capacity(rows.len());
    for (idx, row) in rows.iter().enumerate() {
        let trip_id: String = row.get("trip_id");
        let route_id: String = row.get("route_id");
        let pattern_id: String = row.get("pattern_id");
        let route_idx = *route_idx_by_id
            .get(&route_id)
            .with_context(|| format!("trip {} references unknown route {}", trip_id, route_id))?;
        let pattern_idx = *pattern_idx_by_id
            .get(&pattern_id)
            .with_context(|| format!("trip {} references unknown pattern {}", trip_id, pattern_id))?;
        trip_idx_by_id.insert(trip_id.clone(), idx as u32);
        trips.push(Trip {
            id: idx as u32,
            trip_id,
            route_idx,
            direction_id: row.get("direction_id"),
            headsign: row.get("headsign"),
            pattern_idx,
            n_stops: row.get::<i32, _>("n_stops") as u32,
        });
    }
    info!(count = trips.len(), "loaded trips");

    // 6. Trip stops — flat Vec + per-trip ranges
    let rows = sqlx::query(
        "SELECT trip_id, stop_sequence, stop_id, departure_s, boardable \
         FROM ref.trip_stops ORDER BY trip_id, ordinal",
    )
    .fetch_all(pg)
    .await
    .context("loading ref.trip_stops")?;

    let mut trip_stops_flat: Vec<TripStop> = Vec::with_capacity(rows.len());
    let mut trip_stops_range: Vec<(u32, u32)> = vec![(0, 0); trips.len()];
    let mut current_trip_idx: Option<u32> = None;
    let mut current_start: u32 = 0;

    for row in rows.iter() {
        let trip_id: String = row.get("trip_id");
        let stop_id: String = row.get("stop_id");
        let trip_idx = *trip_idx_by_id
            .get(&trip_id)
            .with_context(|| format!("trip_stops references unknown trip {}", trip_id))?;
        let stop_idx = *stop_idx_by_id
            .get(&stop_id)
            .with_context(|| format!("trip_stops references unknown stop {}", stop_id))?;

        if current_trip_idx != Some(trip_idx) {
            if let Some(prev) = current_trip_idx {
                let end = trip_stops_flat.len() as u32;
                trip_stops_range[prev as usize] = (current_start, end - current_start);
            }
            current_trip_idx = Some(trip_idx);
            current_start = trip_stops_flat.len() as u32;
        }

        trip_stops_flat.push(TripStop {
            stop_idx,
            stop_sequence: row.get("stop_sequence"),
            departure_s: row.get("departure_s"),
            boardable: row.get("boardable"),
        });
    }
    if let Some(prev) = current_trip_idx {
        let end = trip_stops_flat.len() as u32;
        trip_stops_range[prev as usize] = (current_start, end - current_start);
    }
    info!(count = trip_stops_flat.len(), "loaded trip stops");

    // 7. Pattern stops — flat + ranges
    let rows = sqlx::query(
        "SELECT pattern_id, stop_id, dist_m \
         FROM ref.pattern_stops ORDER BY pattern_id, ordinal",
    )
    .fetch_all(pg)
    .await
    .context("loading ref.pattern_stops")?;

    let mut pattern_stops_flat: Vec<PatternStop> = Vec::with_capacity(rows.len());
    let mut pattern_stops_range: Vec<(u32, u32)> = vec![(0, 0); patterns.len()];
    let mut current_pat_idx: Option<u32> = None;
    let mut current_start: u32 = 0;

    for row in rows.iter() {
        let pattern_id: String = row.get("pattern_id");
        let stop_id: String = row.get("stop_id");
        let pat_idx = *pattern_idx_by_id
            .get(&pattern_id)
            .with_context(|| format!("pattern_stops references unknown pattern {}", pattern_id))?;
        let stop_idx = *stop_idx_by_id
            .get(&stop_id)
            .with_context(|| format!("pattern_stops references unknown stop {}", stop_id))?;

        if current_pat_idx != Some(pat_idx) {
            if let Some(prev) = current_pat_idx {
                let end = pattern_stops_flat.len() as u32;
                pattern_stops_range[prev as usize] = (current_start, end - current_start);
            }
            current_pat_idx = Some(pat_idx);
            current_start = pattern_stops_flat.len() as u32;
        }

        pattern_stops_flat.push(PatternStop {
            stop_idx,
            dist_m: row.get("dist_m"),
        });
    }
    if let Some(prev) = current_pat_idx {
        let end = pattern_stops_flat.len() as u32;
        pattern_stops_range[prev as usize] = (current_start, end - current_start);
    }
    info!(count = pattern_stops_flat.len(), "loaded pattern stops");

    // ──────────────────────────────────────────────────────────────
    // 8. Departures — STREAMED (not fetch_all — 9.3M rows would OOM)
    // ──────────────────────────────────────────────────────────────
    // Query uses (today + (horizon - 1)) for exactly `horizon_days` days.
    // Streaming keeps peak memory at ~600MB instead of ~4GB.
    let mut departures_flat: Vec<Departure> = Vec::with_capacity(3_000_000);
    let mut departures_range: HashMap<(u32, i32), (u32, u32)> =
        HashMap::with_capacity(500_000);

    let mut current_key: Option<(u32, i32)> = None;
    let mut current_start: u32 = 0;
    let mut processed: u64 = 0;

    let mut stream = sqlx::query(
        "SELECT trip_id, ordinal, stop_sequence, stop_id, departs_at, service_date, \
       route_id, pattern_id, boardable
        FROM ref.departures
        WHERE service_date BETWEEN ops.today() AND ops.today() + ($1 - 1)
        ORDER BY stop_id, service_date, departs_at",
    )
    .bind(opts.horizon_days)
    .fetch(pg);

    while let Some(row) = stream.try_next().await.context("streaming ref.departures")? {
        let trip_id: String = row.get("trip_id");
        let stop_id: String = row.get("stop_id");
        let route_id: String = row.get("route_id");
        let pattern_id: Option<String> = row.get("pattern_id");

        let trip_idx = *trip_idx_by_id
            .get(&trip_id)
            .with_context(|| format!("departures references unknown trip {}", trip_id))?;
        let stop_idx = *stop_idx_by_id
            .get(&stop_id)
            .with_context(|| format!("departures references unknown stop {}", stop_id))?;
        let route_idx = *route_idx_by_id
            .get(&route_id)
            .with_context(|| format!("departures references unknown route {}", route_id))?;
        let pattern_idx = pattern_id
            .as_ref()
            .and_then(|p| pattern_idx_by_id.get(p).copied())
            .unwrap_or(u32::MAX);

        let departs_at: DateTime<Utc> = row.get("departs_at");

        // Use service_date — Toronto-local, matches the query convention
        let service_date: chrono::NaiveDate = row.get("service_date");
        let key = (stop_idx, days_from_epoch(service_date));

        if current_key != Some(key) {
            if let Some(prev) = current_key {
                let end = departures_flat.len() as u32;
                departures_range.insert(prev, (current_start, end - current_start));
            }
            current_key = Some(key);
            current_start = departures_flat.len() as u32;
        }

        departures_flat.push(Departure {
            trip_idx,
            ordinal: row.get("ordinal"),
            stop_sequence: row.get("stop_sequence"),
            stop_idx,
            departs_at,
            route_idx,
            pattern_idx,
            boardable: row.get("boardable"),
        });

        processed += 1;
        if processed % 1_000_000 == 0 {
            info!(processed, "departures streaming");
        }
    }
    if let Some(prev) = current_key {
        let end = departures_flat.len() as u32;
        departures_range.insert(prev, (current_start, end - current_start));
    }

    // Shrink to fit — Vec was pre-allocated for 3M, actual may be more or less
    departures_flat.shrink_to_fit();
    departures_range.shrink_to_fit();

    info!(
        count = departures_flat.len(),
        buckets = departures_range.len(),
        "loaded departures"
    );

    // 9. Station nodes
    let rows = sqlx::query(
        "SELECT stop_id, station_id, stop_name, location_type, \
                stop_lat, stop_lon, wheelchair_boarding \
         FROM ref.station_nodes ORDER BY stop_id",
    )
    .fetch_all(pg)
    .await
    .context("loading ref.station_nodes")?;

    let mut station_nodes = Vec::with_capacity(rows.len());
    let mut station_idx_by_id: HashMap<String, u32> = HashMap::with_capacity(rows.len());
    for (idx, row) in rows.iter().enumerate() {
        let stop_id: String = row.get("stop_id");
        station_idx_by_id.insert(stop_id.clone(), idx as u32);
        station_nodes.push(StationNode {
            id: idx as u32,
            stop_id,
            station_id: row.get("station_id"),
            name: row.get("stop_name"),
            location_type: row.get("location_type"),
            lat: row.get("stop_lat"),
            lon: row.get("stop_lon"),
            wheelchair_boarding: row.get("wheelchair_boarding"),
        });
    }
    info!(count = station_nodes.len(), "loaded station nodes");

    // 10. Pathway edges
    let rows = sqlx::query(
        "SELECT from_id, to_id, mode, traversal_s, length_m, stair_count \
         FROM ref.pathway_edges",
    )
    .fetch_all(pg)
    .await
    .context("loading ref.pathway_edges")?;

    let mut pathway_edges = Vec::with_capacity(rows.len());
    let mut pathway_edges_by_from: HashMap<u32, Vec<u32>> = HashMap::new();

    for row in rows.iter() {
        let from_id: String = row.get("from_id");
        let to_id: String = row.get("to_id");

        let from_idx = station_idx_by_id
            .get(&from_id)
            .copied()
            .or_else(|| stop_idx_by_id.get(&from_id).copied());
        let to_idx = station_idx_by_id
            .get(&to_id)
            .copied()
            .or_else(|| stop_idx_by_id.get(&to_id).copied());

        let (Some(from_idx), Some(to_idx)) = (from_idx, to_idx) else {
            continue;
        };

        let edge_idx = pathway_edges.len() as u32;
        pathway_edges.push(PathwayEdge {
            from_idx,
            to_idx,
            mode: row.get("mode"),
            traversal_s: row.get("traversal_s"),
            length_m: row.get("length_m"),
            stair_count: row.get("stair_count"),
        });
        pathway_edges_by_from.entry(from_idx).or_default().push(edge_idx);
    }
       info!(count = pathway_edges.len(), "loaded pathway edges");

    let duration = started.elapsed();

        let geo_index = super::geo::GeoIndex::build(&stops);
    let cell_count = geo_index.cell_count();

    // NEW — build transfer table
    let transfer_table = super::transfer_table::build(
        &stops,
        &stop_idx_by_id,
        &station_nodes,
        &station_idx_by_id,
        &pathway_edges,
        &geo_index,
    );
    let transfer_edges = transfer_table.total_edges();
    info!(edges = transfer_edges, "transfer table built");

    let graph = Graph {
        stops,
        stop_idx_by_id,
        routes,
        route_idx_by_id,
        trips,
        trip_idx_by_id,
        trip_stops_flat,
        trip_stops_range,
        departures_flat,
        departures_range,
        patterns,
        pattern_idx_by_id,
        pattern_stops_flat,
        pattern_stops_range,
        station_nodes,
        station_idx_by_id,
        pathway_edges,
        pathway_edges_by_from,
        feed_version,
        loaded_at: Utc::now(),
        load_duration_ms: duration.as_millis() as u64,
        horizon_days: opts.horizon_days,
        geo_index,
        transfer_table,
    };

    info!(cells = cell_count, "geo index built");

    info!(
        duration_ms = graph.load_duration_ms,
        stops = graph.stops.len(),
        departures = graph.departures_flat.len(),
        "graph load complete"
    );

    Ok(graph)
}