# batched submit/harvest loop

Hypothesis: the milestone-0 loop paid ~one `io_uring_enter` per CQE — it called
`io_uring_submit` after every completion and `io_uring_wait_cqe` for one CQE at a time,
so the 4 CQEs/conn (accept/recv/send/close) cost ~3.76 enters/conn.

Change: replace the per-CQE submit+wait with a single `io_uring_submit_and_wait(ring, 1)`
per loop (flushes all queued SQEs and blocks for completions in ONE enter), then drain the
whole batch via `io_uring_peek_batch_cqe` + `io_uring_cq_advance`.

Expected: enters/conn drops from 3.76 toward 1–2 as multiple CQEs are harvested and SQEs
flushed per syscall, raising conn/s-per-core. Measured effect: TBD by harness.
