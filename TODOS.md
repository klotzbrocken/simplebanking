# TODOS

Deferred work captured during engineering and product reviews. Each item includes
enough context to pick up in 3+ months without losing the reasoning.

---

## TODO: Index-based internal transfer detection

**What:** Replace the row-cap O(n²) scan with a DB-indexed approach for detecting
internal transfers between own accounts.

**Why:** The current plan caps the scan at min(30 days, 1,000 rows) to bound runtime.
This silently misses bi-monthly or quarterly transfers (rent deposits, quarterly tax
payments) outside the 30-day window. A DB index on `(slot_id, betrag, buchungsdatum)`
combined with a counterpartyIBAN lookup eliminates the false-negative window entirely
and makes the query O(1) per candidate instead of O(n).

**Current state:** Unified Inbox ships with the 30-day/1,000-row cap. The bound is
documented in code with a comment. Tagging is non-destructive.

**Pros:** Correct for all date ranges; scales to any transaction volume.

**Cons:** Requires a DB migration (v10) to add the composite index; slight schema
coupling between IBAN and transfer detection logic.

**How to start:** Add `CREATE INDEX IF NOT EXISTS idx_tx_transfer ON transactions
(betrag, buchungsdatum, slot_id)` in a v10 migration. Rewrite `detectInternalTransfers`
to use a GRDB join instead of in-memory comparison. Remove the 30/1,000 cap comment.

**Depends on:** Unified inbox core shipped.

---

## TODO: Cross-account analytics and budgeting

**What:** Cross-account spending analytics: "you spent €800 more this month than last,
mostly at Sparkasse." Net savings ring across all accounts. Income cluster detection
("income cluster on the 1st and 15th"). Category breakdown per bank.

**Why:** Transforms simplebanking from a balance viewer into a financial intelligence
tool. The unified inbox gives users the data — analytics gives them the insight.
All transaction data is already in the DB after unified inbox ships.

**Current state:** Not started. Unified inbox is the required foundation.

**Pros:** High user value; no new data collection required (data is already local);
fits the macOS menu bar app format (summary view in flyout).

**Cons:** Significant product scope — needs its own design session (/office-hours)
before engineering. Category and merchant data quality matters a lot for analytics
accuracy.

**How to start:** Run /office-hours on "cross-account analytics for simplebanking."
Key questions: what's the primary metric (net savings? spending delta? category totals)?
What's the UI surface (flyout extension? separate panel? weekly digest notification)?

**Depends on:** Unified inbox core shipped.
