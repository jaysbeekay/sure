require "test_helper"

class CreditCardsHelperTest < ActionView::TestCase
  include ApplicationHelper
  include CreditCardsHelper

  setup do
    @interest = Money.new(BigDecimal("2.37"), "USD")
    @due = Date.new(2026, 12, 14)
  end

  test "interest says what it costs if the statement is not paid in full by its due date" do
    assert_equal "$2.37 if not paid in full by Dec 14, 2026",
                 credit_card_interest_if_unpaid(@interest, due_date: @due, today: Date.new(2026, 11, 26))
    assert_equal "$2.37 if not paid in full by Dec 14, 2026",
                 credit_card_interest_if_unpaid(@interest, due_date: @due, today: @due)
  end

  test "interest after a missed due date says the statement was not paid in full by it" do
    assert_equal "$2.37, not paid in full by Dec 14, 2026",
                 credit_card_interest_if_unpaid(@interest, due_date: @due, today: @due + 1)
  end

  test "interest without a due date says what it costs if the statement is not paid in full" do
    assert_equal "$2.37 if the statement is not paid in full",
                 credit_card_interest_if_unpaid(@interest, due_date: nil, today: @due)
  end

  test "no interest is shown as the bare amount and unknown interest as unknown" do
    assert_equal "$0.00", credit_card_interest_if_unpaid(Money.new(0, "USD"), due_date: @due, today: @due)
    assert_equal I18n.t("credit_cards.tabs.overview.unknown"), credit_card_interest_if_unpaid(nil, due_date: @due, today: @due)
  end
end
