require "test_helper"

# 3.1 classifies what a provider answers for; 3.2 classifies what an instrument's
# own shape implies. Everything else -- every ETF, every country the region config
# does not name -- is left unclassified on purpose, and 3.3's drawer fixes those
# one at a time. This is the bulk path.
#
# The rule the whole model exists to enforce: the assistant proposes, a person
# approves. A proposal is never a classification until someone says so, because
# `classification_source` exists so a figure in an allocation chart can be traced
# to whoever asserted it.
class Security::ClassificationProposalTest < ActiveSupport::TestCase
  include ProviderTestHelper

  setup do
    @security = securities(:aapl)
    @family = families(:dylan_family)
  end

  # ------------------------------------------------------------- proposing

  test "a proposal is stored pending, and changes nothing about the security" do
    proposal = propose(asset_class: "equity", asset_sub_class: "stock", sector: "Technology")

    assert proposal.pending?
    assert_nil @security.reload.asset_class, "proposing classified the security"
    assert_nil @security.classification_source
  end

  # The user's own answer is not second-guessed.
  test "a manually classified security cannot be proposed for" do
    @security.update!(asset_class: "fixed_income", classification_source: "manual")

    proposal = Security::ClassificationProposal.new(
      security: @security, family: @family, asset_class: "equity"
    )

    assert_not proposal.valid?
    assert_includes proposal.errors[:security], "has already been classified by hand"
  end

  test "a locked security cannot be proposed for" do
    @security.update!(classification_locked: true)

    proposal = Security::ClassificationProposal.new(
      security: @security, family: @family, asset_class: "equity"
    )

    assert_not proposal.valid?
  end

  # A proposal that could not be approved must not be storable: the vocabularies
  # are database check constraints on `securities`, so storing an unapprovable
  # proposal only defers the failure to approval time.
  test "a proposal outside the vocabulary is refused" do
    %i[asset_class asset_sub_class region].each do |field|
      proposal = Security::ClassificationProposal.new(
        security: @security, family: @family, field => "nonsense"
      )

      assert_not proposal.valid?, "#{field} accepted a value outside its vocabulary"
      assert_includes proposal.errors[field], "is not included in the list"
    end
  end

  test "re-proposing for the same security replaces rather than duplicating" do
    propose(asset_class: "equity", sector: "First answer")

    assert_no_difference "Security::ClassificationProposal.count" do
      propose(asset_class: "commodity", sector: "Second answer")
    end

    proposal = Security::ClassificationProposal.sole
    assert_equal "commodity", proposal.asset_class
    assert_equal "Second answer", proposal.sector
  end

  # An empty proposal was valid, storable AND approvable, and approval stamped
  # `classification_source: "ai"` on a security with nothing classified. Because
  # "ai" is not in the `[nil, "default"]` set `classification_attributes_from`
  # will overwrite, that security could then never be classified by a provider
  # again -- a permanent lock-out bought with no information at all. The tool's
  # params_schema requires only `ticker`, so the model can send exactly this.
  test "a proposal that answers nothing is refused" do
    proposal = Security::ClassificationProposal.new(security: @security, family: @family)

    assert_not proposal.valid?
    assert_includes proposal.errors[:base], "must propose at least one classification"
  end

  test "a proposal carrying only a rationale is refused" do
    proposal = Security::ClassificationProposal.new(
      security: @security, family: @family, rationale: "Looks like a tech stock."
    )

    assert_not proposal.valid?
  end

  test "a proposal answering a single field is enough" do
    assert Security::ClassificationProposal.new(
      security: @security, family: @family, region: "europe"
    ).valid?
  end

  # ------------------------------------------------------- lifecycle safety

  # `family.destroy` is reached by User#purge, InactiveFamilyCleanerJob,
  # Admin::FamiliesController#destroy and Demo::DataCleaner. A proposal row held
  # a foreign key nothing cascaded, so any family that had ever been offered a
  # classification became undeletable.
  test "a family with a proposal can still be destroyed" do
    family = Family.create!(name: "Doomed", currency: "USD")
    Security::ClassificationProposal.propose!(
      security: @security, family: family, asset_class: "equity"
    )

    assert_difference "Security::ClassificationProposal.count", -1 do
      family.destroy!
    end

    assert Security.exists?(@security.id), "destroying the family took the shared security with it"
  end

  # Same shape from the other side: the duplicate-security merge in
  # lib/tasks/securities.rake destroys a security.
  test "a security with a proposal can still be destroyed" do
    doomed = Security.create!(ticker: "DOOMED", exchange_operating_mic: "XNAS")
    Security::ClassificationProposal.propose!(
      security: doomed, family: @family, asset_class: "equity"
    )

    assert_difference "Security::ClassificationProposal.count", -1 do
      doomed.destroy!
    end
  end

  # -------------------------------------------------------------- approving

  test "approving writes the security and records the source as ai" do
    proposal = propose(
      asset_class: "equity", asset_sub_class: "stock",
      sector: "Technology", region: "north_america"
    )

    assert proposal.approve!

    @security.reload
    assert_equal "equity", @security.asset_class
    assert_equal "stock", @security.asset_sub_class
    assert_equal "Technology", @security.sector
    assert_equal "north_america", @security.region
    assert_equal "ai", @security.classification_source
    assert proposal.reload.approved?
  end

  # The assertion the slice rests on, and the mirror of 3.3's. `"ai"` is not in
  # the `[nil, "default"]` set `classification_attributes_from` will overwrite,
  # so an approved proposal has to outrank a later provider answer -- otherwise
  # the next sync silently undoes the approval.
  test "an approved classification survives a provider that disagrees" do
    propose(asset_class: "equity", asset_sub_class: "stock", sector: "Technology").approve!

    @security.reload.stubs(:price_data_provider).returns(stub_provider)
    @security.import_provider_details(include_classification: true)

    @security.reload
    assert_equal "equity", @security.asset_class
    assert_equal "Technology", @security.sector
    assert_equal "ai", @security.classification_source
  end

  # The window between proposing and approving is exactly where the security's
  # state can change, so the lock is re-checked at approval rather than trusted
  # from validation time.
  test "a security locked after the proposal was made is not approved over" do
    proposal = propose(asset_class: "equity", asset_sub_class: "stock")

    @security.update_columns(
      asset_class: "fixed_income", asset_sub_class: "bond",
      classification_source: "manual", classification_locked: true
    )

    assert_not proposal.approve!
    assert_equal "fixed_income", @security.reload.asset_class,
                 "an approval overwrote a classification locked after the proposal"
    assert proposal.reload.pending?, "a refused approval should not be marked approved"
  end

  # The security must already HOLD the columns this proposal leaves alone, or the
  # test proves nothing: asserting `asset_class` is nil when it was nil anyway
  # passes whether or not the blank values are stripped. An earlier version of
  # this test did exactly that and survived removing `compact_blank`.
  test "a proposal that only answers the region does not blank the columns it left alone" do
    @security.update!(
      asset_class: "equity", asset_sub_class: "stock",
      sector: "Technology", classification_source: "provider"
    )

    propose(region: "europe").approve!

    @security.reload
    assert_equal "europe", @security.region
    assert_equal "equity", @security.asset_class, "a column the proposal did not answer was blanked"
    assert_equal "stock", @security.asset_sub_class
    assert_equal "Technology", @security.sector
    assert_equal "ai", @security.classification_source
  end

  # -------------------------------------------------------------- rejecting

  # Rejection was unconditional, so a stale reject form from another tab moved an
  # already-approved proposal to `rejected` while the security stayed "ai" --
  # the row then denied a classification that is still in force.
  test "rejecting an already-approved proposal is refused" do
    proposal = propose(asset_class: "equity", asset_sub_class: "stock")
    proposal.approve!

    assert_not proposal.reject!
    assert proposal.reload.approved?, "an approved proposal was moved back to rejected"
    assert_equal "ai", @security.reload.classification_source
  end

  test "rejecting leaves the security untouched" do
    proposal = propose(asset_class: "equity", asset_sub_class: "stock")

    proposal.reject!

    assert proposal.reload.rejected?
    assert_nil @security.reload.asset_class
    assert_nil @security.classification_source
  end

  private
    def propose(**attrs)
      Security::ClassificationProposal.propose!(
        security: @security, family: @family, **attrs
      )
    end

    def stub_provider
      info = Provider::SecurityConcept::SecurityInfo.new(
        symbol: "AAPL", name: nil, links: nil, logo_url: nil, description: nil,
        kind: "Common Stock", exchange_operating_mic: "XNAS",
        sector: "Provider sector", industry: "Consumer Electronics"
      )
      provider = mock("provider")
      provider.stubs(:class).returns(Provider::TwelveData)
      provider.stubs(:fetch_security_info).returns(provider_success_response(info))
      provider
    end
end
