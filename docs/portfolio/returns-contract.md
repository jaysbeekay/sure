# Portfolio returns calculation contract

Status: draft for engineering and product sign-off. This document is the decision record for
issue #121 (the performance engine). It is normative for `Portfolio::DailyReturns`,
`Portfolio::Performance`, `Portfolio::Drivers` and `Portfolio::FlowClassifier`; implementation
must not silently choose a different interpretation.

Modelled on `docs/loans/calculation-contract.md`, and enforced the same way:
`bin/rails portfolio:verify_contract_coverage` fails when a row below names a test that does not
exist, so a row cannot quietly lose its evidence.

## Scope and invariants

- All monetary arithmetic uses `BigDecimal` until the display boundary. Returns are ratios and
  are never rounded in the model layer.
- Every entry point takes its reference date as an argument (`period:` / `as_of:`). No method
  reads `Date.current` in a body that already has a date. This is the fork's most-repeated defect
  class (loan epic #79, #83, #86, #89).
- The engine reads `balances`, which the balance calculators write one row per **calendar** day
  per account. `end_balance(t-1) == start_balance(t)` by construction, so no self-join is needed
  to find an opening value.
- The engine never writes. It is safe to call from a GET.

## Contract decisions

| ID | Decision | Demonstrating test |
| --- | --- | --- |
| R1 | **Flow timing is start-of-day.** The daily return is `r_t = V_end(t) / (V_open(t) + F_t) - 1`, where `V_open(t)` is the previous day's closing value in family currency and `F_t` is the day's net external flow. This matches how `balances` composes a day (`start + flows + adjustments = end`) and needs no weighting factor. Other tools default to other conventions, so the UI must disclose this one. | `Portfolio::DailyReturnsTest#test_start_of_day_flow_convention_places_the_flow_in_the_denominator` |
| R2 | **Returns are quoted in the family's currency, so exchange-rate movement is part of the return.** A consolidated portfolio return is the return the family actually experienced. `Portfolio::Drivers#fx_effect` attributes that part separately, but it is inside the return, not excluded from it. | `Portfolio::DailyReturnsTest#test_exchange_rate_movement_alone_produces_a_return` |
| R3 | **Time-weighted return chains daily returns:** `TWR = Π(1 + r_t) - 1` over every day in the period. Chaining is always daily regardless of the interval a chart displays; chaining at a coarser interval silently changes the answer whenever a flow lands mid-interval. | `Portfolio::PerformanceTest#test_twr_matches_the_hand_computed_textbook_case` |
| R4 | **Annualisation applies only to periods of 365 days or more.** `annualized_twr` returns nil below that. Annualising a good week produces a number no one should be shown. | `Portfolio::PerformanceTest#test_annualized_twr_is_nil_for_periods_under_a_year` |
| R5 | **Volatility is the standard deviation of calendar-daily returns, annualised by √365.** The balance rows are calendar daily, so roughly three days in ten are structural zeros (weekends, holidays). Annualising that series by √252 — the trading-day convention — overstates the result. No day is dropped; the basis is disclosed in the UI. | `Portfolio::PerformanceTest#test_volatility_annualises_calendar_daily_returns_by_sqrt_365` |
| R6 | **A day whose denominator `V_open + F_t` is zero or negative contributes a return of zero and is recorded as suppressed.** A fully withdrawn account would otherwise divide by zero, and a negative denominator would inverte the sign of a real gain. Suppressed days are surfaced, not hidden. | `Portfolio::DailyReturnsTest#test_a_non_positive_denominator_suppresses_the_day_rather_than_inverting_it` |
| R7 | **Returns are net of fees.** A fee reduces `end_balance` on the day it is charged, so it is already inside the return. `Portfolio::Drivers#fees` reports the magnitude separately so it can be seen, and the UI says "net of fees". | `Portfolio::DriversTest#test_fees_reduce_the_return_and_are_reported_separately` |
| R8 | **Money-weighted return is the XIRR of the external flows plus the terminal value**, with the opening value as the first (negative) flow. It answers a different question from R3 and the two are never added or averaged. | `Portfolio::PerformanceTest#test_mwr_differs_from_twr_when_flows_are_unevenly_timed` |
| R9 | **`Portfolio::Xirr` uses Newton–Raphson with a bisection fallback** over a bracketed range, capped iterations, `BigDecimal` throughout. It raises `NoSignChangeError` when the flows never change sign (no rate exists) and `ConvergenceError` when neither method converges inside the cap. Callers render "not available" rather than a guess. | `Portfolio::XirrTest#test_raises_when_the_series_never_changes_sign` |
| R10 | **The market driver reads `balances.net_market_flows`, which is only populated for trade-tracked accounts on days without a valuation.** When a valuation overrides the balance, the whole move lands in `cash_adjustments` / `non_cash_adjustments`. Those are reported as a separate `revaluations` driver, and `Portfolio::ReturnScope` tells the UI which label the account earns. A drivers table that read only `net_market_flows` would report zero market return for every manually valued account. | `Portfolio::DriversTest#test_a_valuation_tracked_account_reports_its_move_as_revaluations_not_market` |
| R11 | **`fx_effect` is measured, not inferred.** Each day's change splits exactly as `ΔV = r(t-1)·ΔA + A_end·Δr`, so every local component (flows, market, revaluations) is converted at the PREVIOUS day's rate and the currency term is the closing local balance times the day's rate change. For a single-currency family both rates are 1 and it is zero. An earlier draft defined it as the residual of R12's own equation, which made R12 unfalsifiable and reported any unexplained move as currency movement. | `Portfolio::DriversTest#test_fx_effect_carries_a_rate_only_move_and_market_stays_zero` |
| R12 | **The drivers reconcile, and failing to reconcile is reportable.** `unexplained = change - (external_net + income - fees + market + revaluations + fx_effect)` is expected to be zero to the cent, and `#reconciles?` tests that. Because every term is measured independently (R11), this is a real assertion rather than an identity. `unexplained` is non-zero when the portfolio's COMPOSITION changed rather than its value -- an account whose first balance row falls inside the period brings an opening position no driver describes -- and that is surfaced rather than folded into another component. | `Portfolio::DriversTest#test_drivers_reconcile_to_the_period_change_for_every_account_shape` |
| R13 | **Exchange rates are carried forward, then backward.** For each date the engine takes the most recent rate on or before it, falling back to the earliest rate after it. A pair with no rate anywhere is flagged `rate_missing` and the affected figure is suppressed. New code must never convert at parity through `COALESCE(rate, 1)`; `InvestmentStatement#period_return_trend` does that today and is the pattern not to copy. The flag is raised only for accounts that actually held a balance: an empty foreign-currency account a user has added but not yet synced contributes nothing, and must not blank every other account's performance. | `Portfolio::DailyReturnsTest#test_a_currency_pair_with_no_rate_is_flagged_rather_than_converted_at_parity` |
| R14 | **Cached figures key on `Family#build_cache_key(invalidate_on_data_updates: true)`**, which folds in `latest_sync_completed_at`. `entries_cache_version` is not sufficient: a daily price sync changes holdings and balances and touches no entry, so returns cached on it would be stale until the user next edited a transaction. | `Portfolio::PerformanceTest#test_cache_key_changes_when_a_price_sync_completes_without_touching_entries` |
| R15 | **An account with fewer than two days of balance history in the period supports no return method.** `Portfolio::ReturnScope` reports `:insufficient` and the UI shows nothing rather than a figure derived from a single point. | `Portfolio::ReturnScopeTest#test_an_account_with_one_balance_day_is_insufficient` |
| R16 | **A valuation-tracked account is offered a value return only, never a money-weighted return.** Without trade or transfer records the external flows are unknown, so an XIRR over them would be a fabrication. | `Portfolio::ReturnScopeTest#test_a_valuation_tracked_account_does_not_support_money_weighted_return` |

## Flow classification

`Portfolio::FlowClassifier` is the single definition of what counts as an external flow. It is
consumed by the returns engine and, later, by contribution-limit tracking (#128), so it takes the
scope it is classifying for: a transfer between two accounts is **internal** to a scope that
contains both ends and **external** to a scope that contains only one.

| ID | Entry shape | Class | Reasoning |
| --- | --- | --- | --- |
| F1 | `Trade` labelled `Dividend` or `Interest` (recorded with `qty: 0` since upstream #1311) | `income` | Cash arriving from the holdings themselves is return, not contribution. Classifying it as a flow would cancel it out of the numerator and the denominator and erase the income from the return entirely. |
| F2 | `Trade` labelled `Fee` | `fee` | Reduces the balance; reported separately under R7. |
| F3 | Any other `Trade` — `Buy`, `Sell`, `Reinvestment`, `Sweep In`, `Sweep Out`, `Transfer`, `Exchange`, `Other`, unlabelled | `internal` | A buy writes `cash_outflows` and `non_cash_inflows` of equal magnitude, so `end_balance` does not move. The balance data already treats these as internal and the classifier agrees with it. **Known limitation:** a security transferred in from an outside broker and recorded as a `Transfer` trade is treated as internal, so it does not raise the denominator. Recorded here rather than silently; see #3220 for the label ambiguity behind it. |
| F4 | `Transaction` labelled `Dividend` or `Interest` (the shape Trading212 and SimpleFIN write, carrying `extra["security_id"]`) | `income` | The same economic event as F1 in a different storage shape. Reading only F1 would report zero income for those providers. |
| F5 | `Transaction` labelled `Fee` | `fee` | As F2. |
| F6 | `Transaction` belonging to a `Transfer` whose counterpart entry is **inside** the scope | `internal` | Moving money between two accounts the scope already contains changes nothing about the scope's value. |
| F7 | `Transaction` belonging to a `Transfer` whose counterpart entry is **outside** the scope | `external` | A real contribution to, or withdrawal from, the scope. Direction follows the sign: `entries.amount < 0` is money in. |
| F8 | Any other `Transaction` | `external` | An unlabelled deposit or withdrawal the provider did not describe. Treating it as internal would understate contributions for SimpleFIN users. |
| F9 | Entries with `excluded = true` | ignored | Consistent with `InvestmentStatement::Totals` and `InvestmentFlowStatement`. The column is nullable, so both forms read it through `COALESCE(excluded, false)`: a bare `excluded = false` evaluates to NULL for such a row and silently drops it from the aggregation while the Ruby form treats it as a live flow. |

Sign convention throughout: `entries.amount` is negative for money entering an account and
positive for money leaving it. `F_t` is reported with the opposite sign, so a deposit is a
positive flow.

## Known limitations

These are recorded so they are not mistaken for oversights.

- **Security transfers in** (F3) do not raise the denominator, so a portfolio built by
  transferring positions in rather than buying them will show those positions as gains.
- **Intraday flows** are not modelled. Every flow is treated as landing at the start of its day
  (R1).
- **`fx_effect` is a residual** (R11), so it absorbs rounding as well as rate movement.
- **Provider-specific dividend gaps** persist upstream: Plaid writes cash dividends with
  `amount: 0` (see we-promise/sure#3350), so they classify as income of zero. Fixing that is
  #123's work, not this engine's.
