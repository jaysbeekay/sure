# The value of a property or vehicle against the loans secured on it, on the
# asset's page and on each of those loans' pages. The arithmetic and the
# visibility rules live in Loan::CollateralPosition; this only lays it out.
class UI::Account::CollateralPosition < ApplicationComponent
  attr_reader :account, :viewer

  def initialize(account:, viewer:)
    @account = account
    @viewer = viewer
  end

  def render?
    position.present?
  end

  def position
    return @position if defined?(@position)

    @position = if account.loan?
      Loan::CollateralPosition.for_loan(account.loan, viewer: viewer)
    else
      Loan::CollateralPosition.for_collateral(account, viewer: viewer)
    end
  end

  def secured_by_loan?
    account.loan?
  end

  # The other side of the link, to link to: the asset from a loan, the loans
  # from an asset.
  def counterparts
    secured_by_loan? ? [ position.collateral ] : position.loan_accounts
  end

  def cards
    figures = [ [ t("UI.account.collateral_position.value"), position.value ] ]
    if position.complete?
      figures << [ t("UI.account.collateral_position.debt"), position.debt ]
      figures << [ t("UI.account.collateral_position.equity"), position.equity ]
    end
    figures.map { |title, money| [ title, money.format ] }
  end
end
