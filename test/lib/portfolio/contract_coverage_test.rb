require "test_helper"

class Portfolio::ContractCoverageTest < ActiveSupport::TestCase
  setup do
    @dir = Dir.mktmpdir
    @test_file = "test/models/portfolio/flow_classifier_test.rb"
    write_contract(<<~MD)
      | ID | Decision | Demonstrating test | Resolves |
      | --- | --- | --- | --- |
      | P1 | first | `Portfolio::FlowClassifierTest` "a Dividend income trade is income" | - |
      | P2 | second | `Portfolio::FlowClassifierTest` "every activity label has a rule" | - |
    MD
    write_manifest(
      "P1" => [ entry("a Dividend income trade is income") ],
      "P2" => [ entry("every activity label has a rule") ]
    )
  end

  teardown do
    FileUtils.remove_entry(@dir)
  end

  test "the committed contract and manifest verify" do
    count = Portfolio::ContractCoverage.new(
      contract_path: Rails.root.join("docs/portfolio/methodology.md"),
      manifest_path: Rails.root.join("config/portfolio_contract_tests.yml")
    ).verify!

    assert_operator count, :>=, 20
  end

  test "verifies a contract whose rows all name existing tests" do
    assert_equal 2, coverage.verify!
  end

  test "fails when a row names a test that does not exist" do
    # Document and manifest agree, so the earlier cross-check passes and the
    # failure is the one this test is about: the named test is in neither.
    write_contract(<<~MD)
      | P1 | first | `Portfolio::FlowClassifierTest` "a Dividend income trade is income" | - |
      | P2 | second | `Portfolio::FlowClassifierTest` "a test that was renamed" | - |
    MD
    write_manifest("P1" => [ entry("a Dividend income trade is income") ], "P2" => [ entry("a test that was renamed") ])

    error = assert_raises(Portfolio::ContractCoverage::Error) { coverage.verify! }
    assert_match(/P2: missing test "a test that was renamed"/, error.message)
  end

  test "fails when the document and the manifest disagree on the test class" do
    write_manifest(
      "P1" => [ entry("a Dividend income trade is income") ],
      "P2" => [ entry("every activity label has a rule", class_name: "Portfolio::OtherTest") ]
    )

    error = assert_raises(Portfolio::ContractCoverage::Error) { coverage.verify! }
    assert_match(/P2: contract names Portfolio::FlowClassifierTest, manifest names Portfolio::OtherTest/, error.message)
  end

  test "fails when the rows do not run P1..Pn without gaps" do
    write_contract(<<~MD)
      | P1 | first | `Portfolio::FlowClassifierTest` "a Dividend income trade is income" | - |
      | P3 | third | `Portfolio::FlowClassifierTest` "every activity label has a rule" | - |
    MD
    write_manifest("P1" => [ entry("a Dividend income trade is income") ], "P3" => [ entry("every activity label has a rule") ])

    error = assert_raises(Portfolio::ContractCoverage::Error) { coverage.verify! }
    assert_match(/contract rows must run P1-P3 without gaps/, error.message)
  end

  test "fails when the document cites a test the manifest does not name" do
    write_contract(<<~MD)
      | P1 | first | `Portfolio::FlowClassifierTest` "a test nobody wrote" | - |
    MD
    write_manifest("P1" => [ entry("a Dividend income trade is income") ])

    error = assert_raises(Portfolio::ContractCoverage::Error) { coverage.verify! }
    assert_match(/P1: Portfolio::FlowClassifierTest/, error.message)
    assert_match(/document cites "a test nobody wrote"/, error.message)
  end

  test "fails when the document omits a test the manifest names" do
    write_contract(<<~MD)
      | P1 | first | `Portfolio::FlowClassifierTest` "a Dividend income trade is income" | - |
    MD
    write_manifest("P1" => [ entry("a Dividend income trade is income", "every activity label has a rule") ])

    error = assert_raises(Portfolio::ContractCoverage::Error) { coverage.verify! }
    assert_match(/document does not cite "every activity label has a rule"/, error.message)
  end

  test "fails when the named test lives in a different class in the same file" do
    File.write(File.join(@dir, "two_classes_test.rb"), <<~RUBY)
      class AlphaTest < ActiveSupport::TestCase
        test "belongs to alpha" do
        end
      end

      class BetaTest < ActiveSupport::TestCase
        test "belongs to beta" do
        end
      end
    RUBY
    write_contract(<<~MD)
      | P1 | first | `AlphaTest` "belongs to beta" | - |
    MD
    write_manifest("P1" => [ { "file" => "two_classes_test.rb", "class" => "AlphaTest", "tests" => [ "belongs to beta" ] } ])

    error = assert_raises(Portfolio::ContractCoverage::Error) do
      Portfolio::ContractCoverage.new(
        contract_path: File.join(@dir, "methodology.md"),
        manifest_path: File.join(@dir, "manifest.yml"),
        root: @dir
      ).verify!
    end
    assert_match(/missing test "belongs to beta" in AlphaTest/, error.message)
  end

  # The gate's whole job is to prove a cited test still runs. A substring
  # search over the source accepted a name that had survived only in prose, so
  # a deleted test could keep verifying. Each non-executable shape gets its own
  # case, and the genuine declaration is asserted too, so the check cannot pass
  # by having simply become stricter than the evidence it must accept.
  test "a test name that survives only in a comment is not evidence" do
    write_prose_contract("only in a comment")

    error = assert_raises(Portfolio::ContractCoverage::Error) { rooted_coverage.verify! }
    assert_match(/missing test "only in a comment" in ProseTest/, error.message)
  end

  test "a test name that survives only in a heredoc is not evidence" do
    write_prose_contract("only in a heredoc")

    error = assert_raises(Portfolio::ContractCoverage::Error) { rooted_coverage.verify! }
    assert_match(/missing test "only in a heredoc" in ProseTest/, error.message)
  end

  test "a declaration beside that prose is still evidence" do
    write_prose_contract("really declared")

    assert_equal 1, rooted_coverage.verify!
  end

  test "a manifest entry missing a required key is a contract error, not a KeyError" do
    write_contract(<<~MD)
      | P1 | first | `Portfolio::FlowClassifierTest` "a Dividend income trade is income" | - |
    MD
    write_manifest("P1" => [ { "class" => "Portfolio::FlowClassifierTest" } ])

    error = assert_raises(Portfolio::ContractCoverage::Error) { coverage.verify! }
    assert_match(/manifest entry has no "tests"/, error.message)
  end

  test "fails when a row is duplicated in the document" do
    write_contract(<<~MD)
      | P1 | first | `Portfolio::FlowClassifierTest` "a Dividend income trade is income" | - |
      | P1 | again | `Portfolio::FlowClassifierTest` "every activity label has a rule" | - |
    MD

    error = assert_raises(Portfolio::ContractCoverage::Error) { coverage.verify! }
    assert_match(/duplicate contract rows: P1/, error.message)
  end

  test "fails when a row names a test class that is not declared in the file" do
    write_contract(<<~MD)
      | P1 | first | `Portfolio::MissingTest` "a Dividend income trade is income" | - |
    MD
    write_manifest("P1" => [ entry("a Dividend income trade is income", class_name: "Portfolio::MissingTest") ])

    error = assert_raises(Portfolio::ContractCoverage::Error) { coverage.verify! }
    assert_match(/P1: Portfolio::MissingTest is not declared/, error.message)
  end

  # #152: only a `test` the named class declares directly in its own body is
  # evidence. Every shape below reads as a declaration to a token scan of a text
  # slice, and none of them defines a test on the named class.
  test "a test call inside a helper method is not evidence" do
    coverage = shape_coverage(<<~RUBY, "inside a helper")
      class ShapeTest < ActiveSupport::TestCase
        def helper
          test "inside a helper"
        end
      end
    RUBY

    error = assert_raises(Portfolio::ContractCoverage::Error) { coverage.verify! }
    assert_match(/missing test "inside a helper" in ShapeTest/, error.message)
  end

  test "a test call inside a branch that never runs is not evidence" do
    coverage = shape_coverage(<<~RUBY, "inside if false")
      class ShapeTest < ActiveSupport::TestCase
        if false
          test "inside if false"
        end
      end
    RUBY

    error = assert_raises(Portfolio::ContractCoverage::Error) { coverage.verify! }
    assert_match(/missing test "inside if false" in ShapeTest/, error.message)
  end

  test "a test in an indented nested class is not evidence for the outer class" do
    coverage = shape_coverage(<<~RUBY, "in the nested class")
      class ShapeTest < ActiveSupport::TestCase
        class NestedTest < ActiveSupport::TestCase
          test "in the nested class"
        end
      end
    RUBY

    error = assert_raises(Portfolio::ContractCoverage::Error) { coverage.verify! }
    assert_match(/missing test "in the nested class" in ShapeTest/, error.message)
  end

  # The cited ShapeTest is the top-level one, so its own declaration verifies
  # and the rejections below are exclusions, not a missing class. A class
  # matches on its full lexical path: `module Wrapper; class ShapeTest` is
  # Wrapper::ShapeTest and is not the cited ShapeTest, so neither it nor its
  # sibling can stand in as evidence.
  test "a test in an indented sibling class is not evidence" do
    source = <<~RUBY
      class ShapeTest < ActiveSupport::TestCase
        test "direct in ShapeTest"
      end

      module Wrapper
        class ShapeTest < ActiveSupport::TestCase
          test "in the namespaced twin"
        end

        class SiblingTest < ActiveSupport::TestCase
          test "in the sibling"
        end
      end
    RUBY

    assert_equal 1, shape_coverage(source, "direct in ShapeTest").verify!

    error = assert_raises(Portfolio::ContractCoverage::Error) { shape_coverage(source, "in the sibling").verify! }
    assert_match(/missing test "in the sibling" in ShapeTest/, error.message)

    error = assert_raises(Portfolio::ContractCoverage::Error) { shape_coverage(source, "in the namespaced twin").verify! }
    assert_match(/missing test "in the namespaced twin" in ShapeTest/, error.message)
  end

  # A class is matched on its full lexical path, so a cited top-level name
  # cannot be satisfied by a same-named class nested inside anything else.
  # Without this the enclosing scope was ignored: `module Wrapper; class
  # ShapeTest` read as ShapeTest and answered for the cited top-level class.
  # Both nesting forms are asserted because each extends the path separately.
  test "a test in a nested class of the same name is not evidence" do
    source = <<~RUBY
      class ShapeTest < ActiveSupport::TestCase
      end

      module Wrapper
        class ShapeTest < ActiveSupport::TestCase
          test "declared inside Wrapper"
        end
      end

      class OuterTest < ActiveSupport::TestCase
        class ShapeTest < ActiveSupport::TestCase
          test "declared inside OuterTest"
        end
      end
    RUBY

    error = assert_raises(Portfolio::ContractCoverage::Error) { shape_coverage(source, "declared inside Wrapper").verify! }
    assert_match(/missing test "declared inside Wrapper" in ShapeTest/, error.message)

    error = assert_raises(Portfolio::ContractCoverage::Error) { shape_coverage(source, "declared inside OuterTest").verify! }
    assert_match(/missing test "declared inside OuterTest" in ShapeTest/, error.message)
  end

  # Decided in #152's triage plan: a contract row cites a literal declaration a
  # reader can find, so a generated test is not evidence even though it runs.
  test "a test generated inside a block is not evidence" do
    coverage = shape_coverage(<<~RUBY, "generated")
      class ShapeTest < ActiveSupport::TestCase
        [ 1 ].each do |_n|
          test "generated" do
          end
        end
      end
    RUBY

    error = assert_raises(Portfolio::ContractCoverage::Error) { coverage.verify! }
    assert_match(/missing test "generated" in ShapeTest/, error.message)
  end

  # The three tests above put the `test` call in a place that does not
  # necessarily run. These two put the *class declaration* there instead: the
  # cited class is only ever declared under a dead branch or inside a block, so
  # at load time no ShapeTest exists to hold the test that is cited.
  test "a class declared in a branch that never runs is not evidence" do
    coverage = shape_coverage(<<~RUBY, "inside a dead class")
      if false
        class ShapeTest < ActiveSupport::TestCase
          test "inside a dead class" do
          end
        end
      end
    RUBY

    error = assert_raises(Portfolio::ContractCoverage::Error) { coverage.verify! }
    assert_match(/missing test "inside a dead class" in ShapeTest/, error.message)
  end

  test "a class declared inside a block is not evidence" do
    coverage = shape_coverage(<<~RUBY, "inside a generated class")
      [ 1 ].each do |_n|
        class ShapeTest < ActiveSupport::TestCase
          test "inside a generated class" do
          end
        end
      end
    RUBY

    error = assert_raises(Portfolio::ContractCoverage::Error) { coverage.verify! }
    assert_match(/missing test "inside a generated class" in ShapeTest/, error.message)
  end

  test "a test file that does not parse is a contract error" do
    coverage = shape_coverage(<<~RUBY, "declared before the syntax error")
      class ShapeTest < ActiveSupport::TestCase
        test "declared before the syntax error" do
        end

        def broken(
      end
    RUBY

    error = assert_raises(Portfolio::ContractCoverage::Error) { coverage.verify! }
    assert_match(/P1: shape_test.rb could not be parsed/, error.message)
  end

  test "a test call on a receiver is not evidence" do
    coverage = shape_coverage(<<~RUBY, "on a receiver")
      class ShapeTest < ActiveSupport::TestCase
        helper.test "on a receiver"
      end
    RUBY

    error = assert_raises(Portfolio::ContractCoverage::Error) { coverage.verify! }
    assert_match(/missing test "on a receiver" in ShapeTest/, error.message)
  end

  test "a declaration in a reopened body of the named class is evidence" do
    coverage = shape_coverage(<<~RUBY, "in the second body")
      class ShapeTest < ActiveSupport::TestCase
        test "in the first body" do
        end
      end

      class ShapeTest < ActiveSupport::TestCase
        test "in the second body" do
        end
      end
    RUBY

    assert_equal 1, coverage.verify!
  end

  test "the returns gate accepts a direct declaration in a compact namespaced class" do
    write_returns_test_file(<<~RUBY)
      class Portfolio::DailyReturnsTest < ActiveSupport::TestCase
        test "declared directly" do
        end
      end
    RUBY

    assert_equal Portfolio::ReturnsContractCoverage::EXPECTED_ROWS,
      returns_coverage("Portfolio::DailyReturnsTest#test_declared_directly").verify!
  end

  test "the returns gate rejects a test call inside a helper method" do
    write_returns_test_file(<<~RUBY)
      class Portfolio::DailyReturnsTest < ActiveSupport::TestCase
        def helper
          test "inside a helper"
        end
      end
    RUBY

    error = assert_raises(Portfolio::ContractCoverage::Error) do
      returns_coverage("Portfolio::DailyReturnsTest#test_inside_a_helper").verify!
    end
    assert_match(/R1: .* declares no test "test_inside_a_helper"/, error.message)
  end

  # The textual precondition only proves `class Portfolio::DailyReturnsTest <`
  # appears somewhere; the declaration must still be in that class, not in a
  # same-named class in another namespace later in the file.
  test "the returns gate ignores a same-named class in another namespace" do
    write_returns_test_file(<<~RUBY)
      class Portfolio::DailyReturnsTest < ActiveSupport::TestCase
      end

      module Other
        class DailyReturnsTest < ActiveSupport::TestCase
          test "declared elsewhere" do
          end
        end
      end
    RUBY

    error = assert_raises(Portfolio::ContractCoverage::Error) do
      returns_coverage("Portfolio::DailyReturnsTest#test_declared_elsewhere").verify!
    end
    assert_match(/R1: .* declares no test "test_declared_elsewhere"/, error.message)
  end

  test "the returns gate reports a test file that does not parse as a contract error" do
    write_returns_test_file(<<~RUBY)
      class Portfolio::DailyReturnsTest < ActiveSupport::TestCase
        test "declared before the syntax error" do
        end

        def broken(
      end
    RUBY

    error = assert_raises(Portfolio::ContractCoverage::Error) do
      returns_coverage("Portfolio::DailyReturnsTest#test_declared_before_the_syntax_error").verify!
    end
    assert_match(%r{R1: test/models/portfolio/daily_returns_test.rb could not be parsed}, error.message)
  end

  test "the returns gate still requires the class to be declared as it is cited" do
    write_returns_test_file(<<~RUBY)
      module Portfolio
        class DailyReturnsTest < ActiveSupport::TestCase
          test "declared directly" do
          end
        end
      end
    RUBY

    error = assert_raises(Portfolio::ContractCoverage::Error) do
      returns_coverage("Portfolio::DailyReturnsTest#test_declared_directly").verify!
    end
    assert_match(/R1: Portfolio::DailyReturnsTest is not declared/, error.message)
  end

  private
    # Writes a one-class test file and a single-row contract and manifest citing
    # `name` in ShapeTest, so a failure can only come from the declaration check.
    def shape_coverage(source, name)
      File.write(File.join(@dir, "shape_test.rb"), source)
      write_contract("| P1 | first | `ShapeTest` \"#{name}\" | - |\n")
      write_manifest("P1" => [ { "file" => "shape_test.rb", "class" => "ShapeTest", "tests" => [ name ] } ])
      rooted_coverage
    end

    def write_returns_test_file(source)
      path = File.join(@dir, "test/models/portfolio/daily_returns_test.rb")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, source)
    end

    # A returns contract whose every row cites `reference`, resolved against
    # the temporary directory.
    def returns_coverage(reference)
      rows = (1..Portfolio::ReturnsContractCoverage::EXPECTED_ROWS).map { |n| "| R#{n} | decision | `#{reference}` |" }
      File.write(File.join(@dir, "returns-contract.md"), rows.join("\n") + "\n")
      Portfolio::ReturnsContractCoverage.new(contract_path: File.join(@dir, "returns-contract.md"), root: @dir)
    end

    def coverage
      Portfolio::ContractCoverage.new(
        contract_path: File.join(@dir, "methodology.md"),
        manifest_path: File.join(@dir, "manifest.yml")
      )
    end

    def entry(*tests, class_name: "Portfolio::FlowClassifierTest")
      { "file" => @test_file, "class" => class_name, "tests" => tests }
    end

    # One class whose only executable declaration is "really declared"; the two
    # other names appear solely in a comment and a heredoc.
    def write_prose_test_file
      File.write(File.join(@dir, "prose_test.rb"), <<~'RUBY')
        class ProseTest < ActiveSupport::TestCase
          # Deleted for now: test "only in a comment" do
          def fixture
            <<~SQL
              test "only in a heredoc" do
            SQL
          end

          test "really declared" do
          end
        end
      RUBY
    end

    # Points the single contract row and the manifest at the same name, so a
    # failure can only come from the declaration check.
    def write_prose_contract(name)
      write_prose_test_file
      write_contract("| P1 | first | `ProseTest` \"#{name}\" | - |\n")
      write_manifest("P1" => [ { "file" => "prose_test.rb", "class" => "ProseTest", "tests" => [ name ] } ])
    end

    # Resolves test files against the temporary directory rather than the app.
    def rooted_coverage
      Portfolio::ContractCoverage.new(
        contract_path: File.join(@dir, "methodology.md"),
        manifest_path: File.join(@dir, "manifest.yml"),
        root: @dir
      )
    end

    def write_contract(body)
      File.write(File.join(@dir, "methodology.md"), body)
    end

    def write_manifest(rows)
      File.write(File.join(@dir, "manifest.yml"), rows.to_yaml)
    end
end

# Two shapes the gate already handles correctly, asserted here rather than left
# as silent assumptions in `constant_path` and `declared_test_name`. Both read
# the singleton directly: the contract fixtures cite one fixed class name, and
# what is under test here is the name matching itself.
class Portfolio::ContractCoverageShapeTest < ActiveSupport::TestCase
  # `constant_path` recurses through `const_path_ref`, so a head of three
  # constants reads as its whole path. A suffix of that path is a different
  # class and must not match it.
  test "a class head of three constants is matched only by its whole path" do
    source = <<~RUBY
      class A::B::C < ActiveSupport::TestCase
        test "deep"
      end
    RUBY

    assert_equal [ "deep" ], Portfolio::ContractCoverage.declared_tests(source, "A::B::C")
    assert_empty Portfolio::ContractCoverage.declared_tests(source, "B::C")
    assert_empty Portfolio::ContractCoverage.declared_tests(source, "C")
  end

  # The receiver exclusion holds whether or not the call carries a block:
  # `helper.test "x"` parses as a `:command_call`, and with a block as a
  # `:method_add_block` wrapping one. Neither is a declaration on the class.
  test "a test call on a receiver is not evidence even when it carries a block" do
    source = <<~RUBY
      class ShapeTest < ActiveSupport::TestCase
        helper.test "receiver with a block" do
        end
      end
    RUBY

    assert_empty Portfolio::ContractCoverage.declared_tests(source, "ShapeTest")
  end
end
