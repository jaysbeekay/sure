# Finds the category, merchant and tag ids of a transaction form that the user's family may not
# use, so a crafted request cannot attach another family's records. Built on
# Entry::SplitReferences, which splits already use for the same rule; unlike a split, which drops
# an unusable id, a form refuses the request.
#
# An id the transaction already holds is usable, because the form sends back what it read and a
# link made before this check must stay editable. Blank values are not ids: a blank is how the
# form clears a field.
class Transaction::OwnedReferences
  REFERENCE_KEYS = %i[category_id merchant_id tag_ids].freeze

  def initialize(family, user)
    @family = family
    @user = user
  end

  # attributes holds any of REFERENCE_KEYS; transaction is the one being edited, or nil for a new
  # one. Returns the [kind, id] pairs that cannot be used.
  def unusable(attributes, transaction: nil)
    return [] if attributes.blank? || REFERENCE_KEYS.none? { |key| Array(attributes[key]).any?(&:present?) }

    references
      .unknown(category_id: attributes[:category_id], merchant_id: attributes[:merchant_id], tag_ids: attributes[:tag_ids])
      .reject { |kind, id| held?(transaction, kind, id) }
  end

  private
    # Loading every id the family could use is skipped when a form sends none.
    def references
      @references ||= Entry::SplitReferences.for_user(@family, @user)
    end

    def held?(transaction, kind, id)
      return false if transaction.nil?

      # A merchant the transaction holds is already usable: available_merchants_for includes the
      # merchants on the user's transactions.
      case kind
      when :category then transaction.category_id == id
      when :tag then transaction.tag_ids.include?(id)
      else false
      end
    end
end
