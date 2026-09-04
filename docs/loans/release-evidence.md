# Loan amortization release evidence

Status: disposable test-environment rehearsal. This is not production sign-off.

## Variance sample

Command: `RAILS_ENV=test bin/rails "loans:amortization_variance[5,/tmp/loan-variance.csv]"`

- Sample size: 5 loans.
- All monthly and daily simulations converged.
- Largest daily-versus-monthly interest delta: $379.97.
- Smallest non-zero absolute delta: $0.19.
- The report contained loan IDs only; no source account numbers or statement
  identifiers were included.

The sample is the current disposable test database, not a production-shaped
extract. The figures prove the report path works; they do not establish the
production variance distribution.

## Rebuild rehearsal

Command: `RAILS_ENV=test bin/rails "loans:rebuild_schedules[2,2,0]"`

- Batch size: 2.
- Limit: 2 loans.
- Rebuilt rows: 4.
- Persisted algorithm version: 3.
- The task completed without relying on a page request.

## Rollback rehearsal

On the disposable test database, the daily-accrual metadata migration was
rolled back and re-applied successfully. Both `algorithm_version` and
`generated_at` were present after re-application.

## Remaining release evidence

- Run the variance report against a production-shaped, de-identified sample.
- Set thresholds from that variance distribution rather than this five-loan
  rehearsal.
- Attach queue-depth and failed-rebuild observations from a production-shaped
  rebuild.
- Complete lender reconciliation and finance review in #11.
