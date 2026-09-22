require "test_helper"

# The approve-per-row screen. The one rule it has to hold is that a proposal is
# only ever approved by the family it was made for: the security row is shared,
# so approving publishes the classification to everyone holding the instrument.
class SecurityClassificationProposalsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in users(:family_admin)
    @security = securities(:aapl)
    @family = users(:family_admin).family
    @proposal = Security::ClassificationProposal.propose!(
      security: @security, family: @family,
      asset_class: "equity", asset_sub_class: "stock", sector: "Technology",
      rationale: "Listed common stock on XNAS."
    )
  end

  test "the screen lists this family's pending proposals" do
    get security_classification_proposals_path

    assert_response :success
    assert_select "[data-proposal-id=?]", @proposal.id, { count: 1 }
    assert_includes response.body, "Technology"
  end

  test "an approved proposal is no longer listed" do
    @proposal.approve!

    get security_classification_proposals_path

    assert_select "[data-proposal-id=?]", @proposal.id, { count: 0 },
                  "an approved proposal is still queued for review"
  end

  test "approving from the screen classifies the security as ai" do
    post approve_security_classification_proposal_path(@proposal)

    @security.reload
    assert_equal "equity", @security.asset_class
    assert_equal "ai", @security.classification_source
    assert @proposal.reload.approved?
  end

  # The other half of the double guard, and the half no controller test drove.
  # `approve!` returns false when the security was answered by hand, or locked,
  # between the proposal being made and this click -- the window the veto exists
  # for -- and the action's `else` branch is what tells the user so. Without
  # this, that branch was reachable only through the model (raised by cubic on
  # #199).
  test "approving a proposal a person has since answered by hand reports that it was superseded" do
    @security.update!(asset_class: "fixed_income", classification_source: "manual")

    post approve_security_classification_proposal_path(@proposal)

    @security.reload
    assert_equal "fixed_income", @security.asset_class,
                 "the proposal overwrote an answer a person had just given"
    assert_equal "manual", @security.classification_source
    assert @proposal.reload.pending?, "a vetoed proposal was marked approved"
    assert_equal I18n.t("security_classification_proposals.approve.superseded", ticker: @security.ticker),
                 flash[:alert]
    assert_nil flash[:notice], "a vetoed approval still reported success"
  end

  # The guard in `reject!` is correct -- the proposal stays approved and the
  # security stays classified -- but the controller ignored its return value, so
  # a stale reject from a second tab still reported success. A flash that says
  # "dismissed" about a proposal still in force is worse than no flash.
  test "rejecting an already-approved proposal reports that it was superseded" do
    @proposal.approve!

    post reject_security_classification_proposal_path(@proposal)

    assert @proposal.reload.approved?
    assert_equal "ai", @security.reload.classification_source
    assert_equal I18n.t("security_classification_proposals.reject.superseded", ticker: @security.ticker),
                 flash[:alert]
    assert_nil flash[:notice], "a refused rejection still reported success"
  end

  test "rejecting from the screen leaves the security alone" do
    post reject_security_classification_proposal_path(@proposal)

    assert_nil @security.reload.asset_class
    assert @proposal.reload.rejected?
  end

  # The scoping test. Another family's proposal must not be reachable at all --
  # approving it would write the shared security row on their behalf.
  # The screen had NO role gate: `set_proposal` and nothing else. Approving
  # writes the globally shared `securities` row, so a read-only member of one
  # household could classify an instrument for every household holding it --
  # the same write the holding drawer puts behind a write-permission check two
  # clicks away (raised by the 2026-09-22 sweep, reproduced there).
  test "a guest cannot approve, and the security is untouched" do
    guest = users(:family_member)
    guest.update!(role: :guest)
    sign_in guest

    post approve_security_classification_proposal_path(@proposal)

    @security.reload
    assert_nil @security.asset_class, "a guest classified a security every household shares"
    assert_nil @security.classification_source
    assert @proposal.reload.pending?, "a guest's approval was recorded"
  end

  test "a guest cannot reject either" do
    guest = users(:family_member)
    guest.update!(role: :guest)
    sign_in guest

    post reject_security_classification_proposal_path(@proposal)

    assert @proposal.reload.pending?, "a guest dismissed the household's proposal"
  end

  # The positive half: the gate must admit someone who may write to a position
  # they can see the security in, or it has simply broken the screen.
  test "a member who may write to a holding of the security can approve" do
    member = users(:family_member)
    member.update!(role: :member)
    accounts(:investment).update!(owner: member)
    sign_in member

    post approve_security_classification_proposal_path(@proposal)

    assert_equal "equity", @security.reload.asset_class,
                 "the gate refused someone who may write to a holding of this security"
    assert @proposal.reload.approved?
  end

  test "another family's proposal cannot be approved" do
    other_family = users(:josh).family
    other_security = Security.create!(ticker: "MSFT2", exchange_operating_mic: "XNAS", country_code: "US")
    theirs = Security::ClassificationProposal.propose!(
      security: other_security, family: other_family, asset_class: "equity"
    )

    post approve_security_classification_proposal_path(theirs)

    assert_response :not_found
    assert_nil other_security.reload.asset_class
    assert theirs.reload.pending?
  end

  test "another family's proposals are not listed" do
    other_family = users(:josh).family
    other_security = Security.create!(ticker: "MSFT3", exchange_operating_mic: "XNAS", country_code: "US")
    theirs = Security::ClassificationProposal.propose!(
      security: other_security, family: other_family, asset_class: "equity"
    )

    get security_classification_proposals_path

    assert_select "[data-proposal-id=?]", theirs.id, { count: 0 },
                  "another family's proposal was listed"
  end
end
