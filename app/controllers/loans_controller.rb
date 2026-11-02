class LoansController < ApplicationController
  include AccountableResource

  before_action :protect_inaccessible_collateral, only: :update
  before_action :set_collateral_candidates, only: %i[new create edit update]

  permitted_accountable_attributes(
    :id, :subtype, :rate_type, :interest_rate, :term_months, :initial_balance, :start_date,
    :down_payment, :insurance_rate, :insurance_rate_type, :day_count_convention, :collateral_account_id,
    { rate_changes: [ :effective_date, :rate ] }
  )

  private

    # A loan can outlive a viewer's access to the asset securing it (sharing
    # changes after the link is made). Such a viewer sees no option for it in the
    # form, so a submitted blank would silently unlink an asset they cannot even
    # see. Their edit leaves the link alone.
    def protect_inaccessible_collateral
      loan = @account&.accountable
      return unless loan&.collateral_account_id
      return if Account.accessible_by(Current.user).exists?(id: loan.collateral_account_id)

      params.dig(:account, :accountable_attributes)&.delete(:collateral_account_id)
    end

    # What the form offers: everything the save would accept, plus the asset the
    # loan is already linked to. Resubmitting an existing link is always allowed
    # (see Loan#collateral_account), so it must stay selectable even if it would
    # no longer be accepted fresh; otherwise opening and saving the form would
    # quietly drop it.
    def set_collateral_candidates
      loan = @account&.accountable || Loan.new
      candidates = Loan.collateral_candidates_for(
        loan, viewer: Current.user, family: Current.family, currency: params.dig(:account, :currency).presence
      )
      current = loan.collateral_account
      if current && candidates.none? { |candidate| candidate.id == current.id } &&
          Account.accessible_by(Current.user).exists?(id: current.id)
        candidates = [ current, *candidates ]
      end
      @collateral_candidates = candidates
    end
end
