# frozen_string_literal: true

# Issue #142 (L45), phase 1. `GET /v1/account-details` is the only Redbark
# endpoint that reports a loan's rate, and nothing in Sure called it. The
# response is kept per account, beside the two payloads already stored the same
# way (`raw_payload`, `raw_transactions_payload`), so the processor works from
# what the bank actually sent rather than from a value parsed at fetch time.
#
# Nullable with no backfill: an account that has never had a details fetch, and
# one whose fetch failed, are both "nothing reported" and the processor treats
# them alike.
class AddRawAccountDetailsPayloadToRedbarkAccounts < ActiveRecord::Migration[8.1]
  def change
    add_column :redbark_accounts, :raw_account_details_payload, :jsonb
  end
end
