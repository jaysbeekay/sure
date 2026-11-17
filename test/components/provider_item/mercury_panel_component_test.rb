# frozen_string_literal: true

require "test_helper"

class ProviderItem::MercuryPanelComponentTest < ActiveSupport::TestCase
  include ProviderItemSnapshots

  setup do
    travel_to Time.zone.parse("2026-11-15 12:00:00")
    @item = mercury_items(:one)
    Current.stubs(:user).returns(users(:family_admin))
    Current.stubs(:family).returns(@item.family)
  end

  CASES = {
    "mercury_panel_without_connections" => { items: :none },
    "mercury_panel_with_connection" => { items: :one },
    "mercury_panel_syncing_with_error" => { items: :one, syncing: true, error: "Token rejected" }
  }.freeze

  CASES.each do |name, options|
    test "#{name}: the panel partial renders as before" do
      assert_matches_provider_item_snapshot(name, render_panel(options))
    end
  end

  test "the Mercury panel renders through ProviderItem::PanelComponent" do
    ProviderItem::PanelComponent.any_instance.expects(:before_render).once

    render_panel(items: :one)
  end

  test "the disconnect button has an aria-label naming the connection" do
    doc = Nokogiri::HTML.parse(render_panel(items: :one))

    button = doc.css("button").find { |b| b.text.strip == "Disconnect" }
    refute_nil button, "expected a button with the text 'Disconnect' in the Mercury panel"

    expected = "Disconnect #{@item.name}"
    assert_equal expected, button["aria-label"],
      "the Mercury Disconnect button should carry aria-label=\"#{expected}\" so screen " \
      "readers announce which connection is being disconnected; " \
      "it currently has no aria-label (or a different one)"
  end

  private
    def render_panel(options)
      @item.class.any_instance.stubs(:syncing?).returns(true) if options[:syncing]
      items = options[:items] == :none ? @item.class.none : @item.class.where(id: @item.id)

      ApplicationController.render(partial: "settings/providers/mercury_panel", locals: { mercury_items: items, error_message: options[:error] })
    end
end
