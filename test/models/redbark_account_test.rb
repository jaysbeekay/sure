# frozen_string_literal: true

require "test_helper"

class RedbarkAccountTest < ActiveSupport::TestCase
  setup do
    @redbark_account = redbark_accounts(:savings_account)
  end

  # Redbark's accounts endpoint does not carry institutionLogo; only the
  # connections endpoint does (see Provider::Redbark#list_connections).
  test "upsert_from_redbark! takes the institution logo from the connection" do
    @redbark_account.update_columns(institution_metadata: {})

    @redbark_account.upsert_from_redbark!(
      { id: @redbark_account.redbark_account_id, connectionId: "rb_conn_1", provider: "fiskil",
        name: "Everyday Saver", type: "savings", institutionName: "Test Bank", currency: "AUD" },
      connection_data: { id: "rb_conn_1", institutionName: "Test Bank",
                         institutionLogo: "https://example.com/logo.png", status: "active" }
    )

    assert_equal "https://example.com/logo.png", @redbark_account.reload.institution_metadata["logo"]
  end

  test "sync_start_date allows nil" do
    @redbark_account.sync_start_date = nil
    assert @redbark_account.valid?
  end

  test "sync_start_date allows any date within the max lookback window" do
    @redbark_account.sync_start_date = 6.months.ago.to_date
    assert @redbark_account.valid?

    @redbark_account.sync_start_date = Date.current
    assert @redbark_account.valid?

    @redbark_account.sync_start_date = RedbarkAccount::MAX_SYNC_START_DATE_LOOKBACK_DAYS.days.ago.to_date
    assert @redbark_account.valid?
  end

  test "sync_start_date rejects a date older than the max lookback window" do
    @redbark_account.sync_start_date = (RedbarkAccount::MAX_SYNC_START_DATE_LOOKBACK_DAYS + 1).days.ago.to_date
    assert_not @redbark_account.valid?
    assert_includes @redbark_account.errors[:sync_start_date], "is not included in the list"
  end

  test "sync_start_date rejects a future date" do
    @redbark_account.sync_start_date = 1.day.from_now.to_date
    assert_not @redbark_account.valid?
    assert_includes @redbark_account.errors[:sync_start_date], "is not included in the list"
  end

  test "an unrelated update does not re-validate an unchanged, now-expired sync_start_date" do
    # Bypasses validation on write, simulating a date that was valid when set
    # but has since rolled outside the window - exactly what update_column
    # (not update!) would leave behind if it had ever been written that way.
    @redbark_account.update_column(:sync_start_date, (RedbarkAccount::MAX_SYNC_START_DATE_LOOKBACK_DAYS + 50).days.ago.to_date)

    assert_nothing_raised { @redbark_account.update!(current_balance: 999) }
  end

  test "changing sync_start_date to an out-of-range value is still rejected" do
    @redbark_account.update_column(:sync_start_date, 6.months.ago.to_date)

    @redbark_account.sync_start_date = (RedbarkAccount::MAX_SYNC_START_DATE_LOOKBACK_DAYS + 1).days.ago.to_date
    assert_not @redbark_account.valid?
    assert_includes @redbark_account.errors[:sync_start_date], "is not included in the list"
  end

  test "rejects a nonblank sync_start_date that fails to parse instead of silently clearing it" do
    @redbark_account.update_column(:sync_start_date, 6.months.ago.to_date)

    @redbark_account.sync_start_date = "not-a-date"
    assert_nil @redbark_account.sync_start_date, "Rails casts an unparseable date string to nil before validation sees it"
    assert_not @redbark_account.valid?
    assert_includes @redbark_account.errors[:sync_start_date], "is invalid"
  end

  test "an explicitly blank sync_start_date is still allowed" do
    @redbark_account.update_column(:sync_start_date, 6.months.ago.to_date)

    @redbark_account.sync_start_date = ""
    assert @redbark_account.valid?
  end
end
