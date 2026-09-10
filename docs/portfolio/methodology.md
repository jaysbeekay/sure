# Portfolio methodology

Status: **contract in force for the foundations drop** (issue jaysbeekay/sure#119). This
document is the decision record for the primitives every portfolio figure is
built from: which holdings are one row, what a weight is measured against,
which accounts a chart covers, and what a cash movement *is*. It is normative:
a reader that derives one of these differently is wrong, not merely different.

Every row of the contract table names the test that demonstrates it.
`bin/rails portfolio:verify_contract_coverage` (run in CI, and by
`test/tasks/portfolio_task_test.rb`) fails when a row names a test that does
not exist or when the document and `config/portfolio_contract_tests.yml`
disagree, so a renamed test is a row that has lost its evidence rather than a
silent gap.

## Scope

`InvestmentStatement` is the family-level facade (`family.investment_statement(user:)`).
Everything here applies to Investment and Crypto accounts. Snapshot figures
(portfolio value, weights, day change) convert at today's FX rate; series and
totals convert at the rate on each entry's or balance's date. Both are
correct for their purpose: a snapshot answers "what is it worth now", a
series answers "what was it worth then".

Excluded entries (`entries.excluded`) and pending transactions
(`Transaction#pending?`) carry no flow and count toward no total.

## Contract decisions

Each row: the decision, the test class and test names that demonstrate it,
and the ambiguity it resolves (D-numbers refer to the readiness review on
issue jaysbeekay/sure#119).

| ID | Decision | Demonstrating test | Resolves |
| --- | --- | --- | --- |
| P1 | A security held in several accounts is one row in `top_holdings` and `allocation`, valued in family currency at today's rate. | `InvestmentStatementTest` "top_holdings rolls up the same security across accounts", "rolls up the same security held in a foreign-currency account in family currency" | we-promise/sure#2291 |
| P2 | Every weight is measured against one denominator: `max(portfolio_value, holdings_total)`. Portfolio value (account balances, cash included) is the intended denominator; the holdings total is a floor that keeps every weight at or below 100 when balances are stale or cash is negative. `top_holdings` and `allocation` report the same weight for a security. | `InvestmentStatementTest` "top_holdings and allocation report the same weight for a security", "weights never exceed 100 when cash is negative", "top_holdings still lists positions when portfolio_value is stale zero" | D1, we-promise/sure#3277 |
| P3 | `allocation` appends one cash row for the residual `denominator - holdings_total` when it is positive, so its weights sum to 100 within rounding (each row is rounded to two decimals, so the displayed sum can differ from 100 by up to 0.01 per row). The residual, not `cash_balance`, is used: a stale balance yields no row rather than a sum above 100. The row has `security: nil` and answers `cash?`. | `InvestmentStatementTest` "allocation rolls up duplicate securities and weights sum to 100%", "allocation omits the cash row when account balances are a stale zero" | D1 |
| P4 | Holdings are rolled up only from accounts the user may count: `included_in_finances_for(user)`. A holding in an account shared to the user with `include_in_finances: false` is not summed in. | `InvestmentStatementTest` "a holding in an account shared without include_in_finances is not rolled in" | security risk row in the review |
| P5 | Series are charted over the *historical* scope (`InvestmentStatement::HistoricalScope`): draft, active and disabled Investment and Crypto accounts that are included in reports and, with a user, `included_in_finances_for(user)`. Closing a broker keeps its history. | `InvestmentStatement::HistoricalScopeTest` "includes disabled investment accounts and excludes other types and excluded accounts", "includes draft investment accounts", "with a user, an account shared without include_in_finances is out of scope" | D2 |
| P6 | A disabled account contributes to a series up to and including the day before `disabled_at` (or `updated_at` when unset), the cut-off net worth uses. | `InvestmentStatement::HistoricalScopeTest` "active_until_dates covers only disabled accounts, cut off the day before disabling", "a disabled account without disabled_at is cut off the day before it was last updated"; `InvestmentStatementTest` "a disabled account stops contributing to value_series after its cut-off date" | D2 |
| P7 | `value_series(period:)` equals the sum of the per-account balance series built from the same scope on every date of the period, with historical FX. No investment accounts yields a zero series, not an error. | `InvestmentStatementTest` "value_series sums the per-account balance series on every date of the period", "value_series returns a zero series when there are no investment accounts" | exit criterion |
| P8 | The last point of `value_series` is the historical value; `portfolio_value` is the live one over visible accounts. They differ only when a disabled account still carried a balance inside the period. Support answer for "the chart and the total disagree". | `InvestmentStatementTest` "value_series is historical where portfolio_value is live, so a closed account diverges" | D2 |
| P9 | Flow classification takes `scope_account_ids:` with no default. A transfer between two accounts is `internal` when the counterpart's account is in scope and an external flow otherwise, so the same entry classifies differently at account and family scope. | `Portfolio::FlowClassifierTest` "scope_account_ids is required", "a linked transfer is internal at family scope and external at account scope" | D3 |
| P10 | A Dividend or Interest label is `income` regardless of storage shape: a qty-0 Trade (manual entry), a Transaction with the security id in `extra["security_id"]` or `extra["security"]["id"]` (Trading212, IBKR, Questrade), a Transaction with no security (Kraken, SnapTrade, Indexa), or a Plaid-shaped Dividend Trade whose amount is 0 (known limitation, see below). | `Portfolio::FlowClassifierTest` "a Dividend income trade is income", "a Dividend transaction carrying the security id in extra is income", "a Plaid-shaped zero-amount Dividend trade is income", "Interest is income whether stored as a trade or a transaction" | E4 |
| P11 | A Fee label is `fee` on a Trade or a Transaction. The fee legs of a linked Transfer (standard transactions pointing at the transfer through `transfer_id`) are `fee` too. | `Portfolio::FlowClassifierTest` "a Fee label is a fee whether stored as a trade or a transaction", "the fee leg of a linked transfer is a fee" | D4 |
| P12 | Buy, Sell and Reinvestment are `internal`: cash became a security or back inside the account. A reinvested dividend is income only when a separate Dividend entry records it. | `Portfolio::FlowClassifierTest` "Buy, Sell and Reinvestment trades are internal" | D5 |
| P13 | Sweep In, Sweep Out and Exchange are `internal` at both scopes, on a Trade or a Transaction. Whether a security-for-security Exchange realises a gain is a cost-basis question (`Trade::INTERNAL_MOVEMENT_LABELS`) and not decided here. | `Portfolio::FlowClassifierTest` "Sweep In, Sweep Out and Exchange are internal at both scopes" | D8, we-promise/sure#3220 |
| P14 | Contribution and Withdrawal labels are external flows whose direction comes from the money, not the word: a Trade by the sign of `qty`, a Transaction by the sign of `entries.amount` (negative = money in). The label decides before `kind` does, so a Kraken deposit with `kind: funds_movement` and no Transfer row is still external. | `Portfolio::FlowClassifierTest` "Contribution and Withdrawal labels are external in the direction of the money", "direction follows the trade quantity sign or the transaction amount sign" | D6 |
| P15 | A transfer-kind Transaction (`funds_movement`, `investment_contribution`, `cc_payment`, `loan_payment`) resolves through its linked `Transfer` row by ids only; the counterpart account is never loaded. Without a linked counterpart, or with one outside the scope, it is an external flow by sign. An `investment_contribution` arriving from a checking account is therefore `external_inflow` to the investment scope and `internal` to a scope that contains both accounts. | `Portfolio::FlowClassifierTest` "an investment contribution from outside the scope is an external inflow", "a transfer-kind transaction with no linked counterpart is external by sign" | D3 |
| P16 | A Trade labelled Transfer has no Transfer row. It is `internal` only when an opposite-quantity Transfer trade on the same security and date exists in another in-scope account; otherwise it is an external flow by quantity sign (a position moved in from an untracked broker). | `Portfolio::FlowClassifierTest` "a security transfer is internal only when its opposite leg is in scope" | D3 |
| P17 | An unlabelled or Other Trade is `internal` (a trade is cash turning into a security by definition). An unlabelled or Other standard Transaction is an external flow by sign: a deposit or withdrawal the provider did not label. | `Portfolio::FlowClassifierTest` "an unlabelled or Other trade is internal", "an unlabelled standard transaction is external by sign" | D6 |
| P18 | Excluded entries, pending transactions and valuations are not classified (nil in Ruby, NULL in SQL) and contribute to nothing. | `Portfolio::FlowClassifierTest` "excluded entries, pending transactions and valuations are not classified" | I2 |
| P19 | Every label in `Transaction::ACTIVITY_LABELS` has a rule in `Portfolio::FlowClassifier::LABEL_RULES`. Adding a label without deciding its class fails the build. | `Portfolio::FlowClassifierTest` "every activity label has a rule" | maintainability |
| P20 | The Ruby form (`#classify`) and the SQL form (`#sql_case`, `#classify_ids`) are generated from the same rule table and agree on every entry of a corpus that covers every label, storage shape, kind and counterpart position, at family, account and household scope. The SQL binds only the scope ids; every other literal is a constant. | `Portfolio::FlowClassifierTest` "the SQL form agrees with the Ruby form on every corpus entry at both scopes", "the SQL form only binds the scope ids and never interpolates entry data", "a pending flag that is not a boolean is read the same way by both forms" | S4 |
| P21 | `InvestmentStatement::Totals` reports contributions and withdrawals as the cash each trade entry records (`ABS(entries.amount)`), converted at the entry's date. Whether that amount already contains the trade's fee is a property of the writer, not of the row (`Trade::CreateForm` and Binance P2P fold it in; Kraken and Binance spot do not), and nothing stored on the entry says which, so for a writer that folds it in the fee is inside the contribution *and* in `fees`: the two do not add to cash out for every provider. | `InvestmentStatementTest` "contributions and withdrawals are the cash the trade entry records" | D4, provider audit |
| P22 | `trades.price` is never used to infer the fee out of the cash. It is `numeric(19,10)`, so a sub-1e-10 crypto price stores as 0 and a sale measured against it disappears; it can be stale or quoted in another currency, and a buy measured against it doubles; and Binance P2P's sell quantity is already net of its fee, so the comparison charges the fee twice. All three were reproduced before this rule replaced them. | `InvestmentStatementTest` "a stale, zero or foreign-currency price cannot move contributions or withdrawals" | D4 |
| P23 | `fees` is the sum of Fee-labelled entries (Trade or Transaction), transfer fee legs, and `trades.fee` on every other trade, converted at each entry's date. A Fee-labelled trade counts its amount, never also its fee column. Exposed as `PeriodTotals#fees` and `InvestmentStatement#total_fees`. | `InvestmentStatementTest` "fees sum Fee-labelled entries and transfer fee legs alongside trades.fee" | D4, M6 |
| P24 | Dividends and interest are summed by label over trades and transactions alike, so every storage shape in the provider audit counts; pending transactions and entries outside the period do not. The Plaid zero-amount shape contributes zero (known limitation). | `InvestmentStatementTest` "dividends and interest count the transaction shapes providers write", "totals aggregate dividend and interest income from income trades", "totals convert foreign-currency dividends into family currency" | S5, we-promise/sure#3350 |
| P25 | `Totals` reads its income and fee label sets from `Portfolio::FlowClassifier` rather than carrying its own, and its dividend / interest buckets are checked against that set, so the totals and the classifier cannot disagree about which labels are income. Income and fee labels are excluded from the direction buckets, so a relabelled buy is counted once. | `InvestmentStatementTest` "totals read their income and fee labels from the flow classifier", "the income buckets cover every income label the classifier knows", "a buy relabeled to Dividend is counted as income only, not also as a contribution" | 0.4.3 |
| P26 | The totals cache key carries the aggregation version (`totals_query/v3`), bumped whenever the meaning of a column changes, so a deploy never serves the previous shape from Redis. | `InvestmentStatementTest` "totals cache key carries the v3 aggregation version" | I4 |
| P27 | A security whose current holdings do not sum to a *positive* family-currency value is omitted from `top_holdings` and `allocation`. Zero is a position with no price yet. Negative is corrupt data — `Holding` validates its amounts as non-negative but `Holding::Materializer` writes through `upsert_all`, which skips validations — and keeping it out is what makes P2's denominator a real ceiling: inside the sum it drags `holdings_total` below the largest row and takes that row's weight over 100. | `InvestmentStatementTest` "a security whose holdings carry no value is omitted from top_holdings and allocation", "a holding with a negative value cannot push another security's weight over 100" | jaysbeekay/sure#120 Blocker 3, review round 3 |
| P28 | The return (`trend`) of a rolled-up row is measured over the holdings of that security whose cost basis is known (`Holding#trend` non-nil): the current value and the cost of those holdings only, in family currency. The row's `amount` still counts every holding. With no known cost basis the trend is nil and readers show no return. | `InvestmentStatementTest` "a rolled-up return is measured over the holdings whose cost basis is known" | jaysbeekay/sure#133 review |
| P29 | Every hub series (`value_series`, `holdings_value_series`, `gains_series`) is trimmed to the first date all linked accounts in the scope have provider history for, the way the account charts are (`Balance::LinkedInvestmentSeriesNormalizer`), so the balance rows before a broker's first snapshot are not charted as a portfolio appearing from zero. The start comes from provider-sourced entries and provider holdings, so an account with neither imposes none; an unlinked account that carries imported entries with a `source` does contribute one, because `Balance::LinkedInvestmentSeriesNormalizer`'s multi-account form reads the rows rather than the account's linked flag (the account charts' single-account form checks the flag first). | `InvestmentStatementTest` "value_series does not chart leading zeros before a linked account's first supported history"; `Balance::LinkedInvestmentSeriesNormalizerTest` "trim_to_supported_history drops the points before the common supported start" | jaysbeekay/sure#120 finding 3 |
| P30 | The previous snapshot of every current holding is loaded in one query (`previous_holdings`), and `day_change` and the per-holding day change are computed from it, so a page listing every position issues no query per row. The comparison is the same as `Holding#day_change`: the latest row for the same account, security and currency dated before the current one. | `InvestmentStatementTest` "previous_holdings loads the prior snapshot of every holding in one query" | jaysbeekay/sure#120 finding 4 |
| P31 | The hub's holdings table (`holdings_table_rows(sort:, dir:)`) is the P1 roll-up with per-account positions. Cost basis and unrealised P&L cover the positions whose `Holding#avg_cost` answers, the same partial-credit rule as P28 and the unrealised-gains KPI, so the table never hides a return the KPI above it counts; a position without a known basis is left out of the return and flags the row. The fallback is preloaded (P39), so the table still issues no trades query per row. Sort keys are `value`, `weight`, `return`, `day_change`, `name` with `asc` / `desc`; anything else is `value desc`; rows without the sorted figure go last in both directions. | `InvestmentStatementTest` "holdings_table_rows measures a row's return over the positions whose cost basis is known", "holdings_table_rows sorts by a whitelisted key and puts rows without the figure last", "holdings_table_rows issues no query per holding" | jaysbeekay/sure#120 D4, finding 4 |
| P32 | `allocation_by` (account, currency or kind) weights sum to 100 within each grouping: accounts against their balances, currency and kind against the holdings plus each account's positive cash balance (negative cash is omitted). Kinds are `cash`, `crypto` (Binance MIC) and `standard`. Any other grouping is the P1 security roll-up with its cash row. | `InvestmentStatementTest` "allocation_by groups the portfolio by account, currency and kind with weights summing to 100", "every allocation grouping measures the same portfolio" | jaysbeekay/sure#120 D5 |
| P33 | `data_quality_issues(as_of:)` lists: a holding whose `Holding#avg_cost` is nil, nothing stored and nothing the trades can compute by the holdings tab's own rules (`missing_cost_basis`); a security whose latest price is older than five days before `as_of`, or that has no price (`stale_price`); a security whose `provider_status` is not `:ok` (`provider`). Cash securities are never listed. Two bounded queries (the P39 cost-basis preload, latest price dates). | `InvestmentStatementTest` "data_quality_issues flags missing cost basis, stale prices and unhealthy providers", "data_quality_issues issues a bounded number of queries" | jaysbeekay/sure#120 D6, M5 |
| P34 | The hub renders its sections from `Portfolio::SectionRegistry`, in the user's saved order with keys the order does not mention appended in declaration order (the Reports rule), and `extra_sections` appended after the built-ins, so a later drop adds a section by adding one hash and never edits the view. Each partial receives its statement, period and `as_of` as locals; none reads `Date.current` or the family itself. | `Portfolio::SectionRegistryTest` "orders sections by the user's saved order, appending anything it omits", "ignores keys in the saved order that no longer exist", "appends extra sections after the built-ins", "registers the six built-in sections with their partials and locals" | jaysbeekay/sure#120 S8, E-g |
| P35 | Section order and collapse for the hub live under the `portfolio` namespace of the user's preferences (`portfolio_section_order`, `portfolio_collapsed_sections`); the endpoint allow-lists those two keys and the namespace decides what is written, so the Reports keys are never touched from the hub nor the hub's from Reports. | `PortfoliosControllerTest` "saves the section order and collapsed set under the portfolio namespace only", "drops preference keys that are not the portfolio's own"; `UserTest` "section preferences are namespaced so two pages never touch each other's keys" | jaysbeekay/sure#120 E-f |
| P36 | `/portfolio` is preview-gated by `require_preview_features!` (redirect to the dashboard with the preview flash) and its nav entry is desktop-sidebar-only: the mobile bottom bar is full and the mobile drawer renders no nav list, so phones reach the page through the dashboard widget and Reports links, which render for preview users only. | `PortfoliosControllerTest` "redirects users without preview access to the dashboard", "the nav shows Portfolio on desktop only, and never without the preview flag"; `PagesControllerTest` "dashboard investment widget links to the portfolio hub for preview users only" | jaysbeekay/sure#120 D2, E-a |
| P37 | The hub's holdings table renders the P31 rows: one summary row per security that expands (native `<details>`) to its per-account positions, each linking to the existing holding drawer; sort links carry the period and grouping and mark the active column with `aria-sort`. A full page for 10 accounts and 60 holdings stays within a recorded query ceiling and adding 20 holdings does not change the count. | `PortfoliosControllerTest` "holdings table renders one row per security with its per-account positions", "holdings table sorts through whitelisted links that keep the period and grouping", "the page's query count is bounded and does not grow with holdings" | jaysbeekay/sure#120 D3, D4, S3, E-b, E-d |
| P38 | The allocation donut renders `allocation_by` for the chosen grouping with a deterministic palette (`Category::COLORS` by position) and switches grouping through links that keep the sort; the accounts grid lists exactly `investment_accounts`; the data-quality section lists P33's issues with a drawer link for a missing cost basis and hides itself when the list is empty. | `PortfoliosControllerTest` "allocation donut carries the grouping's segments and switches grouping through links", "accounts grid links every countable investment account to its holdings tab and skips excluded shares", "data quality lists the reasons and hides itself when there is nothing to fix"; `PortfoliosHelperTest` "allocation colours come from the shared chart palette and wrap around" | jaysbeekay/sure#120 D5, D6 |
| P39 | The average-cost fallback (`Holding#calculate_avg_cost`: weighted average of buy trades on or before the holding date, converted at each trade's date, unknown when any of them is a Transfer or there are none) is computed for every current holding without a stored basis in one query (`InvestmentStatement#holdings_with_avg_costs`) and handed to each holding, so `unrealized_gains`, `unrealized_gains_trend` and the roll-up trends issue no trades query per holding. The batched SQL and the per-holding method are held together by a parity test. | `InvestmentStatementTest` "average costs are preloaded in one query and agree with Holding#calculate_avg_cost" | jaysbeekay/sure#120 finding 4 |

## Totals

`InvestmentStatement#totals(period:)` returns contributions, withdrawals,
dividends, interest, fees and a trade count for the period. The invariant the
fee rows protect: **no fee is inside contributions or withdrawals and also
inside fees**. For a manual buy of 10 × 100 with a 5 fee, contributions are
1 000 and fees 5, and their sum is the 1 005 that left the account.

Contributions and withdrawals remain trades-only, as before this change;
labelled Contribution / Withdrawal transactions are the cash-flow figures of
`InvestmentFlowStatement`, a different question.

## Flow classes

| Class | Meaning | Examples |
| --- | --- | --- |
| `external_inflow` | money or assets arriving from outside the scope | deposit, contribution, position transferred in from an untracked broker |
| `external_outflow` | money or assets leaving the scope | withdrawal, transfer to a checking account |
| `income` | a payment the portfolio produced | dividend, interest, staking reward |
| `fee` | a cost of holding or trading | commission, account fee, transfer fee leg |
| `internal` | nothing entered or left the scope | buy, sell, sweep, exchange, transfer whose other leg is in scope |

Order of evaluation, identical in both forms: excluded or pending or not a
Trade/Transaction (nil); a transfer fee leg (`fee`); the activity label; for
an unlabelled Trade, `internal`; for an unlabelled Transaction, its `kind`
(transfer kinds resolve through the counterpart, everything else is external
by sign).

## Provider audit

Read from the processors, not inferred. "Amount includes fee" says whether
the entry amount a processor writes already contains the commission it
reports in `trades.fee`; it is the input to the fee arithmetic in
`InvestmentStatement::Totals` (rows P21-P23).

| Provider | Trades: `trades.fee` set? amount includes fee? | Separate Fee entry | Dividend / Interest shape | Transfers | Pending flag |
| --- | --- | --- | --- | --- | --- |
| Manual (`Trade::CreateForm`) | yes; **includes** (`qty * price + fee`) | no | Trade, qty 0, price 0, negative amount | linked `Transfer` via `Transfer::Creator`, or an unlabelled Transaction | no |
| Kraken spot (`kraken_account/processor.rb`) | yes; **excludes** (`cost` = qty × price) | ledger `fee` rows as Fee Transactions; ledger `trade` rows are skipped, so no double count | ledger: `staking` → Dividend, `earn` → Interest, Transactions | Contribution / Withdrawal Transactions with `kind: funds_movement`, no Transfer row | no |
| Binance spot (`binance_account/processor.rb`) | yes; **excludes** (`quoteQty`) | no | no | Buy / Sell only | no |
| Binance P2P (same file) | yes; **includes** (`totalPrice`) | no | no | fiat leg as an unlabelled Transaction, no Transfer row | no |
| IBKR (`ibkr_account/activities_processor.rb`) | no; amount excludes commission | Fee Transaction per trade (`ibkr_trade_fee_*`), `extra.security_id` | Dividend Transaction, `extra.security_id`, negative | Contribution / Withdrawal Transactions, no Transfer row | no |
| Questrade (`questrade_account/activities_processor.rb`) | no; amount excludes commission | Fee Transaction per trade | Dividend / Interest Transactions, `extra.security_id` | Contribution / Withdrawal; **Transfer as a zero-price Trade** (`price: 0, amount: 0`) | no |
| Trading212 (`trading212_account/activities_processor.rb`) | no; amount **includes** fees when `walletImpact.netValue` is present | Fee Transaction for `FEE` cash rows (a per-order fee row would double count; none observed) | Dividend Transaction, `extra.security_id`; Interest Transaction | Contribution / Withdrawal Transactions | no |
| Trade Republic (`trade_republic_account/activities_processor.rb`) | no; amount **includes** fees and taxes (kept only in `extra`) | no | Dividend / Interest Transactions, no security | Contribution / Withdrawal, `kind: funds_movement` for transfer events, no Transfer row | no |
| Plaid investments (`plaid_account/investments/transactions_processor.rb`) | no; amount = qty × price | Fee as a cash Transaction | **Dividend / Interest as a Trade with qty 0 → amount 0** (see limitations) | transfer / contribution / withdrawal Transactions; Reinvestment Trade | no on this path |
| SnapTrade, Indexa Capital (`*_account/activities_processor.rb`) | no; amount = qty × price | Fee / Tax as own Transactions, never paired with a trade | Dividend / Interest Transactions, no security | Contribution / Withdrawal / Transfer Transactions; Reinvestment Trade | no |
| CoinStats (`coinstats_entry/processor.rb`) | no; amount = qty × price, fee mirrored into `extra` only | Fee Transaction for `fee` type | Dividend / Interest Transactions | Transfer Transactions for sent / received | no |
| Coinbase (`coinbase_account/processor.rb`) | no; modern path excludes (`subtotal`), legacy path includes (`total`) | no | no | Buy / Sell only | no |
| Onchain wallet (`onchain_wallet_account/processor.rb`) | no | no | no | every movement is a **Transfer Trade**; unpriced ones are excluded zero Transactions | no |
| SimpleFIN (`simplefin_entry/processor.rb`) | never writes Trades | only through the adapter's name heuristic | no explicit label; `Account::ProviderImportAdapter#detect_activity_label` matches `/^dividend\b/` and similar names | Contribution by heuristic | **yes** (`extra.simplefin.pending`) |
| CSV (`trade_import.rb`), QIF (`qif_import.rb`), backup restore (`family/data_importer.rb`) | no fee column (QIF amount includes commissions) | no | QIF `Div` / `IntInc` become **unlabelled** Transactions | Buy / Sell only | no |

No processor writes both `trades.fee` and a separate Fee entry for the same
event (Kraken is the near miss and skips its ledger `trade` rows).

## Known limitations

- **Plaid dividends have amount 0.** The processor routes them through the
  trade path with quantity 0, so the cash received is invisible to every
  amount-based total. The classifier still calls them `income`; fixing the
  amount belongs to the income drop (jaysbeekay/sure#123).
- **SimpleFIN and QIF income is unlabelled** unless the transaction name
  matches the adapter's heuristic. Such rows classify as external flows
  (P17). Labelling is a provider concern, not a classifier one.
- **Historical FX gaps** fall back to the nearest rate and then to 1:1 in
  `Balance::ChartSeriesBuilder`. A series over a currency with sparse rates
  is smoothed accordingly; a rate-warning belongs to the returns drop (jaysbeekay/sure#121).
- **`fees` is computed but not shown.** No view reads `PeriodTotals#fees` or
  `InvestmentStatement#total_fees` yet. The figure exists for the hub (jaysbeekay/sure#120)
  and the income drop (jaysbeekay/sure#123) to render; until one does, a user sees no fee
  total anywhere, which is why P21 leaves contributions as the cash that
  moved rather than quietly shrinking a displayed number by an unshown one.
- **A cash security is a holding row.** SnapTrade and Questrade write
  secondary-currency cash as a `Security.cash_for` holding while the primary
  cash stays on `accounts.cash_balance`, so such a position is rolled up like
  any other security and carries its generated `CASH-<account>-<currency>`
  ticker. In `allocation` it therefore sits beside the residual cash row.
  Money is not double counted (the residual is the part the holdings do not
  explain, so the weights still sum to 100), but the first reader of
  `allocation` (jaysbeekay/sure#120) should present the two as one idea.
- **Trading212 fee rows.** Order amounts already include fees; a separate
  `FEE` cash row for the same order would count the fee twice. Not observed
  in payloads; recorded so the next person to see one knows where to look.
