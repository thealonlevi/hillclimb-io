# The optimizer loop — what the autonomous agent does

The agent is **`claude -p` (headless)** invoked once per iteration by the bash harness — see
OPTIMIZER_HEADLESS.md for the verified flags, autonomy model, and session/memory design. It
runs on box 1 (the SUT box). It is the ONLY actor that edits `treatment/`. It never edits the
harness, control arm, loadgen, or scoring. Its world-model is the co-located ClickHouse
(`acceptbench.*`, queried only between runs) + the `kbs/` knowledge folder + the `treatment/`
git history, plus the local `results/BEST.json` (authoritative for keep/revert) and
`results/HISTORY.jsonl` (CH-down fallback). Critically: **ClickHouse is queried only in the
analytics phase, never while an arm is under measurement** — see METRICS.md for the phase split.

Memory tiers (full detail in OPTIMIZER_HEADLESS.md): a **chat session** continued across
iterations and rotated when context crosses a threshold; on rotation a fresh session
rehydrates from **`kbs/` + git history + ClickHouse**. The session is a cache; kbs/git/CH are
the source of truth. Every iteration commits everything (source + kbs note) with a detailed,
structured message so `git log` alone reconstructs what's been tried and what won.

## The loop

CH is touched ONLY in the analytics phase, never while an arm is under measurement (see
METRICS.md). Each iteration is two strictly separated phases:

```
forever:

  # ---- ANALYTICS phase (CH active; SUT NOT under measurement) ----
  BEST     = read results/BEST.json              # local, authoritative champion (NOT from CH)
  CONTROL  = read results/CONTROL_BASELINE.md    # the number to beat
  flush any buffered rows from the previous run into ClickHouse
  reason over ClickHouse (fall back to HISTORY.jsonl if CH is down):
     # "runs with multishot accept have 8x fewer io_uring_enter and +12% score;
     #  registered files untried; hypothesis: direct descriptors cut another read() cost"
  hypothesis = that reasoning
  edit treatment/ to implement hypothesis         # one coherent change, committed to git

  # ---- MEASURE phase (CH IDLE — no inserts, no queries; cycles are being counted) ----
  result = harness/run.sh treatment               # build, pin, ramp (all steps × N reps),
                                                   # score, gate, profile. Rows buffered LOCALLY.
  append result to HISTORY.jsonl                   # local durable fallback (a file, not CH)

  # ---- back to analytics-side bookkeeping (CH still not needed for the verdict) ----
  if build_failed or crashed or gate_failed:
     git -C treatment reset --hard HEAD~1          # discard the bad mutation
     record why in notes
  elif result.score > BEST.score * (1 + EPSILON):
     write result.config to BEST.json              # new champion; keep the commit
     graphify update treatment/                    # refresh code map (ZERO API cost) for next iter
  else:
     git -C treatment reset --hard HEAD~1          # not better -> revert, never keep regressions

  every K iterations:
     re-run control-frozen; if its score drifted >5% from CONTROL_BASELINE -> PAUSE, flag human
     # the box changed (thermal/neighbor/kernel); scores aren't comparable until investigated

  if no improvement > EPSILON over PATIENCE distinct configs:
     generate results/REPORT.md and STOP        # plateau reached = empirical optimum
```

The buffered rows from a MEASURE phase are flushed at the *start of the next* analytics phase
(or at run end), so ClickHouse never does ingest work while the SUT is being measured.

## How the agent should reason (guidance, not rules)

- **Use the syscall profile, not just the score.** The `syscall_profile` per run tells the
  agent *why* something is fast. Fewer `io_uring_enter`/conn, fewer `read`/`write`/conn → that's
  the lever. Correlate profile deltas with score deltas across HISTORY to build a causal model.
- **One change per run.** Bundled changes make HISTORY uninterpretable — the agent can't tell
  which mutation helped. Mutate one dimension, measure, then compound.
- **Spend the budget where the profile points.** If `io_uring_enter`/conn is already ~0
  (SQPOLL), stop optimizing submissions and look at cache misses (`perf stat` LLC-load-misses,
  also recorded). The agent follows the bottleneck, it doesn't guess.
- **Respect the per-core objective.** SQPOLL burning a whole core might raise raw conn/s but
  *lower* conn/s-per-core. The score already encodes this; trust it.
- **Beware overfitting to noise.** The score is a median of N=3 with a recorded spread. Don't
  promote a change whose improvement is within the spread — that's noise, not a win.
- **Log the hypothesis in `notes`.** Future-you (next iteration) reads it. This is the agent's
  lab notebook.

## Tuning knobs (in harness/config, the agent reads but does not change)

| Knob | Default | Meaning |
|------|---------|---------|
| `CORES` | (pinned set) | core budget — denominator of the score |
| `QUEUE_HIGH` | 40 | accept-queue depth = backpressure (matches the reference proxy) |
| `WARMUP` / `MEASURE` | 10s / 30s | per-ramp-step windows |
| `SAMPLE_PCT` | 5% | fraction of conns fully validated by the gate |
| `N` | 3 | repetitions per scored config; score = median |
| `EPSILON` | 1% | min improvement to promote a new champion |
| `PATIENCE` | 30 | configs without improvement before declaring plateau |
| `K` | 20 | treatment runs between control-drift watchdog checks |

## Why this converges to "the optimal architecture" without you choosing it

You never pick multishot vs SQPOLL vs registered-files. The agent tries them, the *scoring
function* — which is fixed, honest, and gate-protected — ranks them, and git keeps only what
wins. The plateau detector tells you when further search isn't paying off. The final REPORT.md
shows what architecture won and *why* (its syscall profile vs the control's), so you get not
just a faster binary but an explanation.

## What a human still does

- Stand up box 1 + box 2, the cgroups, IRQ pinning, the kernel/sysctl baseline (ENVIRONMENT.md).
- Write/verify the FIXED pieces once: control arm, loadgen, harness, scoring. The agent's
  honesty depends entirely on these being correct — they are the referee.
- Review `results/PROPOSALS.md` (where the agent flags fixed params it thinks are wrong).
- Read the final REPORT.md and decide whether to fold the winning ideas back into the production proxy.
