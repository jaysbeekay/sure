class LoanOffsetAccount < ApplicationRecord
  belongs_to :loan
  belongs_to :account

  validates :account_id, uniqueness: { scope: :loan_id }
  validate :account_is_asset
  validate :account_matches_loan_currency
  validate :account_belongs_to_loan_family
  validate :account_is_not_loan_account
  validate :account_is_visible_to_every_loan_viewer

  after_commit :clear_loan_projection_cache, on: %i[create destroy]

  class << self
    # What the loan form offers: every asset the save would accept. A loan that
    # has no account yet (the new-loan form, or a failed create re-rendering it)
    # is judged on the account the create would build, in `family` and
    # `currency` and owned by `viewer`, so the list matches what the save checks
    # (#325). A loan with an account ignores both and is judged on it.
    def eligible_accounts_for(loan, viewer:, family: nil, currency: nil)
      return Account.none unless viewer

      if loan.account.nil?
        loan = prospective_loan(viewer:, family:, currency:)
        return Account.none unless loan
      end

      loan_account = loan.owning_account
      Account.accessible_by(viewer)
        .where(family_id: loan_account.family_id, classification: "asset", currency: loan_account.currency)
        .where.not(id: loan_account.id)
        .select { |account| new(loan: loan, account: account).valid? }
    end

    def invalidate_for_sharing_change!(account)
      return if account.nil?

      loan_ids = Account.where(id: account.id, accountable_type: "Loan").select(:accountable_id)
      where(account_id: account.id).or(where(loan_id: loan_ids)).find_each(&:destroy!)
    end

    # A link is judged on currency only when it is created or resubmitted, so a
    # later currency change on either side left a cross-currency link that the
    # loan then subtracted at face value (#328). Unlike the sharing path, only
    # the links whose two sides now differ go: a change that brings a link back
    # into line keeps it. Each removal is logged, because a provider sync can
    # make the change with nobody watching.
    def invalidate_for_currency_change!(account)
      return if account.nil?

      loan_ids = Account.where(id: account.id, accountable_type: "Loan").select(:accountable_id)
      where(account_id: account.id).or(where(loan_id: loan_ids))
        .includes(:account, loan: :account)
        .find_each do |link|
          loan_account = link.loan.account
          next if loan_account.nil? || link.account.currency == loan_account.currency

          link.destroy!
          DebugLogEntry.capture(
            category: "loan_offset",
            level: "warn",
            message: "Removed a loan offset link after a currency change",
            source: name,
            family_id: loan_account.family_id,
            metadata: {
              loan_id: link.loan_id,
              loan_account_id: loan_account.id,
              offset_account_id: link.account_id,
              offset_currency: link.account.currency,
              loan_currency: loan_account.currency
            }
          )
        end
    end
  end

  class << self
    private

      # An unsaved loan on an unsaved account, shaped as `create` will build it:
      # the viewer owns it, and `Loan.viewers_of` treats it as visible to the
      # whole family when the family shares by default.
      def prospective_loan(viewer:, family:, currency:)
        family ||= viewer.family
        return if family.nil? || family.id != viewer.family_id

        Loan.new.tap do |loan|
          # Built by id rather than through `family.accounts`, which would add
          # the unsaved account to the family's loaded association.
          loan.owning_account = Account.new(
            family_id: family.id, currency: currency.presence || family.currency, owner: viewer, accountable: loan
          )
        end
      end
  end

  private

    def account_is_asset
      return unless account
      errors.add(:account, "must be an asset account") unless account.asset?
    end

    def account_matches_loan_currency
      return unless account && loan_account
      return if account.currency == loan_account.currency

      errors.add(:account, "must use the same currency as the loan")
    end

    def account_belongs_to_loan_family
      return unless account && loan_account
      return if account.family_id == loan_account.family_id

      errors.add(:account, "must belong to the same family as the loan")
    end

    def account_is_not_loan_account
      return unless account && loan_account
      return unless account.id == loan_account.id

      errors.add(:account, "cannot be the loan account")
    end

    def account_is_visible_to_every_loan_viewer
      return unless account && loan_account

      inaccessible_users = loan_viewers.reject { |user| account.shared_with?(user) }
      return if inaccessible_users.empty?

      names = inaccessible_users.map(&:display_name).join(", ")
      errors.add(:account, "must be visible to every loan viewer (missing: #{names})")
    end

    # The loan's account as it is being saved, not `loan.account`: that is nil
    # while a new loan validates and links its offsets, and the stored currency
    # on an edit, so these checks used to skip or read the old currency (#290).
    # The link reaches the loan through the association's inverse, so it is the
    # same instance Account handed itself to.
    def loan_account
      loan&.owning_account
    end

    def loan_viewers
      Loan.viewers_of(loan_account)
    end

    def clear_loan_projection_cache
      loan&.invalidate_offset_cache!
    end
end
