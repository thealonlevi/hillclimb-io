# Token efficiency for the `claude -p` optimizer loop

This loop runs unattended for days across thousands of iterations. Tokens are the budget that
decides how long it survives. The single biggest cost driver in agentic loops is **re-sent
context** — research puts it at ~62% of the bill — because every reasoning step re-sends the
accumulated context on each tool call. Everything below targets that.

Two findings dominate the design and are specific to THIS loop's shape:

## 1. The prompt-cache TTL trap (the #1 thing to get right)

Anthropic's default prompt-cache TTL was dropped from **1 hour → 5 minutes**. Our loop's
iterations are **minutes apart** — each `claude -p` call is separated by a full benchmark run
(ramp × N reps = minutes of wall clock with CH/claude idle). So with the default 5-minute TTL,
**the cache is cold by the time the next iteration starts** → every iteration pays full
input-token price on the system prompt + instructions instead of the ~90% cache-read discount.

The quoted worst case: a 10K-token system prompt at 100 calls/hour costs **~$15/month with the
1-hour TTL vs ~$1,500/month with the 5-minute default** — a 100x regression. Our system prompt
+ optimizer instructions + kbs index can easily be 10K+ tokens.

**Mitigation (do all three):**
- **Set the 1-hour cache TTL explicitly.** In API terms it's
  `"cache_control": {"type": "ephemeral", "ttl": 3600}` on the cached blocks. With `claude -p`
  this is governed by the model/SDK config; if the headless path doesn't expose a 1h-TTL knob,
  drive the loop through the **Agent SDK / Messages API directly** for the caching control (see
  "Build path" below) rather than accepting the 5-minute default. This is the one place where a
  thin SDK wrapper around `claude -p`'s behavior may be worth it.
- **Keep the cached prefix STABLE and put it FIRST.** Cache only the truly static blocks:
  system prompt, optimizer instructions, the kbs INDEX, the fixed contract docs. Put all
  volatile content (this run's metrics, the latest git log, the current hypothesis) AFTER the
  cache breakpoint. "Cache only system prompts, exclude dynamic tool results" is the documented
  best practice — naive full-context caching is worse than targeted caching.
- **Don't let the stable prefix churn.** Every edit to the system prompt / instructions
  invalidates the cache for all subsequent runs. Freeze those files; iterate the *prompt's
  dynamic tail*, not its head.

> If you cannot get a cache hit across the minutes-long gap no matter what, the fallback is to
> **shorten the gap** — but NOT by running CH/claude during MEASURE (that violates the metrics
> isolation). Instead, batch: have one `claude -p` call reason about several candidate mutations
> back-to-back while the cache is warm, queue them, then let bash benchmark them in series. This
> trades a little parallelism-of-thought for cache locality. Decide empirically.

## 2. graphify — pre-built code map at ZERO API cost

`graphify` (already used across this workspace — see `~/dev/*/graphify-out/`) builds a
symbol/dependency/community graph of a codebase and emits `GRAPH_REPORT.md` + `graph.json`.
The report literally states **"Token cost: 0 input · 0 output"** — it's a local static analysis,
not an LLM pass. `graphify update .` refreshes it incrementally after code changes, also at no
API cost.

**Why this matters here:** without it, every iteration the optimizer would burn tokens
re-exploring `treatment/` with grep/read to remember its own structure. Instead:
- Run `graphify` on `treatment/` once; `graphify update .` after each kept mutation (cheap, no
  API cost) so the map stays fresh.
- Feed the optimizer the compact `GRAPH_REPORT.md` (symbols, communities, hot paths) as its map
  of `treatment/`, so it navigates by reading a few-KB summary instead of reading whole source
  files to orient. It reads full source only for the specific function it's about to edit.
- This is the read-side analogue of the cache lever: graphify cuts the *exploration* tokens,
  caching cuts the *re-sent instruction* tokens.

## The rest of the levers (apply all)

### Scope each iteration to a binary, observable success condition
The cheapest loop is a well-scoped one. Each `claude -p` call has ONE job: "form one hypothesis,
make one focused edit to `treatment/`, write a kbs note, commit." Success is observable and
binary downstream (the harness scores it). The model is NOT asked to "optimize the proxy" —
that's an unbounded prompt that invites token-burning wandering. (Matches the "one coherent
mutation per run" rule already in AGENT_LOOP.md.)

### Keep the cached instruction set small and stable
A 5,000-token instruction file costs 5,000 tokens *every* call. Keep `optimizer-system.md` +
`optimizer-prompt.md` lean (target < 200 lines combined of real content). Put architecture/
constraints there once; don't restate them in the per-iteration prompt. The kbs INDEX (one line
per note) is loaded; full kbs notes are read on demand, not always.

### `.claudeignore` the heavy artifacts
`claude -p` will otherwise glob/read large files during tool searches. Add a `.claudeignore`
(gitignore semantics) in `treatment/`'s dir excluding: build outputs, `graph.json` (3MB — the
optimizer reads `GRAPH_REPORT.md`, never the raw json), `results/samples` dumps, core dumps,
loadgen pcaps. Keep the model's filesystem view to source + the small reports.

### Model tiering — Opus only where reasoning is hard
Per-iteration cost drops 60–80% with tiering. But our objective is HARD (io_uring/C perf), so:
- **Opus** for the reasoning+edit step (the actual optimization).
- **Haiku/Sonnet** for any mechanical sub-step that doesn't need deep reasoning: summarizing a
  run's metrics into a kbs note, generating the structured commit message, classifying "did
  this run's syscall profile change meaningfully." Route these to a cheap model via a separate
  short `claude -p --model haiku` call (or do them in plain bash/python with no model at all —
  cheapest of all; a commit message from a template needs no LLM).
> Prefer **no model** over a cheap model wherever the step is deterministic. The structured
> commit message, the HISTORY.jsonl append, the BEST.json update, the graphify refresh — all
> pure bash/python. Spend tokens only on genuine reasoning.

### Session rotation already bounds context growth
The continued-session-until-threshold model (OPTIMIZER_HEADLESS.md) is itself a token control:
it caps how large the re-sent context can grow before a fresh, lean session restarts from
kbs/git/CH. Set the rotation threshold with cost in mind — a session at 120K input tokens
re-sends 120K every turn. Rotating earlier (e.g. 60–80K) may net cheaper than riding a huge
context, even counting the rehydration cost. Tune from the recorded `usage.input_tokens` and
`total_cost_usd` per run (we already capture both).

### Cap thinking and turns; wall-clock timeout
- Bound reasoning effort: don't let the model spend unbounded extended-thinking tokens per
  iteration. Use a conservative thinking budget; raise only if data shows it's needed.
- `timeout <secs> claude -p …` (the runaway guard from OPTIMIZER_HEADLESS.md) also caps token
  spend per iteration — a wedged call can't run up an unbounded bill.

### Track spend as a first-class metric
We already capture `usage` + `total_cost_usd` from the JSON result. Write these into
`acceptbench.runs` (add columns `input_tokens`, `output_tokens`, `cache_read_tokens`,
`cache_write_tokens`, `cost_usd`). Then the optimizer's OWN efficiency is queryable: cost per
score-point gained, cache-hit ratio over time, tokens per kept improvement. A loop that can see
its own token economics can be tuned against it — and you'll spot the day the cache TTL silently
regresses again (cache_read drops to ~0, cost spikes).

## Build path note (caching + claude -p)

`claude -p`'s headless caching behavior may not expose the explicit 1-hour TTL knob. Two options:
- **Stay on `claude -p`** and verify empirically whether cross-iteration cache hits occur
  (watch `cache_read_input_tokens` in the JSON result across iterations). If they're ~0, the
  5-minute TTL is biting.
- **Drive the loop via the Agent SDK / Messages API** for explicit `cache_control` with
  `ttl: 3600` on the stable prefix, reproducing `claude -p`'s tool-use behavior. More code, but
  full control over the single biggest cost lever. Decide after measuring option 1.

This is the one open implementation question worth resolving with a measurement before
committing — it's a 100x cost swing.

## Updates to other docs
- METRICS.md `acceptbench.runs`: add the token/cost columns above.
- OPTIMIZER_HEADLESS.md: the stable system/instruction files are the cached prefix — freeze them.
- AGENT_LOOP.md: graphify refresh (`graphify update .`) is a deterministic post-keep step (bash),
  not a model action.

## Sources
- [Token Optimization: Stop the $1,600 Bill (2026)](https://buildtolaunch.substack.com/p/claude-code-token-optimization)
- [AI Agents Burn 50x More Tokens Than Chats — LeanOps](https://leanopstech.com/blog/agentic-ai-cost-runaway-token-budget-2026/)
- [Anthropic dropped prompt cache TTL 1h→5min — DEV](https://dev.to/whoffagents/anthropic-silently-dropped-prompt-cache-ttl-from-1-hour-to-5-minutes-16ao)
- [Anthropic Prompt Caching in 2026: Cost, TTL, Latency](https://aicheckerhub.com/anthropic-prompt-caching-2026-cost-latency-guide)
- [How to Build an Agentic Loop with Claude Code — MindStudio](https://www.mindstudio.ai/blog/how-to-build-agentic-loop-claude-code)
- [7 Practical Ways to Reduce Claude Code Token Usage — KDnuggets](https://www.kdnuggets.com/7-practical-ways-to-reduce-claude-code-token-usage)
- [Manage costs effectively — Claude Code Docs](https://code.claude.com/docs/en/costs)
