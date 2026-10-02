# Review flow for AI category suggestions over the uncategorised backlog.
#
# Suggesting and accepting are separate steps with nothing persisted between
# them: #suggest asks the provider for one bounded batch and writes nothing,
# and #accept applies only the rows a person posts back. Both work on the same
# backlog, so a row that stops qualifying between the two (categorised by
# hand, locked, moved out of reach) is skipped rather than overwritten.
class Family::CategorySuggestionReview
  Batch = Data.define(:pairs, :remaining)
  Applied = Data.define(:applied, :skipped)

  # How long a signed suggestion may be accepted after it was made.
  TOKEN_LIFETIME = 1.hour
  TOKEN_PURPOSE = :category_suggestion

  def initialize(family, user:)
    @family = family
    @user = user
  end

  def provider_configured?
    family.resolved_categorization_provider.present?
  end

  # Transactions the review can offer a category for. Narrower than the
  # "uncategorised" count elsewhere on purpose: a transaction whose category is
  # locked cannot be enriched (Family::AutoCategorizer skips it), and an account
  # the user may only read cannot be annotated, so counting either would
  # promise suggestions the review will never produce or accept.
  def backlog_count
    backlog_entries.count("entries.id")
  end

  def suggest
    ids = next_batch_transaction_ids
    return Batch.new(pairs: [], remaining: 0) if ids.empty?

    pairs = Family::AutoCategorizer.new(family, transaction_ids: ids).suggest
    Batch.new(pairs: pairs, remaining: [ backlog_count - ids.size, 0 ].max)
  end

  # The proof that `suggest` offered this category for this transaction to this
  # person: the form carries it with each row and #accept refuses a row without it,
  # so a replayed or edited form cannot record another category as the AI's answer.
  #
  # @return [String] a signed, expiring token for the pair
  def token_for(transaction_id, category_id)
    verifier.generate(
      [ family.id, user.id, transaction_id.to_s, category_id.to_s ],
      purpose: TOKEN_PURPOSE, expires_in: TOKEN_LIFETIME
    )
  end

  # rows: [{ transaction_id:, category_id:, token: }]. Each row is applied only
  # with the token signed for that pair, while its transaction is still in the
  # backlog and its category belongs to the family; anything else is counted as
  # skipped.
  def accept(rows)
    requested = normalize(rows)
    return Applied.new(applied: 0, skipped: 0) if requested.empty?

    eligible = Transaction.where(id: backlog_transaction_ids_among(requested.map(&:first))).index_by(&:id)
    categories = family.categories.where(id: requested.map { |_, category_id, _| category_id }).index_by(&:id)

    applied = requested.count do |transaction_id, category_id, token|
      transaction = eligible[transaction_id]
      category = categories[category_id]
      signed?(token, transaction_id, category_id) && transaction.present? && category.present? && apply(transaction, category)
    end

    Applied.new(applied: applied, skipped: requested.size - applied)
  end

  private
    attr_reader :family, :user

    def backlog_entries
      family.entries
            .joins(:account)
            .merge(Account.annotatable_by(user))
            .excluding_split_parents
            .uncategorized_transactions
            .merge(Transaction.enrichable(:category_id))
    end

    # Newest first, with the id as a tie-break so a batch is stable.
    def next_batch_transaction_ids
      backlog_entries
        .order("entries.date DESC", "entries.id")
        .limit(Family::AutoCategorizer::SUGGEST_LIMIT)
        .pluck("entries.entryable_id", "entries.date", "entries.id")
        .map(&:first)
    end

    def backlog_transaction_ids_among(transaction_ids)
      backlog_entries.where(entries: { entryable_id: transaction_ids }).distinct.pluck("entries.entryable_id")
    end

    def verifier
      Rails.application.message_verifier(:category_suggestions)
    end

    def signed?(token, transaction_id, category_id)
      token.present? &&
        verifier.verified(token, purpose: TOKEN_PURPOSE) == [ family.id, user.id, transaction_id.to_s, category_id.to_s ]
    end

    def normalize(rows)
      Array(rows).filter_map do |row|
        row = row.to_h.with_indifferent_access
        triple = [ row[:transaction_id].presence, row[:category_id].presence, row[:token].to_s ]
        triple if triple.first(2).all?
      end.uniq(&:first)
    end

    # Re-checks under a row lock: the eligibility query above ran earlier, and
    # enrich_attribute would overwrite a category set in the meantime.
    #
    # Each row is its own transaction, so a row that raises (a database error on the
    # lock, say) is logged and counted as skipped; the rows before it stay applied and
    # the ones after it still run.
    def apply(transaction, category)
      transaction.with_lock do
        next false if transaction.category_id.present? || transaction.locked?(:category_id)

        modified = transaction.enrich_attribute(:category_id, category.id, source: "ai")
        transaction.lock_attr!(:category_id) if modified
        modified
      end
    rescue StandardError => e
      DebugLogEntry.capture(
        category: "category_suggestions",
        level: "error",
        message: "Accepting an AI category suggestion failed",
        source: self.class.name,
        family: family,
        user: user,
        metadata: { transaction_id: transaction.id, category_id: category.id, error_class: e.class.name, error_message: e.message }
      )
      false
    end
end
