# frozen_string_literal: true

class Assistant::Function::GetPortfolioAllocation < Assistant::Function
  include Assistant::Function::PortfolioSupport

  DIMENSIONS = %w[asset_class asset_sub_class sector region account currency kind tag security].freeze
  LOOK_THROUGH_DIMENSIONS = %w[asset_class asset_sub_class sector region].freeze

  class << self
    def name
      "get_portfolio_allocation"
    end

    def description
      <<~INSTRUCTIONS
        Returns how the user's current investment and crypto holdings are split, as the
        portfolio page's allocation does, by one dimension: asset_class, asset_sub_class,
        sector, region, account, currency, kind, tag, or security. Each segment has its
        value in the family currency and its weight in the total, as a fraction with
        a formatted percentage, the same shape as every return in these tools.

        look_through (asset_class, asset_sub_class, sector and region only) splits a
        fund into what it holds, where the fund's constituents are known. The
        look_through in the result says whether it was actually applied: false
        when no fund held has known constituents, so the split is the plain one.
      INSTRUCTIONS
    end
  end

  def strict_mode?
    false
  end

  def params_schema
    build_schema(
      required: [ "by" ],
      properties: {
        by: { type: "string", enum: DIMENSIONS, description: "The dimension to split by" },
        look_through: { type: "boolean", description: "Split funds into their constituents (classification dimensions only)" }
      }
    )
  end

  def call(params = {})
    by = params["by"].to_s
    return portfolio_error("invalid_dimension", "by must be one of: #{DIMENSIONS.join(", ")}.") unless by.in?(DIMENSIONS)

    look_through = ActiveModel::Type::Boolean.new.cast(params["look_through"]) || false
    if look_through && !by.in?(LOOK_THROUGH_DIMENSIONS)
      return portfolio_error("invalid_look_through", "look_through applies only to #{LOOK_THROUGH_DIMENSIONS.join(", ")}.")
    end

    segments = investment_statement.allocation_by(by, look_through: look_through)

    {
      by: by,
      # Applied, not requested. The page passes the request through as this
      # does and offers the toggle only when a held fund has known
      # constituents; without one the split is the plain one, and echoing the
      # request would claim a look-through that never happened.
      look_through: look_through && investment_statement.holds_any_fund_constituents?,
      currency: family.currency,
      segments: segments.map do |segment|
        { id: segment.id, name: segment.name, value: money(segment.amount), weight: percent(segment.weight.to_d / 100) }
      end,
      total: money(segments.sum { |segment| segment.amount.is_a?(Money) ? segment.amount.amount : segment.amount.to_d })
    }
  end
end
