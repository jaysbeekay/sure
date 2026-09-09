# Loan chart: upstream delivery brief

**Tracker:** [#100](https://github.com/jaysbeekay/sure/issues/100) (the single open issue on this fork)
· **Delivery vehicle:** [#107](https://github.com/jaysbeekay/sure/issues/107)
· **Upstream issues:** we-promise/sure#3295 (engine + variable rates), we-promise/sure#3332 (projection + chart)
· **Written:** 2026-09-08 · **Updated:** 2026-09-09 (opened upstream; heads below are current)

> **Status 2026-09-09.** we-promise/sure#2984 merged (`6c1c8eeec`), so Path A of §8 applied and was
> executed: PR-1 is **we-promise/sure#3473** (ready for review; first review round addressed at
> `0724c935`), PR-2 is **we-promise/sure#3474** (draft, stacked on #3473's commit), and
> we-promise/sure#3296 is closed with the comment §8 specifies. #3332's body is Appendix A.
> The candidate is rebuilt on upstream `main` directly; §5's `a0a4627a` base is superseded.

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
| `base/upstream-2984` | `upstream/main` of 2026-09-04 with we-promise/sure#2984 vendored; the diff base for PR #109's squash. Not a rebase target any more: upstream `main` carries #2984 itself since 2026-09-09 | `45263aaf` |
| `feat/loan-amortisation-engine` | PR #109 — engine port + variable rates (`Fixes #3295`); the reviewed source of PR-1 | `50f94cb8` |
| `feat/mvp-payoff-chart` | PR #111 — projection + chart, stacked on #109 (`Fixes #3332`); the reviewed source of PR-2 | `6eabe6f8` |
| `upstream/loan-amortisation-engine` | **PR-1's branch, open as we-promise/sure#3473**: #109 squashed to one commit onto upstream `main` `1ab36dad` | `0724c935` |
| `upstream/loan-balance-chart` | **PR-2's branch, open as we-promise/sure#3474 (draft)**: #111 squashed to one commit on top of PR-1's | `92210149` |
| `mvp/upstream-candidate` | the same two commits; identical to `upstream/loan-balance-chart` | `92210149` |

The two `upstream/*` refs are force-pushed with lease on every rebuild (§5); each revision of a
PR replaces its single commit rather than appending, and the PR thread says so.

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
| **PR-2** | upstream, **opened after PR-1 merges** (or combined with it at the maintainers' request), `Fixes we-promise/sure#3332` | fork #105, #106, #100 (upstream half) | the candidate's second commit **re-targeted from the Schedule tab to the account page** plus the #100 delta (§7): recorded-balance series, `UI::Account::Chart` loan branch, the two projection cards beside the chart, table alternative and keyboard access, period-governed domain, `:scheduled` payment strategy. **Without** the extra-payment what-if, which is removed from the branch (decision 10) |
| **Fork PR-B** | fork `main`, after upstream merges and the fork syncs | fork #100 (fork half) | retire the fork's own Schedule-tab chart, apply decision 9 to `current_minimum_payment` and `UI::Loan::RateChangeTable`, delete `:reamortize` on the fork's projection and `Loan#interest_bearing_balance` |

PR-2 depends on PR-1 because the projection needs a simulator that runs from an arbitrary
starting balance, holds or follows a payment, and applies recorded rate changes; #2984's annuity
loop cannot do any of that. If a
maintainer wants #3332 without #3295, the answer is "the engine half of PR-1 without the
variable-rate half", which is a re-cut of commit 1, not a rewrite.

**External blocker, resolved 2026-09-09.** we-promise/sure#2984 merged as `6c1c8eeec`; the merged
loan files are byte-identical to the vendored copy. PR-1 opened as we-promise/sure#3473 and PR-2 as
we-promise/sure#3474 (draft); we-promise/sure#3296 is closed. The one conflict between the PR-2
branch and upstream `main` is `app/components/UI/account/chart.html.erb`, where upstream #2733
added `data-time-series-chart-selectable-value="true"` to the block PR-2 moves into its `else`
branch; the rebuild carries the attribute into that branch.

## 3. Decision map

The nine decisions on #100, restated in the candidate's vocabulary, with the PR each lands in.

| # | Decision (short) | Lands in | On the candidate this means |
| --- | --- | --- | --- |
| 1 | The projection pays the schedule's repayment against the actual balance; a loan ahead of schedule pays off earlier | PR-2 | `Loan::Simulator` gains `payment_strategy: :scheduled`, whose per-period amount comes from a callable. `Loan::PayoffProjection` passes a lambda returning `schedule.payments[first_remaining_index + index].payment.amount`, falling back to the last scheduled amount past maturity. Replaces the candidate's `payment_amount: contracted_payment, payment_strategy: :reamortize`, which re-sizes off the *actual* balance at a rate move. Fixed loans: byte-identical, asserted |
| 2 | Two PRs | fork only | Upstream never had a Schedule-tab chart to retire, so there is no PR-B upstream. Fork PR-B is §9 |
| 3 | G6 accessibility is an acceptance criterion | PR-2 | keyboard traversal + `<details>` table + pointer-silent live region in the controller and component |
| 4 | Period governs the x-domain; `Period` untouched | PR-2 | `Loan::PayoffChart` takes `period:`; payload gains `domain_start` / `domain_end`; the actual series is queried `period.start_date → as_of` only and clipped to `>= origination_date`. **More important upstream than on the fork:** upstream has no loan-scoped "All" (#17 is fork-only), so without the clip the actual series carries a flat-zero lead-in from the family's oldest entry |
| 5 | Projected Payoff / Interest Saved cards sit beside the chart in the chart card | PR-2 | rendered by `UI::Account::Chart`, inside the `chart_details` Turbo frame; they compare the projection from the recorded balance with the schedule. No what-if form in this tranche (decision 10) |
| 6 | One reference date | PR-2 | `AccountsController#show` sets `@as_of = Date.current`; `loan_payoff_chart(account, as_of: @as_of, period: @period)`; the Schedule tab's `today` becomes `@as_of` |
| 7 | Evolve, do not fork | PR-2 | the candidate's `loan_payoff_chart_controller.js` and `Loan::PayoffChart` are extended in place; **no rename** (that instruction was for the fork's file and is void here) |
| 8 | Unrecognised non-blank provider `rate_type` is treated as variable | PR-1 | `Loan::AMORTIZABLE_RATE_TYPES` / `#variable_rate_type?` / `#amortizable?` in `app/models/loan.rb`; regression through `PlaidAccount::Liabilities::MortgageProcessor` |
| 9 | "Current Monthly Payment" card and rate-change table read the schedule's repayment | fork only | the candidate has neither `current_minimum_payment` nor `UI::Loan::RateChangeTable`; nothing to align upstream. §9 |
| 10 | Extra-payment what-if descoped from this tranche (owner, 2026-09-08) | PR-2 removes it; fork keeps its own | Remove from the PR-2 branch: `Loan::RepaymentPlan`, the `accelerated` series and `accelerated_payoff_date`, the simulator's `extra_for:` hook, `AccountsController#loan_extra_payment_params` and `MAX_EXTRA_PAYMENT`, the form, its locale keys and its tests. **The projection still reflects extra payments already made**, because it starts from the recorded balance; only *future* hypothetical extras are out. The fork's Schedule-tab what-if form and cards stay on the fork until a later tranche ships it upstream |

## 4. Where to develop

Develop on the two existing PR branches, not on the candidate:

- PR-1 work → `feat/loan-amortisation-engine` (PR #109, base `base/upstream-2984`)
- PR-2 work → `feat/mvp-payoff-chart` (PR #111, base `feat/loan-amortisation-engine`)

Both PRs stay **draft** on the fork until their exit criteria (§6.3, §7.6) are met; CI, cubic,
Codacy and CodeRabbit run there. The candidate is rebuilt from their heads (§5) only when both
are ready, and is what gets pushed upstream. Request `@coderabbitai full review` on each after
the last push; automatic review does not run on drafts or on non-default base branches.

## 5. Step 0: rebuild the candidate from the PR heads

Never push a candidate that was not rebuilt from the reviewed heads. Since 2026-09-09 the base
is upstream `main` itself (#2984 is on it), so the vendored merge `a0a4627a` is gone from the
recipe; `origin/base/upstream-2984` survives only as the diff base for PR-1's squash. This is
the sequence that produced `0724c935` / `92210149`:

```bash
git fetch origin && git fetch upstream main
git checkout -B mvp/upstream-candidate upstream/main
# commit 1: PR-1, squashed; applies cleanly
git diff --binary origin/base/upstream-2984 origin/feat/loan-amortisation-engine | git apply --index
git commit -m "feat(loans): amortisation engine and variable-rate loans

Fixes we-promise/sure#3295"
# commit 2: PR-2, squashed; one hunk in chart.html.erb is rejected (upstream #2733)
git diff --binary origin/feat/loan-amortisation-engine origin/feat/mvp-payoff-chart | git apply --index --reject
git show origin/feat/mvp-payoff-chart:app/components/UI/account/chart.html.erb > app/components/UI/account/chart.html.erb
# then add `data-time-series-chart-selectable-value="true"` to the fallback <div> in the else branch, and:
git add -A && git commit -m "feat(loans): payoff projection and the loan balance chart

Fixes we-promise/sure#3332"
bin/rails test test/models/loan test/models/loan_test.rb test/models/plaid_account/liabilities/mortgage_processor_test.rb test/controllers/loans_controller_test.rb test/controllers/accounts_controller_test.rb test/components/UI/account test/i18n_test.rb
DISABLE_PARALLELIZATION=true bin/rails test test/system/loan_payoff_chart_test.rb
bin/rubocop && bundle exec erb_lint ./app/**/*.erb && npm run lint && bin/brakeman --no-pager
git push --force-with-lease origin mvp/upstream-candidate
git push --force-with-lease origin HEAD~1:refs/heads/upstream/loan-amortisation-engine   # #3473
git push --force-with-lease origin HEAD:refs/heads/upstream/loan-balance-chart           # #3474
```

Fixes for upstream review findings go to the fork PR branches first (#109, then merged into
#111), with their observed-to-fail tests, and reach upstream through this rebuild; the reply on
the upstream thread names both commits.

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
delta, **minus the extra-payment what-if** (decision 10). The Schedule tab keeps only what
#2984 and PR-1 put there; the chart, legend, description and the two projection cards live in the
account chart card.

Remove the what-if from the branch rather than leaving it dormant, so PR-2 reviews as what it
ships: `Loan::RepaymentPlan`, `PayoffProjection#repayment_plan` and its `extra_payment:` keyword,
`Simulator`'s `extra_for:` hook and `extra_repayments_in`, `PayoffChart#accelerated`,
`AccountsController#loan_extra_payment_params` / `MAX_EXTRA_PAYMENT`, the form partial, the
`extra_payment.*` and `accelerated` locale keys, and the tests that cover them in
`test/models/loan/payoff_projection_test.rb`, `test/models/loan/payoff_chart_test.rb`,
`test/controllers/loans_controller_test.rb` and `test/system/loan_payoff_chart_test.rb`. Keep the
removal as one commit on the branch (`git revert`-able) so the next tranche starts from it.

### 7.2 Payload contract — `Loan::PayoffChart`

`Loan::PayoffChart.new(loan, as_of:, period:).payload` returns `nil` when the
schedule has no payments, otherwise:

| Key | Type | Source | Notes |
| --- | --- | --- | --- |
| `today` | ISO date | `as_of` | |
| `currency` | ISO code | `loan.account.currency` | the actual series is queried in this currency, so no FX applies |
| `domain_start` | ISO date | `period.key == "all_time"` → `loan.origination_date`, else `period.start_date` | |
| `domain_end` | ISO date | `all_time` → the later of the scheduled and projected payoff dates, `as_of` fallback; else `period.end_date` | absorbs #102 without touching `Period` |
| `actual` | `[{date, balance}]` | `loan.account.balance_series(period: Period.custom(start_date: domain_start, end_date: actual_end)).values` where `actual_end = [period.end_date, as_of].min`, mapped to `value.amount.to_f`, **dropping points dated before `origination_date`** | **new**; solid green. Never queried past `as_of`, so the LOCF flat line measured on #102 cannot occur; never past `period.end_date`, so a period that ended before today (Last Month) stays inside its domain. The today marker and the projection are drawn only when `as_of` is inside `[domain_start, domain_end]` |
| `scheduled` | `[{date, balance}]` | existing: origination point + `schedule.payments` | red dashed, full term |
| `projected` | `[{date, balance}]` | existing: `(as_of, current balance)` + `projection.payments` | green dashed; drawn whenever `applicable?`, **including when it overlaps `scheduled`** (on-track is a valid picture). Starts from the recorded balance, so extra payments already made are in it |
| `scheduled_payoff_date`, `projected_payoff_date` | ISO or null | existing; `accelerated_payoff_date` removed | |
| `labels`, `aria_description` | strings | existing, keys moved to `UI.account.chart.loan.*` | `aria_description` names every present payoff date (existing) |

Period semantics (decision 4): under any period other than `all_time` the forward series are
outside the domain and the controller does not draw them; the legend (ERB) lists only series with
at least one point inside `[domain_start, domain_end]`, which the payload reports as
`visible: [keys]` so ERB and JS cannot disagree.

### 7.3 File map

| File (candidate) | Change | Serves |
| --- | --- | --- |
| `app/models/loan/simulator.rb` | `PAYMENT_STRATEGIES` gains `:scheduled`; `payment_amount:` accepts a callable `(index:, balance:, sizing_rate:, remaining_payments:) -> BigDecimal` called every period under `:scheduled`; scalar behaviour unchanged for `:hold` / `:reamortize`; remove `extra_for:` and `extra_repayments_in` (added by #111) | D1, D10 |
| `app/models/loan/payoff_projection.rb` | `simulation` uses `payment_strategy: :scheduled` with the lambda in §3 row 1; `contracted_payment` stays for `applicable?`; remove `extra_payment:` and `repayment_plan` | D1, D10 |
| `app/models/loan/payoff_chart.rb` | `period:` keyword; `actual`, `domain_start`, `domain_end`, `visible`; labels re-keyed; remove `extra_payment:`, `accelerated`, `accelerated_payoff_date` and the `aria_accelerated` sentence | D4, D10 |
| `app/models/loan/repayment_plan.rb` | delete | D10 |
| `app/controllers/accounts_controller.rb` | `@as_of = Date.current` in `show`; `loan_payoff_chart(account, as_of:, period:)` memoised per request; remove `loan_extra_payment_params` and `MAX_EXTRA_PAYMENT` | D6, D10 |
| `app/components/UI/account_page.rb` / `.html.erb` | accept and pass `loan_chart:` to `UI::Account::Chart` | D5 |
| `app/components/UI/account/chart.rb` | `loan_chart` attr; `loan?` predicate; the period picker's `extra_params` are unchanged (no what-if state to carry) | D5 |
| `app/components/UI/account/chart.html.erb` | inside `chart_details`: `if loan_chart` → the two projection cards (Projected Payoff with months sooner/later; Interest Saved or Additional Interest, both comparing `projection` with `schedule`), the variable-rate notice, the `loan-payoff-chart` div (`privacy-sensitive`), conditional legend, `<details>` table, `sr-only` description; `else` → the existing `time-series-chart` block **unchanged** | D3, D5 |
| `app/javascript/controllers/loan_payoff_chart_controller.js` | `actual` series (solid, area fill, hover split on this series only); x-domain from `domain_start` / `domain_end` instead of data extent; functional tokens `--color-success` / `--color-destructive` / `--color-info` / `--color-primary` / `--color-secondary` in `_token` calls instead of raw palette names; interval markers; keyboard traversal (`tabindex`, Arrow / Home / End / Escape) ported from this fork's `main` controller; `aria-live` on the tooltip set only while keyboard traversal is active; `aria-describedby` → the `<details>` table id | D3, D4 |
| `app/views/loans/tabs/_schedule.html.erb` | remove the chart div, form, legend and `sr-only` description that #111 added; keep #2984/PR-1 content | D5 |
| `config/locales/views/loans/en.yml`, `config/locales/components/en.yml` (or wherever `UI.account.chart.*` lives on the candidate) | move `loans.tabs.schedule.chart.*` under `UI.account.chart.loan.*`; delete `extra_payment.*`, `accelerated` and `aria_accelerated`; add `view_as_table`, `notice_not_converged` | i18n, D10 |

Not touched: `time_series_chart_controller.js`, `Period`, `Account::Chartable`,
`Balance::ChartSeriesBuilder`, `shared/_trend_change`, `shared/_sparkline`.

### 7.4 Tests (the assertion that fails without the change)

| # | File | Assertion |
| --- | --- | --- |
| 1 | `test/components/UI/account/chart_test.rb` | a loan account with a schedule renders `data-controller="loan-payoff-chart"` and no `time-series-chart`; a depository renders `time-series-chart` and no loan controller |
| 2 | `test/models/loan/payoff_chart_test.rb` | `scheduled.first == (origination_date, principal)`; every `scheduled` balance equals `schedule.payments` for that date; last date is `schedule.payoff_date` |
| 3 | same | `actual.last.date == [period.end_date, as_of].min` (asserted for `all_time` and for `last_month`); no `actual` date after that or before `origination_date`; `currency == account.currency` |
| 4 | same | `projected` present with no divergence; absent when `applicable?` is false; the payload has no `accelerated` key; `visible` matches |
| 5 | `test/models/loan/payoff_projection_test.rb` | (a) variable loan, recorded rate rise, balance **ahead**: every projected `payment_amount` equals the schedule's for that date and `payoff_date < schedule.payoff_date`; (b) a **future** recorded change moves the projected repayment on its first sized payment by the schedule's amount; (c) fixed loan: payments byte-identical to the `:hold` result; (d) fixed loan whose recorded balance is below the scheduled balance for `as_of` (extra payments already made): `payoff_date < schedule.payoff_date` and `months_saved > 0`, with no extra-payment input anywhere |
| 6 | `test/models/loan/simulator_test.rb` | `:scheduled` calls the callable once per period with the running balance; `:hold` and `:reamortize` unchanged |
| 7 | `test/models/loan/payoff_chart_test.rb` | `domain_end` is the later payoff under `all_time`, `period.end_date` under `last_30_days`; `domain_start` is origination under `all_time` |
| 8 | `test/controllers/accounts_controller_test.rb` | `GET show` with header `Turbo-Frame: <dom_id(account, :chart_details)>` renders the chart mount and both cards inside that frame; `GET show` with a stray `extra_payment[...]` parameter renders identically (nothing reads it) |
| 9 | `test/system/loan_payoff_chart_test.rb` (exists on #111 head; retarget) | `visit account_path(account)` (no tab); three `path[data-series]` (`actual`, `scheduled`, `projected`) with resolved stroke in light and dark; `<details>` table row count equals the payload; ArrowRight moves the focused point and updates the tooltip; pointer movement does not change the live region |
| 10 | `test/models/plaid_account/liabilities/mortgage_processor_test.rb` (PR-1) | see §6.2 |
| 11 | Observed to fail first (§17.5.2), captured in the PR body: drop the origination point (2); remove the cards from the frame (8); revert `:scheduled` to `:reamortize` (5a fails on the payoff date); revert decision 8 (10) |

### 7.5 Degradation matrix (assert each in 4 or 9)

| Case | Chart shows |
| --- | --- |
| Not schedulable (no rate, no term, blank rate type) | the existing single-series chart, unchanged |
| Provider rate type outside the known set, non-blank | full chart (PR-1) |
| Balance zero | actual + scheduled; no forward line |
| Scheduled repayment does not cover interest / not converged | actual + scheduled; `notice_not_converged` beside the chart |
| No divergence | all series; projected overlaps scheduled |
| Originated today, or no balance rows yet | valid render, no exception |
| Period other than All | actual + scheduled history only; legend lists only those |

### 7.6 Exit criteria

- [ ] #111's review findings verified on the head against the 2026-09-08 15:57 review comment:
      variable projection no longer freezes one repayment (superseded by `:scheduled`);
      origination point; `privacy-sensitive`; theme redraw; payload built in the controller;
      browser test present. The findings about extras (accrual timing, `total_cost`,
      equal-count suppression, the accelerated `aria_description`, the declined extra-clears-
      balance date) are moot once the what-if is removed; verify none of that code remains
- [ ] `git grep -n 'extra_payment\|RepaymentPlan\|accelerated\|extra_for'` on the branch returns
      nothing outside this brief
- [ ] Codacy's two critical / three high findings read in the Codacy UI, dispositioned, gate green
- [ ] G6 evidence in the PR body: screen-reader transcript (tool and version named), keyboard-only
      walkthrough, greyscale and deuteranopia screenshots
- [ ] Non-loan account chart render asserted unchanged (test 1)
- [ ] Performance: added server time on `show` for a 360-month schedule measured and recorded;
      proposed budget under 150 ms p95. Upstream has no persisted cache, so every loan page load
      runs the schedule and one projection; if the budget fails, memoise
      `Loan#amortization_schedule` per request (already) and add `Rails.cache` keyed on
      `loan.updated_at` + `account.balance` before opening
- [ ] `@coderabbitai full review` on the final head addressed
- [ ] `bin/rails test`, system test, `bin/rubocop`, `erb_lint`, `npm run lint`, `bin/brakeman` clean

## 8. Opening upstream

> **Executed 2026-09-09 via Path A.** #2984 had merged, so the candidate was rebuilt on upstream
> `main` (§5) and PR-1 opened as we-promise/sure#3473 from `upstream/loan-amortisation-engine`;
> PR-2 opened as a draft, we-promise/sure#3474, from `upstream/loan-balance-chart`, with its
> body stating that its diff includes PR-1's commit until #3473 merges. #3296 closed with the
> comment below. The text that follows is kept as the rationale.

Both PRs depend on #2984's `Loan::AmortizationSchedule` API, which `upstream/main` does not
have until #2984 merges. Which path applies is decided by **whether #2984 has merged**, not by
whether jjmata has ruled; a ruling that #2984 goes first still leaves the dependency unmerged
until it lands.

**Path A — #2984 has merged.** From a rebuilt candidate (§5), drop the vendored merge and
open against `we-promise:main`:

```bash
git fetch upstream main
git rebase --onto upstream/main a0a4627a mvp/upstream-candidate   # drops the vendored #2984, now on main
# PR-1
git push -u origin mvp/upstream-candidate~1:refs/heads/upstream/loan-amortisation-engine
# PR-2 branch (pushed now, PR opened after PR-1 merges)
git push -u origin mvp/upstream-candidate:refs/heads/upstream/loan-balance-chart
```

**Path B — #2984 is still open but jjmata has said our work proceeds on top of it.** Do **not**
rebase. A pull request to `we-promise/sure` can only target a branch of that repository, and
#2984's head lives on oliveiraigorm's fork, so the only way to open PR-1 against `we-promise:main`
is with the vendored merge `a0a4627a` still in the history:

```bash
git push -u origin mvp/upstream-candidate~1:refs/heads/upstream/loan-amortisation-engine
git push -u origin mvp/upstream-candidate:refs/heads/upstream/loan-balance-chart
```

That PR then carries oliveiraigorm's ~430 lines unchanged. Two conditions before pushing it:
oliveiraigorm has agreed in writing on #2984, and the PR body says the merge commit is scaffolding
that drops out when #2984 lands (re-run Path A's rebase at that point and force-push with lease).
Without that agreement, Path B is not available: wait for Path A.

**Neither path is available** while jjmata has not ruled, or if the ruling prefers our
implementation over #2984 (the #107 runbook's Path D): the candidate still contains #2984's
files, and shipping them needs oliveiraigorm's sign-off or an independent rewrite.

**PR-2 cannot be stacked upstream.** A pull request into `we-promise/sure` must use a base
branch of that repository, and `upstream/loan-amortisation-engine` exists only on the fork, so a
PR-2 opened while PR-1 is unmerged would carry PR-1's whole diff and review as one change.
Therefore: open **PR-1 only** against `we-promise:main`; push the PR-2 branch so the work is
visible, but open PR-2 only after PR-1 merges (then rebase it onto `upstream/main` first). If a
maintainer prefers a single pull request, open PR-2's branch as the one PR and say it closes
both #3295 and #3332; the commits are already cut so either shape is one push. Tick **Allow
edits from maintainers** on whichever PR is open. Close we-promise/sure#3296 with a comment linking PR-1 and PR-2 and
answering jjmata's 2026-09-01 request: every finding on #3296 was against 8,913 lines that no
longer exist; the two regressions it fixed are carried as tests in PR-1.

PR bodies must state: the mount point is a single loan-only branch in `UI::Account::Chart` with
the non-loan render asserted unchanged, and moving the chart to the Schedule tab is a one-file
change if maintainers prefer. Say it before they ask.

Upstream gates not visible from the fork: Pipelock `security-scan`, upstream CodeRabbit, the DS
drift check, maintainer review. Upstream's `CONTRIBUTING.md` asks contributors to read
`AGENTS.md` and `docs/llm-guides/architecture.md`; do so before opening.

## 9. Fork follow-up (PR-B, on fork `main`)

After PR-1 and PR-2 merge upstream and the fork syncs `upstream/main` (expect conflicts in
`app/models/loan.rb`, `app/views/loans/tabs/_schedule.html.erb`, `app/controllers/accounts_controller.rb`
and the loan locales between the fork's engine and the ported one; that reconciliation is its
own PR and its own cost):

- Remove the fork's Schedule-tab chart block, legend and `sr-only` description from
  `_schedule.html.erb`. **Keep** the fork's extra-payment form and its two projection cards on
  the Schedule tab until the extra-payment tranche ships upstream (decision 10); they drive
  figures, not the retired chart. Delete `Loan#payoff_chart_payload`,
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

The issue as filed says variable rates are out of scope and names the Schedule tab. PR-2
delivers three lines on the account page with variable rates via #3295, so the issue must say so
**before** the PR opens. Future extra payments stay out of scope in this tranche, as filed. The tooling in this session could not edit the upstream repository;
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

Line style carries fact-versus-forecast; colour is secondary, so the chart reads in greyscale
and under colour-vision deficiency.

- A loan ahead of schedule projects an **earlier** payoff; the projection keeps paying the
  schedule's repayment rather than re-amortising the lower balance to maturity
- Extra payments already made are reflected because the projection starts from the recorded
  balance; modelling *future* extra payments is a later change
- The period picker governs the x-axis; forward series appear under "All", which for a loan runs
  origination → later payoff date. `Period` is not changed
- Projected Payoff and Interest Saved cards sit beside the chart, comparing the projection with the schedule
- Keyboard traversal, a "view as table" alternative associated to the SVG, and a live region
  that is silent under pointer movement
- Degrades to today's chart for a loan with no schedule

## Dependencies

Built on #2984's `Loan::AmortizationSchedule` API. Depends on #3295 for the simulator that
runs from an arbitrary balance and holds or follows a payment across recorded rate changes; the
variable-rate half of #3295 is what makes "the schedule's current repayment" differ from the
contracted one.

## Out of scope

Modelling future extra payments (a later tranche), offset accounts, saved scenarios, daily
accrual, a persisted schedule cache, and the interest-versus-principal composition chart.
```

## Appendix B — vocabulary: fork `main` → delivery branch

| #100 body says (fork `main`) | On the delivery branch |
| --- | --- |
| `AmortizationSchedule#display_rows` | `AmortizationSchedule#payments` (structs: `.date`, `.payment`, `.interest`, `.ending_balance`, all Money except `date`) |
| `loan.amortizations`, the read guard, `LoanAmortizationRebuildJob`, "enqueue on show" | do not exist; nothing to enqueue |
| `Loan#payoff_chart_payload` → rename to `balance_chart_payload` | `Loan::PayoffChart#payload`; keep the name |
| `loan_payoff_chart_controller.js` → rename to `loan_balance_chart_controller.js` | keep the name; extend in place |
| `Loan#payoff_projection` (memoised, signature-keyed) | `Loan#payoff_projection(as_of:)`, unmemoised (`extra_payment:` removed in PR-2) |
| `Loan#payoff_projection_with_extra(amount:, frequency:)` + monthly equivalent | not in this tranche (decision 10). The fork's form stays on the fork's Schedule tab; `Loan::RepaymentPlan` (real dates) is the shape to reuse when the what-if ships upstream |
| `PayoffProjection` `:hold` / `:reamortize` with `payment_amount_for` lambda | `Simulator` `payment_amount:` scalar seed + `:reamortize` / `:hold`; PR-2 adds `:scheduled` with a callable |
| `Loan#start_date || account_opening_anchor_date` | `Loan#origination_date` (`start_date` → `first_valuation.date` → opening anchor) |
| `Loan#current_minimum_payment`, `Loan#interest_bearing_balance`, `UI::Loan::RateChangeTable` | do not exist (fork PR-B only) |
| `AccountsController#extra_payment_params` (yearly allowed) | removed in PR-2 (decision 10) |
| `Account::Chartable#chart_period` loan-scoped All (#17) | does not exist; the payload's `domain_start` and the origination clip do the job |
| `loans.tabs.schedule.chart.*` keys | move to `UI.account.chart.loan.*` |
| `test/system/loan_payoff_chart_test.rb` (reads the data attribute) | the #111 version asserts painted SVG paths by `data-series`; keep that shape |
