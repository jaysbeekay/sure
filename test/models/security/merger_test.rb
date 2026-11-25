require "test_helper"

class Security::MergerTest < ActiveSupport::TestCase
  include EntriesTestHelper

  setup do
    @account = accounts(:investment)
    @placeholder = Security.create!(ticker: "MRGX", offline: true, offline_reason: "resolution_pending")
    @listed = Security.create!(ticker: "MRGX", exchange_operating_mic: "XNAS", name: "Merge Co")
  end

  test "moves holdings, trades, prices, splits and tags onto the target and deletes the source" do
    only_on_placeholder = create_holding(@placeholder, date: 3.days.ago.to_date, qty: 2)
    newer_on_placeholder = create_holding(@placeholder, date: 2.days.ago.to_date, qty: 5)
    older_on_listed = create_holding(@listed, date: 2.days.ago.to_date, qty: 3)
    older_on_placeholder = create_holding(@placeholder, date: 1.day.ago.to_date, qty: 7)
    newer_on_listed = create_holding(@listed, date: 1.day.ago.to_date, qty: 4)
    older_on_listed.update_columns(updated_at: 1.hour.ago)
    older_on_placeholder.update_columns(updated_at: 1.hour.ago)

    trade_entry = create_trade(@placeholder, account: @account, qty: 1, date: 3.days.ago.to_date, price: 10)

    moved_price = Security::Price.create!(security: @placeholder, date: 3.days.ago.to_date, price: 10, currency: "USD")
    Security::Price.create!(security: @placeholder, date: 2.days.ago.to_date, price: 11, currency: "USD")
    kept_price = Security::Price.create!(security: @listed, date: 2.days.ago.to_date, price: 12, currency: "USD")

    moved_split = Security::Split.create!(security: @placeholder, ex_date: 10.days.ago.to_date, numerator: 2, denominator: 1, source: "manual")
    Security::Split.create!(security: @placeholder, ex_date: 20.days.ago.to_date, numerator: 3, denominator: 1, source: "manual")
    kept_split = Security::Split.create!(security: @listed, ex_date: 20.days.ago.to_date, numerator: 4, denominator: 1, source: "manual")

    Tagging.create!(tag: tags(:one), taggable: @placeholder)
    Tagging.create!(tag: tags(:one), taggable: @listed)
    Tagging.create!(tag: tags(:two), taggable: @placeholder)

    Account.any_instance.expects(:sync_later).once

    assert_equal @listed, Security::Merger.new(from: @placeholder, into: @listed).merge!

    assert_not Security.exists?(@placeholder.id)

    assert_equal @listed.id, only_on_placeholder.reload.security_id
    assert_equal @listed.id, newer_on_placeholder.reload.security_id
    assert_not Holding.exists?(older_on_listed.id)
    assert_not Holding.exists?(older_on_placeholder.id)
    assert_equal @listed.id, newer_on_listed.reload.security_id
    assert_equal [ 2, 5, 4 ], @account.holdings.where(security: @listed).order(:date).pluck(:qty).map(&:to_i)

    assert_equal @listed.id, trade_entry.reload.trade.security_id

    assert_equal [ moved_price.id, kept_price.id ].sort, @listed.prices.ids.sort
    assert_equal [ moved_split.id, kept_split.id ].sort, @listed.splits.ids.sort
    assert_equal [ tags(:one).id, tags(:two).id ].sort, Tagging.where(taggable: @listed).pluck(:tag_id).sort
  end

  test "repoints provider securities and drops remaps onto the security itself" do
    other = Security.create!(ticker: "MRGY", exchange_operating_mic: "XNAS")
    remapped_to_listed = create_holding(@listed, date: Date.current, qty: 1, provider_security: @placeholder, security_locked: true)
    remapped_elsewhere = create_holding(other, date: Date.current, qty: 1, provider_security: @placeholder, security_locked: true)

    Security::Merger.new(from: @placeholder, into: @listed).merge!

    remapped_to_listed.reload
    assert_nil remapped_to_listed.provider_security_id
    assert_not remapped_to_listed.security_locked

    remapped_elsewhere.reload
    assert_equal @listed.id, remapped_elsewhere.provider_security_id
    assert remapped_elsewhere.security_locked
  end

  test "combines opening lots and repoints lot origins" do
    HoldingLot.create!(account: @account, security: @placeholder, origin_security: @placeholder, qty: 2, currency: "USD")
    listed_lot = HoldingLot.create!(account: @account, security: @listed, origin_security: @listed, qty: 3, currency: "USD")

    Security::Merger.new(from: @placeholder, into: @listed).merge!

    lots = HoldingLot.where(account: @account, security: @listed)
    assert_equal [ listed_lot.id ], lots.ids
    assert_equal 5, listed_lot.reload.qty
    assert_not HoldingLot.where(origin_security_id: @placeholder.id).exists?
  end

  test "leaves both rows alone when the condition no longer holds under the lock" do
    @placeholder.update!(offline: false, offline_reason: nil)

    Security::Merger.new(from: @placeholder, into: @listed).merge!(condition: ->(source) { source.offline? })

    assert Security.exists?(@placeholder.id)
  end

  test "is a no-op when the source is the target" do
    Account.any_instance.expects(:sync_later).never

    assert_equal @listed, Security::Merger.new(from: @listed, into: @listed).merge!
    assert Security.exists?(@listed.id)
  end

  test "returns the target when the source was already merged" do
    stale = Security.find(@placeholder.id)
    Security::Merger.new(from: @placeholder, into: @listed).merge!

    assert_equal @listed, Security::Merger.new(from: stale, into: @listed).merge!
  end

  test "carries the source's locked manual classification onto an unclassified target" do
    classify_by_hand(@placeholder, asset_class: "equity", asset_sub_class: "etf", sector: "Technology", region: "europe")

    assert_changes -> { classification_of(@listed.reload) },
      from: [ nil, nil, nil, nil, nil, false ],
      to: [ "equity", "etf", "Technology", "europe", "manual", true ] do
      Security::Merger.new(from: @placeholder, into: @listed).merge!
    end
  end

  test "copies only the fields a sector-only source holds" do
    @listed.update!(asset_class: "equity", asset_sub_class: "stock", classification_source: "provider")
    classify_by_hand(@placeholder, sector: "Energy")

    Security::Merger.new(from: @placeholder, into: @listed).merge!

    @listed.reload
    assert_equal [ "equity", "stock", "Energy" ], [ @listed.asset_class, @listed.asset_sub_class, @listed.sector ]
    assert_equal [ "manual", true ], [ @listed.classification_source, @listed.classification_locked ]
  end

  test "a locked target keeps its own classification" do
    classify_by_hand(@listed, asset_class: "fixed_income", asset_sub_class: "bond", sector: "Government", region: "north_america")
    classify_by_hand(@placeholder, asset_class: "equity", asset_sub_class: "etf", sector: "Technology", region: "europe")

    assert_no_changes -> { classification_of(@listed.reload) } do
      Security::Merger.new(from: @placeholder, into: @listed).merge!
    end
  end

  test "reads the target's lock from the locked row, not a stale caller copy" do
    stale_target = Security.find(@listed.id)
    classify_by_hand(@listed, asset_class: "fixed_income", asset_sub_class: "bond", sector: "Government", region: "north_america")
    classify_by_hand(@placeholder, asset_class: "equity", asset_sub_class: "etf", sector: "Technology", region: "europe")

    assert_no_changes -> { classification_of(@listed.reload) } do
      Security::Merger.new(from: @placeholder, into: stale_target).merge!
    end
  end

  test "an unlocked source leaves the target's classification alone" do
    @listed.update!(asset_class: "equity", asset_sub_class: "stock", classification_source: "provider")
    @placeholder.update!(asset_class: "fixed_income", asset_sub_class: "bond", sector: "Government", region: "europe", classification_source: "provider")

    assert_no_changes -> { classification_of(@listed.reload) } do
      Security::Merger.new(from: @placeholder, into: @listed).merge!
    end
  end

  test "moves the source's classification proposals onto the target" do
    proposal = Security::ClassificationProposal.create!(security: @placeholder, family: families(:dylan_family), asset_class: "equity")

    assert_no_difference -> { Security::ClassificationProposal.count } do
      Security::Merger.new(from: @placeholder, into: @listed).merge!
    end

    assert_equal @listed.id, proposal.reload.security_id
  end

  test "keeps the target's proposal when one family has a proposal on both rows" do
    family = families(:dylan_family)
    Security::ClassificationProposal.create!(security: @placeholder, family: family, asset_class: "equity")
    kept = Security::ClassificationProposal.create!(security: @listed, family: family, asset_class: "fixed_income")

    Security::Merger.new(from: @placeholder, into: @listed).merge!

    assert_not Security.exists?(@placeholder.id)
    assert_equal [ kept.id ], Security::ClassificationProposal.where(family: family).ids
    assert_equal @listed.id, kept.reload.security_id
  end

  test "a proposal moved onto a target that ends up locked cannot be approved" do
    proposal = Security::ClassificationProposal.create!(security: @placeholder, family: families(:dylan_family), asset_class: "fixed_income", asset_sub_class: "bond")
    classify_by_hand(@placeholder, asset_class: "equity", asset_sub_class: "etf")

    Security::Merger.new(from: @placeholder, into: @listed).merge!

    assert_no_changes -> { classification_of(@listed.reload) } do
      assert_not proposal.reload.approve!
    end
    assert proposal.reload.pending?
  end

  test "an empty target receives the source's constituents" do
    moved = Security::Constituent.create!(security: @placeholder, ticker: "AAPL", weight: 60)

    assert_changes -> { @listed.constituents.ids }, from: [], to: [ moved.id ] do
      Security::Merger.new(from: @placeholder, into: @listed).merge!
    end
  end

  test "a target with constituents keeps its own list" do
    Security::Constituent.create!(security: @placeholder, ticker: "AAPL", weight: 60)
    kept = Security::Constituent.create!(security: @listed, ticker: "MSFT", weight: 40)

    Security::Merger.new(from: @placeholder, into: @listed).merge!

    assert_equal [ kept.id ], @listed.constituents.ids
    assert_not Security::Constituent.where(security_id: @placeholder.id).exists?
  end

  private
    def create_holding(security, date:, qty:, **attributes)
      @account.holdings.create!(security: security, date: date, qty: qty, price: 10, amount: qty * 10, currency: "USD", **attributes)
    end

    # What HoldingsController#classification writes.
    def classify_by_hand(security, **fields)
      security.update!(**fields, classification_source: "manual", classification_locked: true)
    end

    def classification_of(security)
      security.slice(:asset_class, :asset_sub_class, :sector, :region, :classification_source, :classification_locked).values
    end
end
