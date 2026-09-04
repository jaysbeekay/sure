namespace :loans do
  desc "Compare monthly and daily loan calculations for a bounded sample"
  task :amortization_variance, [ :limit, :output ] => :environment do |_, args|
    require "csv"

    raw_limit = args[:limit].presence || ENV["LIMIT"].presence || "100"
    limit = [ raw_limit.to_i, 1 ].max
    output = args[:output].presence || ENV["OUTPUT"].presence
    loans = Loan.where.not(term_months: nil).order(:id).limit(limit)
    rows = []

    loans.find_each do |loan|
      monthly = loan.amortization_schedule.simulation
      daily = loan.amortization_schedule.simulation(daily_accrual: true)
      rows << {
        loan_id: loan.id,
        monthly_interest: monthly.total_interest.to_s("F"),
        daily_interest: daily.total_interest.to_s("F"),
        interest_delta: (daily.total_interest - monthly.total_interest).to_s("F"),
        monthly_cost: monthly.total_cost.to_s("F"),
        daily_cost: daily.total_cost.to_s("F"),
        cost_delta: (daily.total_cost - monthly.total_cost).to_s("F"),
        monthly_converged: monthly.converged?,
        daily_converged: daily.converged?
      }
    end

    columns = rows.first&.keys || %i[loan_id monthly_interest daily_interest interest_delta monthly_cost daily_cost cost_delta monthly_converged daily_converged]
    csv = CSV.generate do |document|
      document << columns
      rows.each { |row| document << columns.map { |column| row[column] } }
    end
    if output
      File.write(output, csv)
      puts "Wrote #{rows.length} variance rows to #{output}"
    else
      puts csv
    end
  end

  desc "Rebuild loan amortization schedules in bounded, rate-limited batches"
  task :rebuild_schedules, [ :batch_size, :limit, :sleep ] => :environment do |_, args|
    raw_batch_size = args[:batch_size].presence || ENV["BATCH_SIZE"].presence || "100"
    batch_size = [ raw_batch_size.to_i, 1 ].max
    limit = args[:limit].presence&.to_i
    pause = args[:sleep].presence&.to_f || 0.0
    rebuilt = 0

    scope = Loan.where.not(term_months: nil).order(:id)
    scope = scope.limit(limit) if limit&.positive?

    puts "Rebuilding loan schedules (batch_size=#{batch_size}, limit=#{limit || 'all'}, sleep=#{pause}s)"
    scope.find_in_batches(batch_size: batch_size) do |loans|
      loans.each do |loan|
        loan.rebuild_amortization_schedule
        rebuilt += 1
        puts "Rebuilt #{rebuilt}: #{loan.id}"
        sleep(pause) if pause.positive?
      end
    end

    puts "Completed loan schedule rebuild: #{rebuilt} loans"
  end
end
