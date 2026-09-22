require "test_helper"

# The tool writes PROPOSALS, never classifications. It is registered through
# `Assistant.function_classes`, which also feeds `/mcp` -- so it is callable by an
# external agent and re-checks the family scope itself rather than trusting the
# caller.
class Assistant::Function::SuggestSecurityClassificationTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @family = @user.family
    @security = securities(:aapl)
    @function = Assistant::Function::SuggestSecurityClassification.new(@user)
  end

  test "a proposal is recorded, and the security is left alone" do
    result = @function.call("proposals" => [ {
      "ticker" => "AAPL", "asset_class" => "equity", "asset_sub_class" => "stock",
      "sector" => "Technology", "rationale" => "Common stock listed on XNAS."
    } ])

    proposal = Security::ClassificationProposal.sole
    assert_equal @security, proposal.security
    assert_equal @family, proposal.family
    assert_equal "equity", proposal.asset_class
    assert proposal.pending?

    assert_nil @security.reload.asset_class, "the tool classified a security directly"
    assert_equal 1, result[:recorded]
  end

  # The tool is reachable over /mcp, so the ticker is resolved within the family's
  # own securities rather than across the table. Otherwise an external caller
  # could queue a proposal against an instrument this family does not hold.
  test "a ticker the family does not hold is refused" do
    Security.create!(ticker: "NVDA", exchange_operating_mic: "XNAS", country_code: "US")

    result = @function.call("proposals" => [ {
      "ticker" => "NVDA", "asset_class" => "equity"
    } ])

    assert_equal 0, result[:recorded]
    assert_empty Security::ClassificationProposal.all
    assert_match(/not held/i, result[:skipped].first[:reason])
  end

  test "a security the user has already classified is skipped, with a reason" do
    @security.update!(asset_class: "fixed_income", classification_source: "manual")

    result = @function.call("proposals" => [ {
      "ticker" => "AAPL", "asset_class" => "equity"
    } ])

    assert_equal 0, result[:recorded]
    assert_empty Security::ClassificationProposal.all
    assert_match(/by hand/i, result[:skipped].first[:reason])
  end

  test "an invalid value is skipped rather than raising" do
    result = nil
    assert_nothing_raised do
      result = @function.call("proposals" => [ {
        "ticker" => "AAPL", "asset_class" => "nonsense"
      } ])
    end

    assert_equal 0, result[:recorded]
    assert_empty Security::ClassificationProposal.all
  end

  # `propose!` writes with a bang, and the pre-check makes a failure there
  # unlikely rather than impossible -- it updates an existing row, so a
  # validation that depends on persisted state can still refuse. Before, that
  # raised out of the loop and the user lost every proposal after the bad one
  # (raised by Codacy on #199).
  test "a security that cannot be recorded does not cost the user the rest of the batch" do
    other = Security.create!(ticker: "MSFT9", exchange_operating_mic: "XNAS", country_code: "US")
    accounts(:investment).holdings.create!(
      security: other, date: Date.current, qty: 1, price: 10, amount: 10, currency: "USD"
    )

    # The first ticker refuses at write time; the second must still land.
    Security::ClassificationProposal.stubs(:propose!).raises(
      ActiveRecord::RecordInvalid.new(Security::ClassificationProposal.new)
    ).then.returns(Security::ClassificationProposal.new)

    result = @function.call("proposals" => [
      { "ticker" => "AAPL", "asset_class" => "equity", "asset_sub_class" => "stock" },
      { "ticker" => "MSFT9", "asset_class" => "equity", "asset_sub_class" => "stock" }
    ])

    assert_equal 1, result[:recorded], "the batch stopped at the first security it could not record"
    assert_equal [ "AAPL" ], result[:skipped].map { |entry| entry[:ticker] }
  end

  test "the tool is registered for preview users only" do
    assert_includes Assistant::PREVIEW_FUNCTION_CLASSES,
                    Assistant::Function::SuggestSecurityClassification

    plain = Assistant.function_classes(users(:family_member))
    assert_not_includes plain, Assistant::Function::SuggestSecurityClassification,
                        "a preview tool reached the default surface, which /mcp also serves"

    # The positive half. Membership of PREVIEW_FUNCTION_CLASSES is not the same
    # as the gate letting a preview user through, and without this the test
    # passes just as happily if the tool is registered for nobody at all
    # (raised by cubic on #199).
    preview_user = users(:family_admin)
    preview_user.update!(preferences: (preview_user.preferences || {}).merge("preview_features_enabled" => true))

    assert_includes Assistant.function_classes(preview_user.reload),
                    Assistant::Function::SuggestSecurityClassification,
                    "the tool is registered for preview users and the gate did not offer it to one"
  end
end
