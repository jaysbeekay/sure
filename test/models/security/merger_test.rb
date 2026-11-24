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

  test "returns nil and keeps the source when the target was already merged away" do
    stale_target = Security.find(@listed.id)
    @listed.destroy!

    assert_nil Security::Merger.new(from: @placeholder, into: stale_target).merge!
    assert Security.exists?(@placeholder.id)
  end

  test "copies a locked manual classification onto an unlocked target" do
    lock_classification(@placeholder, asset_class: "equity", asset_sub_class: "etf", sector: "Technology", industry: "Software", region: "europe")
    before = classification_of(@listed)

    Security::Merger.new(from: @placeholder, into: @listed).merge!

    assert_equal({ "asset_class" => nil, "asset_sub_class" => nil, "sector" => nil, "industry" => nil, "region" => nil, "classification_source" => nil, "classification_locked" => false }, before)
    assert_equal({ "asset_class" => "equity", "asset_sub_class" => "etf", "sector" => "Technology", "industry" => "Software", "region" => "europe", "classification_source" => "manual", "classification_locked" => true },
      classification_of(@listed))
  end

  test "copies an approved AI classification, unlocked, onto an unclassified target" do
    @placeholder.update!(asset_class: "fixed_income", asset_sub_class: "bond", sector: "Government", classification_source: "ai")

    Security::Merger.new(from: @placeholder, into: @listed).merge!

    assert_equal({ "asset_class" => "fixed_income", "asset_sub_class" => "bond", "sector" => "Government", "industry" => nil, "region" => nil, "classification_source" => "ai", "classification_locked" => false },
      classification_of(@listed))
  end

  test "a manual source outranks an AI target, and nothing else outranks the target" do
    [
      [ "manual", "ai", true ],
      [ "ai", "ai", false ],
      [ "manual", "manual", false ],
      [ "ai", "manual", false ]
    ].each do |source, target, copies|
      @listed.update!(asset_class: "fixed_income", asset_sub_class: "bond", sector: "Government", classification_source: target, classification_locked: false)
      placeholder = Security.create!(ticker: "MRG#{source.upcase}#{target.upcase}", offline: true, offline_reason: "resolution_pending")
      placeholder.update!(asset_class: "equity", asset_sub_class: "stock", sector: "Technology", classification_source: source)
      before = classification_of(@listed)

      Security::Merger.new(from: placeholder, into: @listed).merge!

      expected = copies ? before.merge("asset_class" => "equity", "asset_sub_class" => "stock", "sector" => "Technology", "classification_source" => source) : before
      assert_equal expected, classification_of(@listed), "#{source} source onto #{target} target"
    end
  end

  test "classifies a target that fails validation for an unrelated reason" do
    @listed.update_column(:price_provider, "retired_provider")
    assert_not @listed.reload.valid?
    lock_classification(@placeholder, asset_class: "equity", asset_sub_class: "etf")

    Security::Merger.new(from: @placeholder, into: @listed).merge!

    assert_not Security.exists?(@placeholder.id)
    assert_equal [ "equity", "etf", "manual" ], @listed.reload.attributes.values_at("asset_class", "asset_sub_class", "classification_source")
  end

  test "copies the source's name onto a nameless target" do
    @listed.update!(name: nil)
    @placeholder.update!(name: "Placeholder Co")

    Security::Merger.new(from: @placeholder, into: @listed).merge!

    assert_equal "Placeholder Co", @listed.reload.name
  end

  test "returns the target row as the merge left it" do
    lock_classification(@placeholder, asset_class: "equity", asset_sub_class: "etf")

    merged = Security::Merger.new(from: @placeholder, into: @listed).merge!

    assert_equal @listed.id, merged.id
    assert_equal [ "equity", true ], [ merged.asset_class, merged.classification_locked ]
  end

  test "locks no proposal row before the security rows" do
    locks = []
    collect = ->(*, payload) { locks << payload[:sql][/FROM "(securities|security_classification_proposals)"/, 1] if payload[:sql].include?("FOR UPDATE") }

    ActiveSupport::Notifications.subscribed(collect, "sql.active_record") do
      Security::Merger.new(from: @placeholder, into: @listed).merge!
    end

    assert_equal [ "securities" ], locks.compact.uniq
  end

  test "a sector-only source leaves the target's classification untouched" do
    @listed.update!(asset_class: "equity", asset_sub_class: "stock", classification_source: "provider")
    lock_classification(@placeholder, sector: "Energy", industry: "Oil & Gas")
    before = classification_of(@listed)

    Security::Merger.new(from: @placeholder, into: @listed).merge!

    assert_equal before, classification_of(@listed)
  end

  test "a locked target keeps its own classification" do
    @listed.update!(asset_class: "fixed_income", asset_sub_class: "bond", sector: "Government", classification_source: "provider", classification_locked: true)
    lock_classification(@placeholder, asset_class: "equity", asset_sub_class: "stock", sector: "Technology", region: "europe")
    before = classification_of(@listed)

    Security::Merger.new(from: @placeholder, into: @listed).merge!

    assert_equal before, classification_of(@listed)
  end

  test "reads the target's lock under the merge lock, not from a stale target" do
    [
      { classification_source: "provider", classification_locked: true },
      { classification_source: "manual", classification_locked: false }
    ].each_with_index do |concurrent_write, i|
      placeholder = Security.create!(ticker: "MRGS#{i}", offline: true, offline_reason: "resolution_pending")
      lock_classification(placeholder, asset_class: "equity", asset_sub_class: "stock", sector: "Technology")
      @listed.update_columns(sector: nil, classification_source: nil, classification_locked: false)
      stale_target = Security.find(@listed.id)
      @listed.update!(sector: "Government", **concurrent_write)
      before = classification_of(@listed)

      Security::Merger.new(from: placeholder, into: stale_target).merge!

      assert_equal before, classification_of(@listed), concurrent_write.inspect
    end
  end

  test "an unlocked source leaves the target's classification alone" do
    @placeholder.update!(asset_class: "equity", asset_sub_class: "stock", sector: "Technology", classification_source: "provider")
    before = classification_of(@listed)

    Security::Merger.new(from: @placeholder, into: @listed).merge!

    assert_equal before, classification_of(@listed)
  end

  test "moves the source's classification proposals onto the target" do
    proposal = Security::ClassificationProposal.create!(security: @placeholder, family: families(:dylan_family), sector: "Technology")

    assert_difference -> { Security::ClassificationProposal.where(security: @listed).count }, 1 do
      Security::Merger.new(from: @placeholder, into: @listed).merge!
    end

    assert_equal @listed.id, proposal.reload.security_id
  end

  test "keeps the target's proposal when one family has a proposal on both rows" do
    family = families(:dylan_family)
    Security::ClassificationProposal.create!(security: @placeholder, family: family, sector: "Technology")
    kept = Security::ClassificationProposal.create!(security: @listed, family: family, sector: "Energy")

    Security::Merger.new(from: @placeholder, into: @listed).merge!

    assert_equal [ kept.id ], Security::ClassificationProposal.where(family: family).ids
    assert_equal @listed.id, kept.reload.security_id
  end

  test "keeps the pending proposal when only the source's is pending" do
    family = families(:dylan_family)
    pending = Security::ClassificationProposal.create!(security: @placeholder, family: family, sector: "Technology")
    Security::ClassificationProposal.create!(security: @listed, family: family, sector: "Energy").reject!

    Security::Merger.new(from: @placeholder, into: @listed).merge!

    assert_equal [ pending.id ], Security::ClassificationProposal.where(family: family).ids
    assert_equal [ @listed.id, "pending" ], pending.reload.attributes.values_at("security_id", "status")
  end

  test "a proposal moved onto a target that ends up locked cannot be approved" do
    proposal = Security::ClassificationProposal.create!(security: @placeholder, family: families(:dylan_family), asset_class: "fixed_income", asset_sub_class: "bond")
    lock_classification(@placeholder, asset_class: "equity", asset_sub_class: "stock")

    Security::Merger.new(from: @placeholder, into: @listed).merge!
    before = classification_of(@listed)

    assert_not proposal.reload.approve!
    assert proposal.pending?
    assert_equal before, classification_of(@listed)
    assert_equal "equity", @listed.reload.asset_class
  end

  test "moves the source's constituents onto a target that has none" do
    @placeholder.constituents.create!(ticker: "AAA", weight: 60)
    @placeholder.constituents.create!(ticker: "BBB", weight: 40)

    Security::Merger.new(from: @placeholder, into: @listed).merge!

    assert_equal [ "AAA", "BBB" ], @listed.constituents.order(:ticker).pluck(:ticker)
  end

  test "moved constituents carry the source's fetch stamp" do
    fetched_at = 3.days.ago.change(usec: 0)
    @placeholder.constituents.create!(ticker: "AAA", weight: 100)
    @placeholder.update_column(:constituents_fetched_at, fetched_at)

    Security::Merger.new(from: @placeholder, into: @listed).merge!

    assert_equal fetched_at, @listed.reload.constituents_fetched_at
  end

  test "a source the provider answered with no constituents passes its stamp to a target never asked" do
    fetched_at = 2.days.ago.change(usec: 0)
    @placeholder.update_column(:constituents_fetched_at, fetched_at)

    Security::Merger.new(from: @placeholder, into: @listed).merge!

    assert_equal fetched_at, @listed.reload.constituents_fetched_at
    assert_empty @listed.constituents
  end

  test "a target whose provider reported no constituents keeps none" do
    fetched_at = 1.day.ago.change(usec: 0)
    @listed.update_column(:constituents_fetched_at, fetched_at)
    @placeholder.constituents.create!(ticker: "AAA", weight: 100)

    Security::Merger.new(from: @placeholder, into: @listed).merge!

    assert_empty @listed.constituents
    assert_equal fetched_at, @listed.reload.constituents_fetched_at
  end

  test "a target with constituents keeps its own list" do
    @placeholder.constituents.create!(ticker: "AAA", weight: 60)
    @listed.constituents.create!(ticker: "ZZZ", weight: 100)

    Security::Merger.new(from: @placeholder, into: @listed).merge!

    assert_equal [ "ZZZ" ], @listed.constituents.pluck(:ticker)
    assert_not Security::Constituent.where(security_id: @placeholder.id).exists?
  end

  private
    def lock_classification(security, **attributes)
      security.update!(**attributes, classification_source: "manual", classification_locked: true)
    end

    def classification_of(security)
      security.reload.attributes.slice("asset_class", "asset_sub_class", "sector", "industry", "region", "classification_source", "classification_locked")
    end

    def create_holding(security, date:, qty:, **attributes)
      @account.holdings.create!(security: security, date: date, qty: qty, price: 10, amount: qty * 10, currency: "USD", **attributes)
    end
end
