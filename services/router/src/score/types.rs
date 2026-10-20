//! Layer 8 — types for the score sandwich.

use serde::Serialize;
use crate::journey::types::JourneyResponse;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Preset {
    Balanced,
    Fastest,
    Reliable,
    Accessible,
    Comfort,
    LessWait,
}

impl Preset {
    pub fn from_opt(s: Option<&str>) -> Self {
        match s.map(|s| s.trim().to_ascii_lowercase()).as_deref() {
            Some("fastest") => Preset::Fastest,
            Some("reliable") => Preset::Reliable,
            Some("accessible") => Preset::Accessible,
            Some("comfort") => Preset::Comfort,
            Some("less_wait") | Some("lesswait") | Some("less-wait") => Preset::LessWait,
            _ => Preset::Balanced,
        }
    }

    pub fn as_str(&self) -> &'static str {
        match self {
            Preset::Balanced => "balanced",
            Preset::Fastest => "fastest",
            Preset::Reliable => "reliable",
            Preset::Accessible => "accessible",
            Preset::Comfort => "comfort",
            Preset::LessWait => "less_wait",
        }
    }

    pub fn weights(&self) -> Weights {
        match self {
            Preset::Balanced => Weights {
                time: 1.0, reliability: 1.0, walking: 1.0,
                transfers: 1.0, weather: 1.0, comfort: 1.0, waiting: 1.0,
            },
            // Fastest: aggressively prioritize early arrival. Walking matters
            // little (user wants speed). Search radius is widened in handlers.rs.
            Preset::Fastest => Weights {
                time: 3.0, reliability: 0.5, walking: 0.3,
                transfers: 0.5, weather: 0.3, comfort: 0.3, waiting: 0.5,
            },
            // Reliable: weight reliability heavily. Avoid unreliable routes.
            Preset::Reliable => Weights {
                time: 0.5, reliability: 3.0, walking: 0.5,
                transfers: 1.0, weather: 1.0, comfort: 0.5, waiting: 0.5,
            },
            // Accessible: strong walk penalty; gate applies wheelchair_mode.
            Preset::Accessible => Weights {
                time: 1.0, reliability: 0.5, walking: 2.5,
                transfers: 1.0, weather: 1.5, comfort: 0.5, waiting: 0.5,
            },
            // Comfort: user wants fewer transfers AND less waiting.
            Preset::Comfort => Weights {
                time: 0.5, reliability: 0.5, walking: 1.0,
                transfers: 3.0, weather: 1.5, comfort: 0.5, waiting: 3.0,
            },
            // LessWait: minimize standing at stops.
            Preset::LessWait => Weights {
                time: 0.5, reliability: 0.5, walking: 0.5,
                transfers: 0.5, weather: 0.5, comfort: 0.5, waiting: 3.5,
            },
        }
    }
}

#[derive(Debug, Clone, Copy)]
pub struct Weights {
    pub time: f64,
    pub reliability: f64,
    pub walking: f64,
    pub transfers: f64,
    pub weather: f64,
    pub comfort: f64,
    pub waiting: f64,
}

#[derive(Debug, Clone, Serialize)]
pub struct ScoreReason {
    pub dimension: &'static str,
    pub score: f64,
    pub weight: f64,
    pub reason: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct ScoredJourney {
    pub journey: JourneyResponse,
    pub score: f64,
    pub reasons: Vec<ScoreReason>,
    pub departure_slip_s: i64,
}