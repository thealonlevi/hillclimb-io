# Treatment arm (port 31) — C + liburing, the optimizer's playground

This is the ONLY code the optimizer agent edits. It must satisfy the behavioral contract and
pass the correctness gate; everything else about its internals is free.

## Hard requirements (the agent must never break these)

1. Listen on `:31` on the SUT box's chosen interface.
2. Per connection (observed externally): accept → consume the request bytes → write
   `REPLY_BYTES` (`HTTP/1.1 200 OK\r\n\r\n`, 19 bytes) in full → close. One reply per
   connection, then close (no keep-alive in v1).
3. Confine itself to the `CORES` pinned cpus (the harness enforces via cpuset, but the program
   should create no more worker threads than fits the budget, or it just thrashes).
4. Build with a single command the harness runs: `make -C treatment` ⇒ produces
   `treatment/accept-treat`. The agent may change the Makefile and add source files.
5. Come up and pass a 100-conn smoke test within 20s of launch.
6. Bind only :31 and reply to box 2 — no other network egress (harness firewalls this).

## The starting point (milestone 0 — a deliberately simple, correct baseline)

The agent does NOT start from a blank file. Ship a **known-correct, unoptimized** liburing
implementation so the loop has a working floor to improve from and a reference for "still
correct." Suggested milestone-0 (the agent will rewrite it):

- one `io_uring` per worker thread, one worker thread per pinned core
- `SO_REUSEPORT` listen socket per worker (kernel load-balances accepts across them)
- classic re-armed `IORING_OP_ACCEPT` (submit one accept; on completion, handle conn + re-arm)
- per-connection state machine: ACCEPT → READ → WRITE → CLOSE, driven by CQEs
- plain (unregistered) buffers and files

This is intentionally *not* the optimum — it's the correct, legible baseline the agent
mutates away from.

## The design space the agent is invited to explore

(Non-exhaustive — the agent may invent beyond this. Each idea is a hypothesis to test against
the score, not a prescription.)

- **Multishot accept** (`IORING_ACCEPT_MULTISHOT`): one SQE yields many accept CQEs ⇒ far
  fewer submissions.
- **SQPOLL**: kernel thread polls the SQ ⇒ steady-state `io_uring_enter` count → ~0, at the
  cost of a dedicated poller core (which counts against CORES — interesting tradeoff for the
  per-core objective).
- **Registered files / direct descriptors**: skip fd table lookups; accept directly into the
  ring's descriptor table.
- **Registered / ring-mapped buffers** (`IORING_OP_PROVIDE_BUFFERS`, ring buffers): avoid
  per-op buffer setup for the fixed reply.
- **SQE linking** (`IOSQE_IO_LINK`): chain read→write→close so one submission drives the whole
  tail of a connection.
- **Batched CQE harvest** and batched submit (`io_uring_submit_and_wait` with batch counts).
- **Fixed/registered reply buffer**: the 19 reply bytes are constant — register once, reuse.
- **`MSG_WAITALL`/`send`-zc / zero-copy** for the reply (probably noise at 19 bytes, but the
  agent may test it).
- **NAPI busy-poll** (`io_uring` NAPI, `SO_BUSY_POLL`): trade CPU for latency at the accept edge.
- **reuseport CBPF steering** to pin a flow to the core that will handle it (cache locality).
- **memory layout**: per-core conn pools, cache-line-aligned hot structs, no cross-core sharing.
- **kernel version sensitivity**: newer io_uring opcodes (multishot recv, etc.) — record the
  kernel in the fingerprint; an opcode that needs a newer kernel must degrade gracefully.

## What "passing the gate" forces the agent to keep honest

The correctness gate (HARNESS.md) means a config that, say, accepts in multishot but drops the
read or sends a truncated reply will score **0** even if its raw accept rate looks huge. The
agent learns that efficiency only counts when the full contract is served.

## Treatment is a git repo

`treatment/` is initialized as its own git repo. Every mutation the agent benchmarks is a
commit. The AGENT_LOOP promotes a commit to BEST only on improvement and `git reset --hard`s a
regression. This gives a complete, bisectable history of the optimization and a guaranteed
rollback to the last-known-best at any time.
