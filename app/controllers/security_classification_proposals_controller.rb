class SecurityClassificationProposalsController < ApplicationController
  before_action :set_proposal, only: %i[approve reject]

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
    @proposal.reject!
    flash[:notice] = t(".success", ticker: @proposal.security.ticker)

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
end
