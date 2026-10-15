<!--
  NORMATIVE DELIVERY PLAN for the Zero-Based Budgeting epic (#465).

  This is the work management plan: how the epic's feature list becomes
  milestones, issues, and pull requests. The epic issue is the feature
  blueprint; this document is where the work is structured and ordered.
-->

# Zero-Based Budgeting — Delivery Breakdown

Companion to the epic issue [#465](https://github.com/jaysbeekay/sure/issues/465).
That document is the **feature blueprint** (a Zerosum comparison with 17 candidate
features). This one is the **work management plan**: how those features become the
milestones, issues, and pull requests below — including the decisions that must be
recorded before any allocation code changes.

> **This document is the plan as written on 2026-10-15. It is the standing structure
> for the epic; work package status is tracked on the board and in the issues, not
> re-stated here.** If a work package is re-scoped, the issue body changes and this
> file is adjusted in the same PR.

---

## 0. Repository setup

### Labels and milestones to create

The repo already carries the `budgeting` area label, the `phase:0`–`phase:3` phase
labels (used by the loans epic), and the `M0`–`M3` loan milestones (all closed).

To create:

| Item | Kind | Purpose |
|---|---|---|
| `Zero-Based Budgeting` | label | Epic membership — mirrors the `Investment Portfolio Upgrades` convention |
| `phase:4` … `phase:6` | labels | Continues the existing `phase:N` scheme for ZBB phases P4–P6 (P0–P3 reuse `phase:0`–`phase:3`; loans is merged, so no live conflict is expected — see `scope:` note) |
| `type:spike` | label | For Z0/Z1 decision-record and baseline-pinning work |
| `M4 — ZBB core allocation` | milestone | Z0, Z1, Z2, Z3, Z4, Z5 |
| `M5 — ZBB analytics` | milestone | Z6, Z7, Z8 |
| `M6 — ZBB import` | milestone | Z9, Z10, Z11 |
| `M7 — ZBB UX` | milestone | Z12, Z13, Z14 |
| `M8 — ZBB collaboration` | milestone | Z15, Z16 |
| `M9 — ZBB portability` | milestone | Z17, Z18 |

> **Phase-label collision:** `phase:1`–`phase:3` were assigned to the (now merged)
> loans epic. Every ZBB issue additionally carries `Zero-Based Budgeting`, so a
> `phase:N` + epic-label pair is unambiguous. If ambiguity is ever observed, rename
> the ZBB labels to `zbb:p{n}` in one pass; nothing downstream depends on the label
> text.

### Issue convention

Each work package below is filed as one issue in this fork (upstream filing rule
below, §7). Issue bodies use the house format:

- First line: `Plan ID (Z-n) for [epic](https://github.com/jaysbeekay/sure/issues/465).`
- Acceptance criteria checklist (the "AC" list in §3, ticked off as evidence lands).
- Gate evidence attached where the gate requires it (§4).
- Labels: `Zero-Based Budgeting`, `phase:n`, type + area as listed in §3; milestone
  M4–M9 as listed.

---

## 0.1 Plan ID — work package map

| Plan ID | Feature (#465) | Milestone | Phase | Size |
|---|---|---|---|---|
| **Z0** | — (decision record) | M4 | P0 | S |
| **Z1** | — (baseline + gap inventory) | M4 | P0 | S |
| **Z2** | 1. Zero-based budgeting method | M4 | P0→P1 | L |
| **Z3** | 2. Flexible savings goals | M4 | P1 | M |
| **Z4** | 3. Auto-budget panel | M4 | P1 | M |
| **Z5** | 10. Undo/redo *(pulled forward: prerequisite of Z4)* | M4 | P1 | S |
| **Z6** | 6. Spending pace insights | M5 | P2 | S |
| **Z7** | 5. Cash flow forecasts | M5 | P2 | M |
| **Z8** | 4. Advanced analytics dashboard | M5 | P2 | L |
| **Z9** | 9. OFX/QFX/QIF import | M6 | P3 | M |
| **Z10** | 7. YNAB import | M6 | P3 | M |
| **Z11** | 8. Actual Budget import | M6 | P3 | S |
| **Z12** | 13. Mobile-first transaction entry | M7 | P4 | L |
| **Z13** | 11. Keyboard shortcuts | M7 | P4 | S |
| **Z14** | 12. Theme customization | M7 | P4 | S |
| **Z15** | 15. Budget templates | M8 | P5 | S |
| **Z16** | 14. Shared budgets | M8 | P5 | L |
| **Z17** | 16. Full data export | M9 | P6 | S |
| **Z18** | 17. API access | M9 | P6 | M |

Sizes are relative to this repo's existing work packages (an `L` here ≈ a week of
agent+reviewer loop with one or two PRs); they are planning inputs, not commitments.

---

## 1. Current baseline (what already exists)

Inventory as of 2026-10-15; Z1 re-verifies it and records the gap analysis:

- **Budget domain** — `Budget`, `BudgetCategory`, `BudgetShare` models;
  `Budget::RolloverCalculator` already computes monthly rollover. The
  zero-based method therefore extends a working allocation model rather than
  replacing one.
- **Goals** — `GoalPledge` + `GoalPledge::Reconciler`, `Goal::WithdrawalDetector`.
  A "maintained goal" path already surfaces in
  `insight/generators/maintained_goal_depleted_generator.rb`, which suggests
  feature 2 (target-balance goals) is partially present — Z1 must scope Z3
  against this.
- **Insights framework** — `Insight` + `Insight::Generator` +
  `Insight::GeneratorRegistry`, with 12 registered generators including
  `SpendingPaceGenerator`, `CashFlowWarningGenerator`, `TopMoversGenerator`,
  `SavingsRateChangeGenerator` and `IdleCashGenerator`. Features 4 and 6 largely
  ride on this framework; the dashboard work (Z8) is a presentation + series-composition
  layer, not a new analytics engine. (PR #367 in flight adds a spending-pace
  insight against the month's budget — Z6 coordinates with it, does not duplicate it.)
- **Imports** — an `Import` framework exists (`category_import.rb < Import`,
  CSV import in the product). Z9–Z11 add format parsers behind that framework.
- **Mobile** — a `mobile/` directory is present in the repo; Z12 (PWA-first per D7)
  starts from whatever shell exists rather than from scratch.
- **Sharing** — `BudgetShare` exists; household sharing is an existing product
  concept (loan epic constraint: "preserve household sharing rules, and test access
  grant/revoke"). Z16 is therefore a gap-closure work package, not a greenfield one.
- **Open work to coordinate** — #449 (cached totals ignore family currency change),
  #423 (SnapTrade split positions), #136 staging work for the portfolio epic.
  Any ZBB work that reads cached portfolio/net-worth values inherits #449's bug;
  Z2's AC note below reflects this.

---

## 2. Decision record (Z0) — to be filed before allocation code changes

Following the loan epic's L0 precedent ("approve the calculation contract … each
decision needs one demonstrating test"), Z0 produces a decision record resolving:

- **D1 — Method co-existence.** Zero-based and traditional budgets co-exist;
  zero-based is the default for *new* budgets (epic Q1 recommendation).
- **D2 — Rollover interaction.** How `Budget::RolloverCalculator` behaves when
  `budget_method = :zero_based` (rollover feeds "ready to budget" vs. is disabled).
  Must be a stated rule with a demonstrating test.
- **D3 — Income attribution.** Which transactions make a month "ready to budget"
  (linked income transactions vs. cash on hand vs. net deposits). Refunds and
  credits stated explicitly.
- **D4 — Currency.** Zero-based math in family currency; FX treatment per the D4
  decisions; coordinate with #449 so cached totals and allocation balances agree.
- **D5 — Goal funding semantics.** A goal pledge is an *allocation* (consumes
  ready-to-budget) or a *commitment* (projected, not consumed)? State and test.
- **D6 — Transfers & household.** Transfers never count as income or spend in
  either direction (household sharing rules preserved; grants/revokes tested
  wherever a shared budget is exposed — G3).
- **D7 — Platform.** PWA-first for mobile entry (epic Q5); native app deferred.
- **D8 — YNAB sync.** One-time import only; live sync deferred absent demand
  (epic Q3).
- **D9 — Analytics storage.** Pre-computed aggregates per the epic Q4
  recommendation; raw transactions stay the source of truth; no new per-row
  analytics materialization (perf pattern: #434).

Each decision gets one demonstrating test in Z0's PR. The record lands at
`docs/budgeting/calculation-contract.md` (mirrors `docs/loans/calculation-contract.md`).

---

## 3. Phases and work packages

Order of work: phases run in order; within a phase, dependencies as noted. A work
package is merged only when its AC checklist is satisfied and its gate (if any) is
green.

### P0 — Foundation (M4)

**Z0 — Decision record.** §2. Deliverable: `docs/budgeting/calculation-contract.md`
+ one demonstrating test per D-decision + `budget_method` column migration
(proposal only, not yet applied — Z2 applies it).
- Labels: `Zero-Based Budgeting`, `phase:0`, `type:spike` — Milestone M4 — Size S
- AC: all 9 decisions resolved with a test; contract file reviewed; no calculation
  code changed.

**Z1 — Baseline pin + gap inventory.** Golden-master the existing
`Budget`/`BudgetCategory`/`Budget::RolloverCalculator`/`GoalPledge` behavior
(L2 precedent: pin before refactoring; assertions must fail on a deliberate one-cent
mutation). Produce the gap table: each of the 17 epic features → existing
capability (model/generator/framework) → residual work. This drives Z3's scope and
catches the #449 interaction early.
- Labels: `Zero-Based Budgeting`, `phase:0`, `type:refactor` — Milestone M4 — Size S
- AC: golden suite green and mutation-sensitive; gap table committed under
  `docs/budgeting/`; Z3's issue body updated from it.

### P1 — Core zero-based (M4)

**Z2 — Ready-to-budget allocation engine and flow** *(feature 1).*
Apply the `budget_method` migration; compute "ready to budget" per month per
(D3, D4, D5); unassigned-income surface; zero-out indicator; allocation flow in the
budget editor. Inherited-bug note: any read of cached net-worth/investment totals
carries #449's currency bug — AC requires agreement between the allocation balance
and per-account values after a family currency change.
- Depends: Z0, Z1. — Milestone M4 — Size L
- Labels: `Zero-Based Budgeting`, `phase:1`, `area:calculation`, `type:feature`
- AC: a fully assigned month shows ready-to-budget = 0 and nothing else (exact-zero,
  per the invariants convention); transfers excluded (D6); currency case per D4;
  Minitest coverage incl. a mid-month currency change; no materialization from read
  paths (house design constraint inherited from the loan plan).

**Z3 — Flexible savings goals** *(feature 2).*
Goal cadence (weekly/monthly/yearly contribution), target-amount-by-date,
fill-to-target / maintain-balance; required-contribution calculation; progress
indicators in the goals surface and in allocation math per D5.
- Depends: Z0. — Milestone M4 — Size M
- Labels: `Zero-Based Budgeting`, `phase:1`, `type:feature`
- AC: each goal type computes the required contribution under the D5 semantics;
  pledge reconciliation regression-free (Z1 baseline); progress indicators render
  from the same calculation (one source, no duplicated math — #385 precedent).

**Z4 — Auto-budget panel** *(feature 3).*
"Fill underbudgeted categories", "cover overspending" (moves sourced explicitly,
undoable — Z5), carry-overs suggested from the previous month's allocations
(reuses `Budget::RolloverCalculator` output, does not recompute).
- Depends: Z2, Z3, Z5. — Milestone M4 — Size M
- Labels: `Zero-Based Budgeting`, `phase:1`, `type:feature`, `needs:design`
- AC: each action is a single reversible transaction of allocations; undo restores
  the prior state exactly; coverage for underbudgeted, over, and mixed months.

**Z5 — Undo/redo for budget changes** *(feature 10, pulled forward).*
Session-scoped (not persisted) change journal for allocation edits — the epic's
"session-based (not persistent across reloads)" scope is adopted; `Undo/redo for
budget changes` listed as P4 in the epic roadmap, but it is a prerequisite of Z4's
quick actions and therefore ships with core.
- Depends: Z2. — Milestone M4 — Size S
- Labels: `Zero-Based Budgeting`, `phase:1`, `type:feature`
- AC: n-step undo/redo across mixed edit kinds; reload discards the journal (per
  spec); zero impact on traditional-budget users.

**Gate G1 — Zero-based coherence** after Z2+Z3+Z5: a simulated full month closes to
exactly zero; a deliberate one-cent mutation fails the pinned invariants; transfer
double-count check green; rollover interaction per D2 demonstrated. Evidence (test
output + fixture) attached to the epic.

### P2 — Analytics (M5)

**Z6 — Spending pace insights** *(feature 6).*
Extend the existing `SpendingPaceGenerator` (coordinate with in-flight PR #367 —
adopt/extend, do not fork): budget-percentage feedback, daily/weekly/monthly
cadence, category-level + overall, alert when pace > budget.
- Depends: Z2. — Milestone M5 — Size S
- Labels: `Zero-Based Budgeting`, `phase:2`, `area:charts`, `type:feature`
- AC: pace values match the Z2 allocation math (one source); insight rendered where
  existing insights render; regression pin per Z1 baseline.

**Z7 — Cash flow forecasts** *(feature 5).*
Projected balances over N months from recurring transactions + goal pledges
(`GoalPledge`), extending the existing `CashFlowWarningGenerator` pattern;
shortfall alert.
- Depends: Z2. — Milestone M5 — Size M
- Labels: `Zero-Based Budgeting`, `phase:2`, `area:calculation`, `type:feature`
- AC: projection uses pledged withdrawals per D5; forecast for ≥6 months stable and
  cacheable (D9); shortfall alert fires in a constructed-drawdown fixture.

**Z8 — Analytics dashboard** *(feature 4).*
Widget composition layer over the insight/series framework (registry pattern per
`Insight::GeneratorRegistry`): 16 report types, user-persisted layouts, date-range
filtering, MoM/YoY comparison, CSV export of a report.
- Depends: Z6, Z7 (first two widget families). — Milestone M5 — Size L
- Labels: `Zero-Based Budgeting`, `phase:2`, `area:charts`, `type:feature`, `needs:design`
- AC: a fresh install renders a default dashboard; a saved layout survives reload and
  renders identically for two users of a household (D6); CSV export matches the
  on-screen report.

### P3 — Import & migration (M6)

**Z9 — OFX/QFX/QIF import** *(feature 9).*
Statement parsers behind the existing `Import` framework; auto-detect from file
content; split transactions and payee mapping per the CSV importer's existing model.
- Depends: Z1 (importer baseline). — Milestone M6 — Size M
- Labels: `Zero-Based Budgeting`, `phase:3`, `type:feature`
- AC: public fixture set for OFX/QFX/QIF green; duplicate-import safety (idempotent
  replay) — #446 precedent on provider id rotation; bad rows reported, not silently
  dropped.

**Z10 — YNAB import** *(feature 7).*
One-time import per D8: accounts, categories, envelope amounts, scheduled releases,
transaction history; mapping UI (their category → ours, their account → ours) with
dry-run preview.
- Depends: Z9 (shared importer plumbing), Z3 (goals/envelopes). — Milestone M6 — Size M
- Labels: `Zero-Based Budgeting`, `phase:3`, `type:feature`
- AC: a sample YNAB export round-trips with correct totals per category and month
  (fixture-based, G2 evidence); transfers preserved, never double-counted (D6).

**Z11 — Actual Budget import** *(feature 8).*
Same importer core as Z9/Z10; Actual Budget's open format is documented — import
budget, categories, payees, history.
- Depends: Z9. — Milestone M6 — Size S
- Labels: `Zero-Based Budgeting`, `phase:3`, `type:feature`
- AC: documented-format fixture green; budget months map to Z2 allocations per D5.

**Gate G2 — Import parity** after Z10: YNAB and Actual fixtures round-trip within
exact cents per category/month; transfer integrity checked both directions.

### P4 — UX (M7)

**Z12 — Mobile-first transaction entry** *(feature 13).*
PWA-first per D7: one-tap entry, numpad-first drawer, quick category selection;
starting from the existing `mobile/` shell (Z1 inventory).
- Depends: nothing hard (entry writes are existing). — Milestone M7 — Size L
- Labels: `Zero-Based Budgeting`, `phase:4`, `type:feature`, `needs:design`
- AC: entry completes in ≤3 interactions on a small screen; syncs across devices
  with the existing sync behavior; no new client-only business logic.

**Z13 — Keyboard shortcuts** *(feature 11).*
Shortcut map (navigate categories, Cmd/Ctrl+Enter allocate, jump-to), discoverable
in a help surface.
- Milestone M7 — Size S — Labels: `Zero-Based Budgeting`, `phase:4`, `accessibility`
- AC: every shortcut documented; no collision with browser shortcuts on the
  budgeting surfaces; works with the theme from Z14.

**Z14 — Theme customization** *(feature 12).*
Light/dark + high-contrast; persistence per preference store; scoped to CSS custom
properties (biome/package tooling already configured).
- Milestone M7 — Size S — Labels: `Zero-Based Budgeting`, `phase:4`, `accessibility`, `type:feature`
- AC: high-contrast passes WCAG AA contrast on budget UI text; preference survives
  reload and renders on first paint.

### P5 — Collaboration (M8)

**Z15 — Budget templates** *(feature 15).*
Built-in scenario templates (single, couple, family) as seed data + a picker;
community-shared templates explicitly deferred (`scope:deferred`).
- Milestone M8 — Size S — Labels: `Zero-Based Budgeting`, `phase:5`, `type:feature`, `scope:upstream-mvp`
- AC: applying a template produces a valid, fully-allocated month under Z2 rules
  (or reports the remainder in ready-to-budget, never silently over-allocates).

**Z16 — Shared budgets** *(feature 14).*
Gap audit of `BudgetShare` + household permissions against the role matrix
(view/edit/admin); close gaps; activity log on shared-budget writes; real-time
sync only if the audit shows it missing from the existing sync path.
- Depends: Z2. — Milestone M8 — Size L
- Labels: `Zero-Based Budgeting`, `phase:5`, `type:feature`, `risk:high`
- AC: grant/revoke tested for every shared-budget surface (household-rule
  precedent, G3); an unshared budget is never visible to a non-member (#235
  precedent — provider-account leak class of bug); activity log attributes
  author + action.

**Gate G3 — Household sharing** after Z16: the full role matrix (view/edit/manage ×
owner/member) passes, including revocation of a shared budget mid-month without
orphaning allocations. Evidence attached to the epic.

### P6 — Data portability (M9)

**Z17 — Full data export** *(feature 16).*
CSV + JSON export of transactions, budgets, categories, goals; download from
settings; scheduled export deferred unless trivial (D9 caching reuse).
- Milestone M9 — Size S — Labels: `Zero-Based Budgeting`, `phase:6`, `area:api`, `type:feature`
- AC: export re-imports idempotently (round-trip with Z9 fixtures); household
  scoping correct (member sees only what they can see — D6).

**Z18 — Budget API access** *(feature 17).*
rswag-documented endpoints for the budget domain (house rule: rswag for API docs,
Minitest for behavior); authentication/rate-limiting per the existing API surface
(`area:api` label already in taxonomy).
- Depends: Z17 (shape endpoints around the export models). — Milestone M9 — Size M
- Labels: `Zero-Based Budgeting`, `phase:6`, `area:api`, `type:feature`, `upstream:candidate`
- AC: rswag suite green; every endpoint authenticated; no endpoint returns a shared
  budget's contents to a non-member (#235 class re-checked).

---

## 4. Release gates

| Gate | After | Pass condition | Evidence location |
|---|---|---|---|
| **G1 — Zero-based coherence** | Z2, Z3, Z5 | Simulated month closes to exact zero; one-cent mutation fails pinned invariants; transfer double-count test green; rollover per D2 | attached to #465 + Z2 PR |
| **G2 — Import parity** | Z10 | YNAB + Actual fixtures round-trip within exact cents per category/month; transfer integrity both directions | attached to Z10 PR |
| **G3 — Household sharing** | Z16 | Role matrix incl. mid-month revocation passes; no non-member visibility anywhere | attached to #465 + Z16 PR |

A passing fixture suite is never reported as real-world correctness (house rule):
Z10 requires a user-sourced sample export if fixtures are synthetic-only, flagged in
the issue.

---

## 5. The board (Projects v2)

Board: **"Zero-Based Budgeting (#465)"** — Projects v2 (per the loan epic's
setup finding: "Projects is enabled — use Projects v2 for the board; it carries
the fields (Iteration, Estimate, Phase) that milestones cannot").

- **Fields:** `Phase` (single select: P0, P1, P2, P3, P4, P5, P6),
  `Estimate` (single select: S, M, L), `Workflow` (single select:
  Backlog, Ready, In progress, Review, Done).
- **Items:** one per work package Z0–Z18, titled `Zn — <title>`, description
  carrying the AC summary + epic link + feature reference. When a work package is
  filed as an issue, its item is replaced by the issue item (issue becomes the
  source of truth; the standalone item is then the board's pointer to it).
- **Views:** one list view by `Workflow` for day-to-day; the `Phase` field
  doubles as the WBS grouping against this document.
- **Status rule:** the board and the issues never disagree — an item moves only
  with the linked issue/PR state, and the document above is re-read (not
  re-derived) whenever an AC changes.

---

## 6. Validation and handoff protocol (house)

Each issue/PR update states: files changed, decisions made, tests run and their
environment, unresolved risks/blockers, and the exact next work package that is
unblocked. Gate evidence attaches to the epic (§4). Minitest for behavior, rswag
for API documentation only. Financial loops in `BigDecimal` with currency
precision; no Float; no materialization from read paths (inherited from the loan
plan's design constraints, as they apply to any allocation math).

## 7. Upstream and parity policy

Sure forks `we-promise/sure`; the house rule is to track everything in the fork and
file upstream only when actually contributing a PR. Zerosum is a commercial
reference: features are implemented in **sure's** terms, using sure's models and
vocabulary (not Zerosum's), and parity is functional, not cosmetic.
`upstream:candidate` is applied only where the fork would be a clean
contribution (Z18's API is the current candidate); the rest stays fork-local
(`scope:upstream-mvp` where the epic marks it).

## 8. Success metrics (from the epic, operationalized)

- **Adoption:** % of active budgets with `budget_method = :zero_based` at 60 days.
- **Coherence:** G1 invariants green on every release (this is a gate, not a metric —
  it must not regress).
- **Engagement:** mean weekly allocation edits per zero-based budget.
- **Migration:** imports completing without a support question (Z10/Z11).
- **Retention:** 30-day retention comparison, zero-based vs. traditional cohorts.
