namespace :loans do
  # Gate G2b's private run (#409). Reads a normalised lender statement -- the
  # shape Loan::StatementReconciliation documents, with the linked offset
  # accounts' end-of-day totals as offset_balance rows -- and reports how many
  # interest charges the engine reproduces.
  #
  # The statement is personal financial data, so this refuses to read one from
  # inside the repository, and its report carries counts, row numbers, the
  # largest deviation and the basis: nothing that identifies the statement.
  # VERBOSE=1 adds each charge's date and figures, for investigating a residual
  # locally; that output is the statement, and must not be pasted anywhere.
  desc "Reconcile a normalised lender statement's interest, offsets included, against the engine (G2b)"
  task :reconcile_statement, [ :path, :day_count_convention ] => :environment do |_, args|
    path = args[:path].presence || ENV["STATEMENT"].presence
    convention = args[:day_count_convention].presence || ENV["DAY_COUNT_CONVENTION"].presence ||
      Loan::InterestAccrual::DEFAULT_DAY_COUNT_CONVENTION.to_s
    abort "usage: bin/rails 'loans:reconcile_statement[/path/outside/the/repository.csv,actual_365]'" unless path

    statement = Pathname(path).expand_path
    abort "no statement at the given path" unless statement.file?
    if statement.realpath.ascend.include?(Rails.root.realpath)
      abort "refusing to read a statement inside the repository; keep it outside the working tree (docs/loans/methodology.md)"
    end

    # The statement's own arithmetic is checked before the engine sees it, so
    # a broken statement is reported by row rather than by whatever the engine
    # makes of it.
    reconciliation = begin
      Loan::StatementReconciliation.from_csv(statement.read, day_count_convention: convention)
    rescue ArgumentError, CSV::MalformedCSVError => error
      abort "statement not reconciled: #{error.message}"
    end

    problems = reconciliation.problems
    if problems.any?
      puts problems
      abort "statement not reconciled: #{problems.length} #{'row'.pluralize(problems.length)} break its own arithmetic"
    end

    summary = begin
      reconciliation.summary
    rescue ArgumentError => error
      abort "statement not reconciled: #{error.message}"
    end
    abort "statement not reconciled: it holds no interest charge to compare" if summary[:compared].zero?

    if ENV["VERBOSE"].present?
      reconciliation.charges.each do |charge|
        puts format("%s expected=%s engine=%s deviation=%s", charge.date, charge.expected.to_s("F"), charge.actual.to_s("F"), charge.deviation.to_s("F"))
      end
    end
    puts "basis: #{summary[:day_count_convention]}"
    puts "charges compared: #{summary[:compared]}"
    puts "exact: #{summary[:exact]}/#{summary[:compared]}"
    puts "within one cent: #{summary[:within_tolerance]}/#{summary[:compared]}"
    puts "largest deviation: #{format('%.2f', summary[:largest_deviation])}"

    outside = summary[:compared] - summary[:within_tolerance]
    abort "#{outside} of #{summary[:compared]} charges differ by more than one cent" if outside.positive?
  end
end
