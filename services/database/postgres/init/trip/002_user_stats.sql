-- ============================================================================
-- 002_user_stats.sql
-- Nightly aggregates. Powers "your most-used routes/stops".
-- ============================================================================

BEGIN;

CREATE TABLE app.user_route_stat (
  user_id         uuid     NOT NULL REFERENCES app.account(user_id) ON DELETE CASCADE,
  route_id        text     NOT NULL,
  ride_count      integer  NOT NULL DEFAULT 0,
  last_ridden_on  date,
  PRIMARY KEY (user_id, route_id)
);

CREATE INDEX app_user_route_stat_rank_idx
  ON app.user_route_stat (user_id, ride_count DESC);

CREATE TABLE app.user_stop_stat (
  user_id         uuid     NOT NULL REFERENCES app.account(user_id) ON DELETE CASCADE,
  stop_id         text     NOT NULL,
  board_count     integer  NOT NULL DEFAULT 0,
  alight_count    integer  NOT NULL DEFAULT 0,
  last_used_on    date,
  PRIMARY KEY (user_id, stop_id)
);

CREATE INDEX app_user_stop_stat_board_rank_idx
  ON app.user_stop_stat (user_id, board_count DESC);

COMMIT;