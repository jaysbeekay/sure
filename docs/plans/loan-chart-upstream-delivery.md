# Loan chart: upstream delivery brief

**Tracker:** [#100](https://github.com/jaysbeekay/sure/issues/100) (the single open issue on this fork)
· **Delivery vehicle:** [#107](https://github.com/jaysbeekay/sure/issues/107)
· **Upstream issues:** we-promise/sure#3295 (engine + variable rates), we-promise/sure#3332 (projection + chart)
· **Written:** 2026-09-08

This is the document an application developer executes. #100's body records *what* the chart
does and the nine owner decisions behind it; this brief says *where* each piece is built, in
which pull request, against which branch, with which file, and what "done" means for each PR.

> **Read this first.** #100's body names files and methods from this fork's `main`
> (`display_rows`, `payoff_chart_payload`, `current_minimum_payment`, the rate-change table).
> **None of those exist on the delivery branch.** The delivery branch is upstream-shaped and uses
> the names in this brief. Appendix B maps one vocabulary to the other. If this brief and #100's
> body disagree on a name, this brief is right; if they disagree on a *decision*, #100 is right
> and this brief has a bug.

---

## 1. Ground truth: branches and heads

| Branch (on `jaysbeekay/sure`) | What it is | Head at time of writing |
| --- | --- | --- |
| `base/upstream-2984` | current `upstream/main` with we-promise/sure#2984 merged in | `45263aaf` |
| `feat/loan-amortisation-engine` | PR #109 — engine port + variable rates (`Fixes #3295`) | `05785d7d` |
| `feat/mvp-payoff-chart` | PR #111 — projection + chart, stacked on #109 (`Fixes #3332`) | `100c7deb` |
| `mvp/upstream-candidate` | `upstream/main` (`51830f05`) + #2984 vendored (`a0a4627a`) + the two commits above squashed (`96114bb4`, `1c6c90be`) | **stale**: one commit behind each PR head (§5) |

`upstream` is **not** configured as a remote in a fresh clone of this fork. Add it:

```bash
git remote add upstream https://github.com/we-promise/sure.git
git fetch upstream main
```

The fork's own `main` is **not** a delivery branch for this work. It carries the persisted
`loan_amortizations` cache, the read guard, daily accrual, offsets, scenarios and
`current_minimum_payment`; upstream has none of these and #3332 needs none of them.

## 2. Delivery shape

Three units of work, in this order:

| Unit | Where it lands | Closes | Contents |
| --- | --- | --- | --- |
| **PR-1** | upstream, `Fixes we-promise/sure#3295` | fork #103, #104 | the candidate's first commit: `Loan::Simulator`, `AmortizationMath`, `RateResolver`, `SimulationResult`, `AmortizationSchedule` re-implemented behind #2984's API, `variable_rate_schedule` + `start_date` migration, the rate-change form, plus decision 8 |
| **PR-2** | upstream, stacked on PR-1, `Fixes we-promise/sure#3332` | fork #105, #106, #100 (upstream half) | the candidate's second commit **re-targeted from the Schedule tab to the account page** plus the #100 delta (§7): recorded-balance series, `UI::Account::Chart` loan branch, form and cards beside the chart, table alternative and keyboard access, period-governed domain, `:scheduled` payment strategy |
| **Fork PR-B** | fork `main`, after upstream merges and the fork syncs | fork #100 (fork half) | retire the fork's own Schedule-tab chart, apply decision 9 to `current_minimum_payment` and `UI::Loan::RateChangeTable`, delete `:reamortize` on the fork's projection and `Loan#interest_bearing_balance` |

PR-2 depends on PR-1 because the projection needs the simulator's extra-repayment hook
(`extra_for:`) and a held or scheduled payment; #2984's annuity loop cannot do either. If a
maintainer wants #3332 without #3295, the answer is "the engine half of PR-1 without the
variable-rate half", which is a re-cut of commit 1, not a rewrite.

**External blocker.** we-promise/sure#2984 is open and `REVIEW_REQUIRED`; jjmata has not ruled on
ordering between it and #3296. Building is unblocked; *opening* PR-1 waits for that ruling or
for #2984 to merge (§8). Do not force-push #3296.

## 3. Decision map

The nine decisions on #100, restated in the candidate's vocabulary, with the PR each lands in.

| # | Decision (short) | Lands in | On the candidate this means |
| --- | --- | --- | --- |
| 1 | The projection pays the schedule's repayment against the actual balance; a loan ahead of schedule pays off earlier | PR-2 | `Loan::Simulator` gains `payment_strategy: :scheduled`, whose per-period amount comes from a callable. `Loan::PayoffProjection` passes a lambda returning `schedule.payments[first_remaining_index + index].payment.amount`, falling back to the last scheduled amount past maturity, plus nothing (extras go through `extra_for:`, not the payment). Replaces the candidate's `payment_amount: contracted_payment, payment_strategy: :reamortize`, which re-sizes off the *actual* balance at a rate move. Fixed loans: byte-identical, asserted |
| 2 | Two PRs | fork only | Upstream never had a Schedule-tab chart to retire, so there is no PR-B upstream. Fork PR-B is §9 |
| 3 | G6 accessibility is an acceptance criterion | PR-2 | keyboard traversal + `<details>` table + pointer-silent live region in the controller and component |
| 4 | Period governs the x-domain; `Period` untouched | PR-2 | `Loan::PayoffChart` takes `period:`; payload gains `domain_start` / `domain_end`; the actual series is queried `period.start_date → as_of` only and clipped to `>= origination_date`. **More important upstream than on the fork:** upstream has no loan-scoped "All" (#17 is fork-only), so without the clip the actual series carries a flat-zero lead-in from the family's oldest entry |
| 5 | Projected Payoff / Interest Saved cards sit beside the form in the chart card | PR-2 | rendered by `UI::Account::Chart`, inside the `chart_details` Turbo frame |
| 6 | One reference date | PR-2 | `AccountsController#show` sets `@as_of = Date.current`; `loan_payoff_chart(account, as_of: @as_of, period: @period)`; the Schedule tab's `today` becomes `@as_of` |
| 7 | Evolve, do not fork | PR-2 | the candidate's `loan_payoff_chart_controller.js` and `Loan::PayoffChart` are extended in place; **no rename** (that instruction was for the fork's file and is void here) |
| 8 | Unrecognised non-blank provider `rate_type` is treated as variable | PR-1 | `Loan::AMORTIZABLE_RATE_TYPES` / `#variable_rate_type?` / `#amortizable?` in `app/models/loan.rb`; regression through `PlaidAccount::Liabilities::MortgageProcessor` |
| 9 | "Current Monthly Payment" card and rate-change table read the schedule's repayment | fork only | the candidate has neither `current_minimum_payment` nor `UI::Loan::RateChangeTable`; nothing to align upstream. §9 |

## 4. Where to develop

Develop on the two existing PR branches, not on the candidate:

- PR-1 work → `feat/loan-amortisation-engine` (PR #109, base `base/upstream-2984`)
- PR-2 work → `feat/mvp-payoff-chart` (PR #111, base `feat/loan-amortisation-engine`)

Both PRs stay **draft** on the fork until their exit criteria (§6.3, §7.6) are met; CI, cubic,
Codacy and CodeRabbit run there. The candidate is rebuilt from their heads (§5) only when both
are ready, and is what gets pushed upstream. Request `@coderabbitai full review` on each after
the last push; automatic review does not run on drafts or on non-default base branches.

## 5. Step 0: rebuild the candidate from the PR heads

The candidate is behind both PR heads: it predates #109's schema fix (`05785d7d`) and #111's
browser test, hidden `tab` field and `data-series` attributes (`100c7deb`). Never push a
candidate that was not rebuilt from the reviewed heads.

```bash
git fetch origin && git fetch upstream main
git checkout -B mvp/upstream-candidate a0a4627a          # upstream/main + #2984 vendored
# commit 1: PR-1, squashed
git diff --binary origin/base/upstream-2984 origin/feat/loan-amortisation-engine | git apply --index
git commit -m "feat(loans): amortisation engine and variable-rate loans

Fixes we-promise/sure#3295"
# commit 2: PR-2, squashed
git diff --binary origin/feat/loan-amortisation-engine origin/feat/mvp-payoff-chart | git apply --index
git commit -m "feat(loans): payoff projection and the loan balance chart

Fixes we-promise/sure#3332"
bin/rails test test/models/loan test/controllers/loans_controller_test.rb test/controllers/accounts_controller_test.rb test/components/UI/account
DISABLE_PARALLELIZATION=true bin/rails test test/system/loan_payoff_chart_test.rb
bin/rubocop && bundle exec erb_lint ./app/**/*.erb && npm run lint && bin/brakeman --no-pager
git push --force-with-lease origin mvp/upstream-candidate
```

If `a0a4627a` no longer merges cleanly onto a newer `upstream/main`, recreate it: check out
`upstream/main`, `git merge --no-ff` the `pr-2984` ref (fetch it with
`git fetch upstream pull/2984/head:pr-2984`), and use the new merge commit in place of `a0a4627a`
everywhere in this brief.

## 6. PR-1 — `Fixes we-promise/sure#3295`

### 6.1 Content

The candidate's commit 1 as reviewed on #109, plus decision 8. Nothing else. Do not add the
`:scheduled` strategy here; it is PR-2's and keeps PR-1 identical to what was reviewed.

### 6.2 File map (decision 8 only; the rest is already on the branch)

| File | Change |
| --- | --- |
| `app/models/loan.rb` | `variable_rate_type?` true for any non-blank `rate_type` not equal to `"fixed"`; `AMORTIZABLE_RATE_TYPES` semantics documented in the constant's comment; blank stays non-amortizable |
| `test/models/loan_test.rb` | `"arm"` and `"Variable"` are amortizable and variable; `nil` and `""` are not |
| `test/models/plaid_account/liabilities/mortgage_processor_test.rb` | a payload with `interest_rate.type: "arm"` yields a loan whose `amortization_schedule.payments` is non-empty |

### 6.3 Exit criteria

- [ ] The eight cubic findings on #109 verified fixed on the head (last row deletion; invalid rows
      redisplayed with 422; fixed loans hide *and* disable the editor; sub-unit principal
      normalised at construction; `MAX_PERIODS` refuses instead of truncating; `periodic_payment`
      read off the first simulated payment; `rate_change_rows` empty for fixed; origination test
      exercises the valuation branch). Cross-check each against the review comment dated
      2026-09-08 15:57 on #109, not against the reply that says they are fixed
- [ ] `db/schema.rb` diff is the version bump and the two loan columns only
- [ ] Two declined items are stated in the PR body as scope, not omitted: monthly accrual applies
      a mid-period rate change from the next period; no `Rails.cache` layer or p95 benchmark in
      this slice. Amend #3295's expectations in the PR body rather than silently
- [ ] CodeRabbit's **full review** on the final head addressed (the first request was rate-limited
      and never reviewed a head)
- [ ] Decision 8 tests observed to fail before the mapping, per §17.5.2 of the design doc
- [ ] `bin/rails test`, `bin/rubocop`, `erb_lint`, `npm run lint`, `bin/brakeman` clean on the branch

## 7. PR-2 — `Fixes we-promise/sure#3332`

### 7.1 Content

The candidate's commit 2 (#111) **moved from the Schedule tab to the account page** plus the #100
delta. The Schedule tab keeps only what #2984 and PR-1 put there; the chart, form, legend,
description and projection cards all live in the account chart card.

### 7.2 Payload contract — `Loan::PayoffChart`

`Loan::PayoffChart.new(loan, as_of:, period:, extra_payment: nil).payload` returns `nil` when the
schedule has no payments, otherwise:

| Key | Type | Source | Notes |
| --- | --- | --- | --- |
| `today` | ISO date | `as_of` | |
| `currency` | ISO code | `loan.account.currency` | the actual series is queried in this currency, so no FX applies |
| `domain_start` | ISO date | `period.key == "all_time"` → `loan.origination_date`, else `period.start_date` | |
| `domain_end` | ISO date | `all_time` → latest of scheduled / projected / accelerated payoff dates, `as_of` fallback; else `period.end_date` | absorbs #102 without touching `Period` |
| `actual` | `[{date, balance}]` | `loan.account.balance_series(period: Period.custom(start_date: domain_start, end_date: as_of)).values`, mapped to `value.amount.to_f`, **dropping points dated before `origination_date`** | **new**; solid green. Never queried past `as_of`, so the LOCF flat line measured on #102 cannot occur |
| `scheduled` | `[{date, balance}]` | existing: origination point + `schedule.payments` | red dashed, full term |
| `projected` | `[{date, balance}]` | existing: `(as_of, current balance)` + `projection.payments` | green dashed; drawn whenever `applicable?`, **including when it overlaps `scheduled`** (on-track is a valid picture) |
| `accelerated` | `[{date, balance}]` | existing; `[]` unless a valid extra payment changed count or interest | blue dashed |
| `scheduled_payoff_date`, `projected_payoff_date`, `accelerated_payoff_date` | ISO or null | existing | |
| `labels`, `aria_description` | strings | existing, keys moved to `UI.account.chart.loan.*` | `aria_description` names every present payoff date (existing) |

Period semantics (decision 4): under any period other than `all_time` the forward series are
outside the domain and the controller does not draw them; the legend (ERB) lists only series with
at least one point inside `[domain_start, domain_end]`, which the payload reports as
`visible: [keys]` so ERB and JS cannot disagree.

### 7.3 File map

| File (candidate) | Change | Serves |
| --- | --- | --- |
| `app/models/loan/simulator.rb` | `PAYMENT_STRATEGIES` gains `:scheduled`; `payment_amount:` accepts a callable `(index:, balance:, sizing_rate:, remaining_payments:) -> BigDecimal` called every period under `:scheduled`; scalar behaviour unchanged for `:hold` / `:reamortize` | D1 |
| `app/models/loan/payoff_projection.rb` | `simulation` uses `payment_strategy: :scheduled` with the lambda in §3 row 1; `contracted_payment` stays for `applicable?` | D1 |
| `app/models/loan/payoff_chart.rb` | `period:` keyword; `actual`, `domain_start`, `domain_end`, `visible`; labels re-keyed | D4 |
| `app/controllers/accounts_controller.rb` | `@as_of = Date.current` in `show`; `loan_payoff_chart(account, as_of:, period:)` memoised per request; `loan_extra_payment_params` unchanged | D6 |
| `app/components/UI/account_page.rb` / `.html.erb` | accept and pass `loan_chart:` and `extra_payment:` to `UI::Account::Chart` | D5 |
| `app/components/UI/account/chart.rb` | `loan_chart`, `extra_payment` attrs; `loan?` predicate; `period_picker_extra_params` merges `extra_payment[amount]` / `[frequency]` into the existing `chart_view` params | D4, D5 |
| `app/components/UI/account/chart.html.erb` | inside `chart_details`: `if loan_chart` → form (hidden `period` and `tab` fields, explicit submit, Clear link, approximation and variable-rate notices), the two projection cards, the `loan-payoff-chart` div (`privacy-sensitive`), conditional legend, `<details>` table, `sr-only` description; `else` → the existing `time-series-chart` block **unchanged** | D3, D5 |
| `app/javascript/controllers/loan_payoff_chart_controller.js` | `actual` series (solid, area fill, hover split on this series only); x-domain from `domain_start` / `domain_end` instead of data extent; functional tokens `--color-success` / `--color-destructive` / `--color-info` / `--color-primary` / `--color-secondary` in `_token` calls instead of raw palette names; interval markers; keyboard traversal (`tabindex`, Arrow / Home / End / Escape) ported from this fork's `main` controller; `aria-live` on the tooltip set only while keyboard traversal is active; `aria-describedby` → the `<details>` table id | D3, D4 |
| `app/views/loans/tabs/_schedule.html.erb` | remove the chart div, form, legend and `sr-only` description that #111 added; keep #2984/PR-1 content | D5 |
| `config/locales/views/loans/en.yml`, `config/locales/components/en.yml` (or wherever `UI.account.chart.*` lives on the candidate) | move `loans.tabs.schedule.chart.*` and `extra_payment.*` under `UI.account.chart.loan.*`; add `view_as_table`, `notice_not_converged` | i18n |

Not touched: `time_series_chart_controller.js`, `Period`, `Account::Chartable`,
`Balance::ChartSeriesBuilder`, `shared/_trend_change`, `shared/_sparkline`.

### 7.4 Tests (the assertion that fails without the change)

| # | File | Assertion |
| --- | --- | --- |
| 1 | `test/components/UI/account/chart_test.rb` | a loan account with a schedule renders `data-controller="loan-payoff-chart"` and no `time-series-chart`; a depository renders `time-series-chart` and no loan controller |
| 2 | `test/models/loan/payoff_chart_test.rb` | `scheduled.first == (origination_date, principal)`; every `scheduled` balance equals `schedule.payments` for that date; last date is `schedule.payoff_date` |
| 3 | same | `actual.last.date == as_of`; no `actual` date after `as_of` or before `origination_date`; `currency == account.currency` |
| 4 | same | `projected` present with no extra and no divergence; absent when `applicable?` is false; `accelerated` only with a valid extra; `visible` matches |
| 5 | `test/models/loan/payoff_projection_test.rb` | (a) variable loan, recorded rate rise, balance **ahead**: every projected `payment_amount` equals the schedule's for that date and `payoff_date < schedule.payoff_date`; (b) a **future** recorded change moves the projected repayment on its first sized payment by the schedule's amount; (c) fixed loan: payments byte-identical to the `:hold` result |
| 6 | `test/models/loan/simulator_test.rb` | `:scheduled` calls the callable once per period with the running balance; `:hold` and `:reamortize` unchanged |
| 7 | `test/models/loan/payoff_chart_test.rb` | `domain_end` is the later payoff under `all_time`, `period.end_date` under `last_30_days`; `domain_start` is origination under `all_time` |
| 8 | `test/controllers/accounts_controller_test.rb` | `GET show` with `extra_payment[...]` and header `Turbo-Frame: <dom_id(account, :chart_details)>` renders the accelerated series and both cards inside that frame; period-picker hrefs carry the extra-payment params; the form has hidden `period` and `tab` inputs |
| 9 | `test/system/loan_payoff_chart_test.rb` (exists on #111 head; retarget) | `visit account_path(account)` (no tab); four `path[data-series]` with resolved stroke in light and dark; `<details>` table row count equals the payload; ArrowRight moves the focused point and updates the tooltip; pointer movement does not change the live region |
| 10 | `test/models/plaid_account/liabilities/mortgage_processor_test.rb` (PR-1) | see §6.2 |
| 11 | Observed to fail first (§17.5.2), captured in the PR body: drop the origination point (2); remove `extra_params` from the picker (8); revert `:scheduled` to `:reamortize` (5a fails on the payoff date); revert decision 8 (10) |

### 7.5 Degradation matrix (assert each in 4 or 9)

| Case | Chart shows |
| --- | --- |
| Not schedulable (no rate, no term, blank rate type) | the existing single-series chart, unchanged |
| Provider rate type outside the known set, non-blank | full chart (PR-1) |
| Balance zero | actual + scheduled; no form, no forward lines |
| Scheduled repayment does not cover interest / not converged | actual + scheduled; `notice_not_converged` beside the chart |
| No divergence | all series; projected overlaps scheduled |
| Originated today, or no balance rows yet | valid render, no exception |
| Period other than All | actual + scheduled history only; legend lists only those |

### 7.6 Exit criteria

- [ ] #111's review findings verified on the head against the 2026-09-08 15:57 review comment:
      variable projection no longer freezes one repayment (superseded by `:scheduled`); extras
      accrue on the period's opening balance; `total_cost` includes extras; origination point;
      equal-count suppression removed; accelerated payoff in `aria_description`;
      `privacy-sensitive`; theme redraw; payload built in the controller; browser test present
- [ ] The one declined finding (payoff recorded on the payment date when an extra clears the
      balance) stated in the PR body as a monthly-accrual property
- [ ] Codacy's two critical / three high findings read in the Codacy UI, dispositioned, gate green
- [ ] G6 evidence in the PR body: screen-reader transcript (tool and version named), keyboard-only
      walkthrough, greyscale and deuteranopia screenshots
- [ ] Non-loan account chart render asserted unchanged (test 1)
- [ ] Performance: added server time on `show` for a 360-month schedule with an extra payment
      measured and recorded; proposed budget under 150 ms p95. Upstream has no persisted cache,
      so every loan page load runs the schedule and two projections; if the budget fails, memoise
      `Loan#amortization_schedule` per request (already) and add `Rails.cache` keyed on
      `loan.updated_at` + `account.balance` before opening
- [ ] `@coderabbitai full review` on the final head addressed
- [ ] `bin/rails test`, system test, `bin/rubocop`, `erb_lint`, `npm run lint`, `bin/brakeman` clean

## 8. Opening upstream

Wait for one of: #2984 merges, or jjmata rules on ordering. Then, from a rebuilt candidate (§5):

```bash
git fetch upstream main
git rebase --onto upstream/main a0a4627a mvp/upstream-candidate   # drops the vendored #2984
# PR-1
git push -u origin mvp/upstream-candidate~1:refs/heads/upstream/loan-amortisation-engine
# PR-2 (stacked)
git push -u origin mvp/upstream-candidate:refs/heads/upstream/loan-balance-chart
```

Open both against `we-promise:main` from the fork, PR-2 noting it stacks on PR-1. Tick **Allow
edits from maintainers**. Close we-promise/sure#3296 with a comment linking PR-1 and PR-2 and
answering jjmata's 2026-09-01 request: every finding on #3296 was against 8,913 lines that no
longer exist; the two regressions it fixed are carried as tests in PR-1.

PR bodies must state: the mount point is a single loan-only branch in `UI::Account::Chart` with
the non-loan render asserted unchanged, and moving the chart to the Schedule tab is a one-file
change if maintainers prefer. Say it before they ask.

Upstream gates not visible from the fork: Pipelock `security-scan`, upstream CodeRabbit, the DS
drift check, maintainer review. Upstream's `CONTRIBUTING.md` asks contributors to read
`AGENTS.md` and `docs/llm-guides/architecture.md`; do so before opening.

If #2984 is **not** merged when the ruling comes and jjmata prefers our implementation (the #107
runbook's Path D): the candidate contains oliveiraigorm's files via the vendored merge. Do not
open without their sign-off or an independent rewrite of those ~430 lines.

## 9. Fork follow-up (PR-B, on fork `main`)

After PR-1 and PR-2 merge upstream and the fork syncs `upstream/main` (expect conflicts in
`app/models/loan.rb`, `app/views/loans/tabs/_schedule.html.erb`, `app/controllers/accounts_controller.rb`
and the loan locales between the fork's engine and the ported one; that reconciliation is its
own PR and its own cost):

- Remove the fork's Schedule-tab chart block, form, legend, `sr-only` description and the two
  projection cards from `_schedule.html.erb`; delete `Loan#payoff_chart_payload`,
  `loans.tabs.schedule.chart.*` keys in all locales, `test/system/loan_payoff_chart_test.rb`'s
  fork version and the 13 `payoff_chart_payload` cases in `test/models/loan_test.rb`
- Decision 9: `Loan#current_minimum_payment(as_of:)` returns
  `amortization_schedule.payment_in_force(as_of:)` (new; first `display_rows` row after `as_of`),
  nil past maturity; `UI::Loan::RateChangeTable` reads before/after repayments and the balance at
  the effective date from `display_rows`, drops its `:reamortize` projection and offset netting;
  `test/models/loan/current_minimum_payment_test.rb` rewritten (the #79 lender-letter oracle is
  reinterpreted as the schedule's row for that date, with the reason in the test);
  `test/components/UI/loan/rate_change_table_test.rb`'s six projection/offset tests rewritten
- Delete `PayoffProjection` `:reamortize` and `Loan#interest_bearing_balance` once unreferenced
- `amortizations_read_guard_test` stays green throughout

## Appendix A — replacement body for we-promise/sure#3332

The issue as filed says future extra payments and variable rates are out of scope and names the
Schedule tab. PR-2 delivers all three lines on the account page, so the issue must say so
**before** the PR opens. The tooling in this session could not edit the upstream repository;
paste the following as the new body (you are its author).

```markdown
## Problem

The amortisation schedule (#2984) is static: it is generated from the contracted terms and does
not know what the borrower has actually paid. Extra payments therefore do not move the displayed
payoff date, and the account page's balance chart cannot show whether a loan is ahead of or
behind its schedule.

## Proposal

One chart at the top of a loan account page, replacing the balance-only chart for loans and
leaving every other account type untouched, carrying:

| Series | What it is | Style |
| --- | --- | --- |
| Actual | recorded balances, origination → today | solid |
| Projected | from today's actual balance, paying the schedule's current repayment | dashed |
| Scheduled | the amortisation schedule, origination → contracted payoff | dashed |
| With extra payments | the projection under a user-entered weekly or monthly extra repayment; only when one is entered | dashed |

Line style carries fact-versus-forecast; colour is secondary, so the chart reads in greyscale
and under colour-vision deficiency.

- A loan ahead of schedule projects an **earlier** payoff; the projection keeps paying the
  schedule's repayment rather than re-amortising the lower balance to maturity
- Extra repayments are applied on real dates (`RecurringTransaction::Schedule`), not as a
  monthly equivalent
- The period picker governs the x-axis; forward series appear under "All", which for a loan runs
  origination → later payoff date. `Period` is not changed
- Projected Payoff and Interest Saved cards sit beside the extra-payment form in the chart card
- Keyboard traversal, a "view as table" alternative associated to the SVG, and a live region
  that is silent under pointer movement
- Degrades to today's chart for a loan with no schedule

## Dependencies

Built on #2984's `Loan::AmortizationSchedule` API. Depends on #3295 for the simulator that
applies extra repayments and holds or follows a payment; the variable-rate half of #3295 is
what makes "the schedule's current repayment" differ from the contracted one.

## Out of scope

Offset accounts, saved scenarios, daily accrual, a persisted schedule cache, and the interest-
versus-principal composition chart.
```

## Appendix B — vocabulary: fork `main` → delivery branch

| #100 body says (fork `main`) | On the delivery branch |
| --- | --- |
| `AmortizationSchedule#display_rows` | `AmortizationSchedule#payments` (structs: `.date`, `.payment`, `.interest`, `.ending_balance`, all Money except `date`) |
| `loan.amortizations`, the read guard, `LoanAmortizationRebuildJob`, "enqueue on show" | do not exist; nothing to enqueue |
| `Loan#payoff_chart_payload` → rename to `balance_chart_payload` | `Loan::PayoffChart#payload`; keep the name |
| `loan_payoff_chart_controller.js` → rename to `loan_balance_chart_controller.js` | keep the name; extend in place |
| `Loan#payoff_projection` (memoised, signature-keyed) | `Loan#payoff_projection(as_of:, extra_payment:)`, unmemoised |
| `Loan#payoff_projection_with_extra(amount:, frequency:)` + monthly equivalent | `extra_payment: { amount:, frequency: }` → `Loan::RepaymentPlan`, real dates, weekly and monthly only (no yearly) |
| `PayoffProjection` `:hold` / `:reamortize` with `payment_amount_for` lambda | `Simulator` `payment_amount:` scalar seed + `:reamortize` / `:hold`; PR-2 adds `:scheduled` with a callable |
| `Loan#start_date || account_opening_anchor_date` | `Loan#origination_date` (`start_date` → `first_valuation.date` → opening anchor) |
| `Loan#current_minimum_payment`, `Loan#interest_bearing_balance`, `UI::Loan::RateChangeTable` | do not exist (fork PR-B only) |
| `AccountsController#extra_payment_params` (yearly allowed) | `#loan_extra_payment_params` (weekly, monthly; capped at 1,000,000) |
| `Account::Chartable#chart_period` loan-scoped All (#17) | does not exist; the payload's `domain_start` and the origination clip do the job |
| `loans.tabs.schedule.chart.*` keys | move to `UI.account.chart.loan.*` |
| `test/system/loan_payoff_chart_test.rb` (reads the data attribute) | the #111 version asserts painted SVG paths by `data-series`; keep that shape |
