//! Weather dimension — clear conditions score 100, storms penalize.
//!
//! Reads `weather_condition` from each walk leg's `breakdown` (populated by
//! the Layer 3 walk pipeline). Returns `None` if no walk has weather data —
//! the aggregator treats `None` as weight 0, so the dimension is silently
//! skipped for journeys where walk breakdowns are absent (e.g. transfer
//! walks, which carry no breakdown).

use crate::journey::types::{JourneyResponse, ResponseLeg};

pub fn score(j: &JourneyResponse) -> Option<(f64, String)> {
    let mut worst: u8 = 0; // 0=clear, 1=cloudy/fog, 2=rain, 3=snow, 4=storm
    let mut any = false;

    for leg in &j.legs {
        if let ResponseLeg::Walk(w) = leg {
            if let Some(b) = &w.breakdown {
                if let Some(cond) = &b.weather_condition {
                    any = true;
                    let sev = match cond.to_ascii_lowercase().as_str() {
                        "storm" => 4,
                        "snow" => 3,
                        "rain" => 2,
                        "fog" | "cloudy" => 1,
                        _ => 0,
                    };
                    worst = worst.max(sev);
                }
            }
        }
    }

    if !any {
        return None;
    }

    let (s, label) = match worst {
        4 => (30.0, "storm"),
        3 => (55.0, "snow"),
        2 => (75.0, "rain"),
        1 => (92.0, "cloudy/fog"),
        _ => (100.0, "clear"),
    };

    Some((s, format!("weather: {}", label)))
}