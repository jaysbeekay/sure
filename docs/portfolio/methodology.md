# Portfolio methodology

Status: **contract in force for the foundations drop** (issue #119). This
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
issue #119).

| ID | Decision | Demonstrating test | Resolves |
| --- | --- | --- | --- |
| P1 | A security held in several accounts is one row in `top_holdings` and `allocation`, valued in family currency at today's rate. | `InvestmentStatementTest` "top_holdings rolls up the same security across accounts", "rolls up the same security held in a foreign-currency account in family currency" | we-promise/sure#2291 |
| P2 | Every weight is measured against one denominator: `max(portfolio_value, holdings_total)`. Portfolio value (account balances, cash included) is the intended denominator; the holdings total is a floor that keeps every weight at or below 100 when balances are stale or cash is negative. `top_holdings` and `allocation` report the same weight for a security. | `InvestmentStatementTest` "top_holdings and allocation report the same weight for a security", "weights never exceed 100 when cash is negative", "top_holdings still lists positions when portfolio_value is stale zero" | D1, we-promise/sure#3277 |
| P3 | `allocation` appends one cash row for the residual `denominator - holdings_total` when it is positive, so its weights sum to 100. The residual, not `cash_balance`, is used: a stale balance yields no row rather than a sum above 100. The row has `security: nil` and answers `cash?`. | `InvestmentStatementTest` "allocation rolls up duplicate securities and weights sum to 100%", "allocation omits the cash row when account balances are a stale zero" | D1 |
| P4 | Holdings are rolled up only from accounts the user may count: `included_in_finances_for(user)`. A holding in an account shared to the user with `include_in_finances: false` is not summed in. | `InvestmentStatementTest` "a holding in an account shared without include_in_finances is not rolled in" | security risk row in the review |
| P5 | Series are charted over the *historical* scope (`InvestmentStatement::HistoricalScope`): draft, active and disabled Investment and Crypto accounts that are included in reports and, with a user, `included_in_finances_for(user)`. Closing a broker keeps its history. | `InvestmentStatement::HistoricalScopeTest` "includes disabled investment accounts and excludes other types and excluded accounts", "with a user, an account shared without include_in_finances is out of scope" | D2 |
| P6 | A disabled account contributes to a series up to and including the day before `disabled_at` (or `updated_at` when unset), the cut-off net worth uses. | `InvestmentStatement::HistoricalScopeTest` "active_until_dates covers only disabled accounts, cut off the day before disabling"; `InvestmentStatementTest` "a disabled account stops contributing to value_series after its cut-off date" | D2 |
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
| P20 | The Ruby form (`#classify`) and the SQL form (`#sql_case`, `#classify_ids`) are generated from the same rule table and agree on every entry of a corpus that covers every label, storage shape, kind and counterpart position, at family, account and household scope. The SQL binds only the scope ids; every other literal is a constant. | `Portfolio::FlowClassifierTest` "the SQL form agrees with the Ruby form on every corpus entry at both scopes", "the SQL form only binds the scope ids and never interpolates entry data" | S4 |

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
`InvestmentStatement::Totals` (rows P21 onward, added with that change).

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
  amount belongs to the income drop (#123).
- **SimpleFIN and QIF income is unlabelled** unless the transaction name
  matches the adapter's heuristic. Such rows classify as external flows
  (P17). Labelling is a provider concern, not a classifier one.
- **Historical FX gaps** fall back to the nearest rate and then to 1:1 in
  `Balance::ChartSeriesBuilder`. A series over a currency with sparse rates
  is smoothed accordingly; a rate-warning belongs to the returns drop (#121).
- **Trading212 fee rows.** Order amounts already include fees; a separate
  `FEE` cash row for the same order would count the fee twice. Not observed
  in payloads; recorded so the next person to see one knows where to look.
