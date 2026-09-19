require "test_helper"

# 3.1 and 3.2 shipped a precedence ladder and left one rung of it unreachable:
# `classification_source: "manual"` outranks a provider and `classification_locked`
# vetoes every writer, but nothing in the application could set either. These
# assert the drawer can now set them, and -- more importantly -- that setting
# them actually stops the writers that read them.
class HoldingsClassificationTest < ActionDispatch::IntegrationTest
  include ProviderTestHelper

  setup do
    sign_in users(:family_admin)
    @holding = holdings(:one)
    @security = @holding.security
  end

  # ------------------------------------------------------------ the write

  test "a manual classification is stored, and recorded as manual and locked" do
    patch classification_holding_path(@holding), params: { security: {
      asset_class: "equity", asset_sub_class: "stock",
      sector: "Technology", region: "north_america"
    } }

    @security.reload
    assert_equal "equity", @security.asset_class
    assert_equal "stock", @security.asset_sub_class
    assert_equal "Technology", @security.sector
    assert_equal "north_america", @security.region
    assert_equal "manual", @security.classification_source,
                 "the source is what makes a provider defer to this"
    assert @security.classification_locked?,
           "the lock is what makes the defaults defer to this"
  end

  # The whole reason the slice exists. Writing the four columns is not the
  # point; writing the two that make the merged slices' precedence rules fire
  # is. This fails if the action saves the classification but not the
  # provenance -- which is exactly the shape a careless implementation takes.
  test "a manual classification survives a provider that disagrees" do
    patch classification_holding_path(@holding), params: { security: {
      asset_class: "fixed_income", asset_sub_class: "bond", sector: "Hand-picked"
    } }

    @security.reload.stubs(:price_data_provider).returns(
      stub_provider(info(kind: "Common Stock", sector: "Technology", industry: "Consumer Electronics"))
    )
    @security.import_provider_details(include_classification: true)

    @security.reload
    assert_equal "fixed_income", @security.asset_class, "the provider overwrote a manual classification"
    assert_equal "bond", @security.asset_sub_class
    assert_equal "Hand-picked", @security.sector
    assert_equal "manual", @security.classification_source
  end

  # The negative of the test above, and the reason it proves anything. Without
  # this, a lock that was stuck on permanently would pass that test too.
  test "resetting the classification lets the provider back in" do
    patch classification_holding_path(@holding), params: { security: {
      asset_class: "fixed_income", asset_sub_class: "bond", sector: "Hand-picked"
    } }

    post reset_classification_holding_path(@holding)

    @security.reload
    assert_not @security.classification_locked?, "the lock survived the reset"
    assert_nil @security.classification_source

    @security.stubs(:price_data_provider).returns(
      stub_provider(info(kind: "Common Stock", sector: "Technology", industry: "Consumer Electronics"))
    )
    @security.import_provider_details(include_classification: true)

    @security.reload
    assert_equal "equity", @security.asset_class, "the provider is still locked out after a reset"
    assert_equal "Technology", @security.sector
    assert_equal "provider", @security.classification_source
  end

  # --------------------------------------------------------- what is refused

  # `chk_securities_asset_class` is a database check constraint. A value outside
  # the vocabulary has to be caught by the model, or the request is a 500 from
  # Postgres rather than a refusal.
  test "an asset class outside the vocabulary is refused, not passed to the database" do
    @security.update!(asset_class: "equity", asset_sub_class: "stock")

    assert_nothing_raised do
      patch classification_holding_path(@holding), params: { security: { asset_class: "nonsense" } }
    end

    assert_equal "equity", @security.reload.asset_class, "an invalid submission changed the row"
    assert_nil @security.classification_source, "an invalid submission claimed the classification"
  end

  test "a region outside the vocabulary is refused" do
    patch classification_holding_path(@holding), params: { security: { region: "atlantis" } }

    assert_nil @security.reload.region
  end

  # 3.4's `classification_bucket` uses `.presence`, so an empty string would
  # group correctly -- but `import_provider_details` gates on `sector.blank?`
  # and a future `WHERE sector IS NULL` would not. Store one shape, not two.
  #
  # The success flash is asserted first on purpose. An earlier version of this
  # test submitted a blank REGION alongside, which without the normalisation
  # fails `inclusion` and rejects the whole save -- leaving `sector` at the nil
  # it already held, so the test passed while the normalisation was gone.
  test "a blank sector clears the column to nil rather than storing an empty string" do
    @security.update!(sector: "Technology")

    patch classification_holding_path(@holding), params: { security: {
      asset_class: "equity", asset_sub_class: "stock", sector: "", region: "north_america"
    } }

    assert_equal I18n.t("securities.classification.saved"), flash[:notice],
                 "the save was refused, so this asserts nothing about normalisation"
    @security.reload
    assert_nil @security.sector
    assert_equal "equity", @security.asset_class
  end

  # The other half: `region` IS validated against a vocabulary, so a blank that
  # is not normalised does not merely store badly -- it fails `inclusion` and
  # refuses a legitimate "clear this field" edit outright.
  test "a blank region clears the column rather than being refused" do
    @security.update!(region: "europe")

    patch classification_holding_path(@holding), params: { security: {
      asset_class: "equity", asset_sub_class: "stock", region: ""
    } }

    assert_equal I18n.t("securities.classification.saved"), flash[:notice],
                 "a blank region was rejected instead of clearing the field"
    assert_nil @security.reload.region
  end

  # ------------------------------------------------------- who may write it

  # The account is shared with the guest explicitly, so this exercises
  # `require_holding_write_permission!` rather than falling at `set_holding`
  # and passing for the wrong reason.
  test "a read-only member cannot classify a holding" do
    guest = family_guest
    @holding.account.unshare_with!(guest)
    @holding.account.share_with!(guest, permission: "read_only")

    sign_in guest

    patch classification_holding_path(@holding), params: { security: { asset_class: "equity" } }

    assert_equal :read_only, @holding.account.reload.permission_for(guest),
                 "the guest could not even reach the holding, so the permission gate was never tested"
    assert_nil @security.reload.asset_class
    assert_equal I18n.t("accounts.not_authorized"), flash[:alert]
  end

  # `show_exceptions` is `:rescuable` in the test environment, so a holding
  # outside the family is a rendered 404 rather than a raised RecordNotFound.
  test "a holding belonging to another family is not reachable" do
    other = users(:josh)
    assert_not_equal other.family_id, users(:family_admin).family_id

    sign_in other
    patch classification_holding_path(@holding), params: { security: { asset_class: "equity" } }

    assert_response :not_found
    assert_nil @security.reload.asset_class
  end

  # ----------------------------------------------------------------- the UI

  # The field NAMES are asserted, not just the form's presence. The controller
  # tests post their params by hand, so a form that rendered `holding[sector]`
  # would leave every one of them passing and the drawer inert -- which is the
  # defect #191 had when a select was added without the matching permit.
  test "the drawer offers the classification form, with the names the action permits" do
    @security.update!(asset_class: "equity", sector: "Technology")

    get holding_path(@holding)

    assert_response :success
    assert_select "form[action=?]", classification_holding_path(@holding), { count: 1 },
                  "the drawer has no classification form, so the columns are still unreachable"
    %w[asset_class asset_sub_class sector region].each do |field|
      assert_select "form[action=?] [name=?]", classification_holding_path(@holding),
                    "security[#{field}]", { count: 1 },
                    "the form does not submit security[#{field}], so the action never receives it"
    end
    assert_select "form[action=?] select[name=?] option[selected]",
                  classification_holding_path(@holding), "security[asset_class]",
                  { count: 1 }, "the form does not preselect the stored asset class"
  end

  test "the reset control appears only once a classification has been locked" do
    get holding_path(@holding)
    assert_select "form[action=?]", reset_classification_holding_path(@holding), { count: 0 }

    patch classification_holding_path(@holding), params: { security: { asset_class: "equity" } }
    get holding_path(@holding)

    assert_select "form[action=?]", reset_classification_holding_path(@holding), { count: 1 }
  end

  private
    def info(sector: nil, industry: nil, kind: nil)
      Provider::SecurityConcept::SecurityInfo.new(
        symbol: "AAPL", name: nil, links: nil, logo_url: nil, description: nil,
        kind: kind, exchange_operating_mic: "XNAS", sector: sector, industry: industry
      )
    end

    def stub_provider(data)
      provider = mock("provider")
      provider.stubs(:class).returns(Provider::TwelveData)
      provider.stubs(:fetch_security_info).returns(provider_success_response(data))
      provider
    end
end
