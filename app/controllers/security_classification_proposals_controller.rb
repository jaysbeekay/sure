class SecurityClassificationProposalsController < ApplicationController
  include AccountAuthorizable

  before_action :set_proposal, only: %i[approve reject]
  before_action :require_classification_permission!, only: %i[approve reject]

  def index
    # Family scope is not enough. `accessible_accounts` excludes another
    # member's PRIVATE accounts, so listing by family alone showed a reader the
    # ticker, name and rationale for a holding they are not allowed to see --
    # the proposal is the household's, but the position behind it may not be.
    # The rule is the one the approve gate uses, asked the other way round:
    # there, which accounts hold this security; here, which securities those
    # accounts hold (CodeRabbit, #199).
    @proposals = scoped_proposals.pending
                                 .where(security_id: accessible_security_ids)
                                 .includes(:security)
                                 .order(created_at: :desc)
  end

  def approve
    if @proposal.approve!
      flash[:notice] = t(".success", ticker: proposal_ticker)
    elsif @proposal.reload.approved?
      flash[:alert] = t(".already_approved", ticker: proposal_ticker)
    elsif @proposal.rejected?
      flash[:alert] = t(".already_rejected", ticker: proposal_ticker)
    else
      # Still pending, so the refusal came from the SECURITY rather than from
      # the proposal: classified by hand, or locked, since this was proposed.
      flash[:alert] = t(".superseded", ticker: proposal_ticker)
    end

    redirect_to security_classification_proposals_path
  end

  def reject
    # `reject!` refuses a proposal that is no longer pending, and the return
    # value is the only way to know: without checking it a stale form from a
    # second tab reported "dismissed" about a classification still in force.
    #
    # Dismissing twice is still dismissing, though. A double-click leaves the
    # proposal in exactly the state asked for, so reporting a failure for it
    # would be telling the user their own action did not happen.
    if @proposal.reject! || @proposal.reload.rejected?
      flash[:notice] = t(".success", ticker: proposal_ticker)
    else
      flash[:alert] = t(".superseded", ticker: proposal_ticker)
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

    # The securities the viewer can see a position in. Same root as
    # `holding_accounts` -- `Current.user.accessible_accounts` -- so the list
    # and the gate cannot come to disagree about which holdings this user has.
    def accessible_security_ids
      Holding.where(account_id: Current.user.accessible_accounts.select(:id))
             .select(:security_id)
    end

    def proposal_ticker
      @proposal.security.ticker
    end
end
