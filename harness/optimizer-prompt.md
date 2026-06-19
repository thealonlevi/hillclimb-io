This is one optimization iteration for accept-bench. Do exactly this, then exit:

1. Read `results/BEST.json` (champion config + score) and, if present, `results/CONTROL_BASELINE.md`.
2. Read `kbs/INDEX.md`; open any note relevant to your next idea.
3. Query ClickHouse via the clickhouse MCP tools to see prior runs and what correlates with score:
   - champion:    `SELECT config_hash, score FROM acceptbench.runs WHERE arm='treatment' AND gate_passed=1 ORDER BY score DESC LIMIT 1`
   - lever signal: `SELECT round(sysc_io_uring_enter,2) AS enter_pc, count(), avg(score) FROM acceptbench.runs WHERE arm='treatment' AND gate_passed=1 GROUP BY enter_pc ORDER BY enter_pc`
   (If the MCP/CH is unavailable, read the last ~20 lines of `results/HISTORY.jsonl` instead.)
4. Form ONE hypothesis for a single change that should reduce per-connection syscall cost or
   otherwise raise conn/s-per-core. Implement it by editing files under `treatment/` only.
5. Make sure it still builds (`make -C treatment`) and keeps the contract (exact 19-byte reply,
   one reply per connection then close, listens on `--port`). Do NOT run the load benchmark and do
   NOT commit — the harness does that.
6. Write/append a one-line lesson to `kbs/` (and `kbs/INDEX.md`) capturing the hypothesis.
7. Print 1-3 sentences: the hypothesis you implemented and the expected mechanism (this becomes the
   commit message). Then stop.

Leave your edits uncommitted in `treatment/`. The harness will commit, benchmark, score, and keep
or revert based on the score.
