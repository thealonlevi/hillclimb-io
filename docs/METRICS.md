# Metrics storage — ClickHouse (analytics) + local files (loop state)

## The split (important)

ClickHouse is the **queryable memory the optimizer reasons over**. It is NOT the loop's
transactional state. Two things stay as local files and never depend on a network round-trip:

- **`results/BEST.json`** — the champion config + score, and the git-sha→score mapping. The
  keep/revert decision must be local and atomic. DB down ≠ loop stalls.
- **The current run's gate verdict + score** — the harness must score a run even if ClickHouse
  is unreachable. the reference proxy's own monitor is explicitly built to survive ClickHouse outages; this
  harness inherits that. **Writes to ClickHouse are async / best-effort; a failed insert is
  logged and retried, never blocks a run.**

So: local file = the referee's decision; ClickHouse = the agent's analytics and long-term
memory. The agent still keeps appending `HISTORY.jsonl` as a durable local fallback (cheap
insurance); ClickHouse is the primary query surface.

CH is co-located on box 1, so "best-effort, never blocks a run" is less about network outages
and more about (a) not letting a CH hiccup stall the loop and (b) **keeping CH idle for the
whole measured benchmark** — see the co-location caveat below. Buffer rows during the run; flush
+ query only in the post-run phase.

### The loop's phase ordering (where CH is allowed to touch the CPU)

Each optimizer iteration runs in strictly separated phases, and CH is touched in exactly one:

```
[MEASURE phase]   build → pin → ramp (all steps × N reps) → score → gate
                  CH: completely idle. No inserts, no queries. Rows buffered locally.
                  Only the SUT arm + the harness samplers run on/near the box.
        │
        ▼
[ANALYTICS phase] flush buffered rows to CH → run agent queries (champion, lever
                  correlation, drift) → form next hypothesis → keep/revert via BEST.json + git
                  CH: active here, and only here. The SUT is not under measurement.
        │
        ▼  (next iteration)
```

The keep/revert decision still reads `BEST.json` (local, authoritative); CH informs the *next
hypothesis*, not the current verdict.

## Why ClickHouse over JSONL here

The optimizer's value is correlation — across thousands of runs AND within a run:

- *"Do multishot-accept configs have lower `io_uring_enter`/conn and higher score?"* → one
  `GROUP BY` over all runs. In JSONL the agent re-reads + re-parses the whole file every loop;
  cost grows with history. ClickHouse stays flat.
- Per run we emit ~720 per-second sample rows (8 steps × 30s × 3 reps). That's a time series,
  not a blob — it belongs in columnar storage where the agent can ask "where did the accept
  queue break within the saturating step?" instead of parsing nested JSON.

## Target

- **Server:** a **fresh, dedicated ClickHouse instance co-located on box 1** (the agent/SUT
  box). Not the production ClickHouse — its own install. So the benchmark's heavy per-second inserts
  and experimental schema churn never touch prod monitoring, and every analytics query the
  agent runs is a **localhost round-trip** (sub-ms, no network in the loop).
- **Database:** `acceptbench`.
- **Credentials:** a local CH user for the agent; no external secrets-manager dependency needed since it's local —
  but still don't hard-code the password in `treatment/` (the agent edits that and shouldn't
  see/own the DB creds). Put CH connection config in `harness/` (which the agent doesn't edit).

### Co-location caveat (load-bearing — read this)

ClickHouse on the **same box** as the SUT means CH's own CPU/memory/IO can contaminate the
thing you're measuring. The benchmark's core metric is SUT CPU efficiency on a pinned core set
— if CH ingest spikes during a MEASURE window, it steals cycles and corrupts the score.
Mitigations (put these in ENVIRONMENT.md / the cgroup setup):

- **Pin ClickHouse to cpus OUTSIDE the SUT cpuset** (its own cgroup/cpuset). The SUT cpuset is
  already exclusive; CH must live on the *other* cores, same as the NIC IRQs.
- **CH is fully idle for the entire benchmark — no inserts AND no queries while any arm is
  under measurement.** The harness buffers all of a run's rows in memory / a local file and
  touches CH only in a dedicated phase **after the whole run finishes** (all ramp steps, all N
  reps). The agent's analytics queries (champion lookup, lever correlation, drift check) also
  run only in that post-run phase. So during the cycle-counting phases CH does zero work and
  cannot contend for the SUT's cores or IO. This is stricter than "flush between steps" — it
  removes CH from the measured window entirely, in both directions.
- Cap CH memory so a big background merge can't evict the SUT's working set.
- The control-drift watchdog already catches sustained contamination (control score sags), but
  the two rules above prevent it in the first place.

## Schema (per-run + per-step + per-second)

### `acceptbench.runs` — one row per scored run (the agent's primary cross-run table)

```sql
CREATE TABLE acceptbench.runs (
  ts                  DateTime,            -- run completion (stamped by harness, passed in)
  runid               String,
  arm                 LowCardinality(String),  -- treatment | control-frozen | control-adaptive
  config_hash         String,              -- git sha of treatment/ tree
  parent_hash         String,              -- the config this mutated from (lineage)
  hypothesis          String,              -- agent's note: what this change was testing
  score               Float64,             -- max_sustained_conn_s / cores
  max_sustained_conn_s UInt64,
  cores               UInt16,
  ceiling_reason      LowCardinality(String),  -- queue_backpressure | cpu_saturation
  gate_passed         UInt8,               -- 0/1; 0 => score is 0
  drop_rate           Float64,
  median_of           UInt8,
  spread_pct          Float64,             -- run-to-run noise; promote only if win > spread
  -- syscall + perf totals at the ceiling step, per connection
  sysc_io_uring_enter Float64,
  sysc_accept4        Float64,
  sysc_read           Float64,
  sysc_write          Float64,
  sysc_close          Float64,
  sysc_epoll_wait     Float64,
  perf_ipc            Float64,
  perf_llc_miss_pc    Float64,             -- LLC misses per connection
  perf_ctxsw_pc       Float64,
  kernel              String,
  env_fingerprint     String,
  -- optimizer token economics (from the claude -p JSON result; see TOKEN_EFFICIENCY.md)
  input_tokens        UInt64,
  output_tokens       UInt64,
  cache_read_tokens   UInt64,   -- ~0 across iterations => prompt cache went cold (TTL trap)
  cache_write_tokens  UInt64,
  cost_usd            Float64
) ENGINE = MergeTree ORDER BY (arm, ts);
```

### `acceptbench.steps` — one row per ramp step

```sql
CREATE TABLE acceptbench.steps (
  ts            DateTime,
  runid         String,
  step_idx      UInt16,
  offered_cps   UInt64,
  completed_cps UInt64,
  failed_cps    UInt64,
  cpu_util      Float64,        -- fraction of CORES (mean over the MEASURE window)
  max_recvq     UInt32,         -- deepest accept-queue depth seen this step
  p50_accept_ms Float64,
  p99_accept_ms Float64,
  is_ceiling    UInt8           -- 1 = the step that set max_sustained_conn_s
) ENGINE = MergeTree ORDER BY (runid, step_idx);
```

### `acceptbench.samples` — one row per 1s sample (intra-run dynamics)

```sql
CREATE TABLE acceptbench.samples (
  ts            DateTime,
  runid         String,
  step_idx      UInt16,
  t_offset_s    UInt16,         -- seconds into the MEASURE window
  cpu_util      Float64,
  recvq         UInt32,
  completed_cps UInt64,
  p99_accept_ms Float64
) ENGINE = MergeTree ORDER BY (runid, step_idx, t_offset_s)
  TTL ts + INTERVAL 30 DAY;     -- raw per-second detail is bulky; expire it, keep runs/steps
```

> Per-second `samples` is the bulky table — TTL it (30d default). `runs` and `steps` are small
> and permanent: they ARE the optimizer's long-term memory.

## Note: ClickHouse and `Date.now()`

The harness stamps `ts` itself (it's a normal process, not a workflow script) and passes it in
explicitly — fine here. Just don't let any inserter rely on CH `now()` if you want a run's rows
to share one consistent timestamp; compute it once per run and pass it to all three tables.

## Queries the optimizer actually runs each iteration

```sql
-- current champion to beat
SELECT config_hash, score FROM acceptbench.runs
WHERE arm='treatment' AND gate_passed=1 ORDER BY score DESC LIMIT 1;

-- does a design lever correlate with score? (the agent's core reasoning)
SELECT round(sysc_io_uring_enter,2) AS enter_pc, count(), avg(score)
FROM acceptbench.runs WHERE arm='treatment' AND gate_passed=1
GROUP BY enter_pc ORDER BY enter_pc;

-- control drift watchdog (has the box changed under us?)
SELECT ts, score FROM acceptbench.runs
WHERE arm='control-frozen' ORDER BY ts DESC LIMIT 10;

-- within the saturating step, where did the queue break?
SELECT t_offset_s, cpu_util, recvq, p99_accept_ms
FROM acceptbench.samples WHERE runid={runid:String} AND is_ceiling_step
ORDER BY t_offset_s;
```

## Updates to other docs

- `HARNESS.md` HISTORY.jsonl schema stays as the local fallback; the harness writes BOTH
  (local JSONL always, ClickHouse best-effort).
- `AGENT_LOOP.md`: "read results/HISTORY.jsonl" becomes "query acceptbench.runs (fall back to
  HISTORY.jsonl if CH unreachable)". BEST.json stays local and authoritative for keep/revert.
