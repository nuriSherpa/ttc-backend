use super::types::Stop;

const EARTH_RADIUS_M: f64 = 6_371_000.0;
const CELL_SIZE_DEG: f32 = 0.01; // ~1 km at Toronto latitude

pub struct GeoIndex {
    min_lat: f32,
    min_lon: f32,
    n_lat_cells: u32,
    n_lon_cells: u32,
    cells: Vec<Vec<u32>>,
    stop_lats: Vec<f32>,
    stop_lons: Vec<f32>,
}

impl GeoIndex {
    pub fn build(stops: &[Stop]) -> Self {
        if stops.is_empty() {
            return Self {
                min_lat: 0.0, min_lon: 0.0,
                n_lat_cells: 1, n_lon_cells: 1,
                cells: vec![Vec::new()],
                stop_lats: Vec::new(), stop_lons: Vec::new(),
            };
        }

        let (min_lat, max_lat) = stops.iter().fold(
            (f32::INFINITY, f32::NEG_INFINITY),
            |(lo, hi), s| (lo.min(s.lat as f32), hi.max(s.lat as f32)),
        );
        let (min_lon, max_lon) = stops.iter().fold(
            (f32::INFINITY, f32::NEG_INFINITY),
            |(lo, hi), s| (lo.min(s.lon as f32), hi.max(s.lon as f32)),
        );

        let n_lat_cells = (((max_lat - min_lat) / CELL_SIZE_DEG).ceil() as u32).max(1);
        let n_lon_cells = (((max_lon - min_lon) / CELL_SIZE_DEG).ceil() as u32).max(1);

        let total_cells = (n_lat_cells * n_lon_cells) as usize;
        let mut cells: Vec<Vec<u32>> = vec![Vec::new(); total_cells];

        for (idx, s) in stops.iter().enumerate() {
            let la = (((s.lat as f32 - min_lat) / CELL_SIZE_DEG) as u32).min(n_lat_cells - 1);
            let lo = (((s.lon as f32 - min_lon) / CELL_SIZE_DEG) as u32).min(n_lon_cells - 1);
            cells[(la * n_lon_cells + lo) as usize].push(idx as u32);
        }

        Self {
            min_lat, min_lon, n_lat_cells, n_lon_cells,
            cells,
            stop_lats: stops.iter().map(|s| s.lat as f32).collect(),
            stop_lons: stops.iter().map(|s| s.lon as f32).collect(),
        }
    }

    pub fn nearest(&self, lat: f64, lon: f64, radius_m: f64, limit: usize) -> Vec<(u32, f64)> {
        let deg_per_m = 1.0 / 111_320.0;
        let lat_radius = (radius_m * deg_per_m) as f32;
        let cos_lat = (lat.to_radians().cos() as f32).max(0.01);
        let lon_radius = (radius_m * deg_per_m) as f32 / cos_lat;

        let lat_lo_f = lat as f32 - lat_radius;
        let lat_hi_f = lat as f32 + lat_radius;
        let lon_lo_f = lon as f32 - lon_radius;
        let lon_hi_f = lon as f32 + lon_radius;

        if lat_hi_f < self.min_lat
            || lat_lo_f > self.min_lat + self.n_lat_cells as f32 * CELL_SIZE_DEG
            || lon_hi_f < self.min_lon
            || lon_lo_f > self.min_lon + self.n_lon_cells as f32 * CELL_SIZE_DEG
        {
            return Vec::new();
        }

        let lat_cell_lo = (((lat_lo_f - self.min_lat) / CELL_SIZE_DEG) as i32).max(0) as u32;
        let lat_cell_hi = (((lat_hi_f - self.min_lat) / CELL_SIZE_DEG) as u32)
            .min(self.n_lat_cells - 1);
        let lon_cell_lo = (((lon_lo_f - self.min_lon) / CELL_SIZE_DEG) as i32).max(0) as u32;
        let lon_cell_hi = (((lon_hi_f - self.min_lon) / CELL_SIZE_DEG) as u32)
            .min(self.n_lon_cells - 1);

        let mut candidates: Vec<(u32, f64)> = Vec::with_capacity(64);
        for la in lat_cell_lo..=lat_cell_hi {
            for lo in lon_cell_lo..=lon_cell_hi {
                let cell_idx = (la * self.n_lon_cells + lo) as usize;
                for &stop_idx in &self.cells[cell_idx] {
                    let d = haversine_m(
                        lat, lon,
                        self.stop_lats[stop_idx as usize] as f64,
                        self.stop_lons[stop_idx as usize] as f64,
                    );
                    if d <= radius_m {
                        candidates.push((stop_idx, d));
                    }
                }
            }
        }

        candidates.sort_by(|a, b| a.1.partial_cmp(&b.1).unwrap_or(std::cmp::Ordering::Equal));
        candidates.truncate(limit);
        candidates
    }

    pub fn cell_count(&self) -> usize {
        self.cells.len()
    }
}

pub fn haversine_m(lat1: f64, lon1: f64, lat2: f64, lon2: f64) -> f64 {
    let lat1r = lat1.to_radians();
    let lat2r = lat2.to_radians();
    let dlat = (lat2 - lat1).to_radians();
    let dlon = (lon2 - lon1).to_radians();
    let a = (dlat / 2.0).sin().powi(2)
        + lat1r.cos() * lat2r.cos() * (dlon / 2.0).sin().powi(2);
    2.0 * EARTH_RADIUS_M * a.sqrt().asin()
}