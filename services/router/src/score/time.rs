pub fn score(arrival_s: f64, fastest_s: f64) -> (f64, String) {
    let fastest_s = fastest_s.max(1.0);
    let arrival_s = arrival_s.max(1.0);
    let s = (100.0 * (fastest_s / arrival_s)).clamp(0.0, 100.0);
    let delta_min = ((arrival_s - fastest_s) / 60.0).max(0.0);
    let reason = if delta_min < 0.5 {
        format!("fastest arrival ({} min)", (arrival_s / 60.0).round())
    } else {
        format!("arrives {} min later than fastest", delta_min.round() as i64)
    };
    (s, reason)
}

/// Arrive-by scoring: 100 = arrive exactly at deadline, 0 = arrive
/// `window_s` early (or worse). Slack = how early before the deadline.
pub fn score_arrive_by(slack_s: i64, window_s: i64) -> (f64, String) {
    if slack_s < 0 {
        // Arrives AFTER deadline — hard fail. Callers should filter these out
        // before scoring, but be defensive.
        return (0.0, "arrives after deadline".to_string());
    }
    let window = window_s.max(1) as f64;
    let slack = slack_s as f64;
    let s = (100.0 * (1.0 - slack / window)).clamp(0.0, 100.0);
    let reason = if slack_s < 60 {
        "arrives just in time".to_string()
    } else if slack_s < 3600 {
        format!("arrives {} min before deadline", slack_s / 60)
    } else {
        format!("arrives {} hr before deadline", slack_s / 3600)
    };
    (s, reason)
}