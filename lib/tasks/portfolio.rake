namespace :portfolio do
  # The returns contract is only worth writing if it cannot quietly lose its
  # evidence. This is the same gate `loans:verify_contract_coverage` provides
  # for the amortisation contract, and it exists for the same reason: a row that
  # names a test which no longer exists reads exactly like a row that is
  # covered.
  #
  # Deliberately stricter than "the file exists": it resolves the named test
  # method inside the named class, accepting either an explicit `def test_x` or
  # Minitest's `test "x"` form, so renaming a test breaks the build rather than
  # silently orphaning a contract row.
  desc "Verify every R1-R16 returns-contract row maps to an existing test"
  task verify_contract_coverage: :environment do
    contract_path = Rails.root.join("docs/portfolio/returns-contract.md")
    abort "missing #{contract_path}" unless contract_path.file?

    parsed_rows = File.readlines(contract_path).filter_map do |line|
      match = line.match(/^\| R(\d+) \|.*?\| `([^`#]+)#([^`]+)`/)
      next unless match

      [ "R#{match[1]}", { "class" => match[2], "test" => match[3] } ]
    end

    # Reject duplicates BEFORE collapsing: `to_h` keeps the last occurrence, so
    # a contract carrying R7 twice would silently discard one, and if the
    # survivor happened to resolve, the wrong duplicate would pass unseen. The
    # loan gate learned this the hard way.
    duplicate_ids = parsed_rows.map(&:first).tally.select { |_id, count| count > 1 }.keys.sort
    abort "duplicate contract rows: #{duplicate_ids.join(', ')}" if duplicate_ids.any?

    rows = parsed_rows.to_h
    expected_ids = (1..16).map { |id| "R#{id}" }
    actual_ids = rows.keys.sort_by { |id| id.delete_prefix("R").to_i }
    unless actual_ids == expected_ids
      abort "contract rows must cover R1-R16, found: #{actual_ids.join(', ')}"
    end

    rows.each do |id, entry|
      class_name = entry.fetch("class")
      test_name = entry.fetch("test")

      relative_path = "test/models/#{class_name.delete_suffix('Test').underscore}_test.rb"
      file_path = Rails.root.join(relative_path)
      abort "#{id}: missing #{relative_path}" unless file_path.file?

      source = File.read(file_path)
      abort "#{id}: #{class_name} is not declared in #{relative_path}" unless source.include?("class #{class_name} <")

      # Minitest's `test "some words"` defines `test_some_words`. Accept either
      # form so the contract can name the method while the test file reads as a
      # sentence.
      #
      # Both are anchored to a whole declaration. A substring search would let
      # `def test_foo` satisfy a row naming `test_fo`, so a renamed test could
      # still pass the gate through a longer name that starts the same way.
      sentence = test_name.delete_prefix("test_").tr("_", " ")
      declared = source.match?(/^\s*def #{Regexp.escape(test_name)}\b/) ||
                 source.match?(/^\s*test "#{Regexp.escape(sentence)}" do\b/)
      abort "#{id}: #{relative_path} declares no test #{test_name.inspect} (looked for `test \"#{sentence}\"`)" unless declared
    end

    puts "Verified #{rows.length} returns-contract rows against existing tests"
  end
end
