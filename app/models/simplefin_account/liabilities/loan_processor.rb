# SimpleFin Loan processor for loan-specific features
class SimplefinAccount::Liabilities::LoanProcessor
  def initialize(simplefin_account)
    @simplefin_account = simplefin_account
  end

  def process
    return unless simplefin_account.current_account&.accountable_type == "Loan"

    # Update loan specific attributes if available
    update_loan_attributes
  end

  private
    attr_reader :simplefin_account

    def account
      simplefin_account.current_account
    end

    # Nothing to update: SimpleFIN carries no loan metadata to read.
    #
    # This method used to ask whether it could ("I don't know if SimpleFin
    # typically provide detailed loan metadata like interest rates, terms,
    # etc."). It was answered from a real payload in jaysbeekay/sure#159 --
    # a LoanCare mortgage, contributed by @adbsmith:
    #
    #   account: id, org, name, balance, currency, holdings, balance-date,
    #            available-balance
    #
    # There is no `extra` field at all, and the protocol's Account object
    # defines no interest rate, APR, term or original principal of its own
    # (https://www.simplefin.org/protocol.html) -- `extra` is the only place
    # one could appear, and it is optional and server-discretionary.
    #
    # So there is no provider-metadata path to build here. Rate and term for
    # SimpleFIN users come from transaction text instead (#142 Phase 2), which
    # never depended on the provider supplying them.
    #
    # One server answering for itself is not proof that no server populates
    # `extra`. If one ever turns up, this is the method that would read it --
    # with a payload attached, the way #159 was settled.
    #
    # Balance normalization is handled by SimplefinAccount::Processor.process_account!
    def update_loan_attributes
    end
end
