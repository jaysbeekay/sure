namespace :portfolio do
  # Both portfolio contracts, in one task, because a contract is only worth
  # writing if it cannot quietly lose its evidence: a row naming a test that no
  # longer exists reads exactly like a row that is covered. Same gate
  # `loans:verify_contract_coverage` gives the amortisation contract.
  #
  # Two readers because the documents cite evidence differently -- the
  # methodology quotes test sentences against a manifest, the returns contract
  # carries a self-describing `Class#test_method` -- but both resolve the
  # declaration through Portfolio::ContractCoverage's token-stream check, so
  # there is one answer to "does this test exist?".
  desc "Verify every portfolio methodology (P) and returns (R) contract row maps to an existing test"
  task verify_contract_coverage: :environment do
    methodology = Portfolio::ContractCoverage.new(
      contract_path: Rails.root.join("docs/portfolio/methodology.md"),
      manifest_path: Rails.root.join("config/portfolio_contract_tests.yml")
    ).verify!

    returns = Portfolio::ReturnsContractCoverage.new(
      contract_path: Rails.root.join("docs/portfolio/returns-contract.md")
    ).verify!

    puts "Verified #{methodology} methodology and #{returns} returns contract rows against existing tests"
  rescue Portfolio::ContractCoverage::Error => e
    abort e.message
  end
end
