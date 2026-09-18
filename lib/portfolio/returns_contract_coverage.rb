# frozen_string_literal: true

# Proves every row of the returns contract (docs/portfolio/returns-contract.md)
# names a test that exists.
#
# Same purpose as Portfolio::ContractCoverage and run by the same rake task, but
# the two documents cite their evidence differently and neither format is worth
# rewriting to match the other. A methodology row names a class and then quotes
# one or more test sentences, cross-checked against
# config/portfolio_contract_tests.yml. A returns row carries a single
# `Class#test_method` reference, which is self-describing and needs no manifest.
#
# What the two must share is the answer to "does this test exist?", so the
# declaration check is Portfolio::ContractCoverage's. Re-implementing it here
# with a regex would reintroduce the hole #133 closed, where a test name
# surviving in a comment or a heredoc read as evidence that the test still ran.
module Portfolio
  class ReturnsContractCoverage
    Error = ContractCoverage::Error

    ROW_LINE = /\A\| (R\d+) \|.*?\| `([^`#]+)#([^`]+)`/
    EXPECTED_ROWS = 18

    def initialize(contract_path:, root: Rails.root)
      @contract_path = Pathname(contract_path)
      @root = Pathname(root)
    end

    # Returns the number of rows verified; raises Error with the first problem.
    def verify!
      rows = contract_rows
      rows.each { |id, entry| verify_row!(id, entry) }
      rows.size
    end

    private
      attr_reader :contract_path, :root

      def contract_rows
        fail!("contract not found at #{contract_path}") unless contract_path.file?

        parsed = contract_path.readlines.filter_map do |line|
          match = line.match(ROW_LINE)
          next unless match

          [ match[1], { "class" => match[2], "test" => match[3] } ]
        end

        # Reject duplicates BEFORE collapsing: to_h keeps the last occurrence, so
        # a contract carrying R7 twice would silently discard one, and if the
        # survivor resolved, the wrong duplicate would pass unseen.
        duplicates = parsed.map(&:first).tally.select { |_, count| count > 1 }.keys.sort
        fail!("duplicate contract rows: #{duplicates.join(', ')}") if duplicates.any?

        rows = parsed.to_h
        expected = (1..EXPECTED_ROWS).map { |n| "R#{n}" }
        actual = rows.keys.sort_by { |id| id.delete_prefix("R").to_i }
        fail!("contract rows must cover R1-R#{EXPECTED_ROWS}, found: #{actual.join(', ')}") unless actual == expected

        rows.sort_by { |id, _| id.delete_prefix("R").to_i }.to_h
      end

      def verify_row!(id, entry)
        class_name = entry.fetch("class")
        test_name = entry.fetch("test")

        relative_path = "test/models/#{class_name.delete_suffix('Test').underscore}_test.rb"
        file = root.join(relative_path)
        fail!("#{id}: missing #{relative_path}") unless file.file?

        source = file.read
        # `class ::Foo <` declares the same constant as `class Foo <`.
        rooted = source.include?("class #{class_name} <") || source.include?("class ::#{class_name} <")
        fail!("#{id}: #{class_name} is not declared in #{relative_path}") unless rooted

        # Only a test the named class declares directly in its own body counts,
        # so a test in a second class, a helper method or a branch cannot stand
        # in as evidence for this row.
        declared = ContractCoverage.declared_tests(source, class_name)
        fail!("#{id}: #{relative_path} could not be parsed") if declared.nil?

        # Minitest's `test "some words"` defines `test_some_words`. The contract
        # names the method; the file reads as a sentence.
        sentence = test_name.delete_prefix("test_").tr("_", " ")
        return if declared.include?(sentence)

        fail!("#{id}: #{relative_path} declares no test #{test_name.inspect} (looked for `test #{sentence.inspect}`)")
      end

      def fail!(message)
        raise Error, message
      end
  end
end
