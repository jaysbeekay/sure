# G2 lender statement evidence (anonymised)

Source for G2/#11 (`docs/loans/release-evidence.md`): a real Bankwest
"Complete Variable Home Loan" statement history, 8 statement periods,
2 May 2022 - 23 Mar 2026.

**Anonymised.** Names, mailing address, PANs, BSB, loan account number, and
every offset account number have been replaced with fictitious placeholders.
Dates, transaction amounts, running balances, and interest rate changes are
reproduced unchanged from the source, since those are the values needed to
validate daily-accrual behaviour against real-world statement data.

Contents:
- `transactions.csv` / `statements.json` — every transaction line across all
  8 statements (date, particulars, debit, credit, balance).
- `interest_rate_changes.csv` — the full variable-rate change history
  (effective date, owner-occupied limit balance, rate % p.a.).
- `pdf/anonymised_statement_1.pdf` ... `_8.pdf` — reconstructed statement
  pages (not scans of the originals), each marked "ANONYMISED
  RECONSTRUCTION — NOT AN ORIGINAL BANK DOCUMENT".

**This is the statement input only.** G2 also requires finance reviewer
sign-off per `docs/loans/release-evidence.md`; that approval is still
outstanding and is not represented by this directory.
