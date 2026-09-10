# frozen_string_literal: true

require "yaml"

# Proves every row of the portfolio contract (docs/portfolio/methodology.md)
# names a test that exists.
#
# The contract table is where a decision about what a figure *means* is
# written down. A row that cites a test which has been renamed or deleted is
# a decision with no evidence, and nothing else notices: the test suite is
# green, the document reads as authoritative. This check closes that gap the
# way the loan contract does (loans:verify_contract_coverage): the document
# and config/portfolio_contract_tests.yml must agree on which test class
# demonstrates each row, and every named test must be declared in the file
# the manifest points at.
#
# Kept out of the rake task body so a test can exercise the failure paths
# against a temporary contract and manifest rather than only the happy path.
module Portfolio
  class ContractCoverage
    Error = Class.new(StandardError)

    ROW_ID = /\AP(\d+)\z/
    ROW_LINE = /\A\| (P\d+) \|/
    TEST_CLASS_PATTERN = /`([A-Z][A-Za-z0-9]*(?:::[A-Z][A-Za-z0-9]*)*Test)`/
    # A quoted test name in a contract row's evidence cell. The cell reads
    # `SomeTest` "first test", "second test"; `OtherTest` "third test" -- each
    # quoted name belongs to the class named before it.
    TEST_NAME_PATTERN = /"([^"]+)"/
    EVIDENCE_PATTERN = /#{TEST_CLASS_PATTERN}|#{TEST_NAME_PATTERN}/

    def initialize(contract_path:, manifest_path:, root: Rails.root)
      @contract_path = Pathname(contract_path)
      @manifest_path = Pathname(manifest_path)
      @root = Pathname(root)
    end

    # Returns the number of rows verified; raises Error with the first
    # problem found.
    def verify!
      rows = contract_rows
      manifest = load_manifest

      expect_contiguous!(rows.keys, "contract")
      expect_contiguous!(manifest.keys, "manifest")
      fail!("contract rows #{rows.keys.join(', ')} and manifest rows #{manifest.keys.join(', ')} differ") unless rows.keys == manifest.keys

      rows.each do |id, documented|
        entries = Array(manifest.fetch(id))
        fail!("#{id}: manifest has no test entries") if entries.empty?

        documented_classes = documented.keys.sort
        manifest_classes = entries.map { |entry| fetch!(entry, "class", id) }.uniq.sort
        unless documented_classes == manifest_classes
          fail!("#{id}: contract names #{documented_classes.join(', ').presence || 'no test class'}, manifest names #{manifest_classes.join(', ')}")
        end

        # The names printed in the document are the claim a reader acts on, so
        # they are checked too -- not just the class. Without this a row could
        # cite a test that has been renamed or never existed and still verify,
        # which is the exact failure this gate is here to prevent.
        entries.group_by { |entry| entry.fetch("class") }.each do |class_name, class_entries|
          manifest_tests = class_entries.flat_map { |entry| Array(fetch!(entry, "tests", id)) }.sort
          documented_tests = documented.fetch(class_name, []).sort
          next if documented_tests == manifest_tests

          missing = manifest_tests - documented_tests
          extra = documented_tests - manifest_tests
          detail = []
          detail << "document does not cite #{missing.map(&:inspect).join(', ')}" if missing.any?
          detail << "document cites #{extra.map(&:inspect).join(', ')}, which the manifest does not name" if extra.any?
          fail!("#{id}: #{class_name}: #{detail.join('; ')}")
        end

        entries.each { |entry| verify_entry!(id, entry) }
      end

      rows.size
    end

    private
      attr_reader :contract_path, :manifest_path, :root

      def contract_rows
        fail!("contract not found at #{contract_path}") unless contract_path.file?

        parsed = contract_path.readlines.filter_map do |line|
          match = line.match(ROW_LINE)
          next unless match

          cells = line.split("|").map(&:strip)
          # | id | decision | demonstrating test | ... -> the test cell is the third.
          [ match[1], parse_evidence(cells[3].to_s) ]
        end

        duplicates = parsed.map(&:first).tally.select { |_, count| count > 1 }.keys
        fail!("duplicate contract rows: #{duplicates.join(', ')}") if duplicates.any?

        parsed.sort_by { |id, _| row_number(id) }.to_h
      end

      def load_manifest
        fail!("manifest not found at #{manifest_path}") unless manifest_path.file?

        manifest = YAML.load_file(manifest_path)
        fail!("manifest must be a mapping of row id to entries") unless manifest.is_a?(Hash)

        manifest.keys.each { |id| fail!("manifest row id #{id.inspect} is not P<n>") unless id.to_s.match?(ROW_ID) }
        manifest.sort_by { |id, _| row_number(id) }.to_h
      end

      def verify_entry!(id, entry)
        relative_path = fetch!(entry, "file", id)
        file = root.join(relative_path)
        fail!("#{id}: missing #{relative_path}") unless file.file?

        source = file.read
        class_name = fetch!(entry, "class", id)
        fail!("#{id}: #{class_name} is not declared in #{relative_path}") unless source.include?("class #{class_name} <")

        # Search the named class's own body rather than the whole file, so a
        # test that lives in a second class in the same file cannot stand in
        # as evidence for this one.
        body = class_body(source, class_name)

        tests = Array(fetch!(entry, "tests", id))
        fail!("#{id}: #{class_name} lists no tests") if tests.empty?
        tests.each do |name|
          next if body.include?(%(test "#{name}"))

          fail!("#{id}: missing test #{name.inspect} in #{class_name} (#{relative_path})")
        end
      end

      # The source between `class <name> <` and the next top-level `class`
      # declaration (or the end of the file).
      def class_body(source, class_name)
        start = source.index("class #{class_name} <")
        return "" if start.nil?

        rest = source[start..]
        following = rest.index(/^class [A-Z]/, 1)
        following ? rest[0...following] : rest
      end

      # Every value the manifest is required to carry, reported as a contract
      # error rather than a bare KeyError, so the rake task can abort with a
      # message instead of a backtrace.
      def fetch!(entry, key, id)
        fail!("#{id}: manifest entry has no #{key.inspect}") unless entry.is_a?(Hash) && entry.key?(key)
        entry.fetch(key)
      end

      # Walks the evidence cell in order: a backticked class name opens a
      # group and every quoted test name after it belongs to that group.
      def parse_evidence(cell)
        evidence = Hash.new { |hash, key| hash[key] = [] }
        current = nil

        cell.scan(EVIDENCE_PATTERN) do |class_name, test_name|
          if class_name
            current = class_name
            evidence[current]
          elsif current
            evidence[current] << test_name
          end
        end

        evidence
      end

      def expect_contiguous!(ids, label)
        numbers = ids.map { |id| row_number(id) }
        fail!("#{label} has no rows") if numbers.empty?
        expected = (1..numbers.max).to_a
        fail!("#{label} rows must run P1-P#{numbers.max} without gaps, got #{ids.join(', ')}") unless numbers == expected
      end

      def row_number(id)
        id.to_s.match(ROW_ID)&.captures&.first.to_i
      end

      def fail!(message)
        raise Error, message
      end
  end
end
