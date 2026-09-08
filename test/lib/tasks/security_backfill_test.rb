# frozen_string_literal: true

require "test_helper"

class SecurityBackfillTest < ActiveSupport::TestCase
  # Follows the suite convention (see test/encryption_verification_test.rb):
  # runs only when explicit encryption keys are configured, e.g.
  #
  #   ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY=test \
  #   ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY=test \
  #   ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT=test \
  #   bin/rails test test/lib/tasks/security_backfill_test.rb
  setup do
    skip "Encryption not configured" unless LunchflowAccount.encryption_ready?
    # Load only this task's own rake file. `Rails.application.load_tasks` re-reads
    # every file in lib/tasks, which APPENDS a second action to any task already
    # defined elsewhere -- it silently made every loans:* task run its body twice
    # in a full-suite run (#93). It also enhances the `environment` task, which
    # reloads .env over the environment the run was started with.
    load Rails.root.join("lib/tasks/security_backfill.rake") unless Rake::Task.task_defined?("security:backfill_encryption")
    # The environment is already loaded in a test process, and the `environment`
    # task itself is only defined by `Rails.application.load_tasks` -- which is
    # what this file no longer calls. Same pattern as test/tasks/loans_task_test.rb.
    Rake::Task["security:backfill_encryption"].clear_prerequisites
    Rake::Task["security:backfill_encryption"].reenable
  end

  # Lunchflow is a representative provider model, chosen arbitrarily: the bug
  # this guards against applies identically to every json/jsonb encrypts
  # column the task touches (the Plaid/SimpleFin/Enable Banking/... raw
  # payload columns), via the shared safe_read_field helper.
  test "backfill preserves jsonb payload structure and string fields" do
    item = LunchflowItem.new(family: families(:dylan_family), name: "Backfill Test", api_key: "seed")
    item.save!(validate: false)
    account = item.lunchflow_accounts.create!(
      name: "Backfill Test Account", currency: "GBP", account_id: "backfill-test-1")

    payload = [ { "id" => "tx-1", "amount" => -4.5, "currency" => "GBP", "date" => "2026-07-01" } ]

    # Simulate rows written before encryption was enabled: bypass the encrypted
    # setters and write plaintext values directly to the columns.
    ActiveRecord::Base.connection.execute(ActiveRecord::Base.sanitize_sql([
      "UPDATE lunchflow_accounts SET raw_transactions_payload = ?::jsonb WHERE id = ?",
      payload.to_json, account.id ]))
    ActiveRecord::Base.connection.execute(ActiveRecord::Base.sanitize_sql([
      "UPDATE lunchflow_items SET api_key = ? WHERE id = ?", "plaintext-key", item.id ]))

    capture_io { Rake::Task["security:backfill_encryption"].invoke("500", "false") }

    account.reload
    assert_kind_of Array, account.raw_transactions_payload,
      "jsonb payload must decrypt to its original structure, not the JSON text"
    assert_equal "tx-1", account.raw_transactions_payload.first["id"]
    assert_equal "plaintext-key", item.reload.api_key

    # The stored value is ciphertext, not plaintext jsonb
    at_rest = account.read_attribute_before_type_cast(:raw_transactions_payload).to_s
    refute_includes at_rest, "tx-1"
  end

  # Several payload columns default to {} — Rails presence checks treat empty
  # Hash/Array as absent, so the backfill must gate on nil-ness or empty
  # payloads stay plaintext and raise on every read once keys are live.
  test "backfill encrypts empty json payloads" do
    item = LunchflowItem.new(family: families(:dylan_family), name: "Backfill Empty Test", api_key: "seed")
    item.save!(validate: false)
    account = item.lunchflow_accounts.create!(
      name: "Backfill Empty Test Account", currency: "GBP", account_id: "backfill-test-2")

    # Plaintext empty payload, as left by a pre-encryption install
    ActiveRecord::Base.connection.execute(ActiveRecord::Base.sanitize_sql([
      "UPDATE lunchflow_accounts SET raw_payload = ?::jsonb WHERE id = ?", "{}", account.id ]))

    capture_io { Rake::Task["security:backfill_encryption"].invoke("500", "false") }

    account.reload
    assert_equal({}, account.raw_payload,
      "an empty payload must decrypt cleanly after the backfill, not remain plaintext")
    assert_match(/"p":/, account.read_attribute_before_type_cast(:raw_payload).to_s,
      "the stored value must be an encryption envelope, not plaintext {}")
  end
end
