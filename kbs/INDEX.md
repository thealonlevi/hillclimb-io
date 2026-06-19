# kbs index — distilled optimization lessons

One line per note. The optimizer (claude -p) reads this first on a fresh session, then reads
full notes on demand. Each note is a single durable lesson learned across iterations.

Format: - [slug](slug.md) — one-line takeaway (hypothesis → measured effect on conn/s-per-core)

- [batched-submit-harvest](batched-submit-harvest.md) — replace per-CQE submit+wait_cqe with one submit_and_wait + peek_batch_cqe drain per loop → fewer io_uring_enter/conn (3.76 → ~1-2 expected)
