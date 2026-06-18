# The optimizer = `claude -p` (headless) in a bash loop

The "optimizer agent" from AGENT_LOOP.md is concretely **Claude Code in headless/print mode**
(`claude -p`), invoked once per iteration by a deterministic bash harness. Verified against the
`claude` binary on this box: **v2.1.181**. Flags below were confirmed present in `claude --help`
on that version — re-verify with `claude --help` if the binary is upgraded.

## Division of labor (do not blur this)

| Owner | Responsibility |
|-------|----------------|
| **bash harness** (FIXED) | build, pin to cpuset, run the ramp, score, run the correctness gate, capture exit code, **keep/revert via git + BEST.json**, flush buffered metrics to ClickHouse, rotate sessions, wall-clock-timeout the claude call. Deterministic; the model never touches this. |
| **`claude -p`** (the brain) | exactly two things: (1) *reason* over ClickHouse + `kbs/` + git history to form a hypothesis, (2) *edit `treatment/`* to implement it, write a kbs note, and commit. Then exit. |

`claude -p` is invoked **once per iteration** and does **one coherent mutation**. It does NOT
run the benchmark or decide keep/revert — those are the bash referee's job, so the model can't
argue its way to a win. (This matches the MEASURE-vs-ANALYTICS phase split in METRICS.md: the
claude call is the ANALYTICS phase; the benchmark is the MEASURE phase, with CH idle.)

## Autonomy: broad (isolated box)

The loop runs on a dedicated, isolated server, so the optimizer gets full autonomy:

```
--dangerously-skip-permissions
```

(Confirmed present on v2.1.181; the alias `--allow-dangerously-skip-permissions` also exists.
The "deprecated" claim some docs make is wrong for this version.) This skips all permission
prompts — essential, because any prompt **hangs an unattended loop**. Acceptable ONLY because
the box is isolated and disposable. If this ever moves to a shared box, switch to
`--permission-mode dontAsk` + an explicit `--allowedTools` allowlist instead.

> Even with full autonomy, the harness still protects itself structurally: `treatment/` is the
> only thing whose changes are *kept* (everything else the model touches is outside the scored
> path and gets reset between runs), and the keep/revert + scoring live in bash, not in the
> model's hands.

## Memory model: long session, rotate on context pressure, bootstrap from kbs + git

You chose: **continue one session across iterations until context grows too large, then start a
fresh session that re-bootstraps from a `kbs/` knowledge folder + git commit history.**

### Continue while it's cheap

```bash
# iteration 1 (fresh): capture the session id
out=$(claude -p "$PROMPT" --output-format json --dangerously-skip-permissions ...)
SID=$(echo "$out" | jq -r '.session_id')

# iterations 2..N (same session — model keeps its own reasoning in-context)
out=$(claude -p "$PROMPT" --resume "$SID" --output-format json --dangerously-skip-permissions ...)
```

`--resume <session_id>` (alias `-r`) continues a specific session; `--continue`/`-c` continues
the most recent. Both confirmed on v2.1.181, both require `--print`.

### Rotate when context crosses a threshold

After each call, read `usage.input_tokens` from the JSON result. When it crosses a threshold
(default **120k** tokens — tune to leave headroom under the model's window), **drop the session
id and start fresh next iteration.** The fresh session has no chat history, so it must rebuild
context from durable stores:

### The fresh-session bootstrap (the durable memory)

A fresh `claude -p` is told, in its prompt/system-prompt, to begin by ingesting:

1. **`kbs/` knowledge folder** — distilled, indexed lessons the agent has written over time
   ("multishot accept cut io_uring_enter/conn ~8x, +12% score"; "SQPOLL raised raw conn/s but
   LOWERED conn/s-per-core — avoid for this objective"). There's an index file (`kbs/INDEX.md`,
   one line per note) loaded first; the agent reads full notes on demand. This mirrors the
   house `kbs/` convention already used elsewhere in this workspace.
2. **git commit history of `treatment/`** — `git log` with the detailed messages (see below).
   Every mutation is a commit whose message records the hypothesis, the score delta, and the
   verdict. `git log --oneline` + reading specific commits reconstructs the optimization
   trajectory without any chat history.
3. **ClickHouse** — the numeric record (`acceptbench.runs/steps/samples`) for any quantitative
   question, queried directly.

So memory has three tiers: **chat session** (volatile, fast, rotated), **kbs/ + git**
(durable prose + decision lineage), **ClickHouse** (durable numbers). The session is a cache;
kbs/git/CH are the source of truth.

## Always commit everything, with detailed messages

Every iteration, after the model edits `treatment/` and writes its kbs note, the harness (or
the model, with `Bash` autonomy) commits **everything** — source change + kbs note — with a
structured message:

```
optimize: <one-line hypothesis>

Hypothesis: <what this change tested and why>
Change: <what was edited in treatment/>
Result: score <old> -> <new> (<+/-%>), ceiling=<queue|cpu>, gate=<pass|fail>
Syscalls/conn: io_uring_enter <old>-><new>, read <..>, write <..>
Verdict: <KEPT champion | REVERTED regression | REVERTED gate-fail>
kbs: <slug of the note written, if any>
runid: <harness runid, links to ClickHouse rows>
```

Because keep/revert is `git reset --hard` on regressions, the *kept* history is a clean chain of
improvements; but the harness also tags every attempt (even reverted ones) on a `attempts/`
ref namespace or an append-only `results/HISTORY.jsonl`, so nothing is truly lost — a reverted
idea is still readable, so the agent doesn't re-try it. The commit message detail is what lets a
fresh session reconstruct "what's been tried and what won" from `git log` alone.

## The verified invocation (v2.1.181)

```bash
out=$(timeout "${ITER_TIMEOUT:-900}" \
  claude -p "$(cat harness/optimizer-prompt.md)" \
    ${SID:+--resume "$SID"} \
    --model "${OPT_MODEL:-opus}" \
    --append-system-prompt-file harness/optimizer-system.md \
    --add-dir /root/accept-bench/treatment \
    --mcp-config harness/mcp-clickhouse.json \
    --dangerously-skip-permissions \
    --output-format json \
    2>>"$LOGDIR/claude-stderr.log")
rc=$?
```

Flag notes (all checked against this binary):
- `--print`/`-p`: prompt is the positional arg, or piped via stdin (stdin capped ~10MB).
- `--output-format json`: single JSON result. Parse `.result`, `.session_id`, `.usage`,
  `.total_cost_usd` with `python3` (jq is NOT installed on these nodes — use python). **Verify
  the exact field names on first run** (`claude -p hi --output-format json | python3 -m json.tool`)
  and pin them in the harness; don't trust documented schemas blindly across versions.
- `timeout <secs>`: the runaway guard. `--max-turns` was NOT visible in v2.1.181 `--help`, so
  **rely on the wall-clock `timeout` wrapper** (exit 124 = timed out) rather than a turn cap.
- `--add-dir`: lets tools touch `treatment/` (and is one of the few flags `--bare` keeps).
- `--mcp-config`: a local ClickHouse MCP server, so the agent queries CH via tools. The MCP
  server is stdio-based and its connection config (localhost CH) lives in the harness, not in
  anything the model edits.
- `--model opus`: alias resolves to the latest Opus. C-level perf reasoning + io_uring is hard;
  use Opus, not a smaller tier. `--fallback-model` is available if you want auto-failover.

## Exit-code handling in the loop

```bash
if [ $rc -eq 124 ]; then
  log "iteration timed out after ${ITER_TIMEOUT}s — treating as no-op, reverting"
  git -C treatment reset --hard HEAD
elif [ $rc -ne 0 ]; then
  log "claude -p failed (rc=$rc) — see claude-stderr.log; skipping iteration"
  git -C treatment reset --hard HEAD
fi
```

A timed-out or errored claude call is a **no-op iteration** (revert any partial edit, don't
score, move on) — never a crash of the loop. The loop must survive a bad model turn the same
way it survives a crashing treatment binary.

## What this gives you

You hand the box `claude -p`, a prompt file, the kbs/git/CH stores, and a bash referee. The
loop then runs unattended: reason → mutate → (bash) benchmark → score → keep/revert → commit →
write kbs → repeat, rotating the session when it gets heavy and rehydrating from durable memory.
No human in the inner loop; humans only read REPORT.md and PROPOSALS.md.
