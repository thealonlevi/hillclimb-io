-- accept-bench ClickHouse schema (METRICS.md). Apply: clickhouse-client --multiquery < harness/schema.sql
CREATE DATABASE IF NOT EXISTS acceptbench;

CREATE TABLE IF NOT EXISTS acceptbench.runs (
  ts                  DateTime,
  runid               String,
  arm                 LowCardinality(String),
  config_hash         String,
  parent_hash         String,
  hypothesis          String,
  score               Float64,
  max_sustained_conn_s UInt64,
  cores               UInt16,
  ceiling_reason      LowCardinality(String),
  gate_passed         UInt8,
  drop_rate           Float64,
  median_of           UInt8,
  spread_pct          Float64,
  sysc_io_uring_enter Float64,
  sysc_accept4        Float64,
  sysc_read           Float64,
  sysc_write          Float64,
  sysc_close          Float64,
  sysc_epoll_wait     Float64,
  perf_ipc            Float64,
  perf_instr_pc       Float64,             -- instructions per connection (frequency-independent)
  perf_llc_miss_pc    Float64,
  perf_ctxsw_pc       Float64,
  kernel              String,
  env_fingerprint     String,
  input_tokens        UInt64,
  output_tokens       UInt64,
  cache_read_tokens   UInt64,
  cache_write_tokens  UInt64,
  cost_usd            Float64
) ENGINE = MergeTree ORDER BY (arm, ts);

CREATE TABLE IF NOT EXISTS acceptbench.steps (
  ts            DateTime,
  runid         String,
  step_idx      UInt16,
  offered_cps   UInt64,
  completed_cps UInt64,
  failed_cps    UInt64,
  cpu_util      Float64,
  max_recvq     UInt32,
  p50_accept_ms Float64,
  p99_accept_ms Float64,
  is_ceiling    UInt8
) ENGINE = MergeTree ORDER BY (runid, step_idx);

CREATE TABLE IF NOT EXISTS acceptbench.samples (
  ts            DateTime,
  runid         String,
  step_idx      UInt16,
  t_offset_s    UInt16,
  cpu_util      Float64,
  recvq         UInt32,
  completed_cps UInt64,
  p99_accept_ms Float64
) ENGINE = MergeTree ORDER BY (runid, step_idx, t_offset_s)
  TTL ts + INTERVAL 30 DAY;

-- one row per optimizer iteration: economics + the agent's hypothesis + verdict + model.
-- Lets you correlate spend/model with progress and read what each idea was.
CREATE TABLE IF NOT EXISTS acceptbench.iterations (
  ts           DateTime,
  iter         UInt32,
  runid        String,
  model        LowCardinality(String),
  score        Float64,
  champion     Float64,
  verdict      LowCardinality(String),     -- promote | revert-regression | revert-fail
  ceiling      LowCardinality(String),
  cost_usd     Float64,
  cum_cost_usd Float64,
  in_tokens    UInt64,
  hypothesis   String
) ENGINE = MergeTree ORDER BY (ts);

-- function-level CPU profile: the hottest symbols per run (where the cycles actually go).
-- category ∈ kernel | user | liburing | libc | other. self_pct = % of CPU samples in that symbol.
CREATE TABLE IF NOT EXISTS acceptbench.profile (
  ts        DateTime,
  runid     String,
  rank      UInt16,
  symbol    String,
  module    String,
  category  LowCardinality(String),
  self_pct  Float64
) ENGINE = MergeTree ORDER BY (runid, rank);
