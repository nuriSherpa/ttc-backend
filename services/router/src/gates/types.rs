use serde::Serialize;

use crate::walk::types::WalkEstimate;

#[derive(Debug, Clone, Serialize)]
pub struct Candidate {
    pub stop_idx: u32,
    pub raw_distance_m: f64,
    pub walk_estimate: Option<WalkEstimate>,
    pub gates_passed: Vec<&'static str>,
    pub gate_failed: Option<&'static str>,
}

#[derive(Debug, Clone, Default, Serialize)]
pub struct GateStats {
    pub input: usize,
    pub accessibility_dropped: usize,
    pub max_walk_dropped: usize,
    pub output: usize,
}