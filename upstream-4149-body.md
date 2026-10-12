Closes #4036. Fork pre-flight: jaysbeekay/sure#347.

## Summary

The Gains / ROI view of an investment account's chart could show more unrealised gain than the account's holdings add up to. It carried a security's last holding row forward with no end, so a position the account no longer held on that security record kept counting.

Now the chart counts the same securities as the Holdings tab (`Account#current_holdings`):
- **Linked accounts.** Once an account has a provider holdings snapshot on or before a date, a security counts on that date only if that snapshot holds it.
- **Accounts with no provider snapshot yet**, such as manual accounts, keep every security's latest row, carried forward, as before.

## What changed

- `ea11156bf` Stop gains chart counting securities the account left
- `ac7e709ee` Pin the gains chart to the Holdings tab for mixed provider dates (a test only: a Plaid account whose holdings carry different price dates)
- `d78b3bddf` Count a security by the account's latest provider snapshot (from review here; see below)
- `900eb7b9d` Resolve the gains chart's provider snapshot once per date (a performance fix to `d78b3bddf`; see Query cost)
- `47a614f93` Stop counting a security the provider snapshot holds at zero (from review here: a zero-quantity provider row)

```
 app/models/balance/chart_series_builder.rb       |  49 ++++-
 test/models/balance/chart_series_builder_test.rb | 255 +++++++++++++++++++++++
 2 files changed, 303 insertions(+), 1 deletion(-)
```

`Balance::ChartSeriesBuilder#gains_query` gets two CTEs:
- `provider_dates` holds each account's provider holdings dates and the date the next one starts.
- `provider_snapshots` matches each series date to the account's latest provider date on or before it.

Where a date has a snapshot, a security's gain is added only if it has a provider row with a nonzero quantity on that snapshot date. Where it does not, the security counts as before.

**Why the provider snapshot, and not the account's latest row.** The first version of this PR used the account's latest holding date of any kind. Review found two real paths where that is wrong:
- **Editing one holding** re-materializes only that security (`HoldingsController` → `Balance::Materializer` with `security_ids:`). Its rows then reach today, while the account's other securities end at the last full sync. The account-wide date dropped all of them from today's gain, though the Holdings tab still shows them.
- **On a linked account, the reverse calculator gap-fills calculated rows to today.** When the next provider snapshot moves the position to another security record (see #3988), the old record's calculated row on today is not purged: `cleanup_stale_calculated_rows_on_latest_provider_snapshot` removes rows only for securities the new snapshot holds. That row matched the account's latest date and was still counted, which is the case this PR exists for.

The provider snapshot is what `Account#current_holdings` and `Holding::PortfolioSnapshot` already treat as the account's position, so the chart now agrees with them in both cases.

Provider rows are never purged (`Holding::Materializer#purge_stale_holdings`), so before this change the overstatement was permanent. The cost-basis carry-forward (`last_basis`) is unchanged.

## Demo data

No demo data needed. The fix changes how existing holding rows are summed, and the demo generator does not produce a position that moves between security records.

## Screenshots

Account chart, Gains / ROI, 30 days. A position was held on one AAPL record (gain $100) until ten days ago and on a second AAPL record (gain $200) since then.

| | Light | Dark |
|---|---|---|
| Before: the old record's $100 is still counted, so the chart shows $300 | ![before, light](https://raw.githubusercontent.com/jaysbeekay/sure/refs/heads/assets/pr-347-screenshots/screenshots/before-light.png) | ![before, dark](https://raw.githubusercontent.com/jaysbeekay/sure/refs/heads/assets/pr-347-screenshots/screenshots/before-dark.png) |
| After: $200, the position actually held | ![after, light](https://raw.githubusercontent.com/jaysbeekay/sure/refs/heads/assets/pr-347-screenshots/screenshots/after-light.png) | ![after, dark](https://raw.githubusercontent.com/jaysbeekay/sure/refs/heads/assets/pr-347-screenshots/screenshots/after-dark.png) |

The screenshots were taken with the first version. The figures they show are unchanged by `d78b3bddf`.

## Migration notes

No migration.

## Verification

- `bin/rails test test/models/balance/chart_series_builder_test.rb`: 25 runs, 0 failures.
- **Fail first.** With `main`'s query, six tests fail:
  - "gains series stops counting a security record the provider moved the position off": `[100, 300, ...]` instead of `[100, 200, ...]`;
  - "gains series stops counting a position the provider stops reporting": `[150, 150, 150]` instead of `[150, 100, 100]`;
  - "today's gain agrees with the Holdings tab when provider rows carry different dates": 250 instead of 200;
  - "a calculated row for a security the latest provider snapshot dropped is not counted": 300 instead of 200;
  - "a security the provider snapshot holds at zero quantity is not counted from later rows": 1,340 instead of 1,240 on each day after the snapshot;
  - "a provider row's quantity decides whether the security's later rows count": `[100, 250]` instead of `[100, 200]`.

  With `900eb7b9d`, the last two fail, with the same figures. The first of them drives the real `:reverse` materializer; the second writes the rows by hand.

  With this PR's first version (account-wide date), two fail:
  - "a manual account keeps a security whose rows end before another security's": 0 instead of 1,140;
  - the calculated-row test above: 300 instead of 200.

  Both drive the real materializer, `:forward` with `security_ids:` and `:reverse`, rather than writing the rows by hand.
- **Negatives**, passing before and after:
  - every security in the latest provider snapshot keeps counting across gap-filled days;
  - an account that has not synced since keeps its last snapshot;
  - each account is judged against its own snapshot;
  - a zero-quantity closing row counts as no gain;
  - a provider row holding shares keeps the security's later calculated row counting;
  - every existing gains test (LOCF, unusable cost basis, currency conversion, basis carried over gap-fills, trend) is unchanged and passes.
- **Mutations, each caught:**

  | Mutation | Tests that fail |
  | --- | --- |
  | always require a provider row | 8 |
  | drop the membership check | 6 |
  | take the snapshot date from any row | 10 |
  | count membership from any row | 1 |
  | match snapshot rows on or before the date | 4 |
  | do not bound the snapshot by the series date | 4 |
  | drop the next-snapshot bound (a date matched to several snapshots) | 5 |
  | drop the `qty <> 0` guard on the snapshot row | 2 |

  The counts are on `47a614f93`'s 25 tests. The two new tests add to the first three rows and the sixth.

  The `qty <> 0` guard on the snapshot row matches `current_holdings`. A zero-quantity row adds no gain itself, but the calculated rows after it can: the reverse calculator writes them when a snapshot dated before a sale already reports the position closed. Both new tests catch the guard's removal. `qty > 0` in its place passes, because `Holding` validates `qty >= 0`; it stays `<> 0` to match `current_holdings`.
- `bin/rails test` (full, on `47a614f93`, on `main` `2b18df230`): 11,553 runs, 0 failures, 0 errors, 34 skips.
- `bin/rubocop` on the changed files: no offenses. `bin/brakeman --no-pager`: 0 security warnings.
- `bundle exec erb_lint` and `npm run lint`: not applicable (no ERB or JavaScript changed).

## Blast radius

- **Who calls this:** `gains_series` has one caller, `Account::Chartable#balance_series(view: :gains)` (the account chart, then `Balance::LinkedInvestmentSeriesNormalizer`). It passes the account id and the period, and the change applies to whatever period and interval it passes.
- **Sibling readers of holdings, checked and unchanged:**
  - The balance, cash and holdings-balance series read the `balances` table. `Balance::SyncCache` builds it from the holdings on each exact date.
  - `Account#current_holdings` and `Holding::PortfolioSnapshot` define the position this query now follows. Neither is changed.
- **What protects the rest:** accounts with no provider holdings take the same path as before this PR, and the existing gains tests are unchanged and pass.
- **Query cost, measured.** The setup is a linked account with 25 securities and ten years of daily provider holdings (91,325 rows), with `gains_series` timed uncached. The timings were taken on the same patches before the rebase onto `2b18df230`, which changed only the SnapTrade test:

  | Period (interval) | `main` | `d78b3bddf` | `900eb7b9d` |
  | --- | --- | --- | --- |
  | last 365 days (1 day) | 0.18 s | 201.7 s | 0.38 s |
  | last 5 years (1 week) | 0.16 s | 141.3 s | 0.32 s |
  | last 10 years (1 month) | 0.08 s | 62.2 s | 0.18 s |

  - **Why `d78b3bddf` was slow.** There, the snapshot was a lateral `MAX` beside the security join. Postgres evaluated it once per (date, security), and because no index starts with `(account_id, date)`, each evaluation scanned all of the account's holdings: 775 loops of about 91,000 rows for a 30-day chart.
  - **What `900eb7b9d` does instead.** It collects the snapshot dates once per account and matches them once per (date, account). Both CTEs are `MATERIALIZED`, so they cannot be folded back into that loop.
  - **What is left.** The remaining cost over `main` is the range join between series dates and snapshot dates. Expanding each snapshot over the days it covers measured slower (1.1 s for a year), so it was not kept.
  - **The membership check** is an `EXISTS` over the account's provider rows. On a seeded account (25 securities, two years of daily provider rows), Postgres plans it as one hashed scan of those rows per query, with or without the zero-quantity condition; the timings above include it.


