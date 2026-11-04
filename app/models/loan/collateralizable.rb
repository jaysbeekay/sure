# The property or vehicle a loan is secured on. A fork feature that upstream's
# Loan does not have, kept apart from it so the rest of loan.rb stays upstream's.
module Loan::Collateralizable
  extend ActiveSupport::Concern

  # The account types a loan can be secured by.
  COLLATERAL_ACCOUNTABLE_TYPES = %w[Property Vehicle].freeze

  included do
    belongs_to :collateral_account, class_name: "Account", optional: true
    validate :collateral_account_is_eligible, if: :will_save_change_to_collateral_account_id?

    # The account this loan is being saved through, when it is. `loan.account` is
    # read from the database (and is nil for a loan being created), so on a save
    # through the account it describes the account as it WAS: a request that changes
    # the currency and the collateral together would be judged on the old currency.
    # Account hands itself over before validating; a loan saved on its own falls
    # back to `account`.
    attr_writer :owning_account
  end

  class_methods do
    # Everyone who can see the loan's account, or will once it is saved.
    def viewers_of(loan_account)
      users = loan_account.family.users
      # A new account in a family that shares by default is visible to everyone in
      # it the moment it exists, but its shares are written after validation.
      return users.to_a if loan_account.new_record? && loan_account.family.share_all_by_default?

      users.select { |user| loan_account.shared_with?(user) }
    end

    # The accounts a viewer may pick as this loan's collateral: assets of the right
    # type in the loan's family that they can see and that the save would accept.
    # `family` stands in for the loan account's when the loan has none yet.
    # `currency` narrows the list when the loan has no account to read one from.
    def collateral_candidates_for(loan, viewer:, family: nil, currency: nil)
      family ||= loan.account&.family
      return Account.none unless family && viewer

      scope = Account.accessible_by(viewer).visible
        .where(family_id: family.id, accountable_type: COLLATERAL_ACCOUNTABLE_TYPES)
      scope = scope.where(currency: currency) if currency.present? && loan.account.nil?

      loan_account = loan.owning_account
      viewers = viewers_of(loan_account) if loan_account&.family
      scope.order(:name)
        .select { |candidate| loan.collateral_ineligibilities_for(candidate, loan_account: loan_account, viewers: viewers).empty? }
    end
  end

  def owning_account
    @owning_account || account
  end

  # What is wrong with the link as it stands: an id that names no account is
  # refused here, as the foreign key would otherwise raise it as a server error,
  # and a blank id is simply no link.
  def collateral_problems(loan_account: owning_account)
    return [] if collateral_account_id.blank?
    return [ "does not exist" ] if collateral_account.nil?

    collateral_ineligibilities_for(collateral_account, loan_account: loan_account)
  end

  # Why `account` cannot secure this loan; empty when it can. The one definition
  # shared by the validation and by the form's candidate list, so the list never
  # offers an account the save would refuse.
  #
  # The checks that need the loan's own account are skipped until it exists: a
  # loan being created is validated before it is attached to one.
  # `viewers` lets a caller judging many accounts against one loan work the
  # loan's viewers out once instead of once per account.
  def collateral_ineligibilities_for(account, loan_account: owning_account, viewers: nil)
    return [] if account.nil?

    unless COLLATERAL_ACCOUNTABLE_TYPES.include?(account.accountable_type)
      return [ "must be a property or vehicle" ]
    end

    problems = []

    if loan_account&.family
      # Another family's account has no standing to be visible to this one's
      # viewers, so the family is the only thing worth saying about it.
      return [ "must belong to the same family as the loan" ] unless account.family_id == loan_account.family_id

      problems << "must use the same currency as the loan" unless account.currency == loan_account.currency

      # A link the loan's viewers could not follow would show them a figure from
      # an account they cannot see.
      invisible = (viewers || self.class.viewers_of(loan_account)).reject { |user| account.shared_with?(user) }
      if invisible.any?
        problems << "must be visible to every loan viewer (missing: #{invisible.map(&:display_name).join(", ")})"
      end
    end

    problems
  end

  private
    def collateral_account_is_eligible
      collateral_problems.each { |problem| errors.add(:collateral_account, problem) }
    end
end
