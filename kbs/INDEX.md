# kbs index — distilled optimization lessons

One line per note. The optimizer (claude -p) reads this first on a fresh session, then reads
full notes on demand. Each note is a single durable lesson learned across iterations.

Format: - [slug](slug.md) — one-line takeaway (hypothesis → measured effect on conn/s-per-core)

- [batched-submit-harvest](batched-submit-harvest.md) — replace per-CQE submit+wait_cqe with one submit_and_wait + peek_batch_cqe drain per loop → fewer io_uring_enter/conn (3.76 → ~1-2 expected)
- [linked-reply-chain-regressed](linked-reply-chain-regressed.md) — IO_LINK recv→send→close + CQE_SKIP_SUCCESS cut enter_pc 1.896→1.402 but score FELL 29292→19376 (reverted): minimizing enters is not the lever; chain serialization costs more
- [defer-taskrun-single-issuer](defer-taskrun-single-issuer.md) — SINGLE_ISSUER|DEFER_TASKRUN → WON 29292→36079. CHAMPION. Lever is kernel CPU/op.
- [exploit-best-arm](exploit-best-arm.md) — 16 iters, exploration exhausted: per-conn syscalls already minimal (~2.5 enter, 0 read/write). direct-desc@4096 = best arm (champion-level, draws 36136/36048/27217; only one to exceed champion). ~30% noise PROVEN; harness/EPSILON is the constraint, not code. See results/PROPOSALS.md.
- [liburing-older-than-kernel](liburing-older-than-kernel.md) — NO_SQARRAY won't build (liburing headers older than 6.8 kernel); grep liburing headers before proposing new flags/ops.
