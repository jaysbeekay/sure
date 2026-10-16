module LoansHelper
  # The two policies Loan::Insurance knows how to charge. Listed here rather
  # than built from the constant so each one carries a translated label.
  def loan_insurance_rate_type_options
    [
      [ t("loans.form.insurance_rate_type_level_term"), Loan::Insurance::LEVEL_TERM ],
      [ t("loans.form.insurance_rate_type_decreasing_life"), Loan::Insurance::DECREASING_LIFE ]
    ]
  end

  # How leveraged the loan was at drawdown, as a design-system colour. Bands are
  # Loan's; the colours are this layer's.
  def loan_leverage_band_class(band)
    {
      conservative: "text-success",
      moderate: "text-warning",
      high: "text-destructive"
    }.fetch(band, "text-secondary")
  end
end
