# ttc-router

In-memory transit routing engine. Go/No-Go: Go.

## Layers
0. Context loader — user prefs → RoutingContext
1. Graph loader — ref.* → in-memory Graph (200MB)
1b. Live delay refresh (30s)
1c. Elevator outage cache (60s)
1d. Weather cache (10min)
2. Nearest stops (geo index)
3. Walk sub-sandwich (6 ingredients)
4. Gates (accessibility, max_walk, max_transfers)
5. RAPTOR
6. Journey assembly
7. Enrichment
8. Score sandwich
9. Response shaping

## Build
cargo check         # fast feedback loop
cargo build --release
cargo test

## Run
cargo run

## Endpoints
GET  /health
GET  /graph/status       (requires X-Internal-Token)
POST /plan               (requires X-Internal-Token)
