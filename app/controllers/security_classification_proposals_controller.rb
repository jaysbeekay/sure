class SecurityClassificationProposalsController < ApplicationController
  include AccountAuthorizable

  before_action :set_proposal, only: %i[approve reject]
  before_action :require_classification_permission!, only: %i[approve reject]

  def index
    @proposals = scoped_proposals.pending
                                 .includes(:security)
                                 .order(created_at: :desc)
  end

  def approve
    if @proposal.approve!
      flash[:notice] = t(".success", ticker: @proposal.security.ticker)
    else
      # `approve!` returns false when the security was answered by hand, or
      # locked, between the proposal being made and this click.
      flash[:alert] = t(".superseded", ticker: @proposal.security.ticker)
    end

    redirect_to security_classification_proposals_path
  end

  def reject
    # `reject!` refuses an already-approved proposal, and the return value is
    # the only way to know: without checking it a stale form from a second tab
    # reported "dismissed" about a classification still in force.
    if @proposal.reject!
      flash[:notice] = t(".success", ticker: @proposal.security.ticker)
    else
      flash[:alert] = t(".superseded", ticker: @proposal.security.ticker)
    end

    redirect_to security_classification_proposals_path
  end

  private
    # Scoped to the family, not merely filtered in the view. Approving writes the
    # globally shared `securities` row, so reaching another family's proposal at
    # all would let this family classify an instrument on their behalf.
    def scoped_proposals
      Security::ClassificationProposal.where(family: Current.family)
    end

    def set_proposal
      @proposal = scoped_proposals.find(params[:id])
    end

    # Approving writes the globally shared `securities` row -- the same write
    # the holding drawer puts behind `require_account_permission!` (#197). This
    # screen had no gate at all, so a GUEST could classify an instrument for
    # every household holding it, while the same person cannot change it from
    # the drawer two clicks away.
    #
    # The rule is the drawer's, asked of the accounts that actually hold the
    # security: a user may decide its classification if they may write to one
    # of the positions they can see it in. A proposal carries no account of its
    # own, so the account is found rather than passed.
    #
    # Rejecting is gated too. It writes only the proposal row, but the screen
    # is a decision about a shared instrument either way, and a reader who can
    # dismiss the household's proposals is making that decision for them.
    def require_classification_permission!
      return if holding_accounts.any? { |account| account_permission?(account, :write) }

      redirect_back_or_to security_classification_proposals_path,
                          alert: t("accounts.not_authorized")
    end

    def holding_accounts
      Current.user.accessible_accounts.where(
        id: Holding.where(security_id: @proposal.security_id).select(:account_id)
      )
    end
end
