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
