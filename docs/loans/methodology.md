# Loan reconciliation methodology

**Gate state lives in `docs/loans/release-gates.md`.** This page is the method:
how the reconciliation was run, against what, and what it does not cover.

Status: **G2a signed (non-offset scope). G2b — offset reconciliation — OPEN.**

Never report this as "G2 signed" unqualified. That is the overstatement the
split below exists to prevent.

The delivery breakdown defines G2 as reconciliation "including rate-change and
**offset** cases". The signature below covers gross monthly interest with no
independent offset check. Those are not the same thing.

**Where offset-aware accrual actually runs.** Daily accrual is live on `main`
for both paths, but only `Loan::PayoffProjection` passes `offset_for` to the
simulator. `AmortizationSchedule#generate_simulation` -- the persisted,
contracted schedule users read in the table -- does not, so linked offsets do
not move those rows. That is consistent with invariant A7 (the contracted
schedule never tracks the live balance), but it has not been stated anywhere and
it changes what G2b would have to cover. Recorded here rather than asserted
either way; whether the contracted schedule *should* be offset-aware is an open
question, not something this document settles.

This section states the split rather than reporting a fully satisfied gate,
because "G2 signed" on its own would let release reporting claim evidence for
offset-enabled loans that does not exist.

| | G2a — non-offset reconciliation | G2b — offset reconciliation |
| --- | --- | --- |
| State | **Signed** | **Open** |
| Scope | gross monthly interest, one lender, one loan, 43/43 under actual/actual | daily offset-aware accrual against a real statement |
| Evidence | #65, summarised below | none (the #409 method, task and synthetic oracle are tooling, not evidence) |
| Blocked on | — | the owner's statement and linked-account daily balance history, which loan statements do not carry |
| Owner | repository owner | repository owner (holds the data) |

**For release reporting:** contract rows **C15 and C16 are specified and
unit-tested but not lender-reconciled.** Any statement that G2 is met must name
G2a, not G2 unqualified.

| | |
| --- | --- |
| Signed by | Jonathan Kaiser (`jaysbeekay`), repository owner |
| Signed | 2026-09-05, by closing #11 |
| Recorded here | 2026-09-07, on the owner's confirmation that the closure was the sign-off |
| Basis | the real statement reconciliation in #65, summarised below |

The two dates are separate on purpose: the gate was signed on the first and only
became legible on the second. A gate with no durable record is not a gate, and
this one was previously inferable only from an issue closure with no closing
comment, and #11's last comment said the opposite.

**What the signature covers:** gross monthly interest for one lender and one
loan, reconciled 43/43 under actual/actual.

**What it does not cover, and was signed in the knowledge of:**

- **Offset accrual is unproven.** The offset side was reconstructed from the
  lender's own disclosed saving, not checked independently, because the
  statements carry no daily offset balances.
- **One lender, one loan.** Nothing here establishes a basis as correct for any
  other lender.
- **The reconciliation predates the per-loan basis** (`day_count_convention`,
  #70) and has not been re-run against it.
- **Other lenders and other loans.** The reconciliation is a single data point.
  It supports "a fixed basis cannot be assumed"; it cannot support "actual/actual
  is right for anyone else".

The remaining items below are therefore no longer gate blockers. They are open
work, and the last one should land before daily accrual reaches users.

## Why the fixture is synthetic

A lender statement is personal financial data. So is anything derived from one:
drawdown amounts, running balances, charge dates and rate history together
identify a borrower even with names, account numbers and BSBs removed. None of
it belongs in this repository, which is a public fork.

`test/fixtures/loan_reconciliation.csv` is therefore constructed, not observed.
It reproduces the *shape* of a home-loan statement — drawdown, monthly interest
charges, extra repayments between charges, and one rate change falling
mid-cycle — with arithmetic that is exact by construction:

- every movement sums to the stated running balance;
- every rate movement is declared by a `rate_change` row;
- each interest charge is the piecewise actual/365 accrual over the balance and
  rate segments in its own window, rounded once at the charge point.

`test/models/loan/reconciliation_test.rb` asserts all three, plus a structural
de-identification guard: the file may contain only ISO dates, the four known
category tokens, and two-decimal numerics. The guard is an allowlist because a
denylist of names would have to write those names into the test.

**The fixture is also reconciled against the engine.** Every `interest` row is
charged through `Loan::InterestAccrual` over the window since the previous
charge, with the fixture's own movements walked into a change-point list. The
windows, segments and expected values all come from the fixture, so the test
fails if the engine's segmentation, day count, effective-date inclusivity or
charge-point rounding changes. Observed failing against two deliberate
mutations:

| mutation | expected | produced |
| --- | --- | --- |
| `DAY_COUNT` 365 → 360 | 1695.34 | 1718.89 |
| rate change applied from the window start rather than its effective date | 1694.87 | 1826.40 |

The second is the C7 defect this programme was already carrying, and the fixture
catches it. This is repository evidence, not lender evidence — it does not
discharge G2.

## Real statement reconciliation (#65)

A real lender statement has been reconciled against `Loan::InterestAccrual`,
following the procedure below. Per the de-identification rule, no amounts,
dates, balances or rates from the source appear here.

| basis | charges reconciling within one cent |
| --- | --- |
| fixed `DAY_COUNT = 365` | 30 / 43 |
| actual/actual | **43 / 43** |

43 consecutive monthly interest charges were compared. Every window falling
wholly within a leap year was overstated by the same relative amount, 2740 ppm,
which is exactly `366/365 - 1`; the two windows straddling a year boundary were
overstated by intermediate amounts and also resolved exactly under
actual/actual. That pattern is what excludes coincidence. Under actual/actual
the median residual is zero and the maximum is one cent, consistent with a
single rounding at the charge point.

**What this establishes:** a single hardcoded day-count basis cannot be assumed.
That finding is why the basis is now a per-loan property rather than a constant
(contract row C2, landed in #70) instead of the constant being quietly retuned
to fit one statement, which #11 explicitly forbids.

**What it does not establish:** that actual/actual is correct for any other
lender. This is one lender and one loan. It also verified **gross** interest
only — reconstructed as the charge plus the lender's own disclosed offset
saving, which is the lender's figure and not an independent check — so offset
accrual remains unproven.

## Running the real reconciliation

The real statement work happens **outside the repository**, and only its
findings come back:

1. Hold the statements and any normalised export outside the working tree, and
   outside any directory that is committed, indexed or backed up to a shared
   service.
2. Reconcile each interest charge against `Loan::InterestAccrual` over the
   charge window, using the balance and rate segments that actually applied.
3. Record, in this document: the number of charges compared, the residual
   distribution, and a stated reason for every non-zero residual. Record no
   amounts, dates, balances or rates from the source.
4. Where a residual is explained by an offset balance, say so and mark it
   unproven rather than tolerated — an offset saving quoted by the lender is
   the lender's own figure, not an independent check of ours.

## Running the offset reconciliation (G2b, #409)

G2b needs two things only the borrower holds: a lender statement covering at
least six interest charges on one offset-linked loan, and the **end-of-day
balance of every linked offset account** over the same period (the offset
accounts' own statements carry these; the loan statement does not). Nothing
from either enters the repository.

1. **Normalise, outside the working tree,** into one CSV in date order:

   ```
   date,category,amount,balance,annual_rate,offset
   ```

   `balance` is the loan's running balance after the row, negative while owed;
   `annual_rate` the rate in force after it; `offset` the linked accounts'
   combined end-of-day total in force after it. Categories: `loan_disbursal`
   (first row), `repayment` and `fee` (signed as the statement signs them),
   `interest` (closes a charge window; `amount` is the charge), `rate_change`
   (`amount` is the new rate) and `offset_balance` (`amount` is the new offset
   total, one row per day the total changes). Every change is effective from
   its own date: a day's interest is charged on that day's end-of-day balance
   less that day's end-of-day offset.
2. **Run** it with the loan's basis, which the statement should confirm rather
   than assume:

   ```
   bin/rails 'loans:reconcile_statement[/path/outside/the/repository.csv,actual_365]'
   ```

   The task refuses a path inside the repository. It first checks the
   statement's own arithmetic (every movement sums to the running balance;
   every rate and offset move is declared by its row) and reconciles nothing if
   that fails, listing row numbers only. It then charges every window through
   `Loan::InterestAccrual` and prints counts: exact, within one cent, the
   largest deviation and the basis. `VERBOSE=1` adds each charge's date and
   figures for investigating a residual locally; that output **is** the
   statement and goes nowhere.
3. **Record here and in the G2b row of `release-gates.md`** only what the
   summary carries: n/m charges matched, the largest deviation, the basis, the
   number of lenders, loans and linked accounts, and what was excluded, with a
   stated reason for every residual. No amounts, dates, balances or rates.
4. **If charges disagree,** the fix belongs in `Loan::InterestAccrual`,
   `Loan::OffsetResolver` or, after #405, `Loan::DailyInterest`, under its own
   bug issue. G2b is not signed against a known disagreement.

**Which path this reconciles.** `Loan::StatementReconciliation` hands each
window's balance, rate and offset change points to `Loan::InterestAccrual`, the
call every offset-reduced charge ends in: on `main` through
`Loan::PayoffProjection` and the simulator's daily accrual, and after #405
through `Loan::DailyInterest`, which assembles the same change points and makes
the same call. The offsets themselves reach production through
`Loan::OffsetResolver`, from stored daily balances; the synthetic oracle below
reconciles that path too. It does **not** cover the forward-flat projection
(C16's second half), which no statement can show.

**The synthetic oracle.** `test/fixtures/loan_offset_reconciliation.csv` has
G2b's shape and is synthetic, for the reason the G2a fixture is: drawdown,
repayments, a fee, a mid-window rate change, three charges, and daily offset
totals including a day the offset exceeds the balance (C15) and changes on two
windows' first days (C16), plus an offset move on the same day as a repayment.
Its charges were computed by a day-by-day loop over the formula below,
independently of the engine, and rounded once.
`test/models/loan/offset_reconciliation_test.rb` reconciles every charge
through `Loan::StatementReconciliation`, and again with the offsets read from
stored balances through `Loan::OffsetResolver`. It also checks the fixture's own
arithmetic and a de-identification allowlist (ISO dates, six category tokens,
two-decimal numerics). Observed failing under deliberate mutations, each
restored afterwards:

| mutation | charges expected | produced |
| --- | --- | --- |
| C15: offset floor removed, so an offset above the balance accrues negative interest | 237.90, 93.68, 246.70 | 237.90, **89.55**, 246.70 |
| C16: a change on a window's first day ignored | 237.90, 93.68, 246.70 | **263.97, 232.28, 284.20** |
| `Loan::OffsetResolver` keeps a day's first stored balance, not its end-of-day one | — | the stored-balance test fails |
| the reconciler drops the offset a window opens on, or stops merging same-day changes | — | the oracle test fails |

This is repository evidence, not lender evidence. It shows the method and the
engine agree on a statement of this shape; it does not sign G2b.

## Independent reference

The fixed / no-offset reference is written from the formula, independently of
the simulator:

    interest = days × max(0, balance − offset) × annual_rate / 100 / 365

Interest accumulates at full precision and is rounded once at the charge point.
`Loan::ReconciliationTest`, in "independent actual/365 reference agrees with
Loan::InterestAccrual", compares that reference to the engine. A reference
calculation that is never compared to the implementation demonstrates nothing,
so the comparison — not the formula — is the evidence.

## Outstanding after sign-off

G2a is signed (above), so none of these block that gate. G2b remains open and
the offset item below is part of it.

> **Correction, 2026-09-07.** An earlier revision of this section claimed the C2
> day-count disclosure was unbuilt and named it the item to land before daily
> accrual reaches users. That was wrong: it shipped with #70. The claim came
> from grepping a branch seven commits behind `main`, which predated #70, and
> reporting the absence as a fact about the codebase. Recorded here because the
> claim reached this document, `calculation-contract.md`, issue #11 and PR #73
> before it was caught.

- **Re-run the reconciliation against the per-loan basis.** The #65 run predates
  `loans.day_count_convention` (#70). It reconciled the engine against a fixed
  basis chosen by hand; it has not been re-run against the representation the
  code now actually uses. This is the last unchecked box on #65.
- ~~Disclose the basis in the UI.~~ **Already done, in #70.** The schedule tab
  carries a `day_count_notice` naming the basis in force and stating that a
  lender mismatch makes the figures an approximation; the loan form carries the
  selector and an explanatory hint. Covered by
  `test/controllers/accounts_controller_test.rb`, which asserts the notice
  changes with the loan's basis and that the old basis no longer appears.
- **Offset movement.** Daily offset reconciliation needs the linked account's
  balance history, which the statements do not carry — they report the lender's
  own offset saving, not daily balances. The sign-off above therefore excluded
  offset cases rather than tolerating them within its scope, and says so in
  those words. Reconciling them needs that balance history.
- ~~**Mid-cycle rate changes on the path users read.**~~ **Resolved 2026-09-07.**
  An earlier revision of this bullet said `SCHEDULE_DAILY_ACCRUAL` is `false` on
  `main` and that enabling it awaited a merge decision. Both statements were
  true when written and are now false: #73 set it to `true` with
  `ALGORITHM_VERSION = 3`, so the persisted schedule uses the daily path and
  production accrues daily.

  **What this changes about the reconciliation above:** it no longer exercises
  code users' numbers do not come from — the reverse of the previous caveat.
  What it does *not* change is the scope of the signature: the #65 run was
  performed against gross monthly interest for one lender, and enabling daily
  accrual does not extend that evidence to offset cases.

  **Operationally outstanding:** the production prebuild has not been run. Until
  it is, reads enqueue rebuilds rather than performing them, so the estate
  restages through the job queue on first view. See the deployment ordering in
  `release-evidence.md`.
- **Independent finance review.** The sign-off above is the repository owner's,
  who is also the borrower whose statement was reconciled. That is a legitimate
  decision for a self-hosted project and it is what was given; it is not the
  same as an independent reviewer, and this document should not be read as
  claiming one.
- **Which basis a loan uses is now the borrower's assertion** (#65). The
  reconciliation that motivated it covers one lender and one loan: 43/43 charges
  resolve under actual/actual against 30/43 under a fixed 365, with every
  wholly-within-a-leap-year window wrong by exactly 366/365 − 1. That is
  evidence a single fixed constant cannot be assumed, not evidence that
  actual/actual is correct for any other lender. The default stays actual/365.
  The contract (C2) says the schedule discloses the basis in force rather than
  implying it is verified. That disclosure **shipped in #70** and this row is
  satisfied end to end.

  > **Correction, 2026-09-07.** This sentence previously read "specified but not
  > yet built", contradicting the bullet above it in this same document, which
  > was corrected earlier the same day. One correction was applied and its
  > duplicate three paragraphs below was missed. Recorded rather than quietly
  > edited, because a gate document disagreeing with itself is the failure this
  > file exists to prevent.

No production release approval is granted by this document.
