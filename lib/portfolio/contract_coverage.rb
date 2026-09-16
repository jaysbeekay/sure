# frozen_string_literal: true

require "yaml"
require "ripper"

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

    # The names of the tests `class_name` declares directly in its own body, or
    # nil when the source does not parse.
    #
    # A singleton because Portfolio::ReturnsContractCoverage reads a contract in
    # a different row format but must answer "does this test exist?" the same
    # way. One implementation only: a second, regex-based one would reintroduce
    # the holes closed below.
    #
    # A plain substring search accepted a name that appeared anywhere in the
    # file, including a comment, a string or a heredoc (#133). A token scan of a
    # text slice closed that, but still accepted a `test` call inside a helper
    # method, a branch that never runs, a block, or an indented nested or
    # sibling class, because neither the slice nor the tokens know what belongs
    # to the class or runs (#152). Walking the parse tree answers both: a
    # comment is not in the tree, a heredoc is a string, and only statements
    # directly in a matching class's body are read.
    def self.declared_tests(source, class_name)
      tree = Ripper.sexp(source)
      return if tree.nil?

      class_nodes(tree, class_name).flat_map do |(_, _, _, bodystmt)|
        Array(bodystmt[1]).filter_map { |statement| declared_test_name(statement) }
      end
    end

    # Every `class` node whose full lexical path reads exactly `class_name`,
    # including a body reopened later in the file, which Minitest adds to.
    #
    # The path is the enclosing `module` and `class` names joined to the node's
    # own constant path, because that is the constant Ruby defines. Matching on
    # the node's own name alone let a cited top-level `FooTest` be answered by a
    # `FooTest` declared inside any module, which is a different class and a
    # false positive of exactly the kind this check exists to reject.
    #
    # Only a declaration that is a statement of the program, or of a lexical
    # class or module body, is read. Recursing into every child instead let a
    # `class ShapeTest` under `if false`, or inside a block, answer a citation
    # even though nothing defines that class at load time -- the same hole the
    # `test` call itself was closed against above, one level up.
    def self.class_nodes(node, class_name, namespace = nil)
      lexical_statements(node).flat_map do |statement|
        next [] unless statement.is_a?(Array)
        next [] unless statement[0] == :class || statement[0] == :module

        own = constant_path(statement[1])
        next [] if own.nil?

        path = own.start_with?("::") ? own.delete_prefix("::") : [ namespace, own ].compact.join("::")
        matches = statement[0] == :class && path == class_name ? [ statement ] : []
        matches + class_nodes(statement, class_name, path)
      end
    end

    # The statements a program, class or module body holds directly. A
    # `bodystmt` is [:bodystmt, statements, rescue, else, ensure]; only the
    # statements are lexical children of the declaration.
    def self.lexical_statements(node)
      return [] unless node.is_a?(Array)

      body =
        case node[0]
        when :program then node[1]
        when :class   then node[3]
        when :module  then node[2]
        end

      return Array(body) if node[0] == :program
      return [] unless body.is_a?(Array) && body[0] == :bodystmt

      Array(body[1])
    end

    def self.constant_path(node)
      return unless node.is_a?(Array)

      case node[0]
      when :const_ref, :var_ref then node[1][1]
      # `class ::Foo` is the TOP-LEVEL Foo whatever encloses it, so the root
      # qualifier is carried here and consumed in class_nodes rather than
      # dropped, which would read it as a constant of the enclosing module.
      when :top_const_ref then "::#{node[1][1]}"
      when :const_path_ref then [ constant_path(node[1]), node[2][1] ].join("::")
      end
    end

    # `test "name"`, with or without a block, called without a receiver and with
    # a plain string literal as its first argument. `something.test "name"` is a
    # :command_call and an interpolated name has no single string part, so
    # neither matches.
    def self.declared_test_name(statement)
      command = statement[0] == :method_add_block ? statement[1] : statement
      return unless command.is_a?(Array) && command[0] == :command

      _, method, args = command
      return unless method.is_a?(Array) && method[0] == :@ident && method[1] == "test"

      args = args[1] if args.is_a?(Array) && args[0] == :args_add_block
      literal = Array(args).first
      return unless literal.is_a?(Array) && literal[0] == :string_literal

      _, (content_type, *parts) = literal
      return unless content_type == :string_content && parts.size == 1 && parts.first[0] == :@tstring_content

      parts.first[1]
    end

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
        fail!("#{id}: #{class_name} is not declared in #{relative_path}") unless declared_textually?(source, class_name)

        tests = Array(fetch!(entry, "tests", id))
        fail!("#{id}: #{class_name} lists no tests") if tests.empty?

        # Only a test the named class declares directly in its own body counts,
        # so a test in a second class, a helper method or a branch cannot stand
        # in as evidence for this one.
        declared = self.class.declared_tests(source, class_name)
        fail!("#{id}: #{relative_path} could not be parsed") if declared.nil?

        tests.each do |name|
          next if declared.include?(name)

          fail!("#{id}: missing test #{name.inspect} in #{class_name} (#{relative_path})")
        end
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

      # A cheap "is this class even in the file" gate before the parse. Both
      # spellings count: `class Foo <` and the root-qualified `class ::Foo <`,
      # which declares the same constant.
      def declared_textually?(source, class_name)
        source.include?("class #{class_name} <") || source.include?("class ::#{class_name} <")
      end

      def fail!(message)
        raise Error, message
      end
  end
end
