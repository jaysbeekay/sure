# Optional comment for we-promise/sure#4149, after replacing the body

Pushed 900eb7b9d, a performance fix to the snapshot rule from d78b3bddf. That version's per-date `MAX` over provider rows ran once per (date, security), scanning all of the account's holdings each time. On a linked account with 25 securities and ten years of daily holdings, the one-year daily chart took 201.7 s. With the snapshot dates resolved once per (date, account) it takes 0.38 s, against 0.18 s on `main`. Which securities count is unchanged; the description's "Query cost" section has the measurements.
