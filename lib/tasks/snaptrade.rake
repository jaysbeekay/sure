namespace :snaptrade do
  # Repairs SnapTrade positions split across two Security rows of one ticker
  # before jaysbeekay/sure#334: moves each account's trades and holdings onto
  # the row the account holds, then re-materializes. Per account, never
  # destroys a Security and never moves a price.
  #
  #   bin/rails snaptrade:repair_split_securities               # dry run, every SnapTrade account
  #   bin/rails "snaptrade:repair_split_securities[ACCOUNT_ID]" # dry run, one account
  #   DRY_RUN=false bin/rails snaptrade:repair_split_securities # writes
  desc "Repair SnapTrade holdings and trades split across duplicate security rows (dry run unless DRY_RUN=false)"
  task :repair_split_securities, [ :account_id ] => :environment do |_, args|
    dry_run = ENV["DRY_RUN"].to_s.strip.downcase != "false"
    accounts = if args[:account_id].present?
      Account.where(id: args[:account_id])
    else
      SnaptradeAccount::SplitSecurityRepair.accounts
    end

    puts dry_run ? "DRY RUN: nothing will be written. Set DRY_RUN=false to apply." : "Applying repairs."

    accounts.find_each do |account|
      results = SnaptradeAccount::SplitSecurityRepair.new(account, dry_run: dry_run).run
      if results.empty?
        puts "Account #{account.id} (#{account.name}): no split securities"
        next
      end

      puts "Account #{account.id} (#{account.name}):"
      results.each do |result|
        puts "  #{result.ticker}: target #{result.target_id} (#{result.target_source}), from #{result.source_ids.join(', ')}"
        puts "    trades moved: #{result.trades_moved}, holdings moved: #{result.holdings_moved}, " \
             "holdings dropped (target already had the date): #{result.holdings_dropped}"

        gaps = result.price_gap_dates
        next if gaps.empty?

        shown = gaps.first(10).map(&:iso8601).join(", ")
        shown += ", ..." if gaps.size > 10
        puts "    price gap: #{gaps.size} date(s) priced on another row but not the target: #{shown}"
      end
    rescue StandardError => e
      puts "Account #{account.id}: failed, rolled back: #{e.class}: #{e.message}"
    end
  end
end
