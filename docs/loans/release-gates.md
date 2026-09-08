# Release gates — the current state of G1–G8

**This file is the single authority on gate state.** Where any other document,
issue or PR disagrees with it, this one is right and the other is stale.

It exists because they disagreed. On 2026-09-07 an independent review found
`methodology.md` saying daily accrual was off while the code had it on,
`contract-mutation-evidence.md` saying G1 approval was outstanding while #6
recorded it approved, and the delivery breakdown carrying every gate unchecked
and defining G2 more broadly than the scope that was actually signed. Three
documents, three different answers, one running codebase. A release decision
made from any of them would have been made from fiction.

Two rules follow from that, and they are the point of this page:

1. **Cite the artefact, not the intent** (process rule 3). Every state below
   names a commit, a file, a test or a dated issue comment. A row with no
   evidence column is not a gate state, it is a hope.
2. **A signed gate needs a durable record** (process rule 15). G2a was signed
   for two days while three documents said it was open, because its only trace
   was an issue closure with no comment.

`test/models/loan/release_gates_test.rb` asserts this file names G1–G8 exactly
once each, that every path it cites exists, and that no gate is recorded as met
without evidence.

---

## The matrix

| Gate | State | Owner | Evidence | Exclusions | Next action |
| --- | --- | --- | --- | --- | --- |
| **G1** — calculation contract approved, each row naming a test that exists **and fails when that behaviour changes** | **Approved** 2026-09-07 | repository owner, as owner and on behalf of engineering and product | [#6 sign-off](https://github.com/jaysbeekay/sure/issues/6#issuecomment-5566496633) covering `docs/loans/calculation-contract.md` at `1fb3f4e`; `docs/loans/contract-mutation-evidence.md` (16/16 rows, #71); `loans:verify_contract_coverage` runs on every PR | One mutation per row, not whole-row coverage. C16's forward-flat half is tested but not gate-verified, because `config/loan_contract_tests.yml` binds one test class per row | None. #6 closed 2026-09-08 |
| **G2a** — lender statement reconciliation, **non-offset** | **Signed** 2026-09-05 | repository owner | `docs/loans/methodology.md`; 43/43 charges under actual/actual (#65 → #70) | Gross monthly interest, **one lender, one loan**. Offset accrual explicitly excluded. Predates the per-loan basis #70 introduced and has not been re-run against it | None for G2a. Never report it as "G2 signed" unqualified |
| **G2b** — lender statement reconciliation, **offset** | **Open** | *unassigned* | none | — | Needs linked-account daily balance history, which a loan statement does not carry. Until it is signed, release reporting must say C15/C16 are specified and unit-tested but **not lender-reconciled** |
| **G3** — rebuild rehearsed on production-shaped data, rollback demonstrated | **Open** — code released, operation outstanding | repository owner | `docs/loans/release-evidence.md`: variance, rebuild rehearsal, lossless rollback round trip; CI performance gate (#72); daily accrual live since #73 (`SCHEDULE_DAILY_ACCRUAL = true`, `ALGORITHM_VERSION = 3`) | The CI benchmark measures **one** simulation and is a regression detector calibrated to the shared runner — it is not acceptance of #10's 4-simulation ≈50 ms SLO | (a) run the production prebuild, now resumable (#91/#93); (b) measure the 4-simulation SLO, which needs #20; (c) release approval. #10 stays open for all three |
| **G4** — offset privacy tested across link, grant, revoke and every output surface | **Partly evidenced** | *unassigned* | `test/models/loan_offset_account_test.rb` — link, sharing change, revoke, grant, stale link when a viewer loses access, and clearing on a non-variable transition; #87 made the validation actually block a save | The "every output surface" half is not demonstrated. The link-time invariant makes it *likely* the surfaces are safe; likely is not tested | Decide whether the link-time invariant plus revocation is the whole gate, or add per-surface coverage. Then sign, on #13 |
| **G5** — scenario authorisation and slot-cap concurrency tested | **Partly evidenced** | *unassigned* | `test/models/loan_scenario_concurrency_test.rb` — the slot cap is structural, a unique `(loan_id, slot)` index with bounded retry (#83) | Authorisation is untestable until the scenario UI exists; there is no controller to authorise against | #16 PR 7b, then sign |
| **G6** — payoff chart keyboard-operable with an accessible data alternative | **Not started** | *unassigned* | none | — | #57. Needs a person with a screen reader, a real transcript and a keyboard walkthrough — not a task |
| **G7** — API/CSV caching, sharing and versioning approved | **Not started** | *unassigned* | none | — | #23 |
| **G8** — scope, issue count, PR count and milestone exit criteria agree | **Not assessable** | *unassigned* | §17.7 traceability table: 42 rows covering all 45 distinct FR ids, no FR twice (FR-305–308 share one row) | Cannot be assessed while the epic body and the delivery breakdown disagree with the running code | Reassess once #24's body is rewritten against this file |

---

## What each gate is allowed to claim

**G1 is approved; it is not a claim of correctness.** It says every contract row
has a decision and a test that fails when that behaviour changes. A contract can
be internally consistent, fully mutation-verified, and wrong about what a lender
actually does.

**G2a is the oracle, and it is a small one.** One lender, one loan, gross
monthly interest. The characterisation suite is *not* an oracle — it pins current
behaviour, was re-baselined for daily accrual in #73, and will now preserve a new
defect just as faithfully as it preserved the old one.

**G3's code is released; G3 is not.** Daily accrual is live on `main` and changes
production figures. Reads enqueue rebuilds rather than performing them (#39), so
deploying without a controlled prebuild lets the estate restage itself through
the job queue on first view. The prebuild procedure — now cursor-based and
resumable — is in `docs/loans/release-evidence.md`, and
`loans:schedule_version_status` owns the completion decision.

**G4 and G5 are half-gates, and are recorded as half-gates.** Both have real
tests behind the part that is done. Neither is signed, and neither should be
reported as covered because the tests that exist are green.

---

## Where the other documents stand

| Document | Role | Relationship to this file |
| --- | --- | --- |
| `docs/loans/calculation-contract.md` | C1–C16, authoritative for individual financial decisions | Authoritative for the *contract*; this file is authoritative for G1's *state* |
| `docs/loans/methodology.md` | how the reconciliation was run, and the G2a/G2b split | Authoritative for reconciliation method; gate state here |
| `docs/loans/release-evidence.md` | the runbook: rehearsal, rollback, prebuild procedure, monitoring | Authoritative for *how to run the release*; gate state here |
| `docs/loans/contract-mutation-evidence.md` | the per-row mutation transcript for G1 | Authoritative for the transcript; gate state here |
| `docs/plans/loan-amortisation-delivery-breakdown.md` | the delivery plan **as written on 2026-09-04** | Historical. Its gate checklist is inside a fenced block reproducing the epic's as-filed body and is **not maintained** |
| `docs/plans/loan-amortisation-modelling.md` | the design blueprint | Historical for status, current for design and the §17.7 traceability table |
| `docs/plans/loan-amortisation-implementation-plan.md` | superseded | **Retired.** Referenced only by this row and by its own retirement note; kept as a record of an earlier plan |

---

*Last verified against `main` on 2026-09-08. When you change a gate's state,
change it here first, and change it in the same PR as the work that moved it —
process rule 10.*
