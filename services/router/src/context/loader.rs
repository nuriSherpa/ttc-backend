use std::time::Duration;

use chrono::{DateTime, Datelike, Timelike, Utc};
use redis::aio::ConnectionManager;
use redis::AsyncCommands;
use serde::{Deserialize, Serialize};
use sqlx::PgPool;
use uuid::Uuid;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LatLon {
    pub lat: f64,
    pub lon: f64,
}

#[derive(Debug, Clone, Deserialize, Default)]
pub struct PlanFilters {
    pub preset: Option<String>,
    pub max_walk_m: Option<i32>,
    pub max_transfers: Option<i16>,
    pub wheelchair_mode: Option<bool>,
    pub avoid_stairs: Option<bool>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UserPrefs {
    pub wheelchair_mode: bool,
    pub avoid_stairs: bool,
    pub walk_speed_mps: f64,
    pub detour_factor: f64,
    pub correction_ratio: Option<f64>,
    pub max_walk_m: i32,
    pub max_transfers: i16,
    pub prefer_less_walking: bool,
    pub prefer_fewer_transfers: bool,
    pub timezone: String,
}

impl Default for UserPrefs {
    fn default() -> Self {
        Self {
            wheelchair_mode: false,
            avoid_stairs: false,
            walk_speed_mps: 1.40,
            detour_factor: 1.30,
            correction_ratio: None,
            max_walk_m: 800,
            max_transfers: 3,
            prefer_less_walking: false,
            prefer_fewer_transfers: true,
            timezone: "America/Toronto".into(),
        }
    }
}

pub struct RoutingContext {
    pub user_id: Option<Uuid>,
    pub user: UserPrefs,
    pub origin: LatLon,
    pub destination: LatLon,
    pub depart_at: DateTime<Utc>,
    pub service_day: ServiceDay,
    pub hour_bucket: u8,
    pub filters: PlanFilters,
}

#[derive(Debug, Clone, Copy)]
pub enum ServiceDay {
    Weekday,
    Sat,
    Sun,
}

impl ServiceDay {
    pub fn as_str(&self) -> &'static str {
        match self {
            ServiceDay::Weekday => "weekday",
            ServiceDay::Sat => "sat",
            ServiceDay::Sun => "sun",
        }
    }
}

pub struct CtxLoader {
    pg: PgPool,
    redis: ConnectionManager,
}

impl CtxLoader {
    pub fn new(pg: PgPool, redis: ConnectionManager) -> Self {
        Self { pg, redis }
    }

    pub async fn build(
        &self,
        user_id: Option<Uuid>,
        filters: PlanFilters,
        origin: LatLon,
        destination: LatLon,
        depart_at: Option<DateTime<Utc>>,
    ) -> anyhow::Result<RoutingContext> {
        let mut user = if let Some(uid) = user_id {
            self.load_user_prefs(uid).await.unwrap_or_default()
        } else {
            UserPrefs::default()
        };

        if let Some(v) = filters.max_walk_m { user.max_walk_m = v; }
        if let Some(v) = filters.max_transfers { user.max_transfers = v; }
        if let Some(v) = filters.wheelchair_mode { user.wheelchair_mode = v; }
        if let Some(v) = filters.avoid_stairs { user.avoid_stairs = v; }

        let depart_at = depart_at.unwrap_or_else(Utc::now);
        let service_day = match depart_at.weekday() {
            chrono::Weekday::Sat => ServiceDay::Sat,
            chrono::Weekday::Sun => ServiceDay::Sun,
            _ => ServiceDay::Weekday,
        };

        Ok(RoutingContext {
            user_id,
            user,
            origin,
            destination,
            depart_at,
            service_day,
            hour_bucket: depart_at.hour() as u8,
            filters,
        })
    }

    pub async fn load_user_prefs(&self, user_id: Uuid) -> anyhow::Result<UserPrefs> {
        let cache_key = format!("user:prefs:{}", user_id);

        let mut r = self.redis.clone();
        if let Ok(cached) = r.get::<_, String>(&cache_key).await {
            if let Ok(p) = serde_json::from_str::<UserPrefs>(&cached) {
                return Ok(p);
            }
        }

        let mut tx = self.pg.begin().await?;
        sqlx::query("SELECT set_config('app.user_id', $1, true)")
            .bind(user_id.to_string())
            .execute(&mut *tx)
            .await?;

        let row: (
            bool, bool, f64, f64, Option<f64>,
            i32, i16, bool, bool, String,
        ) = sqlx::query_as(
            r#"
            SELECT
                wheelchair_mode, avoid_stairs,
                walk_speed_mps::float8, detour_factor::float8,
                correction_ratio::float8,
                max_walk_m, max_transfers,
                prefer_less_walking, prefer_fewer_transfers,
                timezone
            FROM app.user_preferences
            WHERE user_id = $1
            "#,
        )
        .bind(user_id)
        .fetch_one(&mut *tx)
        .await?;

        tx.commit().await?;

        let prefs = UserPrefs {
            wheelchair_mode: row.0,
            avoid_stairs: row.1,
            walk_speed_mps: row.2,
            detour_factor: row.3,
            correction_ratio: row.4,
            max_walk_m: row.5,
            max_transfers: row.6,
            prefer_less_walking: row.7,
            prefer_fewer_transfers: row.8,
            timezone: row.9,
        };

        if let Ok(serialized) = serde_json::to_string(&prefs) {
            let _: Result<(), _> = r
                .set_ex(&cache_key, serialized, Duration::from_secs(300).as_secs())
                .await;
        }

        Ok(prefs)
    }
}