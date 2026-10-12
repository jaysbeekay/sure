# Replies to post on we-promise/sure#4149, and the note for #4033

Post each reply in its own review thread, then resolve that thread.

---

## 1. Reply to CodeRabbit's thread ("Preserve per-security carry-forward when holdings are not complete snapshots", `chart_series_builder.rb` line 269)

Thanks. Confirmed, and fixed in d78b3bddf (with a performance fix to it in 900eb7b9d).

A real path produces this. Editing one holding re-materializes only that security (`HoldingsController` → `Balance::Materializer` with `security_ids:`). Its rows reach today, while the account's other securities end at the last full sync. With the account-wide date, today's gain dropped to 0 in a test that goes through that path, though `current_holdings` still lists both securities. On `main` it was 1,140.

Membership now follows `Account#current_holdings` exactly:
- where the account has a provider snapshot on or before the date, only the securities in that snapshot count;
- otherwise every security's latest row counts, carried forward, as on `main`.

On the test fixture you mention, the tests that describe provider behaviour now write provider rows (`account_provider` set). New test: "a manual account keeps a security whose rows end before another security's".

---

## 2. Reply to Codex's thread ("Exclude stale same-date calculated holdings", P1)

Thanks. Confirmed, and fixed in d78b3bddf (with a performance fix to it in 900eb7b9d).

Reproduced through the real materializer:
1. The provider snapshot is dated yesterday, and the `:reverse` run gap-fills a calculated row for the old record to today.
2. Today's snapshot holds the position on the new record.
3. `cleanup_stale_calculated_rows_on_latest_provider_snapshot` removes rows only for securities the new snapshot holds, so the old record's calculated row on today stays.
4. It matched the account's latest date and was counted: 300, against 200 on the Holdings tab.

Rather than purge it, membership now comes from the provider snapshot itself. A security counts only if it has a provider row on the account's latest provider date on or before the series date. That is the rule `Account#current_holdings` and `Holding::PortfolioSnapshot` already use. Purging those rows in the materializer would be a wider change than this PR; happy to raise it separately if you want it.

New test: "a calculated row for a security the latest provider snapshot dropped is not counted". It runs `:reverse` twice and asserts the calculated row exists before checking the gain.

---

## 3. Reply to CodeRabbit's finding on a provider row at zero quantity (fixed in 47a614f93)

This session could not read the upstream threads, so the thread's title and line are not quoted here. It is the CodeRabbit finding that `47a614f93` answers: the membership check matched a provider row at zero quantity. If a reply is already there, skip this one.

Thanks. Confirmed, and fixed in 47a614f93.

The membership check matched any provider row for the security on the snapshot date, including one at zero quantity. `Account#current_holdings` skips those rows. So a calculated row dated after the snapshot could still add a gain that the Holdings tab does not show. The reverse calculator writes such rows when a snapshot dated before a sale already reports the position closed: it reads the snapshot as today's position and undoes the sale.

The `EXISTS` now also requires `qty <> 0`, as `current_holdings` does. `provider_dates` still reads every provider row, because it only finds snapshot dates, and `Account#latest_provider_holdings_snapshot_date` has no quantity condition either.

New tests: "a security the provider snapshot holds at zero quantity is not counted from later rows" (1,340 instead of 1,240 on each day after the snapshot, through the real `:reverse` materializer) and "a provider row's quantity decides whether the security's later rows count". Both fail without the guard.

---

## 4. CodeRabbit's "Docstring coverage" pre-merge check (33% against 80%)

No reply needed. The PR adds no methods, and the changed method, `gains_query`, already carries a comment block, which this PR updates. If a maintainer asks, the answer is: "No new methods; the comment on `gains_query` is updated to describe the new rule."

---

## 5. Note for #4033: no longer needed

#4145 has merged (`2b18df230`), so there is nothing left to point at. Kept below for the record only.


The fix is already in flight: #4144 reports it and #4145 by @joshiarnav makes the same three-line change. So this is only a pointer, for anyone who lands on #4033 from a red `test_unit`:

> Since this merged, `SnaptradeAccount::ActivitiesProcessorTest#test_calculates_realized_gain/loss_for_option_buy_and_sell_using_per-contract_prices` fails on `main` (expects 7,000.00, gets 6,999.79): its fixture's 0.21 sell fee and 0.20 buy fee now come off the gain, as intended here. #4144 tracks it and #4145 updates the three expectations (6,999.79 / 5,425.20 / 1,574.59); I get the same values independently, and with them the file passes on `main` `d55eac220`.
