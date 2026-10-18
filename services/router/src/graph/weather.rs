use std::collections::HashMap;
use std::sync::Arc;

use chrono::{DateTime, Datelike, NaiveDate, Timelike, Utc};
use chrono_tz::America::Toronto;
use sqlx::{PgPool, Row};
use tokio::sync::RwLock;
use tracing::info;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Condition {
    Clear,
    Cloudy,
    Fog,
    Rain,
    Snow,
    Storm,
}

impl Condition {
    pub fn from_str(s: &str) -> Self {
        match s {
            "clear" => Self::Clear,
            "cloudy" => Self::Cloudy,
            "fog" => Self::Fog,
            "rain" => Self::Rain,
            "snow" => Self::Snow,
            "storm" => Self::Storm,
            _ => Self::Cloudy,
        }
    }

    pub fn walk_penalty(&self, severity: i16) -> f32 {
        let base = match self {
            Self::Clear => 1.00,
            Self::Cloudy => 1.02,
            Self::Fog => 1.08,
            Self::Rain => 1.12,
            Self::Snow => 1.30,
            Self::Storm => 1.45,
        };
        let bump = match severity {
            0 => 0.00,
            1 => 0.03,
            2 => 0.08,
            _ => 0.15,
        };
        base + bump
    }
}

#[derive(Debug, Clone, Copy)]
pub struct WeatherHour {
    pub temp_c: f32,
    pub precip_mm: f32,
    pub snow_cm: f32,
    pub wind_kph: f32,
    pub condition: Condition,
    pub severity: i16,
}

pub type WeatherKey = (i32, i32, i32, u8);
pub type WeatherCache = Arc<RwLock<HashMap<WeatherKey, WeatherHour>>>;

fn days_from_epoch(d: NaiveDate) -> i32 {
    d.signed_duration_since(NaiveDate::from_ymd_opt(1970, 1, 1).unwrap())
        .num_days() as i32
}

pub async fn refresh(pg: &PgPool, cache: &WeatherCache) -> anyhow::Result<usize> {
    // Widen to 8h of history — observations arrive hourly with ~1-2h lag.
    let rows = sqlx::query(
        "SELECT grid_lat::float8, grid_lon::float8,
                local_date, local_hour,
                temp_c, precip_mm, snow_cm, wind_kph,
                condition, severity
         FROM ref.weather_hourly
         WHERE observed_at_utc BETWEEN now() - interval '8 hours'
                                   AND now() + interval '1 hour'",
    )
    .fetch_all(pg)
    .await?;

    let mut map = HashMap::with_capacity(rows.len());
    for row in rows.iter() {
        let grid_lat: f64 = row.get("grid_lat");
        let grid_lon: f64 = row.get("grid_lon");
        let local_date: NaiveDate = row.get("local_date");
        let local_hour: i16 = row.get("local_hour");

        let key = (
            (grid_lat * 100.0).round() as i32,
            (grid_lon * 100.0).round() as i32,
            days_from_epoch(local_date),
            local_hour as u8,
        );

        map.insert(
            key,
            WeatherHour {
                temp_c: row.get::<Option<f32>, _>("temp_c").unwrap_or(0.0),
                precip_mm: row.get("precip_mm"),
                snow_cm: row.get("snow_cm"),
                wind_kph: row.get::<Option<f32>, _>("wind_kph").unwrap_or(0.0),
                condition: Condition::from_str(&row.get::<String, _>("condition")),
                severity: row.get("severity"),
            },
        );
    }

    let count = map.len();
    *cache.write().await = map;
    info!(count, "weather cache refreshed");
    Ok(count)
}

/// Get weather for (lat, lon, when). Walks backward up to 6 hours if the
/// exact hour isn't cached. Falls back to nearest grid cell on miss.
pub async fn at(
    cache: &WeatherCache,
    lat: f64,
    lon: f64,
    when: DateTime<Utc>,
) -> Option<WeatherHour> {
    let target_lat = (lat * 100.0).round() as i32;
    let target_lon = (lon * 100.0).round() as i32;
    let map = cache.read().await;

    // Try exact hour, then walk backward up to 6 hours.
    for hours_back in 0..=6 {
        let t = when - chrono::Duration::hours(hours_back);
        let local = t.with_timezone(&Toronto);
        let day = days_from_epoch(local.date_naive());
        let hour = local.hour() as u8;

        // Exact grid cell
        if let Some(w) = map.get(&(target_lat, target_lon, day, hour)) {
            return Some(*w);
        }

        // Nearest grid cell at this (day, hour) — ~48 candidates, microseconds.
        let mut best: Option<(i64, WeatherHour)> = None;
        for ((glat, glon, d, h), w) in map.iter() {
            if *d != day || *h != hour {
                continue;
            }
            let dlat = (*glat - target_lat) as i64;
            let dlon = (*glon - target_lon) as i64;
            let dist_sq = dlat * dlat + dlon * dlon;
            if best.map_or(true, |(bd, _)| dist_sq < bd) {
                best = Some((dist_sq, *w));
            }
        }
        if let Some((_, w)) = best {
            return Some(w);
        }
    }

    None
}