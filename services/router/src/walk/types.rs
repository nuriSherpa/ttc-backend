use chrono::{DateTime, Utc};
use serde::Serialize;

use crate::context::loader::UserPrefs;
use crate::graph::weather::WeatherCache;

#[derive(Debug, Clone, Serialize)]
pub struct WalkEstimate {
    pub seconds: u32,
    pub walk_m: f64,
    pub confidence: f64,
    pub breakdown: WalkBreakdown,
}

#[derive(Debug, Clone, Default, Serialize)]
pub struct WalkBreakdown {
    pub base_distance_m: Option<f64>,
    pub detour_factor: Option<f64>,
    pub personal_speed_mps: Option<f64>,
    pub weather_penalty: Option<f32>,
    pub weather_condition: Option<String>,
    pub time_of_day_multiplier: Option<f64>,
    pub personal_correction: Option<f64>,
    pub ingredients_applied: Vec<String>,
    pub ingredients_skipped: Vec<String>,
}

pub struct WalkContext<'a> {
    pub from_lat: f64,
    pub from_lon: f64,
    pub to_lat: f64,
    pub to_lon: f64,
    pub raw_distance_m: f64,
    pub depart_at: DateTime<Utc>,
    pub user: &'a UserPrefs,
    pub weather: &'a WeatherCache,
}