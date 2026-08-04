# e2e-review results

Per-session outputs are written by each review session to the **shared host mount**
`~/cco-e2e-review/S<N>-<slug>.md` (via `--mount ~/cco-e2e-review:/review:rw`), one
file per section of [`../handoff.md`](../handoff.md) (1:1).

When all sessions have run, the raw `S*.md` files are gathered here (committed
alongside this README) and distilled into a single consolidated review + fix design
(`consolidated-review.md`), following [`../handoff.md`](../handoff.md) §7. That
consolidated document is the input to the maintainer HITL review and the subsequent
fix workstream.

Sessions: S1 read-project/min · S2 read-project/rich · S3 read-global/rich ·
S4 none/mid · S5 edit-project/min · S6 config-editor broad · S7 config-editor
--project · S8 tutorial.
