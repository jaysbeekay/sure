namespace :portfolio do
  desc "Verify every row of docs/portfolio/methodology.md maps to an existing test"
  task verify_contract_coverage: :environment do
    count = Portfolio::ContractCoverage.new(
      contract_path: Rails.root.join("docs/portfolio/methodology.md"),
      manifest_path: Rails.root.join("config/portfolio_contract_tests.yml")
    ).verify!

    puts "Verified #{count} portfolio contract rows against existing tests"
  rescue Portfolio::ContractCoverage::Error => e
    abort e.message
  end
end
